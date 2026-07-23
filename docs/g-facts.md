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
| G9g | Epoch windows: `epochVoteStart = start+1h`, `epochVoteEnd = flip−1h` | **verified-live** | `test_fork_G9_epochWindows` |
| G9h | `gaugeToFees` / `gaugeToBribe` registries validate claim targets | **verified-live** | `test_fork_G9_gaugeRewardRegistries` |
| G10 | Rebase claims permissionless per tokenId; auto-compound into unexpired locks via `depositFor` | **verified-live** — asserted on a real third-party mainnet veNFT: a stranger's `claim()` increased the lock's amount by exactly `claimable` | `test_fork_G10_rebasePermissionlessAutoCompounds` |
| — | AERO is a well-behaved ERC-20 (returns true, no fee) | **verified-live** | `test_fork_aeroIsWellBehavedERC20` |

## v3 facts (TranchePilot — spec-freeze gate; diff each Aero code batch from Aug 3, 2026)

| # | Fact | Status | Notes for the diff |
|---|---|---|---|
| G1 | Cooldown keyed per sAERO position (tokenId), **not** per owner | **pending-Aug-3** | **Kill criterion for the tranche edge.** Find the exact storage key in published LeafVoter; cite file+line here. |
| G2 | Positions cannot be split by holders | pending-Aug-3 | |
| G3 | Creation-time permanent-stake flag | pending-Aug-3 | Fallback: max-duration + lock-permanent in two calls (v2 pattern). |
| G4 | Top-ups don't reset allocations or cooldown | pending-Aug-3 | If wrong: deposits buffer and join at each tranche's slot. |
| G5 | Allocations persist until changed | pending-Aug-3 | |
| G6 | Per-gauge caps on the gauge factory, readable, ~48h recalibration | pending-Aug-3 | Strategy signal. If unreadable/uniform → mirror-mode series (§4.3). |
| G7 | Voter allocation entrypoints: pools + relative weights, min-weight anti-dust | pending-Aug-3 | Write interfaces only from published code. |
| G8 | Revenue accrues per position in heterogeneous tokens, pull-per-token | pending-Aug-3 | Distributor design input. **See docs/design-notes.md finding #1 before freezing §3.5.** |
| G11 | `withdraw-to-NFT` role-gated | pending-Aug-3 | **Decides Model P vs Model S** (brief §3.7). |
| G12 | `deposit-into-NFT` gated only by owner/approval of both | pending-Aug-3 | |
| G13 | One tokenId per vote call (no native batch) | pending-Aug-3 | Efficiency-only for Model S. |

## Process

- From Aug 3: pull each published batch, fill the table with file+line citations,
  and commit the diff the same day ("keep a diff log from Aug 3").
- Monitor the Sherlock contest (Aug 24 – Sep 11); diff every public finding against
  this table — each one is a free re-check of our protocol-facing assumptions.
- `TranchePilot` implementation may start only when G1, G3, G4, G6, G7 read
  **verified-in-published-code** here.
