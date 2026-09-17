# ------------------------------------------------------------
# phases/selftest.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines functions only, runs nothing.
# ------------------------------------------------------------

# ═════════════════════════════════════════════════════════════
# What "this artifact works" actually means - the GPU assertion suite
# ═════════════════════════════════════════════════════════════
#
# THE ONLY PHASE THAT EVER VERIFIED ITSELF WAS BITSANDBYTES, and it exists
# because of a failure that a clean compile could not see: a wheel that built,
# installed and imported perfectly while containing no code the GPU could run.
# That is not a bitsandbytes property. It is what every CUDA artifact in here
# can do, and torch is the one that matters most - a torch wheel built for the
# wrong architecture imports fine and dies at the first kernel launch, months
# later, on the box you were relying on the backup for.
#
# So the same rule applies to everything: verify the ARTIFACT, not the exit
# code. These checks launch real kernels on the real device.
#
# Shared by --selftest (after a build) and --verify-archive (against a folder
# you already have), because a restore rehearsal that tests something different
# from what the build tested is not a rehearsal.
seren_gpu_suite() {
    local py="$1" label="$2"
    log "── GPU assertions: ${label} ──"
    SEREN_CUDA_ARCH="$CUDA_ARCH" "$py" - <<'PYSUITE'
import os, sys

arch = os.environ["SEREN_CUDA_ARCH"]
# "72" -> (7,2)   "87" -> (8,7)   "121" -> (12,1)
want_cc = (int(arch[:-1]), int(arch[-1]))
fails, skips = [], []


def check(name, fn):
    try:
        detail = fn()
        print("  PASS  %-34s %s" % (name, detail or ""))
    except ModuleNotFoundError as e:
        # Not built / not installed is not a failure - this archive is allowed
        # to be partial, it just has to say so.
        skips.append(name)
        print("  SKIP  %-34s %s not installed" % (name, e.name))
    except Exception as e:
        fails.append(name)
        print("  FAIL  %-34s %s: %s" % (name, type(e).__name__, e))


def t_import():
    import torch
    return "torch %s / cuda %s" % (torch.__version__, torch.version.cuda)


check("torch imports", t_import)
try:
    import torch
except Exception as e:
    print("\nSELFTEST FAILED: torch will not import at all (%s)" % e)
    sys.exit(1)


def t_avail():
    assert torch.cuda.is_available(), "torch.cuda.is_available() is False"
    return torch.cuda.get_device_name(0)


def t_archlist():
    al = torch.cuda.get_arch_list()
    assert ("sm_" + arch) in al, "sm_%s not among %s" % (arch, al)
    return " ".join(al)


def t_capability():
    cc = torch.cuda.get_device_capability()
    assert cc == want_cc, \
        "this device is sm_%d%d but the wheel was built for sm_%s" % (cc[0], cc[1], arch)
    return "device is sm_%d%d, as built for" % cc


def _finite(t, what):
    n = int((~torch.isfinite(t)).sum())
    if n:
        raise AssertionError(
            "%d of %d values in %s are NaN/Inf" % (n, t.numel(), what))


def _gemm_ref(a, b, chunk=32):
    # a @ b WITHOUT going through the GEMM path: a broadcast multiply and a
    # reduction, which are different kernels entirely. Done in row chunks so the
    # (chunk, K, N) temporary stays around 8MB instead of 67MB.
    #
    # THE REFERENCE MUST NOT SHARE A CODE PATH WITH THE THING IT CHECKS, and
    # using one matmul to check another is how "a cuda kernel launches" ended up
    # failing on a box whose GPU was fine.
    outs = []
    for i in range(0, a.shape[0], chunk):
        blk = a[i:i + chunk]
        outs.append((blk.unsqueeze(2) * b.unsqueeze(0)).sum(1))
    return torch.cat(outs, 0)


def _check_gemm(dev, label):
    # fp32 accumulating K=256 terms in a different order than the reference
    # lands around 1e-6 relative, whatever the matrix size, so 1e-4 still
    # catches a genuinely broken kernel (which is O(1) out) with orders of
    # magnitude to spare. Relative, not absolute: entries here run to |70| and
    # an absolute tolerance would be a tolerance chosen for numbers near 1.
    torch.manual_seed(0)
    a = torch.randn(256, 256, device=dev)
    b = torch.randn(256, 256, device=dev)
    _finite(a, "the %s random inputs (a)" % label)
    _finite(b, "the %s random inputs (b)" % label)
    got = a @ b
    _finite(got, "the %s matmul result" % label)
    ref = _gemm_ref(a, b)
    _finite(ref, "the %s reference accumulation" % label)
    if float(got.abs().max()) == 0.0 and float(ref.abs().max()) > 0.0:
        raise AssertionError("%s matmul returned all zeros - no kernel ran" % label)
    scale = float(ref.abs().max())
    adiff = float((got - ref).abs().max())
    rel = adiff / scale if scale else adiff
    assert rel < 1e-4, (
        "%s matmul disagrees with an independent accumulation by more than fp32 "
        "rounding explains: max abs %.4g, max rel %.4g (largest |value| %.4g). "
        "Around 1e-6 is normal; this is not." % (label, adiff, rel, scale))
    return "256x256 %s matmul matches an independent sum (max rel %.1e)" % (label, rel)


def t_cpu_matmul():
    # ── THE CPU PATH IS PART OF THE ARTIFACT AND IT GETS ITS OWN CHECK ──
    # On the Xavier this wheel returns NaN for 3584 of 65536 entries - a
    # structured block, 256*14, not scattered corruption - while the GPU
    # produces correct results on the same inputs. That was being reported as
    # "a cuda kernel launches FAILED", which accused the one component the run
    # had already proved was working.
    #
    # A torch whose CPU GEMM is broken is a broken wheel even when every CUDA
    # kernel is perfect: any .cpu() tensor operation, any dataloader collate,
    # any fallback path hits it. So it is a first-class check with its own name,
    # and the CUDA check below no longer depends on it being true.
    try:
        return _check_gemm("cpu", "CPU")
    except AssertionError as e:
        raise AssertionError(
            "%s  This is the CPU BLAS in this wheel, not the GPU. Check which "
            "one it linked with torch.__config__.show(), and whether "
            "OPENBLAS_NUM_THREADS=1 makes it go away." % e)


def t_matmul():
    # Referenced against an independent GPU-side accumulation, NOT against the
    # CPU - see t_cpu_matmul for why that distinction had to be made.
    return _check_gemm("cuda", "CUDA")


def t_torchvision():
    import torchvision
    from torchvision.ops import nms
    boxes = torch.tensor([[0., 0., 10., 10.],
                          [1., 1., 11., 11.],
                          [50., 50., 60., 60.]], device="cuda")
    scores = torch.tensor([0.9, 0.8, 0.7], device="cuda")
    kept = nms(boxes, scores, 0.5)
    assert kept.numel() >= 1, "nms returned nothing"
    return "torchvision %s, cuda nms kept %d" % (torchvision.__version__, kept.numel())


def t_bitsandbytes():
    import bitsandbytes as bnb
    from bitsandbytes.functional import quantize_4bit, dequantize_4bit
    x = torch.randn(64, 64, device="cuda", dtype=torch.float16)
    q, state = quantize_4bit(x)
    y = dequantize_4bit(q, state)
    assert y.shape == x.shape, "4-bit round trip changed the shape"
    return "bitsandbytes %s, 4-bit round trip on device" % bnb.__version__


check("cuda is available", t_avail)
check("wheel carries sm_" + arch, t_archlist)
check("device matches the build", t_capability)
check("cpu matmul is sane", t_cpu_matmul)
check("a cuda kernel launches", t_matmul)
check("torchvision cuda op", t_torchvision)
check("bitsandbytes cuda kernel", t_bitsandbytes)

print("")
if fails:
    print("SELFTEST FAILED: " + ", ".join(fails))
    sys.exit(1)
print("SELFTEST PASSED%s" % (" (%d skipped)" % len(skips) if skips else ""))
sys.exit(0)
PYSUITE
}

