# ------------------------------------------------------------
# lib/apt.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines functions only, runs nothing.
# ------------------------------------------------------------

# ═════════════════════════════════════════════════════════════
# apt, which is the oldest live-repository dependency in here
# ═════════════════════════════════════════════════════════════
#
# THIS WHOLE FILE EXISTS BECAUSE OF ONE LINE THAT USED TO READ:
#
#     sudo apt install -y build-essential git ninja-build ... 2>/dev/null || true
#
# Every failure mode apt has was routed to /dev/null and then explicitly
# forgiven. On a healthy box that line is invisible. On a Xavier whose Ubuntu
# 20.04 archives have aged out from under it, EVERY package 404s, the errors are
# discarded, `|| true` says fine, and the run continues to die forty minutes
# later inside llama.cpp with
#
#     cmake: command not found
#
# which is true, useless, and about the fourth-order consequence of the actual
# problem. That is a week of searching for a missing package when the real
# answer was "your sources.list points at a host that stopped serving this
# release." The archive is supposed to be the thing that survives repositories
# going away; it cannot also be the thing that hides them going away.
#
# So: install, then VERIFY the packages actually landed, and when they did not,
# spend the effort to say why while the evidence is still on the machine.

# ── is this package actually installed right now? ──
# dpkg-query exits 0 for a package it merely KNOWS about - one that is removed
# but not purged still has a status line. "install ok installed" is the only
# status that means the files are on disk.
_apt_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

# ── does this base URL still serve this release? ──
# A HEAD request for the Release file, which every apt repository has at a
# predictable path. Quiet, tiny, and definitive - far better than reasoning
# about which mirror SHOULD have it.
_apt_serves() {
    local base="$1" codename="$2"
    command -v curl >/dev/null 2>&1 || return 1
    curl -fsS -I --max-time 10 "${base}/dists/${codename}/Release" >/dev/null 2>&1
}

