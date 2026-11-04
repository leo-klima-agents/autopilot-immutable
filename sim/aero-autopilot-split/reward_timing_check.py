#!/usr/bin/env python3
"""
Fork-only check: does Autopilot split a reward round by "held shares at the moment of the round",
regardless of how long they were held?

Forks Base at the block just before the live relays' first reward round (2026-11-03), then, from
a fresh snapshot each time, replays the REAL round transactions byte-for-byte (same sender, target
and calldata) around three kinds of user action:
  join-before : sAERO #17968 is deposited and processed seconds before the round
  exit-before : an existing holder exits and is paid out before the round
  queued      : the same holder registers the exit before the round, paid out after it
  exit-after  : the same holder exits after the round
Loopback anvil only; nothing is signed or broadcast. Run via run_reward_timing.sh.
"""
import argparse
import json
import re
import subprocess
import sys
import time
import urllib.request

VE = "0xBF7977E1521e9a3032bf7243Ee4712f311f13915"
VOTER = "0x49d7d4f17Ec56Ef8fA04E464AF5D1A4942CC31e6"
VPM = "0xBe8e5149Dc0fE28d124dE4222b7Fb332De99AA79"
DEALLOC_GAUGE = "0x2e67fe7bd6843e2d0095f5d02c60a7cd29a26902"
SAFE, SOURCE_ID = "0xa79cd47655156b299762DFE92A67980805ce5a31", 17968
STRANGER = "0x000000000000000000000000000000000000bEEF"
MAX = 2**256 - 1
USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
RELAYS = {
    "sAERO": {"relay": "0xf588F86577C472D83E5F84403951AA0B92fc1Dd6", "holder": "0x102c98688683ebf3e5212b41fc505d899918b8df", "id": 1210},
    "USDC": {"relay": "0xAfa7cA53e0A63d94218728842ED286308435DD86", "holder": "0x31bce2423640d7e536d0123943175482c11d983b", "id": 441},
}

ap = argparse.ArgumentParser()
ap.add_argument("--rpc", default="http://127.0.0.1:8545")
ap.add_argument("--round", required=True, help="JSON {sAERO:[tx...], USDC:[tx...]} with from/to/input/value")
ap.add_argument("--out", default="results_reward_timing.json")
ap.add_argument("--part", choices=["sAERO", "USDC"], required=True,
                help="which relay's round to test; each needs its own fork at the block before that round")
args = ap.parse_args()
if not re.match(r"^http://(127\.0\.0\.1|localhost)(:\d+)?/?$", args.rpc):
    sys.exit("refusing: --rpc must be a loopback anvil URL")
LOCAL = args.rpc
_op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
ROUND = json.load(open(args.round))


def rpc(m, p=None):
    r = json.load(_op.open(urllib.request.Request(LOCAL, json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p or []}).encode(),
                                                  {"Content-Type": "application/json"}), timeout=600))
    if "error" in r:
        raise RuntimeError(f"{m}: {r['error']}")
    return r["result"]


def cast(*a):
    p = subprocess.run(["cast", *map(str, a)], capture_output=True, text=True)
    if p.returncode:
        raise RuntimeError(p.stderr.strip())
    return p.stdout.strip()


def vint(to, sig, *a):
    return int(re.sub(r"\s*\[.*$", "", cast("call", to, sig, *a, "--rpc-url", LOCAL).splitlines()[0]))


def receipt(h):
    for _ in range(1200):
        rc = rpc("eth_getTransactionReceipt", [h])
        if rc:
            return rc
        time.sleep(0.1)
    raise RuntimeError(h)


def raw(frm, to, data, value="0x0"):
    rc = receipt(rpc("eth_sendTransaction", [{"from": frm, "to": to, "data": data, "value": value, "gas": hex(30_000_000)}]))
    if int(rc["status"], 16) != 1:
        raise RuntimeError(f"reverted: {frm}->{to} {data[:10]}")
    return rc


def send(frm, to, sig, *a):
    return raw(frm, to, cast("calldata", sig, *a))


TOPIC = {}


def logs(rc, name):
    return [l for l in rc["logs"] if l["topics"][0] == TOPIC[name]]


