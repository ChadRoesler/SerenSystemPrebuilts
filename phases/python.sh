# ------------------------------------------------------------
# phases/python.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines functions only, runs nothing.
# ------------------------------------------------------------

# ═════════════════════════════════════════════════════════════
# Python 3.10 tarball (Xavier-only - Nano has it native via JetPack 6)
# ═════════════════════════════════════════════════════════════
build_python() {
    # EVERY PLATFORM, NOT JUST XAVIER. It was Xavier-only because JetPack 6
    # "ships Python 3.10 native" - true, and irrelevant to an archive whose
    # premise is that the thing shipping it may stop. This already builds from
    # python.org sources rather than deadsnakes, so the dependency it removes
    # is real; it just never ran anywhere else.
    # DERIVED FROM THE BASELINE, NOT HARDCODED. `make altinstall` names the
    # binary python<major.minor>, so a 3.12.8 baseline produces python3.12 -
    # and five lines below still said python3.10, left over from when this
    # phase was Xavier-only. They were correct until the phase started running
    # everywhere, and the symptom was a bewildering
    #     sudo: /mnt/nvme/python-stage/usr/local/bin/python3.10: command not found
    # from a build that had just successfully installed pip3.12 beside it.
    local PY_MM="${PYTHON_VERSION%.*}"
    log "Building Python ${PYTHON_VERSION} (python${PY_MM}) for ${JP_FAMILY}/${PLATFORM_TAG}..."

    # Runtime libs that Python 3.10 links against - also needed at install time
    sudo apt install -y \
        zlib1g-dev libncurses5-dev libgdbm-dev libnss3-dev \
        libreadline-dev libffi-dev libsqlite3-dev libbz2-dev liblzma-dev \
        build-essential

    cd "$BUILD_DIR"
    sudo rm -rf Python-${PYTHON_VERSION} Python-${PYTHON_VERSION}.tgz 2>/dev/null || true
    wget -q --show-progress https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz
    tar xzf Python-${PYTHON_VERSION}.tgz
    cd Python-${PYTHON_VERSION}

    # If /usr/local/lib has a newer libsqlite3.so (from build_sqlite or a
    # pre-existing source install), point the Python build at it so the
    # resulting `import sqlite3` reports the modern version. Without this,
    # CPython links against whatever Ubuntu's libsqlite3-dev ships - 3.31
    # on 20.04, which ChromaDB rejects.
    #
    # Note: must export these as separate vars (not jam them into a single
    # string passed to `env`). LDFLAGS contains spaces between flags, and
    # word-splitting that string makes `env` try to treat each flag as its
    # own var assignment, which fails on `-Wl,-rpath,/usr/local/lib`.
    if [ -f /usr/local/lib/libsqlite3.so ] && [ -f /usr/local/include/sqlite3.h ]; then
        log "Detected /usr/local SQLite - linking Python against it"
        export LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib"
        export CPPFLAGS="-I/usr/local/include"
        # Also help configure find sqlite3 via pkg-config style discovery
        export LD_LIBRARY_PATH="/usr/local/lib:${LD_LIBRARY_PATH:-}"
    else
        warn "No /usr/local SQLite found - Python will link against system libsqlite3"
        warn "If you want a modern bundled sqlite3 module, run --sqlite BEFORE --python"
    fi

    ./configure --enable-optimizations --prefix=/usr/local
    make -j"$RESOLVED_MAX_JOBS"

    # Sanity-check: make sure the build actually picked up modern sqlite3
    local PY_SQLITE_VER
    PY_SQLITE_VER=$(./python -c "import sqlite3; print(sqlite3.sqlite_version)" 2>/dev/null || echo "missing")
    log "Built Python's sqlite3 module reports version: $PY_SQLITE_VER"

    # Install into a staging dir so we can tarball just the new files,
    # not whatever else lives in /usr/local on the build box.
    local STAGE_DIR="$BUILD_DIR/python-stage"
    sudo rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR"
    make install DESTDIR="$STAGE_DIR"

    # Bootstrap pip INTO the staged tree so the resulting tarball is
    # self-sufficient. `make install` doesn't run ensurepip, so without this
    # step downstream consumers untar the file and immediately hit
    # "No module named pip" the first time they try to install anything.
    log "Bootstrapping pip into the staged Python tree..."
    # ASSERT THE BINARY IS THERE FIRST. Without this the failure surfaces as
    # sudo reporting "command not found", which reads like a PATH or sudoers
    # problem rather than "the interpreter is not named what we assumed".
    local STAGED_PY="$STAGE_DIR/usr/local/bin/python${PY_MM}"
    if [ ! -x "$STAGED_PY" ]; then
        warn "expected $STAGED_PY after altinstall; found:"
        ls -1 "$STAGE_DIR/usr/local/bin/" 2>/dev/null | sed 's/^/      /' >&2 || true
        fail "the staged Python is not named python${PY_MM} - altinstall layout changed"
    fi
    sudo "$STAGED_PY" -m ensurepip --upgrade --root="$STAGE_DIR" 2>/dev/null || \
        sudo "$STAGED_PY" -m ensurepip --upgrade
    sudo "$STAGED_PY" -m pip install --upgrade pip wheel setuptools \
        --root="$STAGE_DIR" --no-warn-script-location 2>/dev/null || true

    # The DESTDIR install creates $STAGE_DIR/usr/local/{bin,lib,include,share}
    # Strip pycache + binaries to shrink the tarball
    sudo find "$STAGE_DIR" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
    sudo strip "$STAGED_PY" 2>/dev/null || true

    # python3.10-jp5-xavier-... on Xavier exactly as before, because PY_MM is
    # 3.10 there - the install side hardcodes that name and must not break.
    local OUT="$PLATFORM_DIR/python${PY_MM}-${JP_FAMILY}-${PLATFORM_TAG}-aarch64.tar.gz"
    cd "$STAGE_DIR/usr/local"
    sudo tar czf "$OUT" .
    sudo chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$OUT" 2>/dev/null || true

    echo "python: $(basename "$OUT") ($(du -h "$OUT" | cut -f1))" >> "$BUILD_INFO"
    record_artifact "$OUT"
    log "Python tarball saved → $OUT ✓"

    cd ~
    sudo rm -rf "$BUILD_DIR/Python-${PYTHON_VERSION}" "$BUILD_DIR/Python-${PYTHON_VERSION}.tgz" "$STAGE_DIR"
}
