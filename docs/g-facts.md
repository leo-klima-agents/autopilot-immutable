# G-facts tracking table (brief §2) — the spec-freeze diff log

Status legend: **verified-live** = asserted by a green fork test against Base mainnet;
**verified-in-published-code** = confirmed with file+line citations in the published v3
batch (provisional — re-verify at each batch and against the deployment);
**verified-with-modification** = core claim holds, a material detail differs (noted);
**INVALIDATED** = published code contradicts the assumption; **pending** = not yet
publishable/checkable; **DIVERGED** = live protocol contradicts the brief (documented,
code adjusted).

## v2 facts (EpochPilot — all decided)

| # | Fact (per brief) | Status | Evidence |
|---|---|---|---|
| G9a | One vote per epoch per tokenId (`onlyNewEpoch`) | **verified-live** | `test_fork_G9_onlyNewEpoch_oneVotePerEpoch` |
| G9b | First hour of each epoch blocked (`DistributeWindow`) | **verified-live** | `test_fork_G9_distributeWindowBlocksFirstHour` |
| G9c | Last hour whitelist-only | **verified-live** | `test_fork_G9_lastHourIsWhitelistOnly` |
| G9d | `weights(pool)` / `totalWeight()` public | **verified-live** | `test_fork_G9_publicWeightsAndTotalWeight` |
| G9e | `vote()` normalizes relative weights | **verified-live** | `test_fork_G9_voteNormalizesRelativeWeights` |
| G9f | `maxVotingNum` = 30 | **DIVERGED** — live value is **60** (governance raised it after the docs were written). The brief's own rule ("read live values every call; nothing is cached") absorbs the divergence: `EpochPilot.revote` reads `maxVotingNum()` at call time and never hardcodes it. | `test_fork_G9_maxVotingNumLiveValue`; live read 2026-07-23, block 49,016,010 |
| G9g | Epoch windows: `epochVoteStart = start+1h`, `epochVoteEnd = flip−1h` | **verified-live** — note: the whitelist-only final hour is where vote weights move most, and the vault (not whitelisted, one vote/epoch) cannot act in it → mirror carries an end-of-epoch tracking error (design-notes #11), a v2-structural limit v3's continuous allocation removes | `test_fork_G9_epochWindows` |
| G9h | `gaugeToFees` / `gaugeToBribe` registries validate claim targets | **verified-live** | `test_fork_G9_gaugeRewardRegistries` |
| G10 | Rebase claims permissionless per tokenId; auto-compound into unexpired locks via `depositFor` | **verified-live** — asserted on a real third-party mainnet veNFT: a stranger's `claim()` increased the lock's amount by exactly `claimable` | `test_fork_G10_rebasePermissionlessAutoCompounds` |
| G10b | Expired-lock rebase pays the owner **liquid** AERO (the branch `claimRebase`'s post-expiry accounting depends on); the distributor refuses claims while the minter period is stale | **verified-live** — a lock walked past expiry on the fork: stale-period claim reverts, post-`updatePeriod` claim pays the owner liquid, lock amount untouched | `test_fork_G10_expiredLockRebasePaysOwnerLiquid` |
| — | AERO is a well-behaved ERC-20 (returns true, no fee) | **verified-live** | `test_fork_aeroIsWellBehavedERC20` |

## v3 facts (TranchePilot — spec-freeze gate; diff each code batch from Aug 3, 2026)

**P1 diff log — 2026-08-14.** First public batch landed: `dromos-labs/metadex-public`
(v3 core, tag `96db1704…`, version `1.0.0-provisional.1`, first-distribution
2026-08-14) and `dromos-labs/metadex-slipstream-public` (CL AMM). The release is
explicitly **provisional** ("not final and may change prior to release") with **no
deployments**, and it is **partial**: reward-side implementations
(`VotingRewardsManager`/`FeeDistribution`/`IncentiveStreaming`) exist only as
interfaces. Implementations are `LicenseRef-Dromos-Restricted-Use-1.0`; **interfaces
are MIT** — our hand-written-interface rule is unencumbered. Citations below are
`repo-path:line` at that tag; re-verify at every subsequent batch and against the
eventual deployment.

| # | Fact | Status | Citation / notes |
|---|---|---|---|
| G1 | Cooldown keyed per sAERO position (tokenId), **not** per owner | **verified-in-published-code — KILL CRITERION PASSES** | `V3/src/voter/LeafVoter.sol:96` `mapping(uint256 _tokenId => TokenState)` with `lastAllocated` per token (`:415`, `:513`); cooldown consumed per tokenId (`:398`, `:479`, `:725-728`). Root `Voter.sol` performs **no** cooldown check — enforcement is leaf-side, per (tokenId, chain). New: a governance-gated **cooldown-reduction** credit exists (`LeafVoter.sol:428`, off by default via `maxAccumulatedCooldownReduction = 0`) — can only shorten cooldowns, never lengthen; tranche math unaffected. |
| G2 | Positions cannot be split by holders | **verified-in-published-code** | `VotingEscrow.sol` exposes no split of any kind (external surface: `createStake`, `increaseStakeAmount`, `increaseStakingPeriod`, `withdraw`, `upgradeToPermanentStake`, `downgradeFromPermanentStake`, `delegate`). `splitter/Splitter.sol` is unrelated (Minter team-share revenue splitter). |
| G3 | Creation-time permanent-stake flag | **verified-in-published-code** | `VotingEscrow.sol:181-201` `createStake(value, stakingWeeks, isPermanent)`; permanent = `end 0`, no decay; two-call fallback also exists (`upgradeToPermanentStake`, `:287`). |
| G4 | Top-ups don't reset allocations or cooldown | **verified-with-modification** | Cooldown: confirmed untouched — `lastAllocated` is written only by allocation passes (`Voter.sol:832`; re-anchor paths explicitly "leave `lastAllocated` alone", `Voter.sol:862`, `:495`, `:1274`; leaf `:366`). **Modification:** new top-up weight does **not** back standing gauge allocations — it parks on `CHAIN0`, the idle sink, until the next allocation pass spends it (`Voter.sol:820-825`; `ZERO_GAUGE`/`CHAIN0` idle-sink design). This is exactly the brief's anticipated contingency: deposits buffer and join at the tranche's next slot — an accounting change, not an architecture change. Also: `increaseStakeAmount` is **owner-or-approved only** (`VotingEscrow.sol:209`), not permissionless like v2 `depositFor`. |
| G5 | Allocations persist until changed | **verified-in-published-code** (permanent stakes) | Allocations are stored absolute budgets changed only by allocation passes (`LeafVoter.sol:366` "cannot resurrect a deallocated budget… `lastAllocated` untouched"; root `allocationChainAmounts` persists; re-anchoring preserves amounts at new stake shape). "Exact for permanent stakes" (`Voter.sol:974`). |
| G6 | Per-gauge caps on the gauge factory, readable, bounded operator; cap 0 = deactivated | **verified-in-published-code** (mechanism) | `GaugeFactory.sol:55-68` `defaultCap` + per-gauge `_emissionCaps` (sentinel `DEFAULT_CAP_INDICATOR`); public `emissionCap(gauge)` (`:233`); `CAP_ADMIN_ROLE` + **bounded** `CAP_OPERATOR_ROLE` (`operatorMinCap`/`operatorMaxCap`, `:89`). Cap 0 ⇒ gauge unroutable (`LeafVoter.sol:906`) and unvotable by default (`canVoteForZeroCapGauges`, default false). The ~48h revenue-pegged recalibration is *operational* (cap-operator behavior), not in code — strategy signal mechanism confirmed, freshness to be observed post-launch. |
| G7 | Voter entrypoints take pools + relative weights; anti-dust minimum | **INVALIDATED as written — interface is materially different** | Allocation is `allocateGauges(tokenId, chainId, GaugeAllocation[], gasLimit, refundRecipient)` (root `Voter.sol:228`; also `allocateChains` `:207`, combined `allocate` `:250`), all `payable`, gated `onlyAuthorizedForToken` = escrow owner-or-approved (`:137`). `GaugeAllocation[]` carries **absolute uint128 amounts** that must be **strictly ascending by gauge address**, non-zero, and **sum exactly to the token's chain budget** (`LeafVoter.sol:487-506`, `ChainAllocationMismatch`); idle VP is an explicit `ZERO_GAUGE` first entry; `DEALLOC_GAUGE` sentinel returns budget to root. No normalization, no relative weights. Anti-dust = non-zero entries + exact-sum. `maxGauges` bound on leaf (`LeafVoter.sol:143`). TranchePilot's §3.4/§4.2 layer must emit exact-budget ascending allocations (cap-proportional weights scaled to budget with rounding residue assigned deterministically). |
| G8 | Revenue accrues per position in heterogeneous tokens, pull-per-token | **pending — not in this batch** | Only interfaces published (`IVotingRewardsManager`, `IFeeDistribution`, `IIncentiveStreaming`, `IVotingCheckpoints`); root `Voter.claimFees`/`claimIncentives` routing entrypoints exist (`Voter.sol:383`, `:388`). Distributor design decision stays open. |
| G11 | `withdraw-to-NFT` role-gated | **verified-in-published-code** *(corrected 2026-08-15 — an earlier revision of this row wrongly said the primitive does not exist; it lives on the VPM, not the escrow, and was missed by an escrow-only search)* | The fractional carve-out exists: `VoterPaymentsModule.withdrawToNFT(sourceId, destinations[])` (`V3/src/vpm/VoterPaymentsModule.sol:178`) pulls stake out of a source sAERO and, via a mint-sentinel destination, **mints a fresh sAERO to a recipient** (`:171`, escrow `_applyDestinationMint`, `VotingEscrow.sol:392-395` — the mint *inherits the source's unlock shape*, so a slice of a permanent tranche exits as a permanent position, exactly the brief's `exitToNFT`). Role-gating matches the spec draft: the VPM contract needs `VPM_ROLE` on the escrow (`VotingEscrow.sol:339`) **and** owner authorization for each source it drains (`:343-348`); the end caller must be escrow-authorized for the source (`VoterPaymentsModule.sol:279-281`). So the vault does not need a governance grant itself — it approves an allowlisted VPM for its tranche tokenIds. **Residual dependencies to track:** (a) an allowlisted VPM deployed at launch (the repo ships the canonical one); (b) per-operation protocol fee, settable per (signature, caller) from 0 to 100% (`MAX_PIPS`) by `FEE_MANAGER` (`VoterPaymentsModule.sol:88-89`) — an immutable vault is a fee-taker, so exit cost is governance-mediated (disclose alongside the cap-operator trust row); (c) a per-signature `restricted` flag (`:104`); (d) open mechanical question: whether the drained source weight must first be **parked on CHAIN0** (unallocated) — the escrow mirrors moves onto the Voter's chain0 ledger, suggesting yes; verify in fork tests and sequence `exitToNFT` after deallocation if so. |
| G12 | `deposit-into-NFT` merge, owner-gated | **verified-with-modification** *(corrected 2026-08-15 — same erratum as G11)* | Merge exists: `VoterPaymentsModule.depositIntoNFT(sources[], destinationId, recipient)` (`VoterPaymentsModule.sol:131`) drains one or more source sAEROs into an existing destination or a fresh mint. Modification vs the spec draft: it is **not** gated by plain owner/approval-of-both alone — it routes through the VPM (VPM_ROLE + fee + possible restriction), and destinations must satisfy the monotonic-unlock rule (`VotingEscrow.sol:351-354, 397-399`). Joining Model P with an existing position is therefore possible, at the VPM fee; AERO + `createStake`/`increaseStakeAmount` remains the fee-free join path. |
| G13 | One tokenId per allocation call (no native batch) | **verified-in-published-code** | All three root entrypoints take a single `_tokenId` (`Voter.sol:207-255`); no batch-over-tokenIds exists. Model S per-position overhead stands as assumed. |

### New load-bearing facts this batch introduces (not in the original table)

| # | Fact | Impact |
|---|---|---|
| N1 | **Root/leaf cross-chain architecture.** A root `Voter` (with the escrow) dispatches allocations through a message orchestrator to per-chain `LeafVoter`s; the root chain's own gauges are served by a `RootLocalAdapter` that is **in-process and zero-fee** (`RootLocalAdapter.sol:40` rejects value; `quoteMessage = 0`, `:54-56`) — delivery to the local leaf is synchronous within the same transaction. | For a Base-gauges-only series 1, the vault calls the payable entrypoints **with zero value** and never holds ETH — the §5.1 no-ETH rule survives. Cross-chain allocation stays out of scope (needs fee ETH + async delivery). |
| N2 | **Leaf-side synchronous cooldown revert.** The bridged apply path reverts `CooldownActive` (`LeafVoter.sol:392-398`) — with the local adapter this surfaces synchronously in the root call. Allocations also carry a root-stamped **expiry** (`AllocationExpired`). | The revert-free rebalance hook must pre-check the Base leaf's `tokenStates[id].lastAllocated + allocationCooldown <= now` (both public) before submitting — same pattern as today, new read target. |
| N3 | **Per-token leaf `operator`** may vote locally once governance enables `localVotingEnabled` (off by default; `LeafVoter.sol:469-476`). Set from root via `setOperator` (`Voter.sol:579`). | Not needed for the root-path vault; a later series could set itself operator for leaner local votes if governance ever enables it. |
| N4 | **VoterPaymentsModule (VPM)** is the stake-mobility layer: `depositIntoNFT`/`withdrawToNFT` move stake between sAEROs (including fractional carve-outs minting fresh positions) through escrow `rebalanceUnderlying`, without moving the cooldown anchor (`Voter.sol:1274`). Requires the VPM to be globally allowlisted **and** approved by the token's owner (`VotingEscrow.sol:339-348, 497-499`); per-operation fees 0–100% and a restricted flag are FEE_MANAGER-controlled. | **Load-bearing for Model P's `exitToNFT` and merge-joins (see corrected G11/G12).** For tokens whose owner approves no VPM, the module cannot touch them — the griefing surface stays closed; the vault would approve one deliberately and only for its own exit/join paths. Assert both directions in fork tests. |
| N5 | Allocation state is **absolute VP budgets** with stake-shape re-anchoring; token top-ups park on `CHAIN0` until spent (see G4). | Deposit flow: `increaseStakeAmount` → parked VP → moved into gauges at the tranche's next slot via `allocate`/`allocateChains`. The rebalance hook grows one step. |

### Consequences for the spec-freeze gate

G1 ✓, G3 ✓, G4 ✓(modified), G6 ✓(mechanism) — but **G7 is invalidated as assumed and G8 is
still unpublished**, and the whole batch is marked provisional with no deployments. The gate
therefore stays **closed**: interfaces may still move, and the reward layer TranchePilot's
distributor depends on is absent. The custody question is **live again** *(corrected
2026-08-15)*: `exitToNFT` is implementable against the published VPM — Model P can offer
pooled weight *and* a position-level exit (and even merge-joins), at the cost of a
governance-mediated VPM fee (0–100%, FEE_MANAGER-set) and pending the parked-weight
sequencing question. Model S remains the smaller-TCB fallback. Begin writing TranchePilot's
allocation layer against the exact-budget interface now, but freeze nothing until a
non-provisional tag with the rewards batch lands.


## Process

- From Aug 3: pull each published batch, fill the table with file+line citations,
  and commit the diff the same day ("keep a diff log from Aug 3").
- Monitor the Sherlock contest (Aug 24 – Sep 11); diff every public finding against
  this table — each one is a free re-check of our protocol-facing assumptions.
- `TranchePilot` implementation may start only when G1, G3, G4, G6, G7 read
  **verified-in-published-code** here.