# ── the artifacts that are not python packages ──
# A binary and a kernel module fail in their own ways: a missing shared library
# and a vermagic that does not match the running kernel. Both are cheap to ask
# about and neither shows up in a pip install.
seren_binary_checks() {
    local dir="$1" rc=0 f v
    for f in "$dir"/llama-server-*; do
        [ -f "$f" ] || continue
        if ldd "$f" 2>/dev/null | grep -q "not found"; then
            ldd "$f" | grep "not found" >&2
            warn "  FAIL  llama-server is missing shared libraries (above)"
            rc=1
        elif "$f" --version >/dev/null 2>&1 || "$f" --help >/dev/null 2>&1; then
            log "  PASS  $(basename "$f") runs and resolves its libraries"
        else
            warn "  FAIL  $(basename "$f") will not execute"
            rc=1
        fi
    done
    for f in "$dir"/gasket-*.ko "$dir"/apex-*.ko; do
        [ -f "$f" ] || continue
        v="$(modinfo -F vermagic "$f" 2>/dev/null | awk '{print $1}')"
        if [ -z "$v" ]; then
            warn "  FAIL  $(basename "$f") has no readable vermagic"
            rc=1
        elif [ "$v" = "$KERNEL_VER" ]; then
            log "  PASS  $(basename "$f") vermagic $v matches the running kernel"
        else
            warn "  WARN  $(basename "$f") was built for kernel $v, this box runs $KERNEL_VER"
            warn "        insmod will refuse it. Rebuild --coral after a kernel change."
        fi
    done
    return $rc
}

