# ------------------------------------------------------------
# phases/pytorch.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines functions only, runs nothing.
# ------------------------------------------------------------

# ─────────────────────────────────────────────────────────────
# nvcc drops a `typename` that the source definitely has
# ─────────────────────────────────────────────────────────────
#
# CUDA 13.4 on the Spark, building torch 2.11.0:
#
#   aten/src/ATen/core/List_inl.h:201:49: error: need 'typename' before
#   'decltype (...)::difference_type' because '...' is a dependent scope
#     201 |   return {impl_->list.begin() +
#           static_cast<typename decltype(impl_->list)::difference_type>(pos)};
#
# gcc is demanding a `typename` that is RIGHT THERE on the line it printed, and
# its caret lands in the middle of that very token. Carets do not land
# mid-token on code the compiler actually parsed: gcc is quoting the file on
# disk while rejecting nvcc's re-emission of it. nvcc's frontend preprocesses
# and rewrites the translation unit before any host compiler sees it, and on
# 13.4 that rewrite loses the `typename`.
#
# CONFIRMED BY ELIMINATION, not by reading tea leaves: swapping the host
# compiler to g++-12 changed precisely nothing, which is only possible if the
# damage happens upstream of the host compiler.
#
# impl_->list is a std::vector<IValue>, so its difference_type IS
# std::ptrdiff_t. Naming the type directly is the identical type with no
# dependent scope left for nvcc to mangle. Idempotent, verified, and it reports
# anything else in the tree wearing the same shape - because if nvcc gets this
# construct wrong once, the next one is a landmine 2000 objects further in.
patch_pytorch_for_nvcc() {
    local f="aten/src/ATen/core/List_inl.h"
    if [ ! -f "$f" ]; then
        warn "pytorch: $f not found - upstream layout changed, skipping the nvcc patch"
    elif grep -q 'static_cast<std::ptrdiff_t>(pos)' "$f"; then
        log "List_inl.h: already patched for nvcc"
    elif ! grep -q 'static_cast<typename decltype(impl_->list)::difference_type>(pos)' "$f"; then
        log "List_inl.h: the nvcc-sensitive cast is not in this checkout - nothing to patch"
    else
        python3 - "$f" <<'LIST_PATCH'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = "static_cast<typename decltype(impl_->list)::difference_type>(pos)"
new = "static_cast<std::ptrdiff_t>(pos)"
n = s.count(old)
if n == 0:
    sys.exit("ANCHOR_MISS")
s = s.replace(old, new)
if "#include <cstddef>" not in s and "#pragma once" in s:
    s = s.replace("#pragma once",
                  "#pragma once\n#include <cstddef>  // std::ptrdiff_t [seren patch]", 1)
io.open(p, "w", encoding="utf-8").write(s)
print("[seren] List_inl.h: %d dependent-scope cast(s) -> std::ptrdiff_t" % n)
LIST_PATCH
        grep -q 'static_cast<std::ptrdiff_t>(pos)' "$f" \
            || fail "List_inl.h: the nvcc typename patch reported success but the file is unchanged"
        log "List_inl.h: patched for nvcc ✓"
    fi

    # ── the landmine the note above promised, 2000 objects later ──
    #
    # Object 2590/3431, Spark, torch 2.11.0, CUDA 13.4:
    #
    #   ForeachReduceOp.cu(470): error: type name is not allowed
    #   ForeachReduceOp.cu(470): error: expected an expression
    #
    # and the caret, out in the 2275th column of the expanded AT_DISPATCH line,
    # lands on `out_t` inside:
    #
    #   addr_struct.addresses[j] =
    #       vec_res[i * MAX_TENSORS_PER_KERNEL + j]
    #           .mutable_data_ptr<out_t>();
    #
    # "type name is not allowed" is the compiler saying it wanted an expression
    # and got a type. That only happens here if it parsed `mutable_data_ptr` as
    # a plain member and `<` as less-than, which means it did NOT know
    # mutable_data_ptr is a member template. It is - at::TensorBase declares
    # `template <typename T> T* mutable_data_ptr() const`.
    #
    # WHICH CALLS FAIL IS THE WHOLE TELL. Three lines up, in the same lambda,
    # under the same two nested dispatches, with the same kind of dependent
    # template argument:
    #
    #   output_per_tensor.mutable_data_ptr<out_opmath_t>()   <- compiles fine
    #
    # Same member, same file, same instantiation. The only thing that changes
    # is the object expression: a named Tensor works, a std::vector subscript
    # does not. So this is not the dispatch macros and not out_t - it is nvcc's
    # frontend losing the type of `vec_res[...]` on its way through, exactly
    # like it loses the `typename` in List_inl.h above. Same compiler, same
    # bug shape, same container: std::vector.
    #
    # So the same remedy applies - take the dependent scope away rather than
    # argue with the frontend. Binding the element to a named at::Tensor& makes
    # the object type concrete at the point of the call, and mutable_data_ptr
    # is unambiguously a template again. The reference is to the same object,
    # so this is a parse fix with no codegen consequence.
    #
    # IF THIS IS NOT ENOUGH, the next thing to try is the explicit
    # disambiguator - `.template mutable_data_ptr<out_t>()` - which is legal
    # C++11-and-later even on a non-dependent object. It is NOT done here as
    # well, because stacking two fixes for one error means that if the build
    # goes green you never learn which one was load-bearing, and this file
    # will not be the last place nvcc 13.4 does this.
    local fr="aten/src/ATen/native/cuda/ForeachReduceOp.cu"
    if [ ! -f "$fr" ]; then
        warn "pytorch: $fr not found - upstream layout changed, skipping the ForeachReduceOp patch"
    elif grep -q 'seren_res_j' "$fr"; then
        log "ForeachReduceOp.cu: already patched for nvcc"
    elif ! grep -qE 'mutable_data_ptr<[[:space:]]*out_t[[:space:]]*>' "$fr"; then
        # ── "THIS VERSION DOES NOT HAVE THE BUG" IS NOT "THE PATCH BROKE" ──
        #
        # This check was missing and it failed the Xavier. That box is pinned to
        # torch 2.1.0, whose ForeachReduceOp.cu has no out_t, no
        # AT_DISPATCH_OUT_DTYPES and no mutable_data_ptr<out_t> anywhere - the
        # out-dtype foreach norm work landed years later. There was nothing to
        # patch, which is the correct and expected outcome on that pin; the
        # anchor check reported ANCHOR_MISS and killed the phase anyway, so a
        # fix written for the Spark's 2.11.0 broke a build that was fine.
        #
        # The distinction the sibling patch above already makes: absent means
        # nothing to do, present-but-unrecognised means upstream moved it and
        # somebody has to look. The loose pattern here tolerates whitespace so
        # a reformat still counts as "present" and still fails loudly below,
        # rather than silently declining to patch a file that needs it.
        log "ForeachReduceOp.cu: the nvcc-sensitive call is not in this checkout - nothing to patch"
    else
        python3 - "$fr" <<'FOREACH_PATCH'
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
pat = re.compile(
    r"([ \t]*)addr_struct\.addresses\[j\]\s*=\s*"
    r"vec_res\[\s*i\s*\*\s*MAX_TENSORS_PER_KERNEL\s*\+\s*j\s*\]\s*"
    r"\.\s*mutable_data_ptr\s*<\s*out_t\s*>\s*\(\s*\)\s*;"
)
hits = pat.findall(s)
if len(hits) == 0:
    sys.exit("ANCHOR_MISS: no vec_res[...].mutable_data_ptr<out_t>() in this checkout")
if len(hits) > 1:
    sys.exit("ANCHOR_AMBIGUOUS: %d matches, expected 1 - upstream changed" % len(hits))
m = pat.search(s)
ind = m.group(1)
new = "\n".join([
    ind + "// [seren patch] nvcc 13.4 does not see mutable_data_ptr as a member",
    ind + "// template when the object is a std::vector subscript, and parses",
    ind + "// the '<' as less-than. Naming the element type makes it concrete.",
    ind + "at::Tensor& seren_res_j = vec_res[i * MAX_TENSORS_PER_KERNEL + j];",
    ind + "addr_struct.addresses[j] = seren_res_j.mutable_data_ptr<out_t>();",
])
s = pat.sub(lambda _m: new, s, count=1)
io.open(p, "w", encoding="utf-8").write(s)
print("[seren] ForeachReduceOp.cu: vector-subscript member-template call bound to a named Tensor&")
FOREACH_PATCH
        grep -q 'seren_res_j' "$fr" \
            || fail "ForeachReduceOp.cu: the nvcc member-template patch reported success but the file is unchanged"
        log "ForeachReduceOp.cu: patched for nvcc ✓"
    fi

    # The same construct elsewhere is the next failure, 2000 objects later.
    # Reported rather than blind-rewritten: difference_type is only ptrdiff_t
    # when the container is a vector, and guessing that for every hit would be
    # trading a build error for a silent one.
    local others
    others="$(grep -rl 'static_cast<typename decltype(' \
              --include='*.h' --include='*.hpp' --include='*.cu' --include='*.cpp' \
              aten c10 torch 2>/dev/null | grep -v 'List_inl.h' || true)"
    if [ -n "$others" ]; then
        warn "other files carry the same dependent-scope cast nvcc mangles:"
        echo "$others" | sed 's/^/        /' >&2
        warn "  If the build dies in one of those, the same std::ptrdiff_t swap applies"
        warn "  wherever the underlying container is a std::vector."
    fi
}

