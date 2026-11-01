# Splitting sAERO #17968 into 10 via Aero Autopilot — Base fork simulation

**Fork only. Nothing was signed or broadcast.** Every state change ran on a local anvil fork of
Base, with accounts impersonated. Live Base was used only for reads.

## Correction (supersedes the first version of this report)

The first version said "neither Maxi Autopilot relay can take a deposit". **That was wrong.** It
enumerated only the RelayFactory in the published `deployment-addresses` and on Aero's security
page (`0xA972…049d`). The RelayFactoryRegistry `0x0dfB…8f99` (on the security page) approves a
**second factory**, `0xA528…4B78`. That factory redeployed both Maxi relays under the same names,
and these are what users are joining:

| Relay (factory 2) | Name | Backing | Deposit ids issued | Exits paid | VPM |
|---|---|---:|---:|---:|---|
| `0xf588F86577C472D83E5F84403951AA0B92fc1Dd6` | Autopilot sAERO Maxi | 4.52 M AERO | 909 | 31 | registered at 0% since block 53,335,262 |
| `0xAfa7cA53e0A63d94218728842ED286308435DD86` | Autopilot USDC Maxi | 18.54 M AERO | 832 | 30 | registered at 0% since block 53,335,262 |

The factory-1 relays simulated below (`0x871d…`, `0x549C…`) are the de-registered first
deployment.

The factory-2 relays run **different code** from `metadex-public` `main`. The MaxiRelay
implementation `0x3909f8b833A8Beba57CEf8c6E713E885b6c359cE` has a Sourcify exact match
(verified 2026-10-30). Its sources differ from `main` in `RelayBase.sol`, `QueueLib.sol`,
`RelayInitLib.sol` and `IRelay.sol`. The changes that decide this task:

- `requestDeposit` takes the source's **whole stake**. `_amount` must be `type(uint256).max`,
  otherwise it reverts `NotFullStake()`.
- Each processed deposit becomes one **deposit record**. `registerOnWithdrawQueue(depositId, destination)`
  exits **that whole record** to one sAERO. Partial exits and `minWithdrawal` no longer exist.

### Result on the live relay (`split_17968_live_relay.py`, fork block 53,388,239, `results_live.json`)

