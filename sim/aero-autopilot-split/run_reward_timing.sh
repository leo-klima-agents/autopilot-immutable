#!/usr/bin/env bash
# Fork-only: replay the live relays' first reward round (2026-11-03) around joins and exits.
#   BASE_RPC_URL=... ./run_reward_timing.sh [out.json]
set -euo pipefail
: "${BASE_RPC_URL:?}"
PORT="${PORT:-8545}"; OUT_PREFIX="${1:-results_reward_timing}"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROUND_JSON="$(mktemp)"
# read-only fetch of the real round transactions (sender, target, calldata, value)
python3 -I - "$BASE_RPC_URL" "$ROUND_JSON" <<'PY'
import json, subprocess, sys
R, out = sys.argv[1], sys.argv[2]
txs = {"sAERO": ["0xae8cffad78be12b0333f666fd4e5ea611f78b49cb3d24db41e92ba5c191769ed","0x0da5888efe8e6b13ad158d0f92b84f6f3864ea74ecb7d8684f66deafc7fa4fd5","0xfaf3423ac0294d54e2e88abf2e2516de7572a6df9014d03c572d218255f396c2","0x0a960b76491dd16da656e51a9ab8a0d98dbc332c69b9b1bc486368861eb1df9f","0x5a660f813b6b6ed681faf51416a7ae1d36b8fbfcd60ae9917a5c36b616419c00","0x93879387cf99c7d5deb57a9b557dc52ddede9bbaea6e5387d73488015199ca5b","0x3668d8f52f40f06424e7299dd9adb50d462b62725785f1fd0b8776f01ac7771e"],
       "USDC": ["0x6f70eceb37c5e2404482c93f3c635b6153464e535784ba21c5b4593f76e541b2","0x8459276fa7d3949b983a4be811feda853981f4821101233aa562bc900d9fcc57","0x72ad6a2dd2c20c9cd22de07b2398070e812837af0e70e3791ee098ccbd167c15","0xa88910881bc2af264b887685e9021d480fd605fc0a56c90eb70e62157fac7622","0xaf6e002d3ef9bd946d0ebabc1986a15e8f51e31e51e9cacf57d9c1020dfce476","0xfedd74ea47f0963f24ffad28b9aa528c394745fde02ccb175112b3be59df03f0","0x3bc8ea10ba771eff04fa69fc706132f056eb730d9126ebef10bf0ae074a9b133","0x0e27cb4705dc80ae9db44ff2cc3f6f84ecc21e3cb728c7d3cd50d556322cb7a8","0x4a8069cdd5567745e345ff39c451aebc961ba94e6fee106211929e9f90811e19"]}
res = {}
for k, hs in txs.items():
    res[k] = []
    for h in hs:
        t = json.loads(subprocess.run(["cast", "tx", h, "--json", "--rpc-url", R], capture_output=True, text=True, check=True).stdout)
        res[k].append({"hash": h, "from": t["from"], "to": t["to"], "input": t["input"], "value": t.get("value", "0x0")})
json.dump(res, open(out, "w"))
PY
trap 'rm -f "$ROUND_JSON"' EXIT
# each round gets its own fork at the last block before it (the USDC round's swap minimums assume the
# pool state left by everything mined before it, including the sAERO round)
for part in sAERO:53469848 USDC:53469856; do
  name=${part%%:*}; block=${part#*:}
  anvil --fork-url "$BASE_RPC_URL" --fork-block-number "$block" --host 127.0.0.1 --port "$PORT" --silent &
  ANVIL_PID=$!
  for _ in $(seq 1 60); do cast chain-id --rpc-url "http://127.0.0.1:$PORT" >/dev/null 2>&1 && break; sleep 1; done
  python3 -I "$HERE/reward_timing_check.py" --rpc "http://127.0.0.1:$PORT" --round "$ROUND_JSON" --part "$name" --out "${OUT_PREFIX}_${name}.json" || { kill $ANVIL_PID; exit 1; }
  kill $ANVIL_PID; wait $ANVIL_PID 2>/dev/null || true
done
