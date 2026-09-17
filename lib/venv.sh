# ------------------------------------------------------------
# lib/venv.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines functions only, runs nothing.
# ------------------------------------------------------------

# ─────────────────────────────────────────────────────────────
# cmake floor - GLOBAL, because apt's cmake cannot build ANY of these
# ─────────────────────────────────────────────────────────────
#
# Ubuntu 20.04 ships cmake 3.16.3 and every target here wants more than that.
# Read from the upstream sources rather than assumed:
#
#   llama.cpp  ggml/src/ggml-cuda  3.18   (for CMAKE_CUDA_ARCHITECTURES)
#   pytorch    v2.1.0              3.18   FATAL_ERROR
#   vision     v0.16.0             3.18
#   bitsandbytes 0.45.5            3.22.1
#
# The llama one is the trap: its ROOT CMakeLists says 3.14, so configure gets
# all the way through CPU feature detection looking healthy and then dies on
# the CUDA subdirectory - which reads as a CUDA problem and is not one.
#
# THIS USED TO BE SCOPED TO THE BITSANDBYTES PHASE, on the reasoning that
# swapping the toolchain under a working pytorch build was a bad trade. That
# reasoning rested on apt's cmake being good enough for the other three, which
# was an assumption and is false - at 3.16.3 none of them configure at all.
#
# The pip wheel goes to ~/.local/bin, which the PATH export above already puts
# FIRST, so it wins for every phase without anything else being rewired. The
# system cmake stays installed for whatever else on the box expects it.
ensure_cmake() {
    local need="$1" have
    have="$(cmake --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
    if [ -n "$have" ] && [ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -1)" = "$need" ]; then
        log "cmake:       $have (>= $need required)"
        return 0
    fi
    warn "cmake ${have:-not found} is below the $need these builds require"
    # PINNED BELOW 4. `cmake>=3.22.1` alone resolves to 4.x, and CMake 4 removed
    # support for cmake_minimum_required(<3.5) - which is how you turn a version
    # problem into a different version problem. 3.31.x clears every floor above.
    "$PYBIN" -m pip install "cmake>=${need},<4" \
        || fail "could not install a new enough cmake (need >= $need)"
    hash -r
    have="$(cmake --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
    [ -n "$have" ] && [ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -1)" = "$need" ] \
        || fail "installed a pip cmake but '$(command -v cmake || echo none)' still reports '${have:-nothing}'.
  The active venv's bin/ must come first on PATH for this to take effect."
    log "cmake:       $have from $(command -v cmake)"
}

use_venv() {
    local name="$1" cmake_floor="${2:-}" venv="$VENV_ROOT/$1"
    if [ ! -x "$venv/bin/python" ]; then
        log "venv: creating '$name' at $venv"
        mkdir -p "$VENV_ROOT"
        "$HOST_PYBIN" -m venv "$venv" || fail "could not create a venv with $HOST_PYBIN.
  On Debian/Ubuntu this needs the venv module:
     sudo apt install python3-venv
  or, for this platform's baseline series:
     sudo apt install python${PYTHON_VERSION%.*}-venv"
        "$venv/bin/python" -m pip install -q --upgrade pip wheel \
            || warn "could not upgrade pip inside '$name' - continuing"
        $DO_VERIFY || echo "venv     ${name}  $venv (from $HOST_PYBIN)" >> "$PROVENANCE"
    fi
    PYBIN="$venv/bin/python"
    export VIRTUAL_ENV="$venv"
    export PATH="$venv/bin:$SEREN_BASE_PATH"
    hash -r
    log "venv: '$name' -> $("$PYBIN" --version 2>&1)"

    # ── setuptools IS A PINNED DEPENDENCY, and pretending otherwise cost a build ──
    #
    # This used to be `pip install --upgrade pip setuptools wheel`: chase
    # whatever setuptools exists today, in an archive whose entire purpose is
    # that nothing else is allowed to drift. setuptools 81 removed
    # pkg_resources and 82 finished the job, so on the Xavier:
    #
    #   File "/mnt/nvme/torchvision/setup.py", line 10, in <module>
    #     from pkg_resources import DistributionNotFound, get_distribution, parse_version
    #   ModuleNotFoundError: No module named 'pkg_resources'
    #
    # torchvision 0.16.0 is from 2023 and its setup.py is allowed to use the
    # interface that existed in 2023. The thing that changed was a package this
    # script chose to fetch unpinned, in an otherwise fully pinned build.
    #
    # NOT AN ECCENTRIC CEILING: vLLM 0.26.0 - current, actively maintained -
    # declares `setuptools>=77.0.3,<81.0.0` in its own build requires. Upstream
    # caps it in the same place and for the same reason.
    #
    # ENFORCED ON EVERY CALL, not just at creation. The block above only runs
    # when the venv does not exist yet, so a box that already has a torchvision
    # venv from an earlier run would never see the fix. This is idempotent and
    # a no-op once satisfied, which is worth two seconds a phase.
    "$PYBIN" -m pip install -q "setuptools${SEREN_SETUPTOOLS_MAX:-<81}" \
        || warn "  could not pin setuptools in '$name' - builds using pkg_resources may fail"
    # cmake goes IN the venv, so the version a phase needs is the version that
    # phase gets, and no phase can raise or lower it for any other.
    [ -n "$cmake_floor" ] && ensure_cmake "$cmake_floor"
    # Explicit, and load-bearing: the test above is the last command and it is
    # false for every phase that does not compile. Without this the function
    # returns 1 and `set -e` kills the run.
    return 0
}