# ── apt is broken; work out what would fix it, on this box, right now ──
#
# REFUSING TO GUESS THE MIRROR, and this is the one place where guessing is
# genuinely tempting. "Replace archive.ubuntu.com with old-releases.ubuntu.com"
# is the answer everyone repeats, and it is wrong in the detail that matters
# here: these boxes are aarch64, so their sources say ports.ubuntu.com, and the
# EOL path for ports is not the same string. Printing a remediation that does
# not work is worse than printing none - it costs another afternoon before
# anyone doubts it.
#
# So nothing is asserted. The codename comes off the machine, the hosts come out
# of the machine's own sources.list, each candidate is PROBED, and only a base
# that answers for this exact release is offered. If none answers, that is said
# too, rather than dressed up as advice.
#
# $SEREN_ETC is a test seam and is empty in every real run. This function only
# does anything interesting on a box whose repositories have already died, which
# is not a state you can conjure on demand and is a terrible one to first
# execute this code in. With it set, the whole diagnosis can be driven against a
# stub /etc and stub curl - so the remediation this prints has actually been
# seen to print, rather than being written once and hoped at.
apt_diagnose() {
    local out="${1:-}"
    local etc="${SEREN_ETC:-}"
    local codename arch
    codename="$(. "$etc/etc/os-release" 2>/dev/null && echo "${VERSION_CODENAME:-}")"
    arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"

    warn ""
    warn "─── apt could not install what this build needs ───"
    [ -n "$codename" ] && warn "  release: ${codename} (${arch})"

    if ! echo "$out" | grep -qiE '404|Failed to fetch|does not have a Release file|Could not resolve|Temporary failure'; then
        warn "  This does not look like a repository problem - the apt output above"
        warn "  is the evidence. Common other causes: no sudo, another apt/dpkg"
        warn "  holding the lock, or a half-configured dpkg state (sudo dpkg --configure -a)."
        return 0
    fi

    warn "  apt could not FETCH. Either this release has aged out of its mirror,"
    warn "  or this box cannot reach the network at all."
    warn ""

    if ! command -v curl >/dev/null 2>&1; then
        warn "  curl is not installed, so this cannot probe for a working mirror."
        warn "  Check by hand whether the hosts in /etc/apt/sources.list still"
        warn "  serve dists/${codename}/Release."
        return 0
    fi
    [ -n "$codename" ] || { warn "  No VERSION_CODENAME in ${etc}/etc/os-release - cannot probe."; return 0; }

    # The hosts this box is actually configured to use.
    local hosts
    hosts="$(cat "$etc"/etc/apt/sources.list "$etc"/etc/apt/sources.list.d/*.list \
                 "$etc"/etc/apt/sources.list.d/*.sources 2>/dev/null \
             | grep -oE 'https?://[^ ]+' | sed 's#/*$##' | sort -u || true)"

    local live="" dead="" h
    for h in $hosts; do
        case "$h" in *ubuntu*|*debian*) ;; *) continue ;; esac
        if _apt_serves "$h" "$codename"; then live="$live $h"; else dead="$dead $h"; fi
    done
    [ -n "$dead" ] && { warn "  NOT serving ${codename} any more:"; for h in $dead; do warn "      $h"; done; }
    [ -n "$live" ] && { warn "  still serving ${codename}:";        for h in $live; do warn "      $h"; done; }

    # Probe the archive-of-record. Both spellings, because which one applies
    # depends on whether this box's packages come from the main archive or from
    # the ports tree - and that is exactly the detail worth not guessing at.
    local cand found=""
    for cand in http://old-releases.ubuntu.com/ubuntu-ports \
                http://old-releases.ubuntu.com/ubuntu; do
        if _apt_serves "$cand" "$codename"; then found="$cand"; break; fi
    done

    warn ""
    if [ -n "$found" ]; then
        warn "  ${found} DOES still serve ${codename}."
        warn "  Repoint this box at it (keeping a backup), then re-run this script:"
        warn ""
        local d
        for d in $dead; do
            warn "      sudo sed -i.seren-bak 's|${d}|${found}|g' \\"
            warn "           /etc/apt/sources.list /etc/apt/sources.list.d/*.list"
        done
        [ -n "$dead" ] || warn "      # (no dead ubuntu host was identified - check sources.list by hand)"
        warn "      sudo apt-get update"
        warn ""
        warn "  LEAVE THE NVIDIA LINES ALONE. repo.download.nvidia.com is a separate"
        warn "  repository on its own clock; rewriting it will break the CUDA"
        warn "  packages that nothing else can rebuild. Only the ubuntu hosts move."
    else
        warn "  Nothing probed still serves ${codename} - including the EOL archive."
        warn "  If this box has no network at all that is the simpler explanation;"
        warn "  check that first. Otherwise the packages have to come from a local"
        warn "  mirror or from another machine's /var/cache/apt/archives."
    fi
    warn ""
    warn "  If a previous run of this script archived them, they are already here:"
    warn "      $PLATFORM_DIR/apt/     (sudo dpkg -i *.deb; sudo apt-get -f install)"
}

