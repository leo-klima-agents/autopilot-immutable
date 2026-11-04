#!/usr/bin/env python3
"""
Fork-only simulation: split sAERO #17968 into 10 permanent sAERO through Aero's Autopilot
(the v3 "Relay", Maxi tier) on a LOCAL anvil fork of Base.

Safety: every state-changing call goes to the local anvil node (LOCAL_RPC, loopback only).
The live Base RPC is never written to; nothing is signed or broadcast. Accounts are
impersonated on the fork (anvil_impersonateAccount), which needs no keys.

Usage (run.sh does both steps and stops anvil afterwards):
  anvil --fork-url "$BASE_RPC_URL" --fork-block-number 53387600 --host 127.0.0.1 --port 8545 &
  python3 -I split_17968.py --metadex /path/to/metadex-public --out results.json

Every number in the output is read from the fork after the call that produced it.
Steps marked COUNTERFACTUAL change protocol configuration on the fork and are labelled.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

# ── addresses (Base; cross-checked against app.aero.xyz/docs/security and
#    metadex-public/deployment-addresses/{root,relaystack}-base.json) ─────────────────────────
VE = "0xBF7977E1521e9a3032bf7243Ee4712f311f13915"         # VotingEscrow (sAERO)
VOTER = "0x49d7d4f17Ec56Ef8fA04E464AF5D1A4942CC31e6"      # root Voter
VPM = "0xBe8e5149Dc0fE28d124dE4222b7Fb332De99AA79"        # VoterPaymentsModule
LEAF_VOTER = "0x382409fad8503FbCdbB27A4211551fa03e884078"  # LeafVoter (Base, root-colocated)
FACTORY = "0xA972232e6C1860586E1d66aC690d30Dab843049d"    # RelayFactory
MAXI_IMPL = "0x3dE62Ff7EAA843ACD85ba4Ee28a4981e890b1F4d"  # MaxiRelay implementation
RELAY = "0x871d4388589b3d0259089534C0711ea8B7F06E7B"      # "Autopilot sAERO Maxi" (factory index 0)
SOURCE_ID = 17968
BASE_CHAIN = 8453
MINT_SENTINEL = 2**256 - 1
DEALLOC_GAUGE = "0x2e67fe7bd6843e2d0095f5d02c60a7cd29a26902"  # address(uint160(keccak256('DROMOS_DEALLOC_GAUGE')))
PIECES = 10

SEL_DEPOSIT_INTO_NFT = "0x8bb9272c"  # depositIntoNFT((uint256,uint128)[],uint256,address)
SEL_WITHDRAW_TO_NFT = "0xdd2254ff"   # withdrawToNFT(uint256,(uint256,uint128,address)[])

TOPIC = {}  # filled in main() via cast keccak

ap = argparse.ArgumentParser()
ap.add_argument("--rpc", default=os.environ.get("LOCAL_RPC", "http://127.0.0.1:8545"))
ap.add_argument("--metadex", required=True, help="path to a metadex-public checkout (error table)")
ap.add_argument("--out", default="results.json")
args = ap.parse_args()

if not re.match(r"^http://(127\.0\.0\.1|localhost)(:\d+)?/?$", args.rpc):
    sys.exit("refusing: --rpc must be a loopback anvil URL (fork only, broadcast nothing)")
LOCAL = args.rpc
_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # loopback, no proxy


# ── plumbing ────────────────────────────────────────────────────────────────────────────────
class RpcError(Exception):
    def __init__(self, err):
        super().__init__(err.get("message"))
        self.err = err


def rpc(method, params=None):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}).encode()
    req = urllib.request.Request(LOCAL, data=body, headers={"Content-Type": "application/json"})
    r = json.load(_opener.open(req, timeout=300))
    if "error" in r:
        raise RpcError(r["error"])
    return r["result"]


def cast(*a):
    p = subprocess.run(["cast", *map(str, a)], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"cast {' '.join(map(str, a))}: {p.stderr.strip()}")
    return p.stdout.strip()


def calldata(sig, *a):
    return cast("calldata", sig, *a)


def view(to, sig, *a):
    """cast call against the fork; returns list of decoded output lines."""
    out = cast("call", to, sig, *a, "--rpc-url", LOCAL)
    return [re.sub(r"(\d)\s+\[[0-9.e+]+\]$", r"\1", line).strip() for line in out.splitlines()]


def vint(to, sig, *a):
    return int(view(to, sig, *a)[0])


def staked(tid):
    raw = cast("call", VE, "staked(uint256)((uint128,uint48,bool))", tid, "--rpc-url", LOCAL)
    m = re.match(r"\((\d+)(?: \[[^\]]+\])?, (\d+)(?: \[[^\]]+\])?, (true|false)\)", raw)
    return {"amount": int(m.group(1)), "end": int(m.group(2)), "isPermanent": m.group(3) == "true"}


def chain0(tid):
    return vint(VOTER, "allocationChainAmounts(uint256,uint256)(uint128)", tid, 0)


def now():
    return int(rpc("eth_getBlockByNumber", ["latest", False])["timestamp"], 16)


def warp_to(ts):
    """Mine one block stamped exactly `ts`; later blocks continue at +2s."""
    rpc("evm_setNextBlockTimestamp", [ts])
    rpc("evm_mine")
    assert now() == ts


def warp(seconds):
    warp_to(now() + seconds)


def snapshot():
    return rpc("evm_snapshot")


def revert_to(snap):
    assert rpc("evm_revert", [snap]) is True


def build_error_table(root):
    table = {}
    pat = re.compile(r"error\s+(\w+)\s*\(([^)]*)\)")
    for dp, _, fs in os.walk(os.path.join(root, "V3", "src")):
        for f in fs:
            if not f.endswith(".sol"):
                continue
            src = open(os.path.join(dp, f), encoding="utf-8").read()
            for name, params in pat.findall(src):
                types = [p.strip().split()[0] for p in params.split(",") if p.strip()]
                sig = f"{name}({','.join(types)})"
                table.setdefault(sig, None)
    sigs = list(table)
    out = {}
    # one cast keccak per signature; fine for ~500 entries
    for s in sigs:
        out[cast("keccak", s)[:10]] = s
    # dependency errors not declared in V3/src
    for s in ["Unauthorized()", "NotInitializing()", "ReentrancyGuardReentrantCall()",
              "ERC721NonexistentToken(uint256)", "ERC721InsufficientApproval(address,uint256)",
              "AccessControlUnauthorizedAccount(address,bytes32)", "Panic(uint256)", "Error(string)"]:
        out[cast("keccak", s)[:10]] = s
    return out


ERRORS = {}


def decode_error(data):
    if not data or data == "0x":
        return "revert (no data)"
    return ERRORS.get(data[:10], f"unknown selector {data[:10]}")


ROWS = []
T0 = None
LIVE_GAUGES = []  # #17968's Base gauges at the fork block (reused as realistic relay votes)


def record(step, actor, action, result, gas=None, label="SIMULATED", **extra):
    row = {"step": step, "actor": actor, "action": action, "result": result, "gasUsed": gas,
           "t_plus_s": (now() - T0) if T0 is not None else 0, "label": label}
    row.update(extra)
    ROWS.append(row)
    g = f" gas={gas:,}" if gas is not None else ""
    print(f"[{label}] {step} | {actor} | {action} -> {result}{g}", flush=True)
    return row


def receipt(h):
    for _ in range(600):
        rc = rpc("eth_getTransactionReceipt", [h])
        if rc:
            return rc
        time.sleep(0.1)
    raise RuntimeError(f"no receipt for {h}")


def send(frm, to, sig, *a, value=0):
    data = calldata(sig, *a)
    # Explicit limit: anvil's estimate runs against a different block timestamp than the mined
    # block, and the Voter's settlement work is time-dependent. gasUsed is read from the receipt.
    tx = {"from": frm, "to": to, "data": data, "gas": hex(30_000_000)}
    if value:
        tx["value"] = hex(value)
    h = rpc("eth_sendTransaction", [tx])
    rc = receipt(h)
    if int(rc["status"], 16) != 1:
        ok, err = call_err(frm, to, sig, *a)
        txo = rpc("eth_getTransactionByHash", [h])
        raise RuntimeError(f"tx reverted unexpectedly: {sig} {a}; gasUsed={int(rc['gasUsed'], 16)} "
                           f"gasLimit={int(txo['gas'], 16)}; eth_call now: {'ok' if ok else err}; tx={h}")
    return rc


def call_err(frm, to, sig, *a):
    """eth_call; returns (ok, decoded_error)."""
    data = calldata(sig, *a)
    try:
        rpc("eth_call", [{"from": frm, "to": to, "data": data}, "latest"])
        return True, None
    except RpcError as e:
        d = e.err.get("data")
        if isinstance(d, dict):
            d = d.get("data")
        return False, decode_error(d)


def expect_revert(step, frm, actor, to, sig, *a, want=None, note=""):
    ok, err = call_err(frm, to, sig, *a)
    if ok:
        return record(step, actor, f"{note or sig}", "DID NOT REVERT", label="SIMULATED (eth_call)", expected=want)
    match = (want is None) or err.startswith(want)
    return record(step, actor, note or sig, f"reverts {err}" + ("" if match else f"  (expected {want})"),
                  label="SIMULATED (eth_call)", expected=want, matched=match)


def gas(rc):
    return int(rc["gasUsed"], 16)


def logs(rc, topic):
    return [l for l in rc["logs"] if l["topics"][0].lower() == TOPIC[topic].lower()]


def words(data):
    d = data[2:]
    return [int(d[i:i + 64], 16) for i in range(0, len(d), 64)]


def fmt(wei):
    return f"{wei / 1e18:,.6f}"


# ── main ────────────────────────────────────────────────────────────────────────────────────
def main():
    global T0, ERRORS
    assert int(rpc("eth_chainId"), 16) == 8453, "fork must be Base (8453)"
    fork_block = int(rpc("eth_blockNumber"), 16)
    # Deterministic clock: every mined block is +2s (Base's block time), independent of wall time.
    rpc("anvil_setBlockTimestampInterval", [2])
    T0 = now()
    ERRORS = build_error_table(args.metadex)
    for name, sig in {
        "DepositRequested": "DepositRequested(uint256,address,uint256,uint256)",
        "DepositProcessed": "DepositProcessed(uint256,address,uint256,uint256)",
        "WithdrawRegistered": "WithdrawRegistered(address,uint256,uint256,uint256)",
        "WithdrawProcessed": "WithdrawProcessed(address,uint256,uint256,uint256)",
    }.items():
        TOPIC[name] = cast("keccak", sig)

    owner = view(VE, "ownerOf(uint256)(address)", SOURCE_ID)[0]
    cfg = view(RELAY, "relayConfig()((uint256,uint256,uint256,uint256,uint256,uint48,uint48,string,string))")[0]
    m = re.findall(r"(\d+)(?: \[[^\]]+\])?", cfg.split('"')[0])
    relay_tid, min_dep, keeper_window, min_wd, ep_timelock, lock_weeks, evac = map(int, m[:7])
    keeper = "0x7793f0a7dc211045532e53c9c02a8b2c2a1cfe67"   # rolesOf == KEEPER|VOTER_ROLE (RolesUpdated logs)
    fee_manager = view(VPM, "getRoleMember(bytes32,uint256)(address)", cast("keccak", "FEE_MANAGER"), 0)[0]
    stranger = "0x000000000000000000000000000000000000bEEF"
    assert vint(RELAY, "rolesOf(address)(uint256)", keeper) & 1 == 1, "keeper lost KEEPER role"
    assert view(RELAY, "relayType()(uint8)")[0] == "0", "not a Maxi relay"
    assert view(FACTORY, "isRelay(address)(bool)", RELAY)[0] == "true"
    # EIP-1167 clone: the runtime code embeds the implementation it delegates to.
    assert MAXI_IMPL[2:].lower() in rpc("eth_getCode", [RELAY, "latest"]).lower(), "relay is not a MaxiRelay clone"

    for a in [owner, keeper, fee_manager, stranger]:
        rpc("anvil_impersonateAccount", [a])
        rpc("anvil_setBalance", [a, hex(10**19)])

    LIVE_GAUGES[:] = sorted(view(LEAF_VOTER, "allocatedGauges(uint256)(address[])", SOURCE_ID)[0].strip("[]").split(", "),
                            key=lambda a: int(a, 16))
    src = staked(SOURCE_ID)
    deposit_amount = src["amount"]
    rakes = view(RELAY, "rakes()((uint24,uint24,uint24,uint24,uint48))")[0]
    dep_q = view(RELAY, "depositList()(uint40,uint40,uint40)")
    live = {
        "fork_block": fork_block, "fork_timestamp": T0, "relay": RELAY, "relay_name": cfg.split('"')[1],
        "relay_sAERO": relay_tid, "minDeposit": min_dep, "keeperWindow_s": keeper_window,
        "minWithdrawal": min_wd, "entrypointTimelock_s": ep_timelock, "lockWeeks": lock_weeks,
        "evacuationWindow_s": evac, "rakes(protocol,allocator,pendingP,pendingA,executableAt)": rakes,
        "MAX_RAKE_PIPS": vint(RELAY, "MAX_RAKE_PIPS()(uint256)"),
        "rewardTokens": view(RELAY, "rewardTokens()(address[])")[0],
        "owner_17968": owner, "staked_17968": src, "chain0_17968": chain0(SOURCE_ID),
        "allocationChainIds_17968": view(VOTER, "allocationChainIds(uint256)(uint256[])", SOURCE_ID)[0],
        "leaf_cooldown_s": vint(LEAF_VOTER, "allocationCooldown()(uint48)"),
        "leaf_lastAllocated_17968": int(view(LEAF_VOTER, "tokenStates(uint256)(address,uint48,bool,uint128)", SOURCE_ID)[1]),
        "vpm_restricted_deposit": view(VPM, "restricted(bytes4)(bool)", SEL_DEPOSIT_INTO_NFT)[0],
        "vpm_restricted_withdraw": view(VPM, "restricted(bytes4)(bool)", SEL_WITHDRAW_TO_NFT)[0],
        "vpm_relay_registered_deposit": view(VPM, "fees(bytes4,address)(bool,uint128)", SEL_DEPOSIT_INTO_NFT, RELAY),
        "vpm_relay_registered_withdraw": view(VPM, "fees(bytes4,address)(bool,uint128)", SEL_WITHDRAW_TO_NFT, RELAY),
        "vpm_default_fee_deposit": view(VPM, "fees(bytes4,address)(bool,uint128)", SEL_DEPOSIT_INTO_NFT, "0x" + "0" * 40),
        "vpm_default_fee_withdraw": view(VPM, "fees(bytes4,address)(bool,uint128)", SEL_WITHDRAW_TO_NFT, "0x" + "0" * 40),
        "deposit_queue(head,tail,count)": dep_q,
        "pending_deposits": [view(RELAY, "pendingDeposits(uint256)(address,uint48,uint128,uint128)", i)
                             for i in range(1, int(dep_q[1]) + 1)],
        "keeper": keeper, "fee_manager": fee_manager,
    }
    print(json.dumps(live, indent=1, default=str))
    record("0", "-", "live state at fork block", f"#17968 owner {owner}, staked {fmt(deposit_amount)} AERO, "
           f"permanent={src['isPermanent']}, chain0(free)={fmt(live['chain0_17968'])}", label="LIVE READ")

    # ── Step 2: deposit ───────────────────────────────────────────────────────────────────────
    rc = send(owner, VE, "setApprovalForAll(address,bool)", VPM, "true")
    record("2.1", "Safe (impersonated)", "VE.setApprovalForAll(VPM, true)", "ok", gas(rc))
    rc = send(owner, VE, "approve(address,uint256)", RELAY, SOURCE_ID)
    record("2.2", "Safe (impersonated)", "VE.approve(relay, 17968)", "ok", gas(rc))

    RD = "requestDeposit(uint256,uint256)"
    expect_revert("2.3", owner, "Safe", RELAY, RD, SOURCE_ID, deposit_amount, want="NotRegistered",
                  note="requestDeposit(17968, all) — live config, weight still allocated")

    s = snapshot()  # counterfactual probe: VPM open but source weight still allocated
    send(fee_manager, VPM, "setFee(bytes4,address,uint128)", SEL_DEPOSIT_INTO_NFT, RELAY, 0)
    expect_revert("2.4", owner, "Safe", RELAY, RD, SOURCE_ID, deposit_amount, want="InsufficientChain0Allocation",
                  note="requestDeposit(17968, all) with VPM re-registered but source not deallocated "
                       "(source free weight too low) [COUNTERFACTUAL VPM]")
    revert_to(s)

    gauges_dealloc = f"[({DEALLOC_GAUGE},{deposit_amount},0x)]"
    rc = send(owner, VOTER, "allocateGauges(uint256,uint256,(address,uint128,bytes)[],uint256,address)",
              SOURCE_ID, BASE_CHAIN, gauges_dealloc, 0, owner)
    record("2.5", "Safe", "Voter.allocateGauges(17968, Base, [DEALLOC_GAUGE: all]) — pull weight back to chain0",
           f"chain0(17968) = {fmt(chain0(SOURCE_ID))} (allocating={view(VOTER, 'allocating(uint256)(bool)', SOURCE_ID)[0]})",
           gas(rc))
    expect_revert("2.6", owner, "Safe", RELAY, RD, SOURCE_ID, deposit_amount, want="NotRegistered",
                  note="requestDeposit(17968, all) after dealloc — live VPM config")

    rc1 = send(fee_manager, VPM, "setFee(bytes4,address,uint128)", SEL_DEPOSIT_INTO_NFT, RELAY, 0)
    rc2 = send(fee_manager, VPM, "setFee(bytes4,address,uint128)", SEL_WITHDRAW_TO_NFT, RELAY, 0)
    record("2.7", f"VPM FEE_MANAGER {fee_manager} (impersonated)",
           "VPM.setFee(depositIntoNFT|withdrawToNFT, relay, 0) — restores the registration that existed "
           "blocks 52,963,120-52,966,196", "ok", gas(rc1) + gas(rc2), label="COUNTERFACTUAL")

    expect_revert("2.8", owner, "Safe", RELAY, RD, SOURCE_ID, min_dep - 1, want="BelowMinimumDeposit",
                  note=f"requestDeposit(17968, minDeposit-1 = {min_dep - 1} wei)")
    expect_revert("2.9", stranger, "stranger", RELAY, RD, SOURCE_ID, deposit_amount, want="NotAuthorized",
                  note="requestDeposit(17968) by a non-owner")

    acc_before = staked(0)["amount"]
    relay_before = staked(relay_tid)["amount"]
    rc = send(owner, RELAY, RD, SOURCE_ID, deposit_amount)
    req = logs(rc, "DepositRequested")[0]
    dep_id = words(req["data"])[1]
    net_in = words(req["data"])[0]
    vpm_dep_fee = staked(0)["amount"] - acc_before
    assert staked(relay_tid)["amount"] - relay_before == net_in
    record("2.10", "Safe", f"relay.requestDeposit(17968, {fmt(deposit_amount)})",
           f"queued id {dep_id}; net weight in relay {fmt(net_in)}; VPM fee {vpm_dep_fee} wei; "
           f"#17968 left with {staked(SOURCE_ID)['amount']} wei", gas(rc), deposit_id=dep_id, net_in=net_in)
    S_DEPOSITED = snapshot()

    # ── Step 3 + 4 + 5, run on two branches ───────────────────────────────────────────────────
    results = {}
    for branch in ["overdue", "keeper"]:
        revert_to(S_DEPOSITED)
        S_DEPOSITED = snapshot()
        b = branch[0].upper()
        if branch == "keeper":
            expect_revert(f"3{b}.1", stranger, "stranger", RELAY, "processPending(uint256)", 10,
                          want="Unauthorized", note="processPending(10) by non-keeper")
            rc = send(keeper, RELAY, "processPending(uint256)", 10)
            procs = logs(rc, "DepositProcessed")
            mine = [l for l in procs if int(l["topics"][1], 16) == SOURCE_ID][0]
            shares = words(mine["data"])[1]
            record(f"3{b}.2", f"keeper {keeper} (impersonated)", "relay.processPending(10)",
                   f"processed {len(procs)} entries (ids 1-{dep_id}, FIFO); Safe minted {fmt(shares)} PT+YT",
                   gas(rc), shares=shares)
        else:
            expect_revert(f"3{b}.1", stranger, "stranger", RELAY, "processOverduePending(uint256[])", f"[{dep_id}]",
                          want="KeeperWindowNotElapsed", note=f"processOverduePending([{dep_id}]) immediately")
            req_at = int(view(RELAY, "pendingDeposits(uint256)(address,uint48,uint128,uint128)", dep_id)[1])
            warp_to(req_at + keeper_window - 2)
            # tx (not eth_call) so the block timestamp is exact: the reverted tx is mined at
            # requestedAt + keeperWindow - 1 and leaves no state change.
            rpc("evm_setNextBlockTimestamp", [req_at + keeper_window - 1])
            h = rpc("eth_sendTransaction", [{"from": stranger, "to": RELAY, "gas": hex(30_000_000),
                                             "data": calldata("processOverduePending(uint256[])", f"[{dep_id}]")}])
            rc = receipt(h)
            blk = int(rpc("eth_getBlockByNumber", [rc["blockNumber"], False])["timestamp"], 16)
            record(f"3{b}.2", "stranger", f"processOverduePending([{dep_id}]) mined at requestedAt+{blk - req_at}s",
                   "reverted (status 0)" if int(rc["status"], 16) == 0 else "SUCCEEDED", gas(rc))
            rpc("evm_setNextBlockTimestamp", [req_at + keeper_window])
            rc = send(stranger, RELAY, "processOverduePending(uint256[])", f"[{dep_id}]")
            blk = int(rpc("eth_getBlockByNumber", [rc["blockNumber"], False])["timestamp"], 16)
            assert blk - req_at == keeper_window
            mine = logs(rc, "DepositProcessed")[0]
            shares = words(mine["data"])[1]
            record(f"3{b}.3", "stranger (permissionless)", f"relay.processOverduePending([{dep_id}]) "
                   f"mined at requestedAt+{keeper_window}s (= keeperWindow exactly)",
                   f"processed 1 entry out of order ({view(RELAY, 'depositList()(uint40,uint40,uint40)')[2]} older "
                   f"entries still queued); Safe minted {fmt(shares)} PT+YT",
                   gas(rc), shares=shares)
            expect_revert(f"3{b}.4", stranger, "stranger", RELAY, "processOverduePending(uint256[])", f"[{dep_id}]",
                          want="DepositAlreadyProcessed", note="processOverduePending same id again")

        pt, yt = principal(), yield_token()
        free = vint(pt, "balanceOf(address)(uint256)", owner)
        assert free == shares == vint(yt, "balanceOf(address)(uint256)", owner)
        RW = "registerOnWithdrawQueue(uint256,uint256)"

        if branch == "overdue":
            # exit guards (eth_call only, no state change)
            expect_revert("4.1", owner, "Safe", RELAY, RW, 0, MINT_SENTINEL, want="BelowMinimumWithdrawal",
                          note="exit piece = 0 shares")
            expect_revert("4.2", owner, "Safe", RELAY, RW, min_wd - 1, MINT_SENTINEL, want="BelowMinimumWithdrawal",
                          note=f"exit piece = minWithdrawal-1 ({min_wd - 1} wei shares)")
            expect_revert("4.3", owner, "Safe", RELAY, RW, free - (min_wd - 1), MINT_SENTINEL,
                          want="BelowMinimumWithdrawal", note="exit leaving remainder of minWithdrawal-1")
            ok, _ = call_err(owner, RELAY, RW, min_wd, MINT_SENTINEL)
            record("4.4", "Safe", f"exit piece = exactly minWithdrawal ({min_wd} wei shares)",
                   "accepted" if ok else "REVERTED", label="SIMULATED (eth_call)")
            expect_revert("4.5", owner, "Safe", RELAY, RW, free + 1, MINT_SENTINEL, want="InsufficientFreeShares",
                          note="exit piece = free+1")
            expect_revert("4.6", owner, "Safe", RELAY, RW, free // 10, relay_tid, want="InvalidDestination",
                          note="destination = relay's own sAERO")
            expect_revert("4.7", stranger, "stranger", RELAY, RW, min_wd, MINT_SENTINEL, want="InsufficientFreeShares",
                          note="exit by an address holding no shares")
            free_weight_too_low(owner, keeper, stranger, relay_tid, free, min_wd, evac)

        # the 10-piece exit
        piece = free // PIECES
        sizes = [piece] * (PIECES - 1) + [free - piece * (PIECES - 1)]
        reg_gas = []
        for i, sz in enumerate(sizes):
            rc = send(owner, RELAY, RW, sz, MINT_SENTINEL)
            reg_gas.append(gas(rc))
        record(f"4{b}.r", "Safe", f"registerOnWithdrawQueue(piece, MINT_SENTINEL) x{PIECES}",
               f"{PIECES} exits queued; escrowed {fmt(vint(RELAY, 'escrowedShares(address)(uint256)', owner))} shares; "
               f"pieces {fmt(sizes[0])} x9 + {fmt(sizes[-1])}",
               sum(reg_gas), per_call=reg_gas)

        acc_before = staked(0)["amount"]
        backing_before = vint(RELAY, "totalBacking()(uint256)")
        relay_staked_before = staked(relay_tid)["amount"]
        drained, drain_gas = [], []
        if branch == "overdue":
            rc = send(stranger, RELAY, "processWithdrawals(uint256)", PIECES)
            drained = logs(rc, "WithdrawProcessed")
            drain_gas.append(gas(rc))
            record(f"4{b}.d", "stranger (permissionless)", f"relay.processWithdrawals({PIECES})",
                   f"settled {len(drained)} exits in one call", gas(rc))
        else:
            for _ in range(PIECES):
                rc = send(stranger, RELAY, "processWithdrawals(uint256)", 1)
                drained += logs(rc, "WithdrawProcessed")
                drain_gas.append(gas(rc))
            record(f"4{b}.d", "stranger (permissionless)", f"relay.processWithdrawals(1) x{PIECES}",
                   f"settled {len(drained)} exits one per call", sum(drain_gas), per_call=drain_gas)

        # ── Step 5 checks ──
        new = []
        for l in drained:
            sharesBurnt, net_amt, tid = words(l["data"])
            st = staked(tid)
            new.append({"tokenId": tid, "sharesBurnt": sharesBurnt, "net": net_amt, "staked": st["amount"],
                        "isPermanent": st["isPermanent"], "end": st["end"],
                        "owner": view(VE, "ownerOf(uint256)(address)", tid)[0],
                        "chain0": chain0(tid)})
        total = sum(n["staked"] for n in new)
        vpm_wd_fee = staked(0)["amount"] - acc_before
        gross_out = backing_before - vint(RELAY, "totalBacking()(uint256)")
        assert relay_staked_before - staked(relay_tid)["amount"] == gross_out
        queue = view(RELAY, "withdrawQueue()(uint40,uint40,uint40)")
        results[branch] = {
            "shares": shares, "pieces": sizes, "new_sAERO": new, "sum_new": total, "deposit_gross": deposit_amount,
            "deposit_net": net_in, "vpm_deposit_fee": vpm_dep_fee, "vpm_withdraw_fee": vpm_wd_fee,
            "gross_out_of_relay": gross_out, "shortfall_vs_net_deposit": net_in - total,
            "all_permanent": all(n["isPermanent"] and n["end"] == 0 for n in new),
            "all_owned_by_safe": all(n["owner"].lower() == owner.lower() for n in new),
            "all_free_on_chain0": all(n["chain0"] == n["staked"] for n in new),
            "fresh_ids": sorted(n["tokenId"] for n in new),
            "withdrawQueue(head,tail,count)": queue,
            "pendingWithdrawalShares": vint(RELAY, "pendingWithdrawalShares()(uint256)"),
            "escrowedShares_safe": vint(RELAY, "escrowedShares(address)(uint256)", owner),
            "pt_safe": vint(pt, "balanceOf(address)(uint256)", owner),
            "yt_safe": vint(yt, "balanceOf(address)(uint256)", owner),
            "relay_totalBacking": vint(RELAY, "totalBacking()(uint256)"),
            "relay_staked": staked(relay_tid)["amount"],
            "source_17968_after": staked(SOURCE_ID),
            "register_gas": reg_gas, "drain_gas": drain_gas,
        }
        r = results[branch]
        record(f"5{b}.sum", "-", "sum of 10 new sAERO vs deposit",
               f"sum {fmt(r['sum_new'])} vs net deposit {fmt(net_in)}: shortfall {r['shortfall_vs_net_deposit']} wei "
               f"(VPM deposit fee {vpm_dep_fee} wei, VPM withdraw fee {vpm_wd_fee} wei)", label="SIMULATED (state read)")
        record(f"5{b}.perm", "-", "each new sAERO permanent / owner / free",
               f"permanent(end=0)={r['all_permanent']} owner=Safe:{r['all_owned_by_safe']} "
               f"free-on-chain0:{r['all_free_on_chain0']} ids={r['fresh_ids']}", label="SIMULATED (state read)")
        record(f"5{b}.q", "-", "queue drained",
               f"withdrawQueue={queue} pendingShares={r['pendingWithdrawalShares']} escrow={r['escrowedShares_safe']} "
               f"PT={r['pt_safe']} YT={r['yt_safe']}", label="SIMULATED (state read)")
        if branch == "overdue":
            ok, err = call_err(owner, VE, "downgradeFromPermanentStake(uint256)", new[0]["tokenId"])
            record("5.perm2", "Safe", f"VE.downgradeFromPermanentStake({new[0]['tokenId']}) (eth_call)",
                   "callable by holder (permanence is a flag, not irrevocable)" if ok else f"reverts {err}",
                   label="SIMULATED (eth_call)")
            t = new[0]["tokenId"]
            leaf_last = int(view(LEAF_VOTER, "tokenStates(uint256)(address,uint48,bool,uint128)", t)[1])
            root_state = view(VOTER, "tokenStates(uint256)(uint128,uint48,uint48,bool)", t)
            g = LIVE_GAUGES[0]
            amt = new[0]["staked"]
            ok, err = call_err(owner, VOTER,
                               "allocate(uint256,(uint256,uint128,uint256,uint256)[],(uint256,uint256,uint256,(address,uint128,bytes)[])[],address)",
                               t, f"[({BASE_CHAIN},{amt},0,0)]", f"[({BASE_CHAIN},0,0,[({g},{amt},0x)])]", owner)
            record("5.alloc", "Safe", f"Voter.allocate({t} -> one Base gauge, full amount) right after mint (eth_call)",
                   ("accepted" if ok else f"reverts {err}") + f"; leaf lastAllocated={leaf_last}, "
                   f"root tokenStates(committed,lastStakeEnd,lastAllocated,isPermanent)={root_state}",
                   label="SIMULATED (eth_call)")
            ok, err = call_err(owner, RELAY, RW, 1, MINT_SENTINEL)
            record("5.q2", "Safe", "register another exit after full exit", "accepted" if ok else f"reverts {err}",
                   label="SIMULATED (eth_call)")

    out = {"live": live, "rows": ROWS, "results": results, "errors_decoded_from": "metadex-public V3/src"}
    with open(args.out, "w") as f:
        json.dump(out, f, indent=1, default=str)
    print(f"\nwrote {args.out}")


def principal():
    return view(RELAY, "principalToken()(address)")[0]


def yield_token():
    return view(RELAY, "yieldToken()(address)")[0]


def free_weight_too_low(owner, keeper, stranger, relay_tid, free, min_wd, evac):
    """Free chain0 weight below the queued exits: the voter allocates first, then exits queue."""
    s = snapshot()
    c0 = chain0(relay_tid)
    piece = free // PIECES
    delta = c0 - piece // 2  # leave less than half a piece free
    gauges = LIVE_GAUGES
    each = delta // len(gauges)
    amts = [each] * (len(gauges) - 1) + [delta - each * (len(gauges) - 1)]
    glist = "[" + ",".join(f"({g},{a},0x)" for g, a in zip(gauges, amts)) + "]"
    sig = "allocate((uint256,uint128,uint256,uint256)[],(uint256,uint256,uint256,(address,uint128,bytes)[])[],address)"
    rc = send(keeper, RELAY, sig, f"[({BASE_CHAIN},{delta},0,0)]", f"[({BASE_CHAIN},0,0,{glist})]", keeper)
    record("4.8", "keeper as VOTER_ROLE", f"relay.allocate(Base, {fmt(delta)} over {len(gauges)} gauges)",
           f"relay free chain0 now {fmt(chain0(relay_tid))} (< one piece {fmt(piece)})", gas(rc),
           label="SIMULATED (scenario)")
    for sz in [piece] * (PIECES - 1) + [free - piece * (PIECES - 1)]:
        send(owner, RELAY, "registerOnWithdrawQueue(uint256,uint256)", sz, MINT_SENTINEL)
    q_before = view(RELAY, "withdrawQueue()(uint40,uint40,uint40)")
    rc = send(stranger, RELAY, "processWithdrawals(uint256)", PIECES)
    q_after = view(RELAY, "withdrawQueue()(uint40,uint40,uint40)")
    record("4.9", "stranger", f"processWithdrawals({PIECES}) with free weight < head exit",
           f"does NOT revert; settled {len(logs(rc, 'WithdrawProcessed'))}; queue {q_before} -> {q_after}",
           gas(rc), label="SIMULATED (scenario)")
    expect_revert("4.10", keeper, "keeper as VOTER_ROLE", RELAY, sig, f"[({BASE_CHAIN},1,0,0)]", "[]", keeper,
                  want="InsufficientFreeWeight", note="relay.allocate(+1 wei) while exits are queued")
    dealloc = f"[({BASE_CHAIN},0,0,[({DEALLOC_GAUGE},{delta},0x)])]"
    expect_revert("4.11", keeper, "keeper as VOTER_ROLE", RELAY, sig, "[]", dealloc, keeper,
                  want="CooldownActive", note="relay.allocate(DEALLOC all) right after allocating (leaf cooldown)")
    expect_revert("4.12", stranger, "stranger", RELAY, "close()", want="EvacuationWindowNotElapsed",
                  note="close() by anyone before evacuationWindow")
    s2 = snapshot()
    warp(evac)
    ok, err = call_err(stranger, RELAY, "close()")
    record("4.13", "stranger", f"close() after evacuationWindow={evac}s with head still uncovered (eth_call)",
           "callable by anyone" if ok else f"reverts {err}", label="SIMULATED (eth_call, scenario)")
    revert_to(s2)
    cooldown = vint(LEAF_VOTER, "allocationCooldown()(uint48)")
    warp(cooldown)
    rc = send(keeper, RELAY, sig, "[]", dealloc, keeper)
    rc2 = send(stranger, RELAY, "processWithdrawals(uint256)", PIECES)
    record("4.14", "keeper, then stranger", f"after leaf cooldown {cooldown}s: dealloc, then processWithdrawals({PIECES})",
           f"settled {len(logs(rc2, 'WithdrawProcessed'))} exits", gas(rc) + gas(rc2), label="SIMULATED (scenario)")
    revert_to(s)


if __name__ == "__main__":
    main()