# ─────────────────────────────────────────────────────────────
# Which nvtx3 header this build compiles against
# ─────────────────────────────────────────────────────────────
#
# THE FLAG WAS SET FOR A VERSION NOTHING IS PINNED TO ANY MORE. `export
# USE_SYSTEM_NVTX=1` sat at the top of this phase with a comment about PyTorch
# 2.3.1's cuda.cmake hard-erroring on "Failed to find nvToolsExt". jp6 moved to
# 2.11.0 (for vLLM) and jp5 is on 2.1.0 - neither contains that FATAL_ERROR, and
# the log has been saying so on every run: "nvToolsExt fatal-check not present".
# The workaround outlived its reason and then caused a failure of its own:
#
#   torch/csrc/profiler/stubs/cuda.cpp:5:10: fatal error:
#     nvtx3/nvtx3.hpp: No such file or directory
#
# 2.11.0's cmake/Dependencies.cmake does this:
#
#   if(USE_SYSTEM_NVTX)
#     find_path(nvtx3_dir NAMES nvtx3 PATHS ${CUDA_INCLUDE_DIRS})
#   else()
#     find_path(nvtx3_dir NAMES nvtx3 PATHS ".../third_party/NVTX/c/include" ...)
#   endif()
#
# NAMES nvtx3 matches a DIRECTORY CALLED nvtx3, not the header inside it. The
# JetPack 6 toolkit ships /usr/local/cuda-12.6/include/nvtx3/ with the C headers
# and no nvtx3.hpp, so find_path succeeded, TORCH_CUDA_USE_NVTX3 got defined,
# the include path was added - and the C++ header still was not there. A
# successful probe for the wrong thing, which is worse than a failed one.
#
# So: probe for the FILE that actually gets included, and fall back to the copy
# pytorch ships as a submodule. The Spark never hit this because CUDA 13.4 does
# ship nvtx3.hpp - which is exactly why this has to be decided per box rather
# than exported unconditionally.
choose_nvtx_source() {
    local cuda_inc="${CUDA_HOME:-/usr/local/cuda}/include"
    local sys_hpp="$cuda_inc/nvtx3/nvtx3.hpp"
    local bundled="third_party/NVTX/c/include"

    if [ -f "$sys_hpp" ]; then
        export USE_SYSTEM_NVTX=1
        log "nvtx3: the toolkit has nvtx3.hpp - using $cuda_inc"
    else
        warn "nvtx3: $cuda_inc/nvtx3/ has no nvtx3.hpp (JetPack 6 ships the C"
        warn "  headers only), so this build uses the copy pytorch bundles."
        if [ ! -f "$bundled/nvtx3/nvtx3.hpp" ]; then
            log "  third_party/NVTX is not populated - fetching that submodule"
            git submodule update --init --recursive third_party/NVTX >/dev/null 2>&1 || true
        fi
        [ -f "$bundled/nvtx3/nvtx3.hpp" ] || fail "nvtx3: no nvtx3.hpp anywhere.
  Not in the toolkit ($sys_hpp) and not in $bundled after a submodule update.
  Without it torch_cuda cannot compile torch/csrc/profiler/stubs/cuda.cpp.
  Either install the toolkit's NVTX package (on JetPack: cuda-nvtx-\${VER}) or
  fetch the submodule by hand in \$(pwd)."
        unset USE_SYSTEM_NVTX
        log "nvtx3: using pytorch's bundled NVTX ($bundled)"
    fi

    # ── A CONFIGURED BUILD WILL NOT NOTICE THIS ON ITS OWN ──
    # pytorch's tools/setup_helpers/cmake.py returns early when CMakeCache.txt
    # and build.ninja both exist - "Everything's in place. Do not rerun." So on
    # a resumed build, changing USE_SYSTEM_NVTX changes nothing at all: cmake is
    # never re-invoked and the bad cached nvtx3_dir stays. The env var alone
    # would look like a fix and do nothing, which is the worst kind.
    #
    # The invariant worth enforcing is narrow: whatever cmake cached as
    # nvtx3_dir must actually contain nvtx3/nvtx3.hpp. When it does, the
    # configure is fine and is left completely alone - no wasted reconfigure on
    # the Spark or on any healthy resume. When it does not, the cache file is
    # removed so the next configure re-resolves it, which is the same thing
    # setup.py's own --cmake flag does.
    #
    # THE COMPILED OBJECTS SURVIVE THIS. Only CMakeCache.txt is removed, not the
    # build tree; ninja keeps every .o whose command line and inputs are
    # unchanged, so a run that has already finished torch_cpu does not start
    # over. Some torch_cuda objects do recompile - they are the ones whose
    # include path just changed, which is the point.
    local cache="build/CMakeCache.txt" cached
    [ -f "$cache" ] || return 0
    cached="$(awk -F= '/^nvtx3_dir:/{print $2; exit}' "$cache")"
    if [ -n "$cached" ] && [ -f "$cached/nvtx3/nvtx3.hpp" ]; then
        log "  the existing cmake configure already points at a usable nvtx3 - keeping it"
        return 0
    fi
    warn "  the existing cmake configure cached nvtx3_dir=${cached:-<unset>},"
    warn "  which has no nvtx3/nvtx3.hpp. Dropping $cache so it re-resolves."
    warn "  Compiled objects are kept; ninja only rebuilds what actually changed."
    rm -f "$cache"
}

