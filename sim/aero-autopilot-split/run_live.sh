#!/usr/bin/env bash
# Fork-only runner for split_17968_live_relay.py (live factory-2 Maxi relay). Loopback anvil only.
#   BASE_RPC_URL=... METADEX=/path/to/metadex-public SOURCIFY_SRC=/path/to/sourcify/sources ./run_live.sh [out.json]
# SOURCIFY_SRC: the "sources" of https://sourcify.dev/server/v2/contract/8453/0x3909f8b833A8Beba57CEf8c6E713E885b6c359cE
# written out as files (a directory containing V3/src); used only to decode revert selectors.
set -euo pipefail
: "${BASE_RPC_URL:?}"; : "${METADEX:?}"; : "${SOURCIFY_SRC:?}"
FORK_BLOCK="${FORK_BLOCK:-53388239}"
PORT="${PORT:-8545}"
OUT="${1:-results_live.json}"
HERE="$(cd "$(dirname "$0")" && pwd)"
anvil --fork-url "$BASE_RPC_URL" --fork-block-number "$FORK_BLOCK" --host 127.0.0.1 --port "$PORT" --silent &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do cast chain-id --rpc-url "http://127.0.0.1:$PORT" >/dev/null 2>&1 && break; sleep 1; done
python3 -I "$HERE/split_17968_live_relay.py" --rpc "http://127.0.0.1:$PORT" --sources "$METADEX" "$SOURCIFY_SRC" --out "$OUT"