def words(d):
    return [int(d[2 + i:66 + i], 16) for i in range(0, len(d) - 2, 64)]


def impersonate(a):
    rpc("anvil_impersonateAccount", [a])
    rpc("anvil_setBalance", [a, hex(10**19)])


def replay(kind):
    """Replay the real reward round; return the total booked by it."""
    total = 0
    for tx in ROUND[kind]:
        impersonate(tx["from"])
        rc = raw(tx["from"], tx["to"], tx["input"], tx.get("value", "0x0"))
        if kind == "sAERO":
            total += sum(words(l["data"])[0] for l in logs(rc, "Compounded"))
        else:
            total += sum(words(l["data"])[0] for l in logs(rc, "RewardNotified"))
    return total


def state(relay):
    pt = cast("call", relay, "principalToken()(address)", "--rpc-url", LOCAL)
    yt = cast("call", relay, "yieldToken()(address)", "--rpc-url", LOCAL)
    return {"backing": vint(relay, "totalBacking()(uint256)"), "supply": vint(pt, "totalSupply()(uint256)"),
            "ytSupply": vint(yt, "totalSupply()(uint256)"), "pt": pt, "yt": yt}


def now():
    return int(rpc("eth_getBlockByNumber", ["latest", False])["timestamp"], 16)


def keeper_of(relay):
    for a in ["0x7793f0a7dc211045532e53c9c02a8b2c2a1cfe67", "0x2b23Cd54bE2b3B651b671978212477F9e2549546"]:
        if vint(relay, "rolesOf(address)(uint256)", a) & 1:
            return a
    raise RuntimeError("no known keeper")


def process_all(relay, keeper):
    impersonate(keeper)
    while True:
        cnt = int(cast("call", relay, "depositList()(uint40,uint40,uint40)", "--rpc-url", LOCAL).splitlines()[2])
        if cnt == 0:
            return
        send(keeper, relay, "processPending(uint256)", min(cnt, 150))


def join(relay):
    """Deposit sAERO #17968 and have it processed; returns the Safe's new shares (= YT)."""
    amt = int(re.match(r"\((\d+)", cast("call", VE, "staked(uint256)((uint128,uint48,bool))", SOURCE_ID, "--rpc-url", LOCAL)).group(1))
    send(SAFE, VE, "setApprovalForAll(address,bool)", VPM, "true")
    send(SAFE, VE, "approve(address,uint256)", relay, SOURCE_ID)
    send(SAFE, VOTER, "allocateGauges(uint256,uint256,(address,uint128,bytes)[],uint256,address)",
         SOURCE_ID, 8453, f"[({DEALLOC_GAUGE},{amt},0x)]", 0, SAFE)
    send(SAFE, relay, "requestDeposit(uint256,uint256)", SOURCE_ID, MAX)
    process_all(relay, keeper_of(relay))
    return vint(state(relay)["yt"], "balanceOf(address)(uint256)", SAFE)


def register(relay, holder, dep_id):
    impersonate(holder)
    return send(holder, relay, "registerOnWithdrawQueue(uint256,uint256)", dep_id, MAX)


def drain(relay, holder):
    cnt = int(cast("call", relay, "withdrawQueue()(uint40,uint40,uint40)", "--rpc-url", LOCAL).splitlines()[2])
    rc = send(STRANGER, relay, "processWithdrawals(uint256)", cnt)
    mine = [words(l["data"]) for l in logs(rc, "WithdrawProcessed") if l["topics"][1][-40:].lower() == holder[2:].lower()]
    assert len(mine) == 1, "holder exit not settled"
    return mine[0][1]  # net weight delivered to the holder's new sAERO


def claimable(relay, holder):
    return vint(relay, "claimable(address,address)(uint256)", holder, USDC)