ensure_torch() {
    local want="$1" have w
    have="$("$PYBIN" -c 'import torch; print(torch.__version__)' 2>/dev/null || true)"
    if [ -n "$have" ] && { [ -z "$want" ] || [ "${have%%+*}" = "$want" ]; }; then
        log "  torch $have already present in this venv"
        return 0
    fi
    [ -n "$have" ] && warn "  this venv has torch $have but $want is wanted - replacing it"
    for w in "$SEREN_TORCH_WHEEL" \
             "$PLATFORM_DIR"/torch-"${want}"*"${PYTAG}"*.whl \
             "$PLATFORM_DIR"/vendor/torch-"${want}"*"${PYTAG}"*.whl; do
        [ -n "$w" ] && [ -f "$w" ] || continue
        # THE CANDIDATE HAS TO BE THE VERSION THAT WAS ASKED FOR, and the first
        # entry in that list is the reason this check exists: $SEREN_TORCH_WHEEL
        # is whatever the pytorch phase last built, which is NOT necessarily
        # what vLLM pinned. Without this, asking for 2.8.0 installs 2.11.0
        # without comment - a shared-venv bug reproduced faithfully inside the
        # thing that replaced shared venvs. The globs already encode $want;
        # this makes the hand-off do the same.
        case "$(basename "$w")" in
            torch-"${want}"[-+]*) ;;
            *) continue ;;
        esac
        log "  installing $(basename "$w") into this venv"
        if "$PYBIN" -m pip install -q "$w"; then
            _torch_is "$want" && return 0
        fi
        warn "  that wheel did not leave torch $want importable - next candidate"
    done
    warn "  no local torch $want wheel found; asking the index (the fallback,"
    warn "  not the plan - an index wheel is not built for sm_${CUDA_ARCH})"
    if "$PYBIN" -m pip install -q "torch==${want}" 2>/dev/null; then
        _torch_is "$want" && return 0
    fi
    return 1
}

# VERIFIED, NOT ASSUMED - the same rule the bitsandbytes phase applies to its
# cubins. A pip install that exits 0 is not proof that the interpreter now
# imports the version you wanted.
_torch_is() {
    local want="$1" have
    have="$("$PYBIN" -c 'import torch; print(torch.__version__)' 2>/dev/null || true)"
    [ -n "$have" ] && [ "${have%%+*}" = "$want" ] || return 1
    log "  torch $have active in this venv"
    return 0
}

