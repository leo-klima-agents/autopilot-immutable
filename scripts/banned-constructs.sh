#!/usr/bin/env bash
# Banned-constructs gate (brief §5.1) — run over src/ on every commit.
# Comment lines are stripped first so documentation may *name* the bans;
# any hit in code is a hard failure, resolved by rewording code, never by
# weakening the grep.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

# all .sol lines under src/ with comments stripped, prefixed file:line:
code_lines() {
  grep -rnE --include='*.sol' '' src/ \
    | sed -E 's_//.*$__' \
    | grep -vE '^\S+:[0-9]+:\s*(\*|/\*)' || true
}

check() { # pattern description
  local hits
  hits=$(code_lines | grep -E "$1" || true)
  if [ -n "$hits" ]; then
    echo "$hits"
    echo "BANNED CONSTRUCT FOUND: $2" >&2
    fail=1
  fi
}

check 'delegatecall'            'delegatecall (no proxies, ever)'
check 'selfdestruct'            'selfdestruct'
check '\bassembly\b'            'inline assembly'
check '\bcatch\b'               'try/catch control flow (fail loudly)'
check '\bpayable\b'             'payable functions (the vault never holds ETH)'
check '\breceive\s*\(\s*\)'     'receive() (the vault never holds ETH)'
check '\bfallback\s*\(\s*\)'    'fallback()'
check '\bonly[A-Z][a-zA-Z]*'    'onlyX modifier (zero privileged parties)'
check '\becrecover\b'           'signatures'
check '\bpermit\s*\('           'permit'
check 'upgradeTo|UUPS|ERC1967'  'upgradeability'

# import allowlist: every import in src/ must target ./interfaces/ or ../interfaces/
while IFS= read -r line; do
  path=$(echo "$line" | sed -E 's/.*"([^"]+)".*/\1/')
  case "$path" in
    ./interfaces/*|../interfaces/*) ;;
    *) echo "BANNED IMPORT: $line" >&2; fail=1 ;;
  esac
done < <(grep -rhE --include='*.sol' '^\s*import\b' src/)

if [ "$fail" -ne 0 ]; then
  echo "banned-constructs: FAIL" >&2
  exit 1
fi
echo "banned-constructs: clean"
