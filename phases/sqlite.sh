# ------------------------------------------------------------
# phases/sqlite.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines functions only, runs nothing.
# ------------------------------------------------------------

# Dispatch for SQLite + Python is below, after build_sqlite is defined.
# (Bash needs function definitions to precede their calls.)

# ═════════════════════════════════════════════════════════════
# SQLite 3.45 tarball (Xavier-only - Ubuntu 22.04 on Nano ships 3.37+)
# ═════════════════════════════════════════════════════════════
build_sqlite() {
    # Every platform, same reasoning as build_python: "the distro ships one"
    # is a statement about today.
    log "Building SQLite ${SQLITE_VERSION} for ${JP_FAMILY}/${PLATFORM_TAG}..."

    cd "$BUILD_DIR"
    sudo rm -rf sqlite-autoconf-${SQLITE_URL_VERSION} sqlite-autoconf-${SQLITE_URL_VERSION}.tar.gz 2>/dev/null || true
    wget -q --show-progress https://www.sqlite.org/${SQLITE_YEAR}/sqlite-autoconf-${SQLITE_URL_VERSION}.tar.gz
    tar xzf sqlite-autoconf-${SQLITE_URL_VERSION}.tar.gz
    cd sqlite-autoconf-${SQLITE_URL_VERSION}
    ./configure --prefix=/usr/local
    make -j"$RESOLVED_MAX_JOBS"

    local STAGE_DIR="$BUILD_DIR/sqlite-stage"
    sudo rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR"
    make install DESTDIR="$STAGE_DIR"

    local OUT="$PLATFORM_DIR/sqlite3.45-${JP_FAMILY}-${PLATFORM_TAG}-aarch64.tar.gz"
    cd "$STAGE_DIR/usr/local"
    sudo tar czf "$OUT" .
    sudo chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$OUT" 2>/dev/null || true

    # ALSO install to /usr/local on the build host. Required so a subsequent
    # build_python in the same pipeline run can link Python against modern
    # libsqlite3 (which is the whole point - older system libsqlite3 makes
    # Python's bundled sqlite3 module too old for ChromaDB).
    cd "$BUILD_DIR/sqlite-autoconf-${SQLITE_URL_VERSION}"
    sudo make install
    sudo ldconfig
    log "SQLite 3.45 also installed to /usr/local on build host ✓"

    echo "sqlite: $(basename "$OUT") ($(du -h "$OUT" | cut -f1))" >> "$BUILD_INFO"
    record_artifact "$OUT"
    log "SQLite tarball saved → $OUT ✓"

    cd ~
    sudo rm -rf "$BUILD_DIR/sqlite-autoconf-${SQLITE_URL_VERSION}" "$BUILD_DIR/sqlite-autoconf-${SQLITE_URL_VERSION}.tar.gz" "$STAGE_DIR"
}