def main():
    assert int(rpc("eth_chainId"), 16) == 8453
    fork_block = int(rpc("eth_blockNumber"), 16)
    rpc("anvil_setBlockTimestampInterval", [1])
    for n, s in {"Compounded": "Compounded(uint256)", "RewardNotified": "RewardNotified(address,uint256,uint256)",
                 "WithdrawProcessed": "WithdrawProcessed(address,uint256,uint256,uint256)"}.items():
        TOPIC[n] = cast("keccak", s)
    for a in [SAFE, STRANGER]:
        impersonate(a)
    snap = [rpc("evm_snapshot")]
    out = {"part": args.part, "fork_block": fork_block, "round_txs": [t["hash"] for t in ROUND[args.part]]}

    def fresh():
        rpc("evm_revert", [snap[0]])
        snap[0] = rpc("evm_snapshot")

    # ---------------- sAERO Maxi: rewards compound into the share price ----------------
    if args.part == "sAERO":
        run_saero(out, fresh)
    else:
        run_usdc(out, fresh)
    json.dump(out, open(args.out, "w"), indent=1, default=str)
    print(json.dumps(out, indent=1, default=str))


def run_saero(out, fresh):
    R = RELAYS["sAERO"]
    relay, holder, dep = R["relay"], R["holder"], R["id"]
    hs = int(cast("call", relay, "deposits(uint256)(address,uint48,uint128,uint128)", dep, "--rpc-url", LOCAL).splitlines()[3].split()[0])
    s = {}

    fresh()
    st0 = state(relay)
    booked = replay("sAERO")
    st1 = state(relay)
    s["baseline"] = {"booked": booked, "pps_before": st0["backing"] / st0["supply"], "pps_after": st1["backing"] / st1["supply"]}

    fresh()
    shares = join(relay)
    t_in = now()
    a = state(relay)
    booked_j = replay("sAERO")
    b = state(relay)
    gain = shares * b["backing"] // b["supply"] - shares * a["backing"] // a["supply"]
    s["join_before"] = {"safe_shares": shares, "supply_at_round": a["supply"], "booked": booked_j, "safe_gain": gain,
                        "pro_rata": booked_j * shares // a["supply"],
                        "seconds_held_before_round": now() - len(ROUND["sAERO"]) - t_in + 1}

    fresh()
    register(relay, holder, dep)
    paid_before = drain(relay, holder)
    replay("sAERO")
    s["exit_before"] = {"holder": holder, "deposit_id": dep, "shares": hs, "paid": paid_before}

    fresh()
    register(relay, holder, dep)
    st_q = state(relay)
    replay("sAERO")
    s["queued"] = {"paid": drain(relay, holder), "supply_at_round": st_q["supply"]}

    fresh()
    st_e = state(relay)
    booked_e = replay("sAERO")
    register(relay, holder, dep)
    s["exit_after"] = {"paid": drain(relay, holder), "pro_rata_of_round": booked_e * hs // st_e["supply"]}
    out["sAERO"] = s


def run_usdc(out, fresh):
    # ---------------- USDC Maxi: rewards paid per yield-token balance ----------------
    R = RELAYS["USDC"]
    relay, holder, dep = R["relay"], R["holder"], R["id"]
    u = {}

    fresh()
    shares = join(relay)
    a = state(relay)
    c0 = claimable(relay, SAFE)
    paid = replay("USDC")
    u["join_before"] = {"safe_yt": shares, "yt_supply_at_round": a["ytSupply"], "distributed": paid,
                        "safe_claimable_gain": claimable(relay, SAFE) - c0, "pro_rata": paid * shares // a["ytSupply"]}

    fresh()
    h_yt = vint(state(relay)["yt"], "balanceOf(address)(uint256)", holder)
    c0 = claimable(relay, holder)
    register(relay, holder, dep)
    drain(relay, holder)
    replay("USDC")
    u["exit_before"] = {"holder": holder, "deposit_id": dep, "holder_yt": h_yt, "claimable_gain": claimable(relay, holder) - c0}

    fresh()
    c0 = claimable(relay, holder)
    a = state(relay)
    register(relay, holder, dep)
    paid = replay("USDC")
    drain(relay, holder)
    u["queued"] = {"claimable_gain": claimable(relay, holder) - c0, "pro_rata": paid * h_yt // a["ytSupply"]}
    out["USDC"] = u


if __name__ == "__main__":
    main()
