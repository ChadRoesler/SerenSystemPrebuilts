# ------------------------------------------------------------
# phases/coral.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines functions only, runs nothing.
# ------------------------------------------------------------

# ─────────────────────────────────────────────────────────────
# gasket on modern kernels
# ─────────────────────────────────────────────────────────────
#
# google/gasket-driver is effectively frozen and the kernel is not. It already
# carries a LINUX_VERSION_CODE guard for the 6.4 class_create() signature
# change, which is the shape to follow - so this adds the next one rather than
# hacking the line out.
#
#   gasket_core.c:  .llseek = no_llseek,
#
# `no_llseek` was REMOVED from the kernel in 6.12. A Jetson on 5.10/5.15 never
# noticed; a DGX Spark on 6.17 fails to compile with 'no_llseek' undeclared.
# Dropping the assignment is what the upstream kernel series did to every
# driver: gasket never calls nonseekable_open(), so the field simply falls back
# to default_llseek, which is harmless for a device driven by ioctl and mmap.
#
# VERIFIED, NOT ASSUMED. A patch that silently fails to apply is worse than no
# patch - you get the original error one step later and start doubting the
# toolchain - so this checks the line is gone and says so either way.
patch_gasket_for_kernel() {
    # ── 1. no_llseek, removed in 6.12 ──
    local f="gasket_core.c"
    [ -f "$f" ] || fail "patch_gasket_for_kernel: $f not found (upstream layout changed?)"
    if grep -q "KERNEL_VERSION(6, 12, 0)" "$f"; then
        log "gasket: no_llseek already guarded"
    elif ! grep -q "no_llseek" "$f"; then
        log "gasket: no no_llseek in this checkout - nothing to patch"
    else
        python3 - "$f" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8", errors="surrogateescape").read()
old = "\t.llseek = no_llseek,\n"
new = ("#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 12, 0)\n"
       "\t/* no_llseek was removed in 6.12; gasket never calls\n"
       "\t * nonseekable_open(), so leaving .llseek unset falls back to\n"
       "\t * default_llseek. Patched by build-jetson-prebuilts.sh. */\n"
       "\t.llseek = no_llseek,\n"
       "#endif\n")
if old not in s:
    sys.exit("ANCHOR_MISS")
io.open(p, "w", encoding="utf-8", errors="surrogateescape").write(s.replace(old, new, 1))
PY
        if [ $? -ne 0 ]; then
            warn "gasket: no_llseek present but not in the expected form - kernel 6.12+ will fail"
        else
            grep -q "KERNEL_VERSION(6, 12, 0)" "$f" || fail "gasket: no_llseek patch claimed success but the guard is not in $f"
            log "gasket: no_llseek guarded for kernel >= 6.12 ✓"
        fi
    fi

    # ── 2. MODULE_IMPORT_NS, changed in 6.13 ──
    #
    # Kernel 6.13 made the namespace a STRING LITERAL:
    #     < 6.13   #define MODULE_IMPORT_NS(ns)  MODULE_INFO(import_ns, __stringify(ns))
    #    >= 6.13   #define MODULE_IMPORT_NS(ns)  MODULE_INFO(import_ns, ns)
    # so the old bare-token call fails on 6.13+ with "'DMA_BUF' undeclared"
    # plus a static_assert about __builtin_strlen - which reads like a dma-buf
    # problem and is purely a macro signature change.
    #
    # A VERSION GUARD, NOT A BLANKET SWAP: the string form passed to the OLD
    # macro stringifies twice and yields "\"DMA_BUF\"", so simply adding quotes
    # would fix the Spark and break both Jetsons.
    local g="gasket_page_table.c"
    if [ ! -f "$g" ]; then
        warn "gasket: $g not found - skipping the MODULE_IMPORT_NS patch"
    elif grep -q "KERNEL_VERSION(6, 13, 0)" "$g"; then
        log "gasket: MODULE_IMPORT_NS already guarded"
    elif ! grep -qE "^MODULE_IMPORT_NS\(" "$g"; then
        log "gasket: no MODULE_IMPORT_NS in this checkout - nothing to patch"
    else
        # version.h must be reachable or the #if silently takes the < branch and
        # the build fails exactly as before. It is included at the top of this
        # file upstream; check rather than trust.
        grep -q "linux/version.h" "$g" \
            || fail "gasket: $g has no <linux/version.h>; a LINUX_VERSION_CODE guard there would be a no-op"
        python3 - "$g" <<'PY'
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8", errors="surrogateescape").read()
pat = re.compile(r'^MODULE_IMPORT_NS\((?!")([A-Za-z_][A-Za-z0-9_]*)\);\s*$', re.M)
found = pat.findall(s)
if not found:
    sys.exit("ANCHOR_MISS")
def rep(m):
    ns = m.group(1)
    return ("#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 13, 0)\n"
            "MODULE_IMPORT_NS(%s);\n"
            "#else\n"
            "/* 6.13 made the namespace a string literal. */\n"
            "MODULE_IMPORT_NS(\"%s\");\n"
            "#endif" % (ns, ns))
io.open(p, "w", encoding="utf-8", errors="surrogateescape").write(pat.sub(rep, s))
PY
        if [ $? -ne 0 ]; then
            warn "gasket: MODULE_IMPORT_NS present but not in the expected form - kernel 6.13+ will fail"
        else
            grep -q 'MODULE_IMPORT_NS("' "$g" || fail "gasket: MODULE_IMPORT_NS patch claimed success but no string form is in $g"
            log "gasket: MODULE_IMPORT_NS guarded for kernel >= 6.13 ✓"
        fi
    fi

    # ── runtime note, not a build break ──
    # dma_buf_map_attachment() has needed the reservation lock held since 6.2
    # and gasket calls it unlocked. Every dma_buf symbol it uses still exists in
    # mainline, so this compiles - it can WARN at runtime, and only on the
    # dma-buf import path, which a plain Coral does not touch. Filed, not fixed:
    # guessing at locking in a driver nobody here can test is worse than the warn.
    if grep -q "dma_buf_map_attachment" "${g:-/dev/null}" 2>/dev/null && \
       [ "$JP_FAMILY" = "jp7" ]; then
        warn "gasket: dma_buf_map_attachment() is called without the reservation"
        warn "  lock, which kernels >= 6.2 assert on. Harmless unless you use the"
        warn "  dma-buf import path; it would show as a dma_resv WARN in dmesg."
    fi
}

