# ------------------------------------------------------------
# lib/archive.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines functions only, runs nothing.
# ------------------------------------------------------------

# ═════════════════════════════════════════════════════════════
# --verify-archive - the restore rehearsal, against a folder you have
# ═════════════════════════════════════════════════════════════
#
# AN ARCHIVE IS ONLY AS GOOD AS ITS LAST RESTORE. Everything else in this script
# is about producing files; this is the only thing that asks whether the files
# are still what they claim to be and still do what they claim to do. Run it on
# the folder you pulled off a release tag, on the box you would be restoring.
#
# It touches nothing: no provenance rewrite, no SHA256SUMS truncation, no
# artifacts. It reads, it installs into a throwaway venv, and it reports.
verify_archive() {
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Archive verification (nothing is built)${NC}"
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    log "folder:   $PLATFORM_DIR"
    [ -d "$PLATFORM_DIR" ] || fail "no such folder: $PLATFORM_DIR
  Point --output-dir at the parent of <platform>-<jp>/, or pass --platform."

    local rc=0

    # ── 1. is it still the bytes we wrote ──
    if [ -f "$PLATFORM_DIR/SHA256SUMS" ]; then
        log "── checksums ──"
        if ( cd "$PLATFORM_DIR" && sha256sum -c --quiet SHA256SUMS ); then
            log "  PASS  every file matches SHA256SUMS"
        else
            warn "  FAIL  checksum mismatch or missing file (above)"
            rc=1
        fi
    else
        warn "  no SHA256SUMS in this folder - it was not produced by this script,"
        warn "  or it was produced before checksums were written."
        rc=1
    fi

    # ── 2. does it still install, with the index switched off ──
    rm -rf "$VENV_ROOT/verify"
    use_venv verify
    local links=(--find-links "$PLATFORM_DIR")
    [ -d "$PLATFORM_DIR/wheelhouse" ] && links+=(--find-links "$PLATFORM_DIR/wheelhouse")
    local targets=() w
    for w in "$PLATFORM_DIR"/torch-*.whl "$PLATFORM_DIR"/torchvision-*.whl \
             "$PLATFORM_DIR"/bitsandbytes-*.whl; do
        [ -f "$w" ] && targets+=("$w")
    done
    if [ ${#targets[@]} -eq 0 ]; then
        warn "no wheels in this folder to install - verifying binaries only."
    else
        log "── offline install ──"
        if "$PYBIN" -m pip install -q --no-index "${links[@]}" "${targets[@]}"; then
            log "  PASS  installed from this folder with no index"
        else
            warn "  FAIL  this archive cannot install without a network."
            warn "        That is the claim it exists to make. Rebuild with --wheelhouse."
            rc=1
        fi
        # ── 3. do the artifacts still run on this GPU ──
        seren_gpu_suite "$PYBIN" "archive at $PLATFORM_DIR" || rc=1
    fi

    seren_binary_checks "$PLATFORM_DIR" || rc=1

    echo ""
    if [ "$rc" -eq 0 ]; then
        echo -e "${GREEN}ARCHIVE VERIFIED - checksums match, it installs offline, and it runs here.${NC}"
    else
        echo -e "${RED}ARCHIVE VERIFICATION FAILED - see the FAIL lines above.${NC}"
    fi
    echo ""
    return $rc
}

# ═════════════════════════════════════════════════════════════
# The box, as it stood - cheap, and impossible to reconstruct later
# ═════════════════════════════════════════════════════════════
#
# Two files nobody will think to write down and everybody will want: every
# installed apt package, and what the interpreters on this box had in them.
# In four years "it worked on this machine" is only useful if somebody wrote
# down what this machine WAS.
record_system_snapshot() {
    local pkgs="$PLATFORM_DIR/SYSTEM-PACKAGES-${PLATFORM_TAG}-${JP_FAMILY}.txt"
    local freeze="$PLATFORM_DIR/SYSTEM-PIP-${PLATFORM_TAG}-${JP_FAMILY}.txt"
    dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' > "$pkgs" 2>/dev/null || true
    {
        local v
        for v in "$HOST_PYBIN" "$HOME"/seren-venvs/*/bin/python \
                 /mnt/nvme/seren-venvs/*/bin/python; do
            [ -x "$v" ] || continue
            echo "# ── $v ── $("$v" --version 2>&1)"
            "$v" -m pip freeze 2>/dev/null || echo "# (no pip)"
            echo ""
        done
    } > "$freeze" 2>/dev/null || true
    record_artifact "$pkgs"
    record_artifact "$freeze"
    log "recorded $(wc -l < "$pkgs" 2>/dev/null || echo 0) system packages and the pip state"
}

# ═════════════════════════════════════════════════════════════
# INSTALL.sh - so the folder explains itself without this repo
# ═════════════════════════════════════════════════════════════
#
# THE PREMISE AGAIN: in four years the person holding these files will not have
# this script. They will have a folder. Everything about how to consume it
# currently lives in a README in a different repository, which is a dependency
# on something staying online - the thing this whole exercise is against.
#
# Generated from what is ACTUALLY in the folder, not from what was requested,
# so it never offers to install something that is not there.
write_install_script() {
    local f="$PLATFORM_DIR/INSTALL.sh"
    local py_tar sq_tar has_wheels=false
    py_tar="$(cd "$PLATFORM_DIR" && ls python*.tar.gz 2>/dev/null | head -1)"
    sq_tar="$(cd "$PLATFORM_DIR" && ls sqlite*.tar.gz 2>/dev/null | head -1)"
    ls "$PLATFORM_DIR"/*.whl >/dev/null 2>&1 && has_wheels=true

    {
        echo '#!/bin/bash'
        echo "# Installs this folder onto a ${PLATFORM_TAG} (${JP_FAMILY}, sm_${CUDA_ARCH})."
        echo "# Generated $(date -Iseconds) by build-jetson-prebuilts.sh."
        echo '#'
        echo '# Nothing here needs a network. Verify first, then install what you want:'
        echo '#   sha256sum -c SHA256SUMS'
        echo '#   ./INSTALL.sh --python --venv ~/seren-venv'
        echo 'set -e'
        echo 'cd "$(dirname "$0")"'
        echo 'DO_PY=false; DO_VENV=""; DO_CORAL=false; DO_APT=false'
        echo 'while [ $# -gt 0 ]; do case "$1" in'
        echo '  --python) DO_PY=true ;;'
        echo '  --venv)   DO_VENV="$2"; shift ;;'
        echo '  --coral)  DO_CORAL=true ;;'
        echo '  --apt)    DO_APT=true ;;'
        echo '  *) echo "unknown: $1"; exit 1 ;;'
        echo 'esac; shift; done'
        echo ''
        if [ -n "$sq_tar" ] || [ -n "$py_tar" ]; then
            echo 'if $DO_PY; then'
            [ -n "$sq_tar" ] && echo "  sudo tar xzf '$sq_tar' -C /usr/local && sudo ldconfig"
            [ -n "$py_tar" ] && echo "  sudo tar xzf '$py_tar' -C /usr/local && sudo ldconfig"
            echo "  echo 'installed to /usr/local - check: python${PYTHON_VERSION%.*} -c \"import sqlite3;print(sqlite3.sqlite_version)\"'"
            echo 'fi'
            echo ''
        fi
        if $has_wheels; then
            echo 'if [ -n "$DO_VENV" ]; then'
            echo "  python${PYTHON_VERSION%.*} -m venv \"\$DO_VENV\""
            echo '  LINKS="--find-links ."'
            echo '  [ -d wheelhouse ] && LINKS="$LINKS --find-links wheelhouse"'
            echo '  # --no-index: these are built for sm_'"${CUDA_ARCH}"' and must not be'
            echo '  # silently replaced by a generic wheel from an index.'
            echo '  "$DO_VENV/bin/pip" install --no-index $LINKS ./*.whl'
            echo '  "$DO_VENV/bin/python" -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.get_arch_list())"'
            echo ''
            echo '  # ── THE BLAS THIS TORCH NEEDS, not the one the distro defaults to ──'
            echo '  # torch is built USE_OPENMP=ON. Ubuntu default-selects the PTHREAD'
            echo '  # OpenBLAS, and that combination makes the FIRST cpu matmul in every'
            echo '  # process return NaN for a few percent of its output - silently, no'
            echo '  # error, wrong numbers. Measured on a Xavier: pthread 3584 bad values'
            echo '  # out of 65536, openmp and serial both 0. Same soname, chosen by'
            echo '  # update-alternatives, so this is a symlink and not a rebuild.'
            echo '  grp="$(update-alternatives --get-selections 2>/dev/null | awk "\$1 ~ /^libopenblas\\.so\\.[0-9]+-/ {print \$1; exit}")"'
            echo '  if [ -n "$grp" ]; then'
            echo '    omp="$(update-alternatives --list "$grp" 2>/dev/null | grep openblas-openmp | head -1)"'
            echo '    if [ -n "$omp" ]; then'
            echo '      sudo update-alternatives --set "$grp" "$omp" >/dev/null && echo "openblas -> openmp"'
            echo '    else'
            echo '      # Install it from the archive if it travelled with us, since the'
            echo '      # box that needs this most is the one whose apt mirror is gone.'
            echo '      if ls apt-toolchain/libopenblas0-openmp*.deb >/dev/null 2>&1; then'
            echo '        echo "installing libopenblas0-openmp from apt-toolchain/"'
            echo '        sudo dpkg -i apt-toolchain/libopenblas0-openmp*.deb || sudo apt-get -f install'
            echo '        grp2="$(update-alternatives --get-selections 2>/dev/null | awk "\$1 ~ /^libopenblas\\.so\\.[0-9]+-/ {print \$1; exit}")"'
            echo '        omp2="$(update-alternatives --list "$grp2" 2>/dev/null | grep openblas-openmp | head -1)"'
            echo '        [ -n "$omp2" ] && sudo update-alternatives --set "$grp2" "$omp2" >/dev/null && echo "openblas -> openmp"'
            echo '      else'
            echo '        echo "WARNING: no openmp OpenBLAS installed; the pthread one gives wrong"'
            echo '        echo "         cpu matmul results with this torch. Fix with:"'
            echo '        echo "           sudo apt install libopenblas0-openmp"'
            echo '      fi'
            echo '    fi'
            echo '  fi'
            echo '  # Prove it, rather than assume the symlink took.'
            echo '  "$DO_VENV/bin/python" - <<'"'"'BLASCHECK'"'"''
            echo 'import torch'
            echo 'torch.manual_seed(0)'
            echo 'a = torch.randn(256, 256); b = torch.randn(256, 256)'
            echo 'n = int((~torch.isfinite(a @ b)).sum())'
            echo 'print("cpu matmul check:", "OK" if n == 0 else "%d BAD VALUES - see the OpenBLAS note above" % n)'
            echo 'BLASCHECK'
            echo 'fi'
            echo ''
        fi
        if ls "$PLATFORM_DIR"/gasket-*.ko >/dev/null 2>&1; then
            echo 'if $DO_CORAL; then'
            echo '  want="$(modinfo -F vermagic gasket-*.ko | awk "{print \$1}")"'
            echo '  [ "$want" = "$(uname -r)" ] || { echo "modules are for kernel $want, this is $(uname -r) - refusing"; exit 1; }'
            echo '  sudo cp gasket-*.ko apex-*.ko "/lib/modules/$(uname -r)/kernel/drivers/"'
            echo '  sudo depmod -a && sudo modprobe gasket && sudo modprobe apex'
            echo '  echo "loaded - check: ls /dev/apex_0"'
            echo 'fi'
            echo ''
        fi
        if [ -d "$PLATFORM_DIR/apt" ] || [ -d "$PLATFORM_DIR/apt-toolchain" ]; then
            echo 'if $DO_APT; then'
            echo '  # Two directories, and a release only ever carries the second one:'
            echo '  # apt/ is NVIDIA CUDA/cuDNN/L4T (not redistributable, local only),'
            echo '  # apt-toolchain/ is Ubuntu build packages (redistributable).'
            echo '  # Whichever is present gets installed; neither is required.'
            echo '  if ls apt/*.deb >/dev/null 2>&1; then'
            echo '    sudo dpkg -i apt/*.deb || sudo apt-get -f install'
            echo '  fi'
            echo '  if ls apt-toolchain/*.deb >/dev/null 2>&1; then'
            echo '    sudo dpkg -i apt-toolchain/*.deb || sudo apt-get -f install'
            echo '  fi'
            echo 'fi'
            echo ''
        fi
        echo 'echo "done."'
    } > "$f"
    chmod +x "$f"
    record_artifact "$f"
    log "wrote $(basename "$f") - this folder can now be installed without the repo"
}
