# ------------------------------------------------------------
# lib/pins.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines values and two helpers, runs nothing.
# ------------------------------------------------------------
#
# ═════════════════════════════════════════════════════════════
# The two git sources, pinned by default
# ═════════════════════════════════════════════════════════════
#
# llama.cpp and gasket-driver are the two things here that come from a git
# clone rather than a versioned tarball, and both used to be cloned at
# whatever HEAD was that minute. --llama-ref / --gasket-ref were added so a
# build COULD be pinned, and then the default stayed "that minute" - so every
# build that did not think to pass the flag was unreproducible by
# construction, with a note in the provenance saying so.
#
# A default that has to be overridden to be reproducible is the wrong way
# round. These are the defaults now. `--llama-ref latest` (or --gasket-ref)
# is the explicit way to chase upstream HEAD, and the resolved SHA is written
# to the provenance either way, as it always was.
#
# WHAT THE SHIPPED ARCHIVES WERE BUILT FROM IS NOT KNOWN. The September 2026
# builds recorded their llama.cpp and gasket commits in the provenance, and a
# later one-minute --cudadebs pass truncated the file (the bug fixed alongside
# this). The binaries carry no recoverable commit string. So these pins are
# not "what shipped"; they are "what a rebuild gets", chosen on 2026-09-23:
#
#   llama.cpp      the release current on that date. Bump deliberately, with
#                  a --llama --selftest run on each box, and record the new
#                  tag here.
#   gasket-driver  upstream HEAD, which has not moved since 2024-04-25 - so a
#                  clone at any point in the last two years, including the
#                  September builds, got this commit. The kernel patches in
#                  phases/coral.sh are written against it.
#
# A ref here is whatever `git checkout` accepts: a tag, a branch, or a SHA.
LLAMA_REF_DEFAULT="v0.4.1"
GASKET_REF_DEFAULT="5815ee3908a46a415aac616ac7b9aedcb98a504c"

# resolve_ref USER_VALUE DEFAULT
#   empty  -> the default (pinned)
#   latest -> "" (unpinned: clone HEAD, record what it was)
#   else   -> as given
resolve_ref() {
    local user="$1" default="$2"
    case "$user" in
        "")       echo "$default" ;;
        latest)   echo "" ;;
        *)        echo "$user" ;;
    esac
}

# describe_ref REF - the provenance's one-line description of a pin.
describe_ref() {
    if [ -n "$1" ]; then
        echo "$1 (pinned; resolved sha recorded below)"
    else
        echo "<unpinned: upstream HEAD, sha recorded below>"
    fi
}