# ═════════════════════════════════════════════════════════════
# selftest - prove the artifacts, from the archive, on the device
# ═════════════════════════════════════════════════════════════
build_selftest() {
    # ALWAYS FROM SCRATCH. The point is to prove the ARTIFACTS, not to prove
    # that a venv which has been accumulating packages since phase two still
    # imports something. A reused selftest venv is a selftest that has quietly
    # stopped testing.
    rm -rf "$VENV_ROOT/selftest"
    use_venv selftest

    local links=(--find-links "$PLATFORM_DIR")
    [ -d "$PLATFORM_DIR/wheelhouse" ] && links+=(--find-links "$PLATFORM_DIR/wheelhouse")

    local targets=() w
    for w in "$PLATFORM_DIR"/torch-*.whl "$PLATFORM_DIR"/torchvision-*.whl \
             "$PLATFORM_DIR"/bitsandbytes-*.whl; do
        [ -f "$w" ] && targets+=("$w")
    done
    if [ ${#targets[@]} -eq 0 ]; then
        warn "no wheels in $PLATFORM_DIR to test."
        note_skip selftest "no wheels present to install"
        return 0
    fi

    # ── THE NUMPY PIN IS PART OF THE ARTIFACT, NOT A SUGGESTION ──
    #
    # torch is compiled against NUMPY_BUILD_VERSION and carries numpy's C ABI in
    # the binary. On jp5 that is 1.24.4 - the 1.x ABI - and NUMPY_RUNTIME_VERSION
    # is 1.26.1 to stay on that side of the break. Nothing here constrained it,
    # torchvision 0.16.0 depends on numpy unpinned, so pip fetched 2.2.6 and
    # every import said so at length:
    #
    #   A module that was compiled using NumPy 1.x cannot be run in NumPy 2.2.6
    #   UserWarning: Failed to initialize NumPy: _ARRAY_API not found
    #
    # A torch whose array interop is dead is not the artifact this archive
    # claims to hold, and the selftest existing to catch exactly that while
    # itself installing the combination that breaks it is the worst version of
    # this bug. wheelhouse already writes this constraint for its closure
    # (phases/wheelhouse.sh); the same one belongs here, because a constraint
    # file is the only thing pip honours when a DEPENDENCY pulls numpy in.
    local cons; cons="$(mktemp)"
    echo "numpy==${NUMPY_RUNTIME_VERSION}" > "$cons"
    links+=(-c "$cons")
    log "constraining numpy to ${NUMPY_RUNTIME_VERSION} (torch here was built against ${NUMPY_BUILD_VERSION})"

    # OFFLINE FIRST, AND A FAILURE HERE IS ITSELF THE FINDING: if these wheels
    # cannot be installed without an index, then this archive cannot restore
    # this box, which is the only claim it makes.
    local offline=true
    log "installing from the archive with the index switched off..."
    if ! "$PYBIN" -m pip install -q --no-index "${links[@]}" "${targets[@]}"; then
        offline=false
        warn "OFFLINE INSTALL FAILED - the archive cannot satisfy its own dependencies."
        warn "  Run --wheelhouse to close over them. Falling back to the index so the"
        warn "  GPU checks below can still run, but note what just happened."
        "$PYBIN" -m pip install -q "${links[@]}" "${targets[@]}" || {
            rm -f "$cons"
            warn "  the wheels will not install at all, even online"
            note_skip selftest "wheels could not be installed"
            return 0
        }
    fi
    rm -f "$cons"
    log "numpy in the selftest venv: $("$PYBIN" -c 'import numpy; print(numpy.__version__)' 2>/dev/null || echo absent)"
    $offline && log "installed with --no-index: the archive is self-sufficient ✓"

    local report="$PLATFORM_DIR/SELFTEST-${PLATFORM_TAG}-${JP_FAMILY}.txt"
    local rc=0
    {
        echo "# selftest $(date -Iseconds) on $(uname -n)"
        echo "# platform ${PLATFORM_TAG}/${JP_FAMILY}, sm_${CUDA_ARCH}, ${PYTAG}"
        echo "# offline install from the archive: $offline"
    } > "$report"

    # PIPESTATUS, NOT `|| rc=1`. A pipeline's exit status is the LAST command's,
    # which here is tee - and tee always succeeds. Written the obvious way, the
    # one phase whose entire purpose is to fail could not fail: every selftest
    # would have passed, including the ones that printed FAIL on every line.
    seren_gpu_suite "$PYBIN" "freshly built archive" 2>&1 | tee -a "$report"
    [ "${PIPESTATUS[0]}" -eq 0 ] || rc=1
    seren_binary_checks "$PLATFORM_DIR" 2>&1 | tee -a "$report"
    [ "${PIPESTATUS[0]}" -eq 0 ] || rc=1

    record_artifact "$report"
    if [ "$rc" -ne 0 ]; then
        echo "selftest         FAILED - see $(basename "$report")" >> "$PROVENANCE"
        fail "SELFTEST FAILED. The artifacts are built and recorded, but at least one
  of them does not work on this box - see $report.
  Do NOT publish this folder as a backup until that is understood."
    fi
    echo "selftest         passed (offline install: $offline)" >> "$PROVENANCE"
    echo "selftest: passed" >> "$BUILD_INFO"
    log "Selftest passed ✓"
    note_built selftest
    cd ~
}
