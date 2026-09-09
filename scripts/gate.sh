#!/usr/bin/env bash
# Run the required analyzer before the legacy project gate.
set -u

script_dir=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd) || exit 2
project_root=$(CDPATH= cd "$script_dir/.." 2>/dev/null && pwd) || exit 2
cd "$project_root" || exit 2

resolve_executable() {
    candidate=$1
    case "$candidate" in
        */*)
            if [ -f "$candidate" ] && [ -x "$candidate" ]; then
                printf '%s\n' "$candidate"
            fi
            ;;
        *)
            command -v "$candidate" 2>/dev/null || true
            ;;
    esac
}

if [ -n "${ZWANZIG:-}" ]; then
    zwanzig=$(resolve_executable "$ZWANZIG")
elif [ -n "${HOME:-}" ] && [ -f "$HOME/.local/bin/zwanzig" ] && [ -x "$HOME/.local/bin/zwanzig" ]; then
    zwanzig=$HOME/.local/bin/zwanzig
else
    zwanzig=$(resolve_executable zwanzig)
fi

if [ -z "$zwanzig" ] || [ ! -f "$zwanzig" ] || [ ! -x "$zwanzig" ]; then
    echo "required analyzer not found: zwanzig" >&2
    exit 127
fi

threads=${ZWANZIG_THREADS:-2}
case "$threads" in
    *[1-9]*) ;;
    *)
        echo "ZWANZIG_THREADS must be a positive decimal integer" >&2
        exit 2
        ;;
esac
case "$threads" in
    *[!0-9]*)
        echo "ZWANZIG_THREADS must be a positive decimal integer" >&2
        exit 2
        ;;
esac

"$zwanzig" --threads "$threads" src tools build.zig
zwanzig_status=$?
if [ "$zwanzig_status" -ne 0 ]; then
    echo "required analyzer failed (exit $zwanzig_status)" >&2
    exit "$zwanzig_status"
fi

exec zig-gate "$@"
