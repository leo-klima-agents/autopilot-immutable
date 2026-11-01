#!/usr/bin/env python3
"""
Fork-only check against the LIVE Maxi relay (second RelayFactory, Sourcify-verified MaxiRelay
implementation 0x3909f8b8...): deposit sAERO #17968 and try to exit it in 10 pieces.

Same safety rules as split_17968.py: loopback anvil only, impersonated accounts, nothing signed
or broadcast. Run through run_live.sh.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

VE = "0xBF7977E1521e9a3032bf7243Ee4712f311f13915"
VOTER = "0x49d7d4f17Ec56Ef8fA04E464AF5D1A4942CC31e6"
VPM = "0xBe8e5149Dc0fE28d124dE4222b7Fb332De99AA79"
LEAF_VOTER = "0x382409fad8503FbCdbB27A4211551fa03e884078"
REGISTRY = "0x0dfBE7b949EAE4b826E33146F1df4C0c60c78f99"       # RelayFactoryRegistry (on Aero's security page)
FACTORY2 = "0xA5283582951ae0cF72bE4BEA54dA63D199264B78"       # second, registry-approved RelayFactory
MAXI_IMPL2 = "0x3909f8b833A8Beba57CEf8c6E713E885b6c359cE"      # Sourcify exact match, verified 2026-10-30
RELAY = "0xf588F86577C472D83E5F84403951AA0B92fc1Dd6"           # live "Autopilot sAERO Maxi"
KEEPER = "0x7793f0a7dc211045532e53c9c02a8b2c2a1cfe67"
STRANGER = "0x000000000000000000000000000000000000bEEF"
SOURCE_ID = 17968
BASE_CHAIN = 8453
MAX = 2**256 - 1                      # whole-stake sentinel (deposit) and mint sentinel (exit)
DEALLOC_GAUGE = "0x2e67fe7bd6843e2d0095f5d02c60a7cd29a26902"
SEL_WITHDRAW_TO_NFT = "0xdd2254ff"

ap = argparse.ArgumentParser()
ap.add_argument("--rpc", default="http://127.0.0.1:8545")
ap.add_argument("--sources", nargs="+", required=True, help="dirs containing V3/src (error table)")
ap.add_argument("--out", default="results_live.json")
args = ap.parse_args()
if not re.match(r"^http://(127\.0\.0\.1|localhost)(:\d+)?/?$", args.rpc):
    sys.exit("refusing: --rpc must be a loopback anvil URL")
LOCAL = args.rpc
_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class RpcError(Exception):
    def __init__(self, err):
        super().__init__(err.get("message"))
        self.err = err


def rpc(method, params=None):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}).encode()
    r = json.load(_opener.open(urllib.request.Request(LOCAL, data=body, headers={"Content-Type": "application/json"}),
                               timeout=300))
    if "error" in r:
        raise RpcError(r["error"])
    return r["result"]


def cast(*a):
    p = subprocess.run(["cast", *map(str, a)], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"cast {a}: {p.stderr.strip()}")
    return p.stdout.strip()


def view(to, sig, *a):
    out = cast("call", to, sig, *a, "--rpc-url", LOCAL)
    return [re.sub(r"(\d)\s+\[[0-9.e+]+\]$", r"\1", x).strip() for x in out.splitlines()]


def vint(to, sig, *a):
    return int(view(to, sig, *a)[0])


def staked(tid):
    raw = cast("call", VE, "staked(uint256)((uint128,uint48,bool))", tid, "--rpc-url", LOCAL)
    m = re.match(r"\((\d+)(?: \[[^\]]+\])?, (\d+)(?: \[[^\]]+\])?, (true|false)\)", raw)
    return {"amount": int(m.group(1)), "end": int(m.group(2)), "isPermanent": m.group(3) == "true"}


def now():
    return int(rpc("eth_getBlockByNumber", ["latest", False])["timestamp"], 16)


def receipt(h):
    for _ in range(600):
        rc = rpc("eth_getTransactionReceipt", [h])
        if rc:
            return rc
        time.sleep(0.1)
    raise RuntimeError(h)


ERRORS = {}


def build_errors(dirs):
    pat = re.compile(r"error\s+(\w+)\s*\(([^)]*)\)")
    sigs = set()
    for root in dirs:
        for dp, _, fs in os.walk(os.path.join(root, "V3", "src")):
            for f in fs:
                if f.endswith(".sol"):
                    for n, p in pat.findall(open(os.path.join(dp, f), encoding="utf-8").read()):
                        sigs.add(f"{n}({','.join(x.strip().split()[0] for x in p.split(',') if x.strip())})")
    sigs |= {"Unauthorized()", "ERC721NonexistentToken(uint256)", "Panic(uint256)", "Error(string)"}
    for s in sigs:
        ERRORS[cast("keccak", s)[:10]] = s


def call_err(frm, to, sig, *a):
    try:
        rpc("eth_call", [{"from": frm, "to": to, "data": cast("calldata", sig, *a)}, "latest"])
        return True, None
    except RpcError as e:
        d = e.err.get("data")
        d = d.get("data") if isinstance(d, dict) else d
        return False, ERRORS.get((d or "0x")[:10], f"selector {(d or '0x')[:10]}")


def send(frm, to, sig, *a):
    h = rpc("eth_sendTransaction", [{"from": frm, "to": to, "data": cast("calldata", sig, *a), "gas": hex(30_000_000)}])
    rc = receipt(h)
    if int(rc["status"], 16) != 1:
        ok, err = call_err(frm, to, sig, *a)
        raise RuntimeError(f"{sig} reverted: {err}")
    return rc


ROWS, T0 = [], None


def record(step, label, actor, action, result, gas=None):
    ROWS.append({"step": step, "label": label, "actor": actor, "action": action, "result": result,
                 "gasUsed": gas, "t_plus_s": now() - T0})
    print(f"[{label}] {step} | {actor} | {action} -> {result}" + (f" gas={gas:,}" if gas else ""), flush=True)


def expect(step, frm, actor, to, sig, *a, note):
    ok, err = call_err(frm, to, sig, *a)
    record(step, "SIMULATED (eth_call)", actor, note, "accepted" if ok else f"reverts {err}")
    return ok, err


def g(rc):
    return int(rc["gasUsed"], 16)


def topic(sig):
    return cast("keccak", sig)


def words(d):
    return [int(d[2 + i:66 + i], 16) for i in range(0, len(d) - 2, 64)]


def fmt(w):
    return f"{w / 1e18:,.6f}"


def main():
    global T0
    assert int(rpc("eth_chainId"), 16) == 8453
    rpc("anvil_setBlockTimestampInterval", [2])
    T0 = now()
    fork_block = int(rpc("eth_blockNumber"), 16)
    build_errors(args.sources)

    # provenance of the relay
    factories = view(REGISTRY, "relayFactories()(address[])")[0]
    assert FACTORY2.lower() in factories.lower()
    assert view(FACTORY2, "isRelay(address)(bool)", RELAY)[0] == "true"
    assert MAXI_IMPL2[2:].lower() in rpc("eth_getCode", [RELAY, "latest"]).lower()
    assert view(RELAY, "relayType()(uint8)")[0] == "0"
    cfg = view(RELAY, "relayConfig()((uint256,uint256,uint256,uint256,uint48,uint48,string,string))")[0]
    relay_tid, min_dep, keeper_window = map(int, re.findall(r"(\d+)(?: \[[^\]]+\])?", cfg.split('"')[0])[:3])
    owner = view(VE, "ownerOf(uint256)(address)", SOURCE_ID)[0]
    src = staked(SOURCE_ID)
    q = view(RELAY, "depositList()(uint40,uint40,uint40)")
    record("0", "LIVE READ", "-", "provenance + state",
           f"registry factories {factories}; relay {RELAY} is a factory-2 MaxiRelay clone of {MAXI_IMPL2}; "
           f"config {cfg}; deposit queue (head,tail,count)={q}; #17968 {fmt(src['amount'])} AERO, "
           f"chain0 {fmt(vint(VOTER, 'allocationChainAmounts(uint256,uint256)(uint128)', SOURCE_ID, 0))}; "
           f"VPM registration(relay, withdrawToNFT)={view(VPM, 'fees(bytes4,address)(bool,uint128)', SEL_WITHDRAW_TO_NFT, RELAY)}")

    for a in [owner, KEEPER, STRANGER]:
        rpc("anvil_impersonateAccount", [a])
        rpc("anvil_setBalance", [a, hex(10**19)])

    # direct split through the VPM (the only 1->N primitive) is not open to holders
    dests = "[" + ",".join(f"({MAX},{src['amount'] // 10},{owner})" for _ in range(10)) + "]"
    expect("1", owner, "Safe", VPM, "withdrawToNFT(uint256,(uint256,uint128,address)[])", SOURCE_ID, dests,
           note="VPM.withdrawToNFT(17968 -> 10 fresh sAERO) called directly by the holder")

    rc1 = send(owner, VE, "setApprovalForAll(address,bool)", VPM, "true")
    rc2 = send(owner, VE, "approve(address,uint256)", RELAY, SOURCE_ID)
    record("2.1", "SIMULATED", "Safe", "approve VPM (operator) + relay (token)", "ok", g(rc1) + g(rc2))
    rc = send(owner, VOTER, "allocateGauges(uint256,uint256,(address,uint128,bytes)[],uint256,address)",
              SOURCE_ID, BASE_CHAIN, f"[({DEALLOC_GAUGE},{src['amount']},0x)]", 0, owner)
    record("2.2", "SIMULATED", "Safe", "Voter.allocateGauges(17968, Base, [DEALLOC_GAUGE: all])",
           f"chain0 = {fmt(vint(VOTER, 'allocationChainAmounts(uint256,uint256)(uint128)', SOURCE_ID, 0))}", g(rc))
    RD = "requestDeposit(uint256,uint256)"
    expect("2.3", owner, "Safe", RELAY, RD, SOURCE_ID, src["amount"], note="requestDeposit(17968, explicit amount)")
    expect("2.4", owner, "Safe", RELAY, RD, SOURCE_ID, src["amount"] // 10, note="requestDeposit(17968, 1/10 of stake)")
    rc = send(owner, RELAY, RD, SOURCE_ID, MAX)
    lg = [l for l in rc["logs"] if l["topics"][0] == topic("DepositRequested(uint256,address,uint256,uint256)")][0]
    net, dep_id = words(lg["data"])
    record("2.5", "SIMULATED", "Safe", "requestDeposit(17968, type(uint256).max)",
           f"queued id {dep_id}, net {fmt(net)} (gross {fmt(src['amount'])}); #17968 left {staked(SOURCE_ID)['amount']} wei; "
           f"queue now {view(RELAY, 'depositList()(uint40,uint40,uint40)')}", g(rc))
    snap = rpc("evm_snapshot")

    results = {}
    for path in ["keeper", "overdue"]:
        rpc("evm_revert", [snap])
        snap = rpc("evm_snapshot")
        if path == "keeper":
            pending = int(view(RELAY, "depositList()(uint40,uint40,uint40)")[2])
            rc = send(KEEPER, RELAY, "processPending(uint256)", pending)
            record("3K", "SIMULATED", "keeper", f"processPending({pending}) (whole backlog incl. ours, FIFO)",
                   f"processed {sum(1 for l in rc['logs'] if l['topics'][0] == topic('DepositProcessed(uint256,address,uint256,uint256)'))}",
                   g(rc))
        else:
            req_at = int(view(RELAY, "deposits(uint256)(address,uint48,uint128,uint128)", dep_id)[1])
            rpc("evm_setNextBlockTimestamp", [req_at + keeper_window])
            rpc("evm_mine")
            rc = send(STRANGER, RELAY, "processOverduePending(uint256[])", f"[{dep_id}]")
            record("3O", "SIMULATED", "stranger", f"processOverduePending([{dep_id}]) at requestedAt+{keeper_window}s",
                   "processed our entry alone", g(rc))
        rec = view(RELAY, "deposits(uint256)(address,uint48,uint128,uint128)", dep_id)
        ids = view(RELAY, "depositIdsOf(address,uint256)(uint256)", owner, 0)
        shares = int(rec[3])
        record(f"4{path[0].upper()}.0", "SIMULATED (state read)", "-", "deposit record after processing",
               f"deposits({dep_id}) = recipient {rec[0]}, requestedAt {rec[1]}, shares {fmt(shares)}; depositIdsOf(Safe)[0]={ids[0]}")

        RW = "registerOnWithdrawQueue(uint256,uint256)"
        if path == "keeper":
            expect("4.1", owner, "Safe", RELAY, RW, shares // 10, MAX,
                   note="registerOnWithdrawQueue(shares/10, fresh) — old-ABI style partial exit")
            expect("4.2", STRANGER, "stranger", RELAY, RW, dep_id, MAX, note=f"registerOnWithdrawQueue({dep_id}) by non-holder")
        rc = send(owner, RELAY, RW, dep_id, MAX)
        record(f"4{path[0].upper()}.1", "SIMULATED", "Safe", f"registerOnWithdrawQueue({dep_id}, fresh sAERO)",
               f"escrowed {fmt(vint(RELAY, 'escrowedShares(address)(uint256)', owner))} shares (the whole record)", g(rc))
        ok, err = expect(f"4{path[0].upper()}.2", owner, "Safe", RELAY, RW, dep_id, MAX,
                         note=f"registerOnWithdrawQueue({dep_id}) again, for a 2nd piece")
        wq = view(RELAY, "withdrawQueue()(uint40,uint40,uint40)")
        rc = send(STRANGER, RELAY, "processWithdrawals(uint256)", int(wq[2]))
        wp = [l for l in rc["logs"] if l["topics"][0] == topic("WithdrawProcessed(address,uint256,uint256,uint256)")]
        mine = [words(l["data"]) for l in wp if l["topics"][1][-40:].lower() == owner[2:].lower()]
        new = [{"tokenId": t, "net": n, **staked(t), "owner": view(VE, "ownerOf(uint256)(address)", t)[0]} for _, n, t in mine]
        record(f"4{path[0].upper()}.3", "SIMULATED", "stranger", f"processWithdrawals({wq[2]})",
               f"Safe received {len(new)} sAERO: " + ", ".join(f"#{n['tokenId']} {fmt(n['amount'])} perm={n['isPermanent']}" for n in new)
               + f"; shortfall vs net deposit {net - sum(n['amount'] for n in new)} wei", g(rc))
        results[path] = {"deposit_id": dep_id, "net_in": net, "shares": shares, "new_sAERO": new,
                         "second_exit_error": err, "shortfall_wei": net - sum(n["amount"] for n in new)}

    json.dump({"fork_block": fork_block, "rows": ROWS, "results": results}, open(args.out, "w"), indent=1, default=str)
    print("wrote", args.out)


if __name__ == "__main__":
    main()
