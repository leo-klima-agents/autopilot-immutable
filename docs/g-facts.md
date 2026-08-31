# G-facts tracking table (brief §2) — the spec-freeze diff log

Status legend: **verified-live** = asserted by a green fork test against Base mainnet;
**pending-Aug-3** = cannot be checked until Aero publishes v3 code; **DIVERGED** =
live protocol contradicts the brief (documented, code adjusted).

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

## v3 facts (TranchePilot — spec-freeze gate; diff each Aero code batch from Aug 3, 2026)

**Diff basis:** the full v3 codebase published at
[dromos-labs/metadex-public](https://github.com/dromos-labs/metadex-public), read at commit
`0d75da99a68ee862c60cd9ab1e8271aea04da2fe` (2026-08-30, `VERSIONS` = `1.0.0-provisional.3`).
All file+line citations below are into `V3/src/` of that commit. Concentrated-liquidity
contracts live in a separate repo (`metadex-slipstream-public`) and are not vault-facing.
`deployment-addresses/` is empty — **nothing is deployed yet**; every fact below must be
re-verified against the deployed contracts before deployment (brief §2), and the code is
still provisional while the Sherlock contest (Aug 24 – Sep 11) runs.

Status legend addition: **verified-in-published-code** = confirmed by reading the published
v3 source at the commit above (not yet a fork test — none can exist until deployment).

| # | Fact | Status | Evidence (metadex-public @ `0d75da99`, paths under `V3/src/`) |
|---|---|---|---|
| G1 | Cooldown keyed per sAERO position (tokenId), **not** per owner | **verified-in-published-code** — **kill criterion passes; the tranche edge stands.** | Anchor lives in per-tokenId state: `interfaces/voter/ILeafVoter.sol:56-61` (`struct TokenState { …; uint48 lastAllocated; … }`), stored as `mapping(uint256 _tokenId => TokenState)` at `voter/LeafVoterStorageLayout.sol:45`. Enforcement: `libraries/LeafAllocationLibrary.sol:762-779` (`_consumeCooldownReduction` reverts `CooldownActive` from `lastAllocated + allocationCooldown`); anchor set per token at `LeafAllocationLibrary.sol:184`. `allocationCooldown` is a global config value (`LeafVoterStorageLayout.sol:53`), read live. No owner-keyed cooldown state exists anywhere in the voter path. Bonus: per-tokenId one-shot cooldown reductions exist (`reduceCooldown`, `voter/Voter.sol:280`; accrual clamped by `maxAccumulatedCooldownReduction`, **zero by default** — governance opt-in, `voter/LeafVoter.sol:300-309`). |
| G2 | Positions cannot be split by holders | **verified-in-published-code** | `core/VotingEscrow.sol` exposes no split: full mutating surface is `createStake`/`reviveStake`/`increaseStakeAmount`/`increaseStakingPeriod`/`withdraw`/`upgradeToPermanentStake`/`downgradeFromPermanentStake`/`rebalanceUnderlying`/`delegate` (lines 181–463). The only fractional carve-out is `rebalanceUnderlying`, which is role-gated (see G11). `splitter/Splitter.sol` is a Minter team-fee splitter, unrelated to positions. |
| G3 | Creation-time permanent-stake flag | **verified-in-published-code** | `core/VotingEscrow.sol:181-201` — `createStake(uint128 _value, uint48 _stakingWeeks, bool _isPermanent)`; shape rules in `_resolveNewStakeEnd` (`VotingEscrow.sol:898-906`: permanent ⇒ `stakeEnd = 0`, no weeks). The two-call fallback also exists (`upgradeToPermanentStake`, `VotingEscrow.sol:308`). Note: `downgradeFromPermanentStake` (`VotingEscrow.sol:326`) lets the **owner** reverse permanence after fully deallocating to chain0 — fine for the vault (it is the owner and simply never calls it; enforce via banned-selector probe). |
| G4 | Top-ups don't reset allocations or cooldown | **verified-in-published-code** (with a nuance the brief pre-approved) | `core/VotingEscrow.sol:231-252` — `increaseStakeAmount` keeps end/mode and routes through `_depositFor` → `VOTER.parkOnChain0` (`VotingEscrow.sol:682-686`). `libraries/AllocationLogicLibrary.sol:348`: "`lastAllocated` stays untouched: parking must not move the cooldown anchor"; booked gauge allocations are untouched. **Nuance:** new weight parks on the `CHAIN0` idle sink (earns nothing, `interfaces/voter/IVoter.sol:16`) and joins gauges only at the next allocation — the protocol itself implements the brief's fallback ("deposits buffer and join at each tranche's rebalance slot"). Accounting change only, as §2 anticipated. |
| G5 | Allocations persist until changed | **verified-in-published-code** | Continuous model, no epoch reset: `allocations[tokenId][gauge]` persists (`voter/LeafVoterStorageLayout.sol:48`); contributions are bias/slope points — non-permanent stakes decay on schedule, permanent stakes contribute constant `permanentStakeBalance` (`libraries/LeafAllocationLibrary.sol:548-564`). A stopped vault keeps earning (capped, see G6). `allocationLifetime`/`AllocationExpired` (`LeafAllocationLibrary.sol:91`) applies to **in-flight bridged messages**, not booked allocations. |
| G6 | Per-gauge caps on the gauge factory, readable, ~48h recalibration | **verified-in-published-code** (cadence is off-chain policy) | `factories/GaugeFactory.sol:63` — `mapping(address _gauge => uint128 _cap) public emissionCap` (readable); default stamped at gauge creation (`:137`); set by `CAP_OPERATOR_ROLE` within `[operatorMinCap, operatorMaxCap]`, `CAP_ADMIN_ROLE` beyond, emergency-council zeroing (`:154-201`). Semantics: **per-second emission-rate cap applied per weekly segment**; effective share = min(allocated share, cap), excess flows to `surplusAccrued` (`libraries/LeafAllocationLibrary.sol:1177-1196`, walk spec `:1280-1300`). **No on-chain recalibration cadence** — the ~48h cycle is ops policy, so the strategy must read `emissionCap` live and assume no cadence. Signal readable → §4 cap-tracking strategy viable. |
| G7 | Voter allocation entrypoints: pools + relative weights, min-weight anti-dust | **DIVERGED (shape)** — entrypoints verified, but allocation is **absolute-amount, two-level, cross-chain**, not relative weights | Root entrypoints (`voter/Voter.sol:162-255`, all single-tokenId, `onlyAuthorizedForToken`): `allocateChains` moves absolute AERO deltas from `CHAIN0`-parked power onto chains; `allocateGauges(tokenId, chainId, GaugeAllocation[])` distributes a chain budget; composed `allocate` does both. `GaugeAllocation = {gauge, allocated (uint128 absolute), data}` (`interfaces/voter/IVoterCommon.sol:66-70`). Anti-dust: zero-amount entries revert `ZeroAllocation`; gauge lists strictly ascending; `DEALLOC_GAUGE` sentinel returns budget (`libraries/AllocationLogicLibrary.sol:1348-1375`). Root-chain gauges are served **in-process with zero native fee** (`interfaces/voter/IVoter.sol:44,58-59`; `bridge/RootLocalAdapter.sol:18`, `bridge/RootMessageOrchestrator.sol:135`) — a Base-side vault needs no bridge fees and no `payable` surface beyond calling the payable entrypoints with zero value. Leaf-local `allocateGauges` is **off by default** (`localVotingEnabled`) and operator-gated (`voter/LeafVoter.sol:318-340`) — not our path. Per-chain `maxGauges` read live (`LeafVoterStorageLayout.sol:55`). Interfaces must be hand-written from these signatures (license also demands it — see Process). |
| G8 | Revenue accrues per position in heterogeneous tokens, pull-per-token | **verified-in-published-code** | Per-gauge `rewards/VotingRewardsManager.sol`: `claimFees(tokenId, recipient, maxCheckpoints)` pays the pool's two fee tokens; `claimIncentives(tokenId, recipient, programId, maxCheckpoints)` pays per incentive program (`:92-110`) — per-position, pull, caller-chosen recipient, checkpoint-bounded. **Both are `_checkAuthorized(tokenId)`-gated (owner/approved only)** — no v2-style open claim-for; the vault claims as owner and wraps it in its own bountied permissionless function. **v3 has no staker rebase**: no `RewardsDistributor`, no rebase in `minter/Minter.sol` — the EpochPilot `claimRebase` leg has **no v3 analog**; AERO-denominated principal growth comes only from compounding claimed fees/incentives. Feed into §3.5 with design-notes #1. |
| G11 | `withdraw-to-NFT` role-gated | **verified-in-published-code — as spec'd; Model P's `exitToNFT` needs a governance grant** | The carve-out primitive is `core/VotingEscrow.sol:349-430` `rebalanceUnderlying(SourceDelta[], DestinationDelta[])`: fractional drains from source positions, destinations may **mint new sTokens** (sentinel `tokenId = type(uint256).max`), balance-conserving, monotonic-unlock rule. Double-gated: caller must hold `VPM_ROLE` (`:354`, granted only by `VPM_ADMIN_ROLE`, `:52,149`) **and** be ERC-721-authorized for every source (`:358-364`) — exactly the spec draft. Per §3.7's decision rule: **ship Model P with shares-only exit (exitToNFT inert unless the VPM grant lands), keep Model S as the role-free fallback / whale product.** Context: the protocol ships its own pooled product — `relay/MaxiRelay.sol` (permissionless-deposit relay with PT/YT clone share tokens) — which is what Model P competes with; our differentiators remain zero-admin immutability and the K-tranche staggered cooldown. |
| G12 | `deposit-into-NFT` gated only by owner/approval of both | **verified-in-published-code** (stricter than v2) | No open `depositFor` exists. `increaseStakeAmount` requires owner/operator/approval via `_authorizedStake` → `_checkAuthorized` (`core/VotingEscrow.sol:231-233,848-852`). Third parties cannot push stake into our NFT (no grief-deposit surface); all compounding is executed by the vault as owner. |
| G13 | One tokenId per vote call (no native batch) | **verified-in-published-code** | All root allocation entrypoints take a single `_tokenId` (`voter/Voter.sol:162,184,207`); no multi-position batch exists. Model S keeps its O(N) aggregate cost as assumed. |

### Gate verdict (2026-08-31)

G1 ✓, G3 ✓, G4 ✓, G6 ✓, G7 entrypoints known (shape **diverged** — absolute amounts +
chain budgets, not relative weights). Per the rule below, **the spec-freeze gate lifts:
`TranchePilot` design/implementation may start**, with these design inputs from the diff:

1. **The tranche edge is real in code** (G1): cooldown is per tokenId, so K staggered
   permanent positions deliver K-fold reallocation freshness. Cooldown reductions
   (G1 bonus) are per-token and governance-gated — treat as zero.
2. **§3 accounting must move from relative weights to absolute budgets** (G7):
   allocate = park→chain→gauges; deposits auto-buffer on `CHAIN0` (G4) until each
   tranche's slot — the brief's fallback is the protocol's native behavior.
3. **No rebase leg** (G8): drop the `claimRebase` analog from the v3 design; compound =
   claim AERO-denominated revenue → `increaseStakeAmount`.
4. **Model P ships shares-only exit; Model S stays the fallback** (G11): `exitToNFT`
   only if a `VPM_ROLE` grant is ever obtained; do not architect around it.
5. **Strategy reads `emissionCap` live with no cadence assumption** (G6); caps are
   per-second rates applied per segment, excess → surplus.

## Process

- ~~From Aug 3: pull each published batch, fill the table with file+line citations,
  and commit the diff the same day ("keep a diff log from Aug 3").~~ **Done 2026-08-31**
  against the full release (`metadex-public` @ `0d75da99`, `1.0.0-provisional.3`).
  Re-diff on every new `VERSIONS` entry until launch.
- Monitor the Sherlock contest (**live now**, Aug 24 – Sep 11; the repo ships
  `audits/sherlock-contest-auditor-guide.md`); diff every public finding against
  this table — each one is a free re-check of our protocol-facing assumptions.
- `TranchePilot` implementation may start only when G1, G3, G4, G6, G7 read
  **verified-in-published-code** here. **They do, as of 2026-08-31 — the gate is open**;
  G7's shape divergence is a design input (absolute budgets), not a blocker.
- Before deployment: re-verify every row against the **deployed** contracts with fork
  tests (statuses graduate to **verified-live**), exactly as the v2 table did.
- License note: metadex-public is under the **Dromos Restricted Use License 1.0**
  (converts to GPL-2.0-or-later five years after first distribution). Do **not** copy
  its source into this repo — hand-write minimal interfaces from observed signatures,
  which `scripts/banned-constructs.sh` (no imports outside `src/interfaces/`) already
  enforces.
