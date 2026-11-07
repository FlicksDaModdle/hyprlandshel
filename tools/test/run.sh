#!/bin/bash
# The Rust rewrite's automated tests: everything runs on its own, and what
# broke comes back as a report — no clicking through it by hand.
#
#   tools/test/run.sh                 everything
#   tools/test/run.sh lock greeter    some areas: unit lock greeter settings shell
#   tools/test/run.sh shell:launcher  one test of an area
#   tools/test/run.sh --accept        take this run's screenshots as the new
#                                     references (after a change meant to show)
#   tools/test/run.sh --keep          keep the test folder (logs, screenshots)
#   tools/test/run.sh --list          the areas and their tests
#
# How: a private, headless sway (nothing appears on your screen, nothing of
# yours is touched — its own HOME, config and runtime folder), the shell,
# Settings and the login screen run in it, driven by a virtual pointer and
# keyboard (tools/test/harness), with stand-ins for what isn't there to test
# against (tools/test/fakes): hyprshell-daemon, hyprctl, pactl, greetd, PAM.
# Each test checks what happened — a file written, a command run, a process
# ended — and screenshots are compared with the last accepted ones
# (~/.local/share/hyprshell/test-ref, per machine: fonts differ).
#
# Needs: cargo, sway, grim, python3. The report ends in
# $XDG_RUNTIME_DIR/hyprshell-test/report.md (and is printed); exit status 0
# when everything passed.
#
# The tests' shell is built with --features test-hooks, in its own target
# folder: the stand-in PAM and clock exist only in that build.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
. "$HERE/lib.sh"

areas=() accept=0 keep=0 list=0
for a in "$@"; do
    case "$a" in
        --accept) accept=1 ;;
        --keep) keep=1 ;;
        --list) list=1 ;;
        -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option $a" >&2; exit 2 ;;
        *) areas+=("$a") ;;
    esac
done
ALL=(unit lock greeter settings shell)
[ ${#areas[@]} -eq 0 ] && areas=("${ALL[@]}")

if [ "$list" = 1 ]; then
    for a in "${ALL[@]}"; do
        echo "$a:"
        ( TT_TESTS=(); . "$HERE/lib.sh"; . "$HERE/scenarios/$a.sh"
          [ ${#TT_TESTS[@]} -eq 0 ] && mapfile -t TT_TESTS < <(grep -o '^test_[a-z0-9_]*' "$HERE/scenarios/$a.sh")
          printf '  %s\n' "${TT_TESTS[@]#test_}" )
    done
    exit 0
fi

export TT_ACCEPT=$accept
tt_setup || exit 2
trap 'tt_teardown' EXIT

for a in "${areas[@]}"; do
    only=""
    case "$a" in *:*) only="test_${a#*:}"; a="${a%%:*}" ;; esac
    f="$HERE/scenarios/$a.sh"
    [ -f "$f" ] || { echo "no area called $a (tools/test/run.sh --list)"; continue; }
    tt_area "$a"
    # shellcheck disable=SC1090
    TT_TESTS=()
    . "$f"
    # A file may list its own (Settings makes one per pane); else its
    # test_ functions, in the order written.
    [ ${#TT_TESTS[@]} -eq 0 ] && mapfile -t TT_TESTS < <(grep -o '^test_[a-z0-9_]*' "$f")
    for t in "${TT_TESTS[@]}"; do
        [ -n "$only" ] && [ "$t" != "$only" ] && continue
        tt_run "$a" "$t"
    done
done

tt_report
[ "$keep" = 1 ] && TT_KEEP=1
[ "$TT_FAILED" = 0 ]