# ── install these, then prove they are installed ──
#
# THE EXIT CODE IS NOT THE TEST. `apt-get install -y` can exit non-zero having
# installed most of what was asked, and - with the wrong flags or a held
# package - can exit zero having installed none of it. dpkg is asked afterwards,
# per package, because that is the question the build actually cares about.
#
# Fatal when it cannot be satisfied, and that is a deliberate change from the
# `|| true` this replaced. These packages are only requested when a phase that
# needs a compiler was requested; carrying on without them does not produce a
# smaller archive, it produces the same failure later with less context.
apt_require() {
    local pkgs=("$@") missing=() p
    [ ${#pkgs[@]} -gt 0 ] || return 0

    for p in "${pkgs[@]}"; do _apt_installed "$p" || missing+=("$p"); done
    if [ ${#missing[@]} -eq 0 ]; then
        log "apt: all ${#pkgs[@]} build dependencies already present"
        return 0
    fi

    log "apt: ${#missing[@]} of ${#pkgs[@]} build dependencies missing: ${missing[*]}"
    local out
    out="$(sudo apt-get install -y "${missing[@]}" 2>&1)" || true

    local still=()
    for p in "${missing[@]}"; do _apt_installed "$p" || still+=("$p"); done
    if [ ${#still[@]} -eq 0 ]; then
        log "apt: installed ${#missing[@]} package(s) ✓"
        return 0
    fi

    echo "$out" | tail -25 >&2
    apt_diagnose "$out"
    fail "apt could not install: ${still[*]}
  Every compiled phase in this script needs these. Continuing would fail later,
  further from the cause - which is the entire reason this is fatal here."
}

# ═════════════════════════════════════════════════════════════
# WHICH OpenBLAS, and it is not a detail
# ═════════════════════════════════════════════════════════════
#
# On the Xavier this produced a torch wheel that silently returned NaN for 5%
# of the first matmul in every process. Measured, not inferred:
#
#   openblas-openmp    nan 0
#   openblas-pthread   nan 3584      <- the distro default
#   openblas-serial    nan 0
#
# The failing entries were every column where c mod 32 is 14 or 15, EXCEPT the
# ones inside thread 0's slice - so the count tracked the thread count exactly
# (1->0, 2->8, 4->12, 8->14 bad columns, i.e. 16 - 16/t). The GEMM micro-kernel
# has a 2-column remainder at offset 14-15 of each 32-column panel, and on the
# FIRST call the worker threads never run it. The master thread does, which is
# why single-threaded was clean and why every later matmul in the process was
# clean - and why this survived in an archive that was treated as finished.
#
# The cause is two thread pools, not a broken kernel: torch is built
# USE_OPENMP=ON and Ubuntu's default libopenblas is the PTHREAD build, so
# OpenBLAS spawns its own pthreads inside torch's OpenMP region. The openmp
# build shares torch's runtime; the serial build has no threads to get wrong.
# Debian/Ubuntu ship all three behind one soname and pick between them with
# update-alternatives, so this is a symlink, not a rebuild.
#
# NOT FATAL. A box where this cannot be selected still builds a usable archive -
# every CUDA path is unaffected, and the selftest's "cpu matmul is sane" check
# is what catches the consequence either way. This is here so the default stops
# being the broken one, not to gate the build on it.
ensure_openblas_openmp() {
    command -v update-alternatives >/dev/null 2>&1 || return 0

    local group
    group="$(update-alternatives --get-selections 2>/dev/null \
             | awk '$1 ~ /^libopenblas\.so\.[0-9]+-/ {print $1; exit}')"
    if [ -z "$group" ]; then
        log "openblas: not managed by update-alternatives here - leaving it alone"
        return 0
    fi

    local alt want=""
    for alt in $(update-alternatives --list "$group" 2>/dev/null); do
        case "$alt" in *openblas-openmp*) want="$alt"; break ;; esac
    done
    if [ -z "$want" ]; then
        warn "openblas: no openmp variant installed, so the pthread one stays selected."
        warn "  On JetPack 5 that combination returns NaN from the first CPU matmul"
        warn "  in each process. Install it with:  sudo apt install libopenblas0-openmp"
        warn "  The selftest's 'cpu matmul is sane' check will tell you if it bites here."
        return 0
    fi

    local now
    now="$(update-alternatives --query "$group" 2>/dev/null | awk '/^Value:/{print $2}')"
    if [ "$now" = "$want" ]; then
        log "openblas: already using $(basename "$(dirname "$want")") ✓"
    else
        # Plainly, not as a nested parameter expansion: dirname of an empty
        # string is "." and would log "switching from .", but `${now:+a}${now:-b}`
        # emits BOTH halves when now is set. A variable and a test are clearer
        # than a one-liner that is wrong in one of its two cases.
        local nowlabel="<unknown>"
        [ -n "$now" ] && nowlabel="$(basename "$(dirname "$now")")"
        log "openblas: switching from $nowlabel to $(basename "$(dirname "$want")")"
        sudo update-alternatives --set "$group" "$want" >/dev/null 2>&1 \
            || { warn "  could not set the alternative - leaving it as it was"; return 0; }
    fi

    # RECORDED, because the wheel's correctness depended on which of three
    # interchangeable symlinks was active and nothing anywhere wrote that down.
    # Read back rather than assumed; falls back to what was requested if this
    # box's update-alternatives will not answer a query.
    local active
    active="$(update-alternatives --query "$group" 2>/dev/null | awk '/^Value:/{print $2}')"
    $DO_VERIFY || echo "openblas         ${active:-$want}" >> "$PROVENANCE"
}