| # | Label | Actor | Action | Result | Gas |
|---|---|---|---|---|---:|
| 0 | LIVE READ | — | provenance | factory 2 is registry-approved; relay is its MaxiRelay clone of `0x3909…`; queue has 86 pending | — |
| 1 | eth_call | Safe | `VPM.withdrawToNFT(17968 → 10 fresh sAERO)` directly | reverts `NotRegistered()`: holders can't split at the VPM | — |
| 2.1–2.2 | SIMULATED | Safe | approve VPM + relay; deallocate #17968 from its 6 Base gauges | ok | 95,029 + 2,689,356 |
| 2.3–2.4 | eth_call | Safe | `requestDeposit(17968, amount)` / `(17968, amount/10)` | reverts `NotFullStake()` | — |
| 2.5 | SIMULATED | Safe | `requestDeposit(17968, type(uint256).max)` | deposit id 910, net 4,160,871.205527 AERO, fee 0 | 510,977 |
| 3K | SIMULATED | keeper | `processPending(87)` (whole backlog, FIFO) | 87 processed; record 910 = 4,160,871.205527 shares | 6,129,888 |
| 3O | SIMULATED | stranger | `processOverduePending([910])` at requestedAt + 176,400 s | ours alone | 230,307 |
| 4.1 | eth_call | Safe | old-style `registerOnWithdrawQueue(shares/10, fresh)` | reverts `DepositRecordNotFound()` (the argument is now a deposit id) | — |
| 4.2 | eth_call | stranger | `registerOnWithdrawQueue(910, fresh)` | reverts `NotDepositHolder()` | — |
| 4.3 | SIMULATED | Safe | `registerOnWithdrawQueue(910, fresh)` | escrows the whole record | 156,872 |
| 4.4 | eth_call | Safe | `registerOnWithdrawQueue(910, …)` again, for a 2nd piece | reverts **`DepositRecordNotFound()`** | — |
| 4.5 | SIMULATED | stranger | `processWithdrawals(1)` | Safe receives **one** sAERO (#21269): 4,160,871.205527 AERO, permanent; 0 wei shortfall | 807,007 |

Both processing paths (keeper and overdue) give the same outcome. **A 10-way split of one sAERO
through the live Autopilot is impossible by design.** One deposit gives one record, which gives
one sAERO. Ten pieces would need ten source sAERO going in, and holders cannot create those: the
VPM's split primitive is restricted to registered callers.

### Keeper speed on the live relay (`0xf588…`, logs from its creation at block 53,275,056)

The same keeper, `0x7793…fe67`, processed **823 of 909** deposits. Latency from request to
processing: median **70 s**, p90 **120 s**, max **1,304 s**. The gaps between its processing
transactions stayed under 40 min until block 53,381,721. From then until block 53,388,199 it
processed nothing (≈ 3.6 h), and 86 deposits were waiting. Usually fast, but not guaranteed:
the permissionless overdue path (49 h) is the fallback.

---

# Original simulation: factory-1 relay `0x871d…` (de-registered first deployment)

Everything below is the first version of this report. It applies to the factory-1 relay, which
still runs the code on `metadex-public` `main` (partial exits by share amount). It required the
counterfactual VPM re-registration in step 2.7. Its "Bottom line" claim that no Maxi relay can
take a deposit is **wrong**; see the correction above. Fork block **53,387,600**.

### Original bottom line (factory-1 relay only)

- Both factory-1 Maxi relays were de-registered at the VPM at block 52,966,196.
- With the labelled counterfactual (step 2.7), a 10-way split through the **old** code works
  exactly: 0 wei lost, 0 fees, all permanent.
- The factory-1 keeper never processed a deposit. That says nothing about the live relay, whose
  keeper runs (above).

## What is real and what is simulated (original run)

| Label | Meaning |
|---|---|
| LIVE READ | Read from Base at the fork block. |
| SIMULATED | A transaction mined on the local fork. `gasUsed` is taken from the fork receipt. |
| SIMULATED (eth_call) | A dry-run call on the fork, used for revert checks. Changes no state. |
| SIMULATED (scenario) | A side branch run from an `evm_snapshot` and then reverted, so the main path is unaffected. |
| COUNTERFACTUAL | Protocol configuration changed on the fork, by the real role holder (impersonated). |

Actors, all impersonated on the fork:
- **Safe:** owner of #17968, `0xa79c…5a31`, a Safe 1.3.0 with threshold 3 of 5. Impersonating it
  skips signatures and Safe `execTransaction` overhead.
- **Keeper:** `0x7793…fe67`. It holds KEEPER and VOTER_ROLE on the relay (rolesOf = 3, from the
  relay's `RolesUpdated` logs).
- **VPM FEE_MANAGER:** `0x4225…4cE0`.
- **stranger:** `0x…bEEF`, an address with no roles.

Clock: blocks are 2 s apart, as on Base. Time jumps use `evm_setNextBlockTimestamp`. Two runs gave
byte-identical output.

**Relay used:** "Autopilot sAERO Maxi" `0x871d4388589b3d0259089534C0711ea8B7F06E7B`.
- Factory index 0, `relayType() == Maxi`, `isRelay == true` on RelayFactory `0xA972…049d`.
- RelayFactory, MaxiRelay implementation, VotingEscrow, Voter and VPM addresses match
  app.aero.xyz/docs/security and `metadex-public/deployment-addresses/*-base.json`.
- Code: `metadex-public` `V3/src/relay` at commit `8b506b4`.

**Relay config (live):**
- minDeposit = minWithdrawal = 1 AERO
- keeperWindow = 176,400 s (49 h)
- evacuationWindow = 604,800 s (7 d)
- lockWeeks = 0 (permanent)
- entrypointTimelock = 3,600 s
- rakes 0/0, MAX_RAKE_PIPS = 200,000 (20%)
- reward-token registry empty

## Steps and results

Overdue path (main run). `t+` is simulated seconds since the fork block.

| # | t+ | Label | Actor | Action | Result | Gas |
|---|---:|---|---|---|---|---:|
| 0 | 0 | LIVE READ | — | state of #17968 | 4,160,871.205527 AERO, permanent, owner = Safe; **chain0 (free) = 0**: all on 6 Base gauges, last allocation 2026-10-26 (LeafVoter cooldown 169,200 s, already elapsed) | — |
| 1 | — | — | — | Install Foundry | forge/cast/anvil **1.7.1** from the official `@foundry-rs/*` npm packages (registry signatures and SLSA attestations verified). The installer's GitHub release download was blocked by this session's proxy. | — |
| 2.1 | 2 | SIMULATED | Safe | `VE.setApprovalForAll(VPM, true)` | ok. VE checks that the VPM is authorized on the source. | 46,323 |
| 2.2 | 4 | SIMULATED | Safe | `VE.approve(relay, 17968)` | ok. The VPM checks that its caller (the relay) is authorized on the source. | 48,706 |
| 2.3 | 4 | eth_call | Safe | `requestDeposit(17968, all)`, live config | **reverts `NotRegistered()`** (VPM restricted) | — |
| 2.4 | 6 | eth_call (+CF VPM) | Safe | same, VPM re-registered, source not deallocated | **reverts `InsufficientChain0Allocation()`**: the source's free weight is too low | — |
| 2.5 | 6 | SIMULATED | Safe | `Voter.allocateGauges(17968, 8453, [DEALLOC_GAUGE: all], 0, Safe)` | chain0(17968) = 4,160,871.205527; `allocating = false`. Synchronous: Base is the root-colocated leaf. | 2,732,034 |
| 2.6 | 6 | eth_call | Safe | `requestDeposit(17968, all)`, live config | **reverts `NotRegistered()`**. This is today's real blocker. | — |
| 2.7 | 10 | **COUNTERFACTUAL** | FEE_MANAGER | `VPM.setFee(depositIntoNFT \| withdrawToNFT, relay, 0)` | Restores the on-chain registration that existed from block 52,963,120 to 52,966,196 | (99,100) |
| 2.8 | 10 | eth_call | Safe | `requestDeposit(17968, 1e18 − 1)` | reverts `BelowMinimumDeposit()` | — |
| 2.9 | 10 | eth_call | stranger | `requestDeposit(17968, all)` | reverts `NotAuthorized()` | — |
| 2.10 | 12 | SIMULATED | Safe | `relay.requestDeposit(17968, 4,160,871.205527)` | queued as id 4. Net in relay = gross; **VPM fee 0**. #17968 left at 0 AERO; the NFT stays with the Safe. | 440,572 |
| 3O.1 | 12 | eth_call | stranger | `processOverduePending([4])` right away | reverts `KeeperWindowNotElapsed()` | — |
| 3O.2 | 176,411 | SIMULATED | stranger | same, mined at requestedAt + 176,399 s | reverted (status 0) | 55,394 |
| 3O.3 | 176,412 | SIMULATED | **stranger** | same, mined at requestedAt + **176,400 s** | processed out of order (the 3 older entries stay queued). Safe minted 4,160,871.205527 PT + YT at price 1.0. | 235,992 |
| 3O.4 | 176,412 | eth_call | stranger | same id again | reverts `DepositAlreadyProcessed()` | — |
| 4.1 | 176,412 | eth_call | Safe | exit 0 shares | reverts `BelowMinimumWithdrawal()` | — |
| 4.2 | 176,412 | eth_call | Safe | exit 1e18 − 1 shares (piece below minimum) | **reverts `BelowMinimumWithdrawal()`** | — |
| 4.3 | 176,412 | eth_call | Safe | exit that leaves 1e18 − 1 behind | **reverts `BelowMinimumWithdrawal()`**. The floor applies to both sides. | — |
| 4.4 | 176,412 | eth_call | Safe | exit exactly 1e18 shares | accepted (boundary is inclusive) | — |
| 4.5 | 176,412 | eth_call | Safe | exit free + 1 | reverts `InsufficientFreeShares()` | — |
| 4.6 | 176,412 | eth_call | Safe | destination = relay's own sAERO 10028 | reverts `InvalidDestination()` | — |
| 4.7 | 176,412 | eth_call | stranger | exit with no shares | reverts `InsufficientFreeShares()` | — |
| 4.8 | 176,414 | scenario | keeper (VOTER_ROLE) | `relay.allocate(Base, 3,952,831.6 over #17968's 6 gauges)` | relay free chain0 = 208,043.6, which is less than one piece (416,087.1) | 3,377,330 |
| 4.9 | 176,436 | scenario | stranger | 10 exits queued, then `processWithdrawals(10)` | **does not revert**: settles 0, queue unchanged. Free weight too low is a silent stall, not a revert. | 63,235 |
| 4.10 | 176,436 | eth_call | keeper | `relay.allocate(+1 wei)` while exits are queued | reverts `InsufficientFreeWeight()`: queued exits reserve chain0 | — |
| 4.11 | 176,436 | eth_call | keeper | `relay.allocate(DEALLOC all)` right after allocating | reverts `CooldownActive()`: LeafVoter cooldown of 169,200 s (47 h) | — |
| 4.12 | 176,436 | eth_call | stranger | `close()` | reverts `EvacuationWindowNotElapsed()` | — |
| 4.13 | 781,236 | eth_call | stranger | `close()` 7 d after registration, head still uncovered | **callable by anyone**; it would close the relay permanently for everyone | — |
| 4.14 | 345,640 | scenario | keeper → stranger | after 47 h: dealloc, then `processWithdrawals(10)` | 10 settled | 8,684,384 |
| 4O.r | 176,432 | SIMULATED | Safe | `registerOnWithdrawQueue(piece, MINT_SENTINEL)` ×10 | 9 × 416,087.120552688226370732 + 1 × …370736 (remainder in the last piece) | 1,248,478 (171,021 first, then ~119,734 each) |
| 4O.d | 176,434 | SIMULATED | **stranger** | `processWithdrawals(10)` | 10 fresh sAERO minted to the Safe: **#21265–#21274** | 4,839,111 |
| 5O.sum | 176,434 | state read | — | sum of new sAERO vs deposit | **4,160,871.205526882263707324 = deposit, shortfall 0 wei** (VPM fee in 0, out 0) | — |
| 5O.perm | 176,434 | state read | — | permanence, owner, free | all 10 `isPermanent = true`, `end = 0`, owner = Safe, chain0 = amount (unallocated) | — |
| 5O.q | 176,434 | state read | — | queue drained | withdrawQueue (0, 10, 0); pendingWithdrawalShares 0; escrow 0; Safe PT 0, YT 0 | — |
| 5.perm2 | 176,434 | eth_call | Safe | `VE.downgradeFromPermanentStake(21265)` | callable: permanent is a flag the holder can reverse, not a lock | — |
| 5.alloc | 176,434 | eth_call | Safe | `Voter.allocate(21265 → one Base gauge)` right after mint | accepted. LeafVoter `lastAllocated = 0`, so the new tokens carry no cooldown. | — |
| 5.q2 | 176,434 | eth_call | Safe | register another exit | reverts `InsufficientFreeShares()` | — |

Keeper path, branched from the same post-deposit snapshot:

| # | t+ | Label | Actor | Action | Result | Gas |
|---|---:|---|---|---|---|---:|
| 3K.1 | 12 | eth_call | stranger | `processPending(10)` | reverts `Unauthorized()` (KEEPER only) | — |
| 3K.2 | 14 | SIMULATED | keeper | `processPending(10)` | processed 4 entries FIFO: three strangers' 1-AERO deposits, then ours. Safe minted 4,160,871.205527 PT + YT. | 570,425 |
| 4K.r | 34 | SIMULATED | Safe | 10 × `registerOnWithdrawQueue` | same pieces as the overdue path | 1,248,478 |
| 4K.d | 54 | SIMULATED | stranger | `processWithdrawals(1)` ×10 | 10 settled; ~828k each (fixed per-call cost) | 8,259,110 |
| 5K.* | 54 | state read | — | checks | same 10 amounts, 0 wei shortfall, all permanent, queue drained | — |

## Checks

| Check | Result |
|---|---|
| 10 new sAERO add up to the deposit | **Exact**, 0 wei. Share price was exactly 1.0 (backing = supply, since the relay has never compounded). The 4-wei remainder of shares/10 lands in the last piece. At a price other than 1.0, each piece would floor by up to 1 wei and the deposit mint floors once; that case was not exercised. |
| Each new sAERO is permanent | Yes: `isPermanent = true`, `end = 0` for all 10 (`_applyDestinationMint` inherits from the permanent relay sAERO). The holder can still `downgradeFromPermanentStake`. |
| Pieces below the minimum | Revert `BelowMinimumWithdrawal()`: zero, 1e18 − 1, or leaving 1e18 − 1 behind. Exactly 1e18 is accepted. A deposit below 1e18 reverts `BelowMinimumDeposit()`. |
| Free weight too low | On the source sAERO: `requestDeposit` **reverts** `InsufficientChain0Allocation()`. On the relay: `processWithdrawals` **does not revert**; it settles 0 and leaves the queue intact. The voter cannot allocate into queued exits (`InsufficientFreeWeight()`), but weight allocated *before* registration stays stuck until the voter deallocates (47 h cooldown). If nobody does, anyone can `close()` the relay 7 d after registration. |
| Fees | VPM protocol fee = 0 on both legs, measured as the change in accumulator sAERO #0. The relay itself charges nothing on principal (no fee path in `QueueLib`). **Caveat:** the VPM fee is `min(default, registered rate)`, set by FEE_MANAGER with **no timelock and up to 100%**. Today the default is 0 and the relay is unregistered, so the call reverts rather than charging. |
| Rake | protocol 0 / allocator 0, nothing pending. It applies only to reward flows (`compound`, `notifyReward`), never to deposits or exits. The cap is 20% (MAX_RAKE_PIPS 200,000 of 1e6), changeable by a RAKE_MANAGER after a **1 h** timelock. This relay has no reward token registered yet. |

## Timing

| Wait | Length | Source |
|---|---|---|
| LeafVoter cooldown before the Safe can deallocate #17968 | 169,200 s (47 h) after the last allocation. Already met (last allocation 2026-10-26 12:05 UTC). | `LeafVoter.allocationCooldown()` |
| Deposit → shares, keeper path | whenever the keeper acts. **Observed: never** on this relay. Three deposits were 9.8 d old at the fork block. The USDC Maxi relay is stalled the same way. | `DepositProcessed` log scan, `depositList()` |
| Deposit → shares, overdue path | exactly **176,400 s (49 h)**; reverts at 176,399 s | `keeperWindow` |
| Shares → 10 sAERO | same block, if relay free chain0 covers the exits. Otherwise up to 47 h (voter dealloc cooldown), or `close()` after 7 d. | 4.9–4.14 |
| **End to end, without relying on the keeper** | **≈ 49 h; 16 transactions** (14 from the Safe; the overdue process and the drain can come from anyone). The 4.16 M weight earns nothing from the dealloc (2.5) until the new sAERO are re-allocated. Re-allocation is immediately possible (5.alloc). | |

## Gas (fork receipts)

At Base's live gas price at the fork block (0.006 gwei; base fee 0.005 + tip 0.001), the
overdue path costs **≈ 9.59 M gas ≈ 0.000058 ETH**. That covers 2.1, 2.2, 2.5, 2.10, 3O.3, 4O.r
and 4O.d. It excludes the L1 data fee and the Safe `execTransaction` overhead for the 14 Safe
transactions (2 approvals, dealloc, deposit, 10 exits; ~+30–50k gas each). Drain all 10 exits in
one `processWithdrawals(10)` (4.84 M). Ten separate calls cost 8.26 M.

## Why some steps could not run as-is

1. **Deposit and exit on the factory-1 Maxi relays (live config).** VPM `restricted(depositIntoNFT) =
   restricted(withdrawToNFT) = true` since VPM deployment (block 52,688,130). The two factory-1
   Maxi relays were registered at a 0% rate at block 52,963,120 and removed at 52,966,196; their
   factory-2 replacements were registered at block 53,335,262 (see the correction). Steps 2.10
   onward of the original run therefore depend on counterfactual step 2.7.
2. **Historical fork without the counterfactual.** Not possible: sAERO #17968 did not exist during
   that 3.4 h window (`ownerOf` reverts `ERC721NonexistentToken(17968)` at blocks 52,964,000 and
   52,966,000).

## Observations relevant to `docs/g-facts.md` (table not edited)

- **G1:** the allocation cooldown is keyed per tokenId (`LeafVoter.tokenStates(tokenId).lastAllocated`).
  sAERO minted by a relay exit start at `lastAllocated = 0` (5.alloc).
- **G2:** holders still cannot split a position themselves (`VPM.withdrawToNFT` reverts
  `NotRegistered()` for them). The factory-1 relay code allowed a split through a relay round-trip.
  The live factory-2 code removes it: one deposit gives one record, which gives one sAERO.
- **G11/G12:** `withdrawToNFT` and `depositIntoNFT` are both `restricted` to registered callers.
  The source must authorize both the VPM and the calling relay.

## Reproduce

```bash
cd sim/aero-autopilot-split
# live factory-2 relay (the correction); SOURCIFY_SRC = Sourcify sources of 0x3909f8b8... written to disk
BASE_RPC_URL=... METADEX=/path/to/metadex-public SOURCIFY_SRC=/path/to/sources ./run_live.sh results_live.json   # FORK_BLOCK defaults to 53388239
# original factory-1 run
BASE_RPC_URL=... METADEX=/path/to/metadex-public ./run.sh results.json   # FORK_BLOCK defaults to 53387600
```

Both runners start anvil on 127.0.0.1, and both drivers refuse any non-loopback RPC. Revert
selectors are decoded against every `error` declared in the given sources. `results_live.json`
and `results.json` are the outputs reported here.
