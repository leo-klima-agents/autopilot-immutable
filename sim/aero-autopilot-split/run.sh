#!/usr/bin/env bash
# Fork-only runner: start a fresh local anvil fork of Base at a pinned block, run the driver
# against 127.0.0.1 only, stop anvil. Nothing is signed or broadcast to Base.
#
#   BASE_RPC_URL=... METADEX=/path/to/metadex-public ./run.sh [out.json]
set -euo pipefail
: "${BASE_RPC_URL:?set BASE_RPC_URL (read-only upstream for the fork)}"
: "${METADEX:?set METADEX to a metadex-public checkout (used for the error-selector table)}"
FORK_BLOCK="${FORK_BLOCK:-53387600}"
PORT="${PORT:-8545}"
OUT="${1:-results.json}"
HERE="$(cd "$(dirname "$0")" && pwd)"

anvil --fork-url "$BASE_RPC_URL" --fork-block-number "$FORK_BLOCK" --host 127.0.0.1 --port "$PORT" \
  --silent &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do
  cast chain-id --rpc-url "http://127.0.0.1:$PORT" >/dev/null 2>&1 && break
  sleep 1
done

python3 -I "$HERE/split_17968.py" --rpc "http://127.0.0.1:$PORT" --metadex "$METADEX" --out "$OUT"
