# ------------------------------------------------------------
# phases/cudadebs.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines functions only, runs nothing.
# ------------------------------------------------------------

# ═════════════════════════════════════════════════════════════
# CUDA / cuDNN / L4T .debs - the layer underneath everything else
# ═════════════════════════════════════════════════════════════
#
# THE DEEPEST DEPENDENCY IN THIS REPO IS NOT ON PyPI. Every torch wheel here
# links libcudart, libcublas and libcudnn at runtime. Those come from NVIDIA's
# apt repositories, which are live repositories on a support clock - and
# JetPack 5's will age out. The day it does, a reflashed Xavier cannot get the
# toolkit back, and every wheel in this archive is inert: correct, verified,
# and unloadable.
#
# So the .debs get cached while the repo still serves them. This is gigabytes.
# It is also the only part of the stack that genuinely cannot be rebuilt from
# source by anybody outside NVIDIA.
build_cudadebs() {
    local D="$PLATFORM_DIR/apt"
    mkdir -p "$D"
    log "Caching the CUDA / cuDNN / L4T .debs this box is running..."

    # WHAT IS INSTALLED, read from dpkg. Not a hand-written package list, which
    # would be a guess about a layout that differs across all three boxes.
    local list="$D/PACKAGES-${PLATFORM_TAG}-${JP_FAMILY}.txt"
    local installed
    installed="$(dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' 2>/dev/null || true)"

    # ── THE TOOLCHAIN GOES IN TOO, AND IT IS NOT A NICE-TO-HAVE ──
    # CUDA was archived here because "NVIDIA's repo is a live repository on a
    # support clock". Every word of that is also true of Ubuntu's, and Ubuntu's
    # is the one that actually aged out from under a Xavier first: 20.04 went
    # EOL and every apt line in this script started 404ing. An archive holding
    # a perfect CUDA stack and no build-essential still cannot rebuild the box.
    #
    # THE CLOSURE, NOT JUST THE NAMES. build-essential is a metapackage - it is
    # about 3KB and depends on gcc, g++, make, libc6-dev and a chain behind
    # those. Caching the twelve names in SEREN_APT_BUILD_DEPS and nothing else
    # would archive twelve pointers to packages that are gone. apt-cache works
    # the closure out; it is filtered to what is actually INSTALLED here,
    # because that is the set these artifacts were genuinely built against.
    # ── TWO SETS, TWO DIRECTORIES, AND THE REASON IS LICENSING ──
    #
    # These packages come from two different worlds and only one of them can be
    # republished. NVIDIA's CUDA/cuDNN/L4T debs carry redistribution terms that
    # are not permissive - mirroring them in a public GitHub release is a real
    # legal exposure, and cuDNN's terms are stricter than CUDA's. Ubuntu's own
    # toolchain packages (gcc, libc6-dev, cmake, libopenblas0-openmp) are BSD
    # and GPL and are explicitly redistributable.
    #
    # Keeping both in one folder forced an all-or-nothing choice, and "nothing"
    # is the wrong answer: libopenblas0-openmp is what makes the Xavier's torch
    # wheel CORRECT (see ensure_openblas_openmp - the pthread build silently
    # returns NaN from the first CPU matmul). An archive that ships the wheel
    # but not the one package that makes it right is not self-sufficient.
    #
    # So they are separated HERE, at download time, rather than by a filter at
    # publish time. A release step that has to re-derive which deb came from
    # which vendor is a filter that can be got wrong once and leak; a directory
    # that only ever receives Ubuntu packages cannot.
    #
    # WHEN IN DOUBT IT GOES IN THE NVIDIA PILE. A package matching the NVIDIA
    # pattern stays out of the publishable set even if the toolchain closure
    # also pulled it in - the conservative direction is the safe one.
    local T="$PLATFORM_DIR/apt-toolchain"
    mkdir -p "$T"

    local wanted; wanted="$(mktemp)"
    printf '%s\n' "$installed" | awk -v re="$CUDA_DEB_MATCH" '$1 ~ re {print $0, "nvidia"}' > "$wanted"
    local cuda_count; cuda_count=$(wc -l < "$wanted" 2>/dev/null || echo 0)

    local closure="" tool_count=0
    if [ "${#SEREN_APT_BUILD_DEPS[@]}" -gt 0 ] && command -v apt-cache >/dev/null 2>&1; then
        closure="$(apt-cache depends --recurse --no-recommends --no-suggests \
                       --no-conflicts --no-breaks --no-replaces --no-enhances \
                       "${SEREN_APT_BUILD_DEPS[@]}" 2>/dev/null \
                   | grep -oE '^[a-zA-Z0-9][a-zA-Z0-9+.-]*$' | sort -u || true)"
    fi
    if [ -n "$closure" ]; then
        # Intersect the closure with what dpkg says is installed, and drop
        # anything already claimed by the NVIDIA pattern.
        printf '%s\n' "$installed" \
            | awk -v re="$CUDA_DEB_MATCH" \
                  'NR==FNR{keep[$1];next} ($1 in keep) && $1 !~ re {print $0, "toolchain"}' \
                  <(printf '%s\n' "$closure") - \
            >> "$wanted"
        tool_count=$(( $(wc -l < "$wanted") - cuda_count ))
    fi

    sort -u "$wanted" > "$list"; rm -f "$wanted"

    local count; count=$(wc -l < "$list" 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then
        warn "no installed packages matched /$CUDA_DEB_MATCH/ and no toolchain closure resolved"
        warn "  Adjust the filter with --cuda-debs-match if this box names them differently."
        note_skip cudadebs "no packages matched the filter"
        return 0
    fi
    log "  $count packages to cache ($cuda_count matched /$CUDA_DEB_MATCH/, $tool_count from the build toolchain)"

    local avail_gb
    avail_gb=$(df -BG "$PLATFORM_DIR" | awk 'NR==2 {gsub("G",""); print $4}')
    if [ -n "$avail_gb" ] && [ "$avail_gb" -lt 12 ] 2>/dev/null; then
        warn "only ${avail_gb}GB free at $PLATFORM_DIR - a full JetPack cache is bigger than that."
        warn "  Continuing anyway; partial is still better than nothing, and"
        warn "  UNAVAILABLE.txt will record whatever did not fit or download."
    fi

    # Where the packages came from, so a future you knows what to hunt for even
    # if the .deb itself is missing.
    { apt-cache policy 2>/dev/null || true; } > "$D/APT-SOURCES.txt"
    cat /etc/apt/sources.list /etc/apt/sources.list.d/*.list \
        /etc/apt/sources.list.d/*.sources 2>/dev/null >> "$D/APT-SOURCES.txt" || true

    : > "$D/UNAVAILABLE.txt"
    local got=0 have=0 missed=0 pkg ver arch set dest cached escaped
    while read -r pkg ver arch set; do
        [ -n "$pkg" ] || continue
        escaped="${ver//:/%3a}"
        # Default to the NVIDIA (non-publishable) directory: an unmarked line
        # from an older PACKAGES file must not silently become publishable.
        dest="$D"; [ "$set" = "toolchain" ] && dest="$T"

        # 0. ALREADY IN THE ARCHIVE - and without this the phase could not be
        #    re-run, which is what let the Xavier ship without its OpenBLAS deb.
        #    Every package went back to apt whether or not the .deb was already
        #    sitting here, so a second run meant re-downloading gigabytes. That
        #    made the phase feel one-shot, it was state-skipped to match, and a
        #    package installed AFTER the first run could therefore never be
        #    added. Checking here makes re-running nearly free, which is what
        #    makes it safe to always run (see the never-skip list in the
        #    orchestrator).
        #
        # BOTH DIRECTORIES ARE CHECKED, because the split arrived after some
        # archives had already been built - a toolchain deb sitting in the old
        # apt/ folder is still cached, it is just in the wrong place. Moved
        # rather than re-downloaded.
        if [ -f "$dest/${pkg}_${escaped}_${arch}.deb" ]; then
            have=$((have + 1)); continue
        fi
        if [ "$dest" = "$T" ] && [ -f "$D/${pkg}_${escaped}_${arch}.deb" ]; then
            mv "$D/${pkg}_${escaped}_${arch}.deb" "$T/" 2>/dev/null \
                && { have=$((have + 1)); continue; }
        fi

        # 1. apt's own cache, if it has not been cleaned. The version in a .deb
        #    filename escapes ':' as %3a, which is why this is not a plain glob.
        cached="/var/cache/apt/archives/${pkg}_${escaped}_${arch}.deb"
        if [ -f "$cached" ]; then
            cp -n "$cached" "$dest/" 2>/dev/null && got=$((got + 1)) && continue
        fi
        # 2. ask the repository, pinned to the version that is actually
        #    installed - `apt-get download pkg` would fetch the CANDIDATE, which
        #    can be newer than what these artifacts were built against.
        if ( cd "$dest" && apt-get download "${pkg}=${ver}" >/dev/null 2>&1 ); then
            got=$((got + 1))
        elif ( cd "$dest" && apt-get download "${pkg}:${arch}" >/dev/null 2>&1 ); then
            warn "  $pkg: repo would not serve $ver, took the candidate instead"
            echo "$pkg $ver (cached a DIFFERENT version - repo no longer serves this one)" >> "$D/UNAVAILABLE.txt"
            got=$((got + 1))
        else
            missed=$((missed + 1))
            echo "$pkg $ver $arch" >> "$D/UNAVAILABLE.txt"
        fi
    done < "$list"

    local size tsize
    size=$(du -sh "$D" 2>/dev/null | cut -f1)
    tsize=$(du -sh "$T" 2>/dev/null | cut -f1)
    log "  cached $got new .debs, $have already here, $missed unavailable"
    log "    apt/           $size  (NVIDIA CUDA/cuDNN/L4T - DO NOT REPUBLISH)"
    log "    apt-toolchain/ $tsize  (Ubuntu build toolchain - redistributable)"
    if [ "$missed" -gt 0 ]; then
        warn "  $missed packages could not be downloaded - listed in $(basename "$D")/UNAVAILABLE.txt"
        warn "  If those are CUDA runtime libraries, this archive cannot fully"
        warn "  rebuild this box. That is worth knowing NOW rather than later."
    fi

    {
        echo "# NVIDIA CUDA / cuDNN / L4T packages - ${cuda_count} matched /${CUDA_DEB_MATCH}/"
        echo "#"
        echo "# ***  DO NOT REPUBLISH THIS DIRECTORY.  ***"
        echo "# These are NVIDIA's redistributables and their licence terms are NOT"
        echo "# permissive about mirroring - cuDNN's are stricter than CUDA's. Keep"
        echo "# this folder local. It is excluded from GitHub releases deliberately;"
        echo "# the sibling apt-toolchain/ directory is the publishable one."
        echo "#"
        echo "# It is still worth keeping: this is the ONLY part of the archive that"
        echo "# nobody outside NVIDIA can rebuild from source, and JetPack 5's repo"
        echo "# is on a support clock. Reinstall on a box that has lost the toolkit:"
        echo "#   sudo dpkg -i *.deb          # then, to settle dependencies:"
        echo "#   sudo apt-get -f install"
        echo "#"
        echo "# Cached $(date -Iseconds) on $(uname -n) for ${PLATFORM_TAG}/${JP_FAMILY}."
        echo "# PACKAGES-*.txt is what was INSTALLED; UNAVAILABLE.txt is what the"
        echo "# repository would no longer serve on that date."
    } > "$D/README.txt"

    {
        echo "# Ubuntu build toolchain - ${tool_count} packages, with their dependency closure"
        echo "#"
        echo "# Redistributable: these are Ubuntu's own packages (BSD, GPL and"
        echo "# friends), not NVIDIA's. Safe to attach to a GitHub release, unlike"
        echo "# the sibling apt/ directory."
        echo "#"
        echo "# WHY AN ARCHIVE NEEDS THESE AT ALL: Ubuntu's repositories age out"
        echo "# exactly like NVIDIA's. When 20.04 went EOL every apt line for this"
        echo "# box started returning 404, and a folder full of perfect wheels with"
        echo "# no compiler cannot rebuild anything."
        echo "#"
        echo "# ONE OF THESE IS LOAD-BEARING FOR CORRECTNESS, not just for building:"
        echo "# libopenblas0-openmp. This platform's torch is built USE_OPENMP=ON,"
        echo "# and Ubuntu's DEFAULT libopenblas is the pthread build. That pairing"
        echo "# makes the first CPU matmul in every process return NaN for a few"
        echo "# percent of its output - silently, no error. Measured on a Xavier:"
        echo "# 3584 wrong values out of 65536; the openmp and serial builds both"
        echo "# give 0. INSTALL.sh selects the openmp one and then proves it."
        echo "#"
        echo "# Install from here when apt cannot reach a mirror:"
        echo "#   sudo dpkg -i *.deb || sudo apt-get -f install"
        echo "#"
        echo "# Cached $(date -Iseconds) on $(uname -n) for ${PLATFORM_TAG}/${JP_FAMILY}."
    } > "$T/README.txt"

    echo "apt_cache        $got debs, apt/ $size + apt-toolchain/ $tsize ($missed unavailable)" >> "$PROVENANCE"
    echo "apt_publishable  apt-toolchain/ only - apt/ holds NVIDIA redistributables" >> "$PROVENANCE"
    echo "cuda debs: $got cached (apt/ $size, apt-toolchain/ $tsize)" >> "$BUILD_INFO"
    record_artifact "$list"
    record_artifact "$D/README.txt"
    record_artifact "$T/README.txt"
    # The .debs themselves are checksummed but not listed one per line in the
    # build log - there are hundreds and the manifest is the record. Both
    # directories get checksummed: the toolchain set is the one that travels in
    # a release, so it is the one that most needs a verifiable SHA256SUMS line.
    local f
    for f in "$D"/*.deb "$T"/*.deb; do
        [ -f "$f" ] && record_artifact "$f"
    done
    [ "$got" -gt 0 ] && note_built cudadebs
    cd ~
}