build_coral() {
    log "Building Coral kernel modules (${PLATFORM_TAG}, $JP_FAMILY, kernel $KERNEL_VER)..."

    # WHICH CORAL THIS IS FOR, because on the Spark it is a real fork and the
    # wrong answer wastes a build. gasket.ko + apex.ko drive the PCIe/M.2 Edge
    # TPU. The Coral USB ACCELERATOR is a libusb device and uses NONE of this -
    # it needs libedgetpu1-std plus a udev rule and no kernel module at all.
    # So: an M.2 Coral in a USB4/Thunderbolt PCIe enclosure wants these modules;
    # the little USB dongle does not.
    if [ "$JP_FAMILY" = "jp7" ]; then
        warn "Spark: these modules are for an M.2/PCIe Coral - including one in a"
        warn "  USB4/Thunderbolt PCIe enclosure, which is why this is supported."
        warn "  If you are plugging in the Coral USB ACCELERATOR instead, it needs"
        warn "  no kernel module: apt install libedgetpu1-std, then the udev rule"
        warn "  and the plugdev group. These .ko files would do nothing for it."
    fi

    # ── KERNEL HEADERS, TESTED BY WHAT ACTUALLY NEEDS THEM ──
    #
    # Both installs used to be masked with 2>/dev/null and the last resort was
    # "module build may fail" - which then did, a minute later, as a bare kbuild
    # error about a missing Makefile that says nothing about apt. Same shape as
    # the toolchain install this script used to do: the failure was known at
    # this line and reported four steps downstream.
    #
    # Trying two package names is right, because it genuinely differs -
    # nvidia-l4t-kernel-headers on a Tegra, linux-headers-$(uname -r) elsewhere.
    # What is NOT right is treating apt's exit code as the answer. The real
    # precondition is the build tree that line 162 compiles against, and on a
    # freshly flashed Jetson the BSP has usually put it there already - in which
    # case neither package needs installing and a failed apt means nothing.
    # So: look for the tree, install only if it is absent, then look again.
    local KBUILD="/lib/modules/${KERNEL_VER}/build"
    if [ -d "$KBUILD" ]; then
        log "kernel build tree already present: $KBUILD"
    else
        local hdr_out
        hdr_out="$(sudo apt-get install -y nvidia-l4t-kernel-headers build-essential 2>&1 \
                   || sudo apt-get install -y "linux-headers-${KERNEL_VER}" build-essential 2>&1 \
                   || true)"
        if [ ! -d "$KBUILD" ]; then
            echo "$hdr_out" | tail -20 >&2
            apt_diagnose "$hdr_out"
            fail "coral: no kernel build tree at $KBUILD, so the modules cannot compile.
  Tried nvidia-l4t-kernel-headers and linux-headers-${KERNEL_VER}.
  On a Jetson these come from the BSP - if apt cannot reach its repositories the
  diagnosis above is the thing to fix first. This phase is skippable: everything
  else in the archive builds without it."
        fi
        log "kernel build tree installed: $KBUILD"
    fi

    cd "$BUILD_DIR"
    rm -rf gasket-driver
    if [ -n "$USER_GASKET_REF" ]; then
        git clone https://github.com/google/gasket-driver.git
        git -C gasket-driver checkout --quiet "$USER_GASKET_REF" \
            || fail "gasket-driver: no such ref '$USER_GASKET_REF'"
        log "gasket-driver pinned to $USER_GASKET_REF"
    else
        git clone https://github.com/google/gasket-driver.git
        warn "gasket-driver is UNPINNED (default branch HEAD) - commit recorded below"
    fi
    record_source gasket-driver "$PWD/gasket-driver"
    cd gasket-driver/src

    patch_gasket_for_kernel

    log "Compiling gasket + apex against kernel $KERNEL_VER..."
    make -C "/lib/modules/$KERNEL_VER/build" M="$(pwd)" modules

    [ -f gasket.ko ] || fail "gasket.ko not produced"
    [ -f apex.ko ]   || fail "apex.ko not produced"

    local GASKET_OUT="$PLATFORM_DIR/gasket-${JP_FAMILY}-${PLATFORM_TAG}-aarch64.ko"
    local APEX_OUT="$PLATFORM_DIR/apex-${JP_FAMILY}-${PLATFORM_TAG}-aarch64.ko"
    cp gasket.ko "$GASKET_OUT"
    cp apex.ko   "$APEX_OUT"
    record_artifact "$GASKET_OUT"
    record_artifact "$APEX_OUT"

    # Capture kernel version into a manifest so install side can validate
    local MANIFEST="$PLATFORM_DIR/coral-${JP_FAMILY}-${PLATFORM_TAG}.manifest"
    {
        echo "kernel=$KERNEL_VER"
        echo "jp_family=$JP_FAMILY"
        echo "platform=$PLATFORM_TAG"
        echo "gasket=$(basename "$GASKET_OUT")"
        echo "apex=$(basename "$APEX_OUT")"
        # The install side needs to know these are the PCIe-path modules and
        # not something a USB Accelerator can use.
        echo "interface=pcie"
        echo "built=$(date -Iseconds)"
    } > "$MANIFEST"
    record_artifact "$MANIFEST"

    {
        echo "coral gasket: $(basename "$GASKET_OUT")"
        echo "coral apex:   $(basename "$APEX_OUT")"
        echo "coral kernel: $KERNEL_VER"
    } >> "$BUILD_INFO"

    log "Coral modules built ✓"
    log "  $GASKET_OUT"
    log "  $APEX_OUT"
    log "  $MANIFEST"
    cd ~
    rm -rf "$BUILD_DIR/gasket-driver"
}
