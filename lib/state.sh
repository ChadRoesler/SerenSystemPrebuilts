# ------------------------------------------------------------
# lib/state.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines functions only, runs nothing.
# ------------------------------------------------------------

ensure_jq() {
    command -v jq &>/dev/null || sudo apt-get install -y jq
}

phase_done() { jq -r ".\"$1\" // false" "$STATE_FILE"; }

phase_mark() {
    local key="$1"
    local tmp; tmp="$(mktemp)"
    jq ".\"$key\" = true" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

phase_skip_if_done() {
    if [ "$(phase_done "$1")" = "true" ]; then
        info "Phase '$1' already complete - skipping (delete $STATE_FILE to redo)"
        return 0
    fi
    return 1
}

# ── dependency check, before anything is compiled ──
# A missing dependency is a WARNING, not a refusal: the dep is very often
# already satisfied on the box (python3.10 installed last month), and refusing
# would make the common case worse to serve the rare one. But it is said before
# the first compile rather than discovered four hours in.
_phase_requested() {
    local row name flag
    for row in "${PHASE_TABLE[@]}"; do
        IFS='|' read -r name flag _ _ _ <<< "$row"
        [ "$name" = "$1" ] && { [ "${!flag}" = "true" ] && return 0 || return 1; }
    done
    return 1
}

# ── did the phase skip ITSELF, or just one item inside it? ──
#
# A PHASE THAT BAILED IS NOT A PHASE THAT FINISHED, and conflating the two is
# how the Spark ended up with a complete-looking archive and no vLLM wheel.
#
# Every bail-out inside a phase is `note_skip <thing> <reason>; return 0`. It
# returns 0 deliberately - `set -e` is on and these are soft skips, not build
# failures. But the loop below then ran `phase_mark`, so the state file recorded
# vllm_spark=true for a phase that produced nothing. Every later run answered
# "Phase 'vllm_spark' already complete - skipping", so the one condition that
# caused the skip - torch was not the pinned version yet - could be fixed and
# the phase would still never run again. The archive stayed permanently short a
# wheel, and the only documented escape was deleting the whole state file and
# rebuilding torch from scratch to get back to it.
#
# The distinction that matters is WHAT was skipped. The vendor phase calls
# note_skip once per package it could not mirror ("vendor:numpy"); that is a
# complete phase with a known hole in it, and re-running it every time would
# make a resumable phase unresumable. A phase that skips ITSELF names itself -
# `note_skip vllm`, `note_skip wheelhouse`, `note_skip bitsandbytes` - and the
# keys it uses are already exactly the PHASE_TABLE names, so the table can tell
# the two apart without anyone maintaining a second list.
_phase_skipped_itself() {
    local want="$1" e
    for e in "${SEREN_SKIPPED[@]}"; do
        [ "${e%%|*}" = "$want" ] && return 0
    done
    return 1
}

# ── which dependency, if any, already failed this run ──
#
# The deps column in PHASE_TABLE existed only to print a warning before the
# first compile. It is a real graph and this uses it as one: if pytorch failed
# there is no point attempting torchvision, but bitsandbytes failing says
# nothing at all about vLLM. Echoes the first failed dependency so the caller
# can name it; silent when the phase is clear to run.
#
# Transitive by construction: a phase blocked this way is itself recorded with
# note_fail, so anything depending on IT is blocked on the next pass through
# the table. No graph walk needed, because the table is already in build order.
_phase_first_failed_dep() {
    local deps="$1" d e
    for d in ${deps//,/ }; do
        for e in "${SEREN_FAILED[@]}"; do
            [ "${e%%|*}" = "$d" ] && { echo "$d"; return 0; }
        done
    done
    return 0
}

# ── the three things a phase hands to the phases after it ──
#
# Phases now run inside a subshell so that `fail` - which is `exit 1`, in a
# hundred places - kills the phase instead of the run. The cost of that is a
# subshell cannot write to its parent's variables, and three of them genuinely
# have to survive:
#
#   SEREN_TORCH_WHEEL   build_pytorch sets it; ensure_torch reads it in every
#                       later phase to install the torch THIS run just built
#                       rather than whatever an index would serve.
#   SEREN_SKIPPED       note_skip appends; the summary and _phase_skipped_itself
#                       both read it.
#   SEREN_BUILT         note_built appends; the summary reads it.
#
# That is the entire contract, and it is written out with %q so a reason string
# containing spaces or quotes survives the round trip. Everything else a phase
# touches - cwd, PATH, VIRTUAL_ENV, the exported build vars - is deliberately
# NOT carried back: each phase calls use_venv and sets its own, so letting them
# die with the subshell is isolation, not loss.
_seren_export_handoff() {
    local out="$1"
    {
        printf 'SEREN_TORCH_WHEEL=%q\n' "${SEREN_TORCH_WHEEL:-}"
        _seren_emit_array SEREN_SKIPPED "${SEREN_SKIPPED[@]}"
        _seren_emit_array SEREN_BUILT   "${SEREN_BUILT[@]}"
    } > "$out" 2>/dev/null || true
}

# `printf '%q ' "${empty[@]}"` does NOT print nothing. With no arguments left to
# consume, printf runs the format once anyway and %q renders the absent argument
# as '' - so an empty array round-trips as an array holding one empty string.
# That is silent and it is wrong in the direction that matters: ${#SEREN_SKIPPED[@]}
# becomes 1, and a run that skipped nothing reports a skip with a blank name.
# The empty case gets its own branch rather than a clever one-liner.
_seren_emit_array() {
    local name="$1"; shift
    if [ "$#" -eq 0 ]; then
        printf '%s=()\n' "$name"
    else
        printf '%s=( %s )\n' "$name" "$(printf '%q ' "$@")"
    fi
}
