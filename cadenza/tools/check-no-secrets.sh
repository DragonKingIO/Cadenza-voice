#!/bin/bash
# Scans the files Git tracks (or, with --staged, the files about to be committed) for things that must never be published:
# private keys, access tokens, personal e-mail addresses and absolute home-directory paths.
#
#   cadenza/tools/check-no-secrets.sh            # every tracked file
#   cadenza/tools/check-no-secrets.sh --staged   # only what is staged
#
# Exit status 0 means nothing was found. It is a safety net, not a guarantee: read your diff before you push.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

if [ "${1:-}" = "--staged" ]; then FILES=$(git diff --cached --name-only --diff-filter=ACMR); else FILES=$(git ls-files); fi
[ -z "$FILES" ] && { echo "check-no-secrets: nothing to scan"; exit 0; }

FOUND=0
scan() { # description, extended regex, [allowed-regex]
    local hits
    hits=$(printf '%s\n' "$FILES" | tr '\n' '\0' | xargs -0 grep -I -n -E -- "$2" 2>/dev/null | grep -v -E "check-no-secrets\.sh:" || true)
    [ -n "${3:-}" ] && hits=$(printf '%s\n' "$hits" | grep -v -E -- "$3" || true)
    hits=$(printf '%s\n' "$hits" | sed '/^$/d')
    if [ -n "$hits" ]; then
        echo "FOUND: $1"; printf '%s\n' "$hits" | cut -c1-160 | head -8 | sed 's/^/    /'; FOUND=1
    fi
}

scan "private key block"            '-----BEGIN [A-Z ]*PRIVATE KEY-----'
scan "GitHub token"                 'gh[pousr]_[A-Za-z0-9]{30,}'
scan "API key shaped like sk-"      'sk-[A-Za-z0-9]{24,}'
scan "AWS access key id"            'AKIA[0-9A-Z]{16}'
scan "app device token (cdz_...)"   'cdz_[A-Za-z0-9_-]{30,}'
scan "absolute home path"           '/Users/[A-Za-z0-9._-]+/' '/Users/(you|name|me|example|USER|user)/'
# Upstream license texts in cadenza/licenses/ must stay verbatim and name their authors, so their addresses are allowed there.
scan "e-mail address"               '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' '^cadenza/licenses/|noreply|@example\.|@localhost|@2x|@3x|git@github\.com|@users\.noreply'

if [ "$FOUND" -eq 0 ]; then echo "check-no-secrets: clean ($(printf '%s\n' "$FILES" | wc -l | tr -d ' ') files scanned)"; fi
exit "$FOUND"