# ═════════════════════════════════════════════════════════════
# PyTorch (version pinned per platform - see detect_platform)
# ═════════════════════════════════════════════════════════════
build_pytorch() {
    # THE SPARK BUILDS THIS TOO NOW. It is the best-provisioned box in the
    # fleet - 128GB unified, 20 cores - so it is the one machine where a torch
    # build is least painful, and the archive stops depending on NVIDIA's index
    # existing. See the jp7 branch in detect_platform for why 2.8.0 is a floor.
    [ -n "$PYTORCH_VERSION" ] || fail "PYTORCH_VERSION is unset for $PLATFORM_TAG/$JP_FAMILY"
    log "Building PyTorch ${PYTORCH_VERSION} ${PYTAG} (${PLATFORM_TAG}, arch $TORCH_ARCH_LIST)..."
    use_venv pytorch "$CMAKE_MIN_TORCH"

    # The build-time numpy pin - see the reasoning in detect_platform. jp5 needs
    # a 1.x C API because torch 2.1 predates the numpy 2 headers; everywhere
    # else builds against 2.x deliberately, so the wheel runs under both.
    "$PYBIN" -m pip install \
        "numpy==${NUMPY_BUILD_VERSION}" \
        scikit-build ninja pyyaml \
        typing-extensions cffi future six requests dataclasses setuptools wheel

    export USE_CUDA=1
    export USE_CUDNN=1
    # DISTRIBUTED STAYS IN WHERE vLLM IS IN PLAY, and the flat USE_DISTRIBUTED=0
    # hid a hard dependency: vLLM goes through torch.distributed even for a
    # single GPU (its executor initialises a process group of one). Built
    # against a torch with distributed compiled out, the vllm wheel compiles
    # and then dies at import - "Distributed package doesn't have NCCL /
    # torch.distributed is not available" - hours after the decision was made.
    #
    # Xavier keeps 0: it cannot run vLLM at any version (sm_72 is in none of
    # vLLM's arch branches), so the smaller, faster build is correct there.
    if [ "$JP_FAMILY" = "jp5" ]; then
        export USE_DISTRIBUTED=0
        export USE_NCCL=0
    else
        export USE_DISTRIBUTED=1
        # NCCL only where the libraries actually exist. The Spark has them (a
        # two-node cluster is a shipped feature of that box); Jetsons do not,
        # and asking for it there fails the build rather than degrading.
        # Gloo covers single-node either way, which is what vLLM needs here.
        if [ -f "${CUDA_HOME:-/usr/local/cuda}/lib64/libnccl.so" ] || \
           ls /usr/lib/*/libnccl.so* >/dev/null 2>&1; then
            export USE_NCCL=1
            log "  NCCL found - USE_DISTRIBUTED=1 USE_NCCL=1"
        else
            export USE_NCCL=0
            log "  no NCCL on this box - USE_DISTRIBUTED=1 USE_NCCL=0 (gloo only)"
        fi
    fi
    export USE_QNNPACK=0
    export USE_PYTORCH_QNNPACK=0
    export USE_MKLDNN=0
    export USE_XNNPACK=0
    # USE_SYSTEM_NVTX IS DECIDED LATER, FROM THE BOX. It used to be exported
    # unconditionally right here, with a comment explaining PyTorch 2.3.1 - a
    # version nothing is pinned to any more. See choose_nvtx_source, called
    # after the checkout exists, for what replaced it and why.
    export TORCH_CUDA_ARCH_LIST="$TORCH_ARCH_LIST"
    export PYTORCH_BUILD_VERSION="$PYTORCH_VERSION"
    export PYTORCH_BUILD_NUMBER=1
    export MAX_JOBS="$RESOLVED_MAX_JOBS"
    export CMAKE_POLICY_VERSION_MINIMUM=3.5

    cd "$BUILD_DIR"
    clone_or_reuse pytorch "v${PYTORCH_VERSION}" https://github.com/pytorch/pytorch --recursive
    # A TAG IS NOT A COMMIT. v2.1.0 is stable in practice and can still be moved
    # or deleted; the SHA it pointed at on the day cannot.
    record_source pytorch "$PWD/pytorch"
    cd pytorch

    # ── Patch: CUDA 12.x nvToolsExt target ──
    # PyTorch 2.3.1's cmake/public/cuda.cmake hard-errors with
    # "Failed to find nvToolsExt" if the CMake target CUDA::nvToolsExt
    # doesn't exist. On CUDA 12.x (JetPack 6) NVTX went header-only and
    # find_package(CUDAToolkit) stopped defining that target (the modern one
    # is CUDA::nvtx3). USE_SYSTEM_NVTX=1 alone does NOT fix this - the TARGET
    # check runs regardless. So we create a stand-in interface target that
    # aliases the header-only nvtx3, satisfying both the existence check and
    # any downstream `target_link_libraries(... CUDA::nvToolsExt)`. Harmless
    # on CUDA 12.2 (jp5) too - if CUDA::nvToolsExt already exists there, the
    # NOT TARGET guard means this block never runs. Idempotent: only patches
    # if the fatal line is still present.
    if grep -q 'message(FATAL_ERROR "Failed to find nvToolsExt")' cmake/public/cuda.cmake; then
        python3 - << 'NVTX_PATCH'
p = "cmake/public/cuda.cmake"
s = open(p).read()
old = '''if(NOT TARGET CUDA::nvToolsExt)
  message(FATAL_ERROR "Failed to find nvToolsExt")
endif()'''
new = '''if(NOT TARGET CUDA::nvToolsExt)
  # [seren patch] CUDA 12.x made NVTX header-only and dropped the
  # CUDA::nvToolsExt target (modern target is CUDA::nvtx3). Create a
  # stand-in so PyTorch 2.3.1 stops hard-erroring; alias header-only nvtx3.
  add_library(CUDA::nvToolsExt INTERFACE IMPORTED)
  if(TARGET CUDA::nvtx3)
    set_target_properties(CUDA::nvToolsExt PROPERTIES
      INTERFACE_LINK_LIBRARIES CUDA::nvtx3)
  endif()
endif()'''
if old in s:
    open(p, "w").write(s.replace(old, new))
    print("[seren] cuda.cmake nvToolsExt patch applied")
else:
    print("[seren] WARNING: nvToolsExt block not matched - cuda.cmake may have changed; build may fail at line ~70")
NVTX_PATCH
    else
        log "cuda.cmake nvToolsExt fatal-check not present (already patched or different pytorch version) - skipping patch"
    fi

    patch_pytorch_for_nvcc
    choose_nvtx_source

    "$PYBIN" -m pip install -r requirements.txt
    # AFTER requirements.txt, NOT BEFORE IT ALONE. pytorch lists numpy unpinned,
    # so the install above quietly replaced the pinned one - the pin was set
    # sixty lines earlier and then thrown away before a single .cpp compiled.
    # Re-assert it, then say which numpy actually built the wheel.
    "$PYBIN" -m pip install -q "numpy==${NUMPY_BUILD_VERSION}"
    log "numpy in this venv: $("$PYBIN" -c 'import numpy; print(numpy.__version__)' 2>/dev/null || echo absent)"

    log "Starting PyTorch build (this takes 2-4 hours)..."
    "$PYBIN" setup.py bdist_wheel

    local WHEEL; WHEEL=$(ls dist/torch-*.whl 2>/dev/null | head -1)
    [ -z "$WHEEL" ] && fail "PyTorch build failed - no wheel produced"

    cp "$WHEEL" "$PLATFORM_DIR/"
    record_artifact "$PLATFORM_DIR/$(basename "$WHEEL")"
    echo "pytorch: $(basename "$WHEEL")" >> "$BUILD_INFO"
    log "PyTorch wheel saved → $PLATFORM_DIR/$(basename "$WHEEL") ✓"

    # HANDED ON AS A FILE, not as a shared site-packages. This used to
    # pip-install into the one venv everything ran in, which is exactly what
    # made the venv shared; torchvision, bitsandbytes and vllm each install
    # this wheel into their own now, via ensure_torch.
    SEREN_TORCH_WHEEL="$PLATFORM_DIR/$(basename "$WHEEL")"
    cd ~
}