# ═════════════════════════════════════════════════════════════
# [build-system] requires - the step `setup.py bdist_wheel` skips
# ═════════════════════════════════════════════════════════════
#
# EVERY PHASE HERE BUILDS WHEELS THE LEGACY WAY, and that is deliberate: a PEP
# 517 build creates its own isolated environment and would fetch its own torch
# from an index, discarding the sm_XX wheel this archive just spent hours
# compiling. `setup.py bdist_wheel` builds in THIS venv, against THAT torch.
#
# The cost of that choice is the whole of PEP 517's dependency step. Nothing
# reads [build-system] requires, so nothing installs it, and the failure lands
# wherever the missing package is first touched - somewhere that does not
# mention packaging at all. It has now done so twice, differently:
#
#   vllm 0.26.0      ModuleNotFoundError: No module named 'setuptools_rust'
#   bitsandbytes     a wheel called UNKNOWN-0.50.2+sm87-....whl
#
# The second one is the instructive one. bitsandbytes' pyproject.toml carries
# `[project] name = "bitsandbytes"` and requires trove-classifiers and
# setuptools>=77 to read that table. Without them setuptools never applied
# [project] at all, so the package NAME was never picked up - it compiled
# perfectly, stamped the version correctly, and wrote it under the placeholder
# name setuptools uses when it knows nothing. The build did not fail; it
# succeeded at building the wrong thing, and only the `ls dist/bitsandbytes-*`
# glob downstream noticed.
#
# So this does the step by hand: read the section, install it here.
#
# Excludes are passed by the caller and are not an optimisation - see the torch
# note at each call site.
install_build_requires() {
    local label="$1"; shift
    local excl=("$@")

    [ -f pyproject.toml ] || return 1

    # tomllib IS NOT AVAILABLE EVERYWHERE, and assuming it was is what broke the
    # Orin. It landed in the stdlib in 3.11; jp5 and jp6 are both pinned to
    # python 3.10, so on two of the three boxes this import fails. The first
    # version of this swallowed that and wrote an empty list, which read
    # downstream as "upstream has no build requires" and killed the phase with a
    # confidently wrong diagnosis. tomli is the 3.10 backport of the same
    # parser, pure python and tiny.
    if ! "$PYBIN" -c 'import tomllib' 2>/dev/null \
       && ! "$PYBIN" -c 'import tomli' 2>/dev/null; then
        log "  this interpreter has no tomllib (needs 3.11+) - installing tomli to read pyproject.toml"
        "$PYBIN" -m pip install -q tomli \
            || fail "$label: cannot read pyproject.toml - no tomllib in this python and tomli would not install."
    fi

    local reqs; reqs="$(mktemp)"
    # Written to a requirements FILE rather than passed as arguments. A
    # requirement may contain spaces ("torch == 2.11.0" is one) and an
    # environment marker after a semicolon; xargs would split the first into
    # three broken arguments and dropping the second would install things meant
    # for a different python. pip reads this format natively.
    # "COULD NOT READ IT" AND "IT IS EMPTY" MUST NOT LOOK THE SAME. The first
    # version of this caught every exception and exited 0, so a parse failure
    # produced an empty list, which the caller then reported as "upstream has no
    # build requires" - a confident, wrong, and completely misleading answer.
    # A crash here is fatal and says so; only a genuinely absent or fully
    # excluded section returns 1.
    if ! "$PYBIN" - "$reqs" "${excl[@]}" <<'REQS'
import sys
try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib          # 3.10 and older; installed above
out_path = sys.argv[1]
excl = {e.replace("_", "-").strip().lower() for e in sys.argv[2:]}
with open("pyproject.toml", "rb") as fh:
    reqs = tomllib.load(fh).get("build-system", {}).get("requires", [])
keep = []
for r in reqs:
    bare = r.split(";")[0].replace("_", "-").split("[")[0]
    for op in ("===", "==", ">=", "<=", "~=", "!=", ">", "<", " "):
        bare = bare.split(op)[0]
    if bare.strip().lower() in excl:
        continue
    keep.append(r)                    # full line, markers and all
with open(out_path, "w") as fh:
    fh.write("\n".join(keep) + ("\n" if keep else ""))
REQS
    then
        rm -f "$reqs"
        fail "$label: could not read [build-system] requires from pyproject.toml - see the error above.
  That is not the same as upstream having none, and must not be reported as it."
    fi

    if [ ! -s "$reqs" ]; then
        rm -f "$reqs"
        return 1
    fi

    log "  $label build requires, from pyproject.toml${excl[*]:+ (excluding: ${excl[*]})}:"
    sed 's/^/        /' "$reqs"

    # THE setuptools CEILING SURVIVES THIS. bitsandbytes asks for
    # `setuptools >= 77.0.3` with no upper bound, and pip would happily resolve
    # that to 82+, which no longer ships pkg_resources - re-creating by the back
    # door the exact breakage use_venv pins against. A constraints file binds
    # the whole resolution without touching what upstream asked for.
    local cons; cons="$(mktemp)"
    echo "setuptools${SEREN_SETUPTOOLS_MAX:-<81}" > "$cons"

    # NOT masked. If these will not install the build cannot succeed, and pip's
    # error is the only thing that explains why.
    "$PYBIN" -m pip install -c "$cons" -r "$reqs" \
        || { rm -f "$reqs" "$cons"
             fail "$label: could not install its own [build-system] requires - see pip's output above"; }
    rm -f "$reqs" "$cons"
    return 0
}
