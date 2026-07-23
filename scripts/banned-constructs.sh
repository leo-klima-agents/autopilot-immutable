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

# ── opcode-level pass ─────────────────────────────────────────────────────
# Identifier greps filter vocabulary; the properties themselves are enforced
# on the compiled artifact: no DELEGATECALL / SELFDESTRUCT / CALLCODE opcode
# may appear in reachable runtime code (a rename cannot evade an opcode).
# The CBOR metadata tail is stripped first so its arbitrary bytes cannot
# false-positive as opcodes.
if command -v cast >/dev/null 2>&1 && [ -f out/EpochPilot.sol/EpochPilot.json ]; then
  RUNTIME=$(python3 - <<'PYEOF'
import json
code = json.load(open('out/EpochPilot.sol/EpochPilot.json'))['deployedBytecode']['object']
h = code[2:] if code.startswith('0x') else code
cbor_len = int(h[-4:], 16)          # last 2 bytes = metadata length
h = h[: len(h) - (cbor_len + 2) * 2]  # strip metadata + the length bytes
print('0x' + h)
PYEOF
)
  BADOPS=$(cast disassemble "$RUNTIME" 2>/dev/null | grep -cE '\b(DELEGATECALL|SELFDESTRUCT|CALLCODE)\b' || true)
  if [ "${BADOPS:-0}" -ne 0 ]; then
    echo "BANNED OPCODE in runtime bytecode (DELEGATECALL/SELFDESTRUCT/CALLCODE): $BADOPS occurrence(s)" >&2
    fail=1
  else
    echo "opcode scan: clean (no DELEGATECALL/SELFDESTRUCT/CALLCODE)"
  fi
else
  echo "opcode scan: skipped (need cast + a forge build); source greps only" >&2
fi

if [ "$fail" -ne 0 ]; then
  echo "banned-constructs: FAIL" >&2
  exit 1
fi
echo "banned-constructs: clean"
