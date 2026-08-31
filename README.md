# Tranche Pilot

**Immutable, fully on-chain allocation autopilots for the Aero economy on Base.**

> ## ⚠️ Read this before anything else
>
> - **`TranchePilot` (future, Aero v3): principal is permanently staked and can never be
>   withdrawn as liquid AERO.** Exit is selling your transferable shares.
> - **`EpochPilot` (live target, Aerodrome v2): deposits are locked for the full 26-week
>   term.** Exit before term end is selling shares; at term end, `redeem()` returns AERO.
> - **The code cannot be changed by anyone, ever.** No owner, no admin, no keeper, no
>   oracle, no pause, no upgrade path. The deployer's keys are worthless the moment the
>   constructor returns. Bugs are forever; that is why most of this repository is tests.

Two deliverables (build brief §0):

| Contract | Protocol | Status |
|---|---|---|
| `src/EpochPilot.sol` | Aerodrome v2 (live on Base) | implemented — proof-of-concept demonstrating the machinery: pooled custody, permissionless bountied operations, immutability, reproducible verification. Capped at 10,000 AERO. |
| `src/TranchePilot.sol` | Aero v3 | **not yet started; gate open.** The spec-freeze gate (brief §2) lifted 2026-08-31: G1/G3/G4/G6/G7 verified in the published v3 code ([dromos-labs/metadex-public](https://github.com/dromos-labs/metadex-public) @ `0d75da99`). The full diff — including the G7 shape divergence (absolute budgets, not relative weights) and the no-rebase finding — lives in `docs/g-facts.md`. Re-verification against deployed contracts still required before any deployment. |

## What EpochPilot does

Pools AERO into a single fixed-term veNFT and runs the honest strategy v2 permits —
**mirror-ex-self** (track every other participant's allocation). This earns the
weight-average return *against the settled vote distribution* — but v2 votes are cast
once per epoch, before the whitelist-only final hour when weights move most, so the
realized return is the weight-average with an end-of-epoch tracking error, not the
weight-average itself (see `docs/design-notes.md` #11; v3 removes this). v2's
synchronized weekly epochs offer no reactivity edge either, so the PoC demonstrates
*machinery*, not alpha:

- `deposit` — 1:1 refundable during seeding; pro-rata and irrevocable after `activate()`.
- `revote(pools, deadPools)` — anyone, weekly, from 6h before the flip until the Voter's
  live `epochVoteEnd`; candidate set must carry ≥ 80% of live vote weight (the on-chain
  check that defeats self-serving subsets; `deadPools` lets callers exclude
  validated-dead gauges from the denominator so a big gauge kill can't brick the
  strategy); caller earns an **escalating bounty** that ramps with staleness (brief
  §3.4) — the sole liveness mechanism, deliberately field-tested here before v3 relies
  on it.
- `claimRevenue(gauges, feeTokens, bribeTokens)` — anyone; targets validated against the
  Voter's own registry; balance-delta accounting (fee-on-transfer safe); caller earns 0.3%
  of each claimed token in kind. AERO revenue is never distributed — it is compounded.
- `claimRebase` / `compound` — anyone, bountied; both grow the locked principal.
- `unwind` → `redeem` — after term + 1-week grace, anyone burns the expired lock back to
  liquid AERO; shareholders redeem pro-rata. Non-AERO revenue stays claimable forever.
  Unwind touches nothing but the Voter and the escrow, so principal recovery works even
  if the rest of the protocol has halted (the final rebase is claimed separately during
  the grace week).

Revenue distribution is **event-sourced** (per-token credit events + per-user balance
checkpoints) rather than the classic per-token reward-debt pattern, which is unsound for
transferable shares with an unbounded token set — see `docs/design-notes.md` for the
finding, which feeds back into the v3 design.

## Trust model

Zero privileged parties. Every state-changing function is callable by anyone and gated
only by arithmetic (phase, epoch window, share ownership). Enforced three ways:
`scripts/banned-constructs.sh` in CI (no `delegatecall`, no assembly, no `payable`, no
`onlyX`, no imports outside `src/interfaces/`), the invariant suite, and the fork-test
probe of the deployed ABI.

## Verify it yourself

Everything needed to reproduce the exact deployed bytecode and derive the deployment
address from the code alone is in [`verification/`](verification/README.md). The
contract is not seeded until Sourcify exact-match and Basescan verification are both
live and the bytecode-diff CI is green against the deployed address.

## Repository map

```
src/EpochPilot.sol        the v2 vault (single file, zero dependencies)
src/interfaces/           hand-written minimal interfaces, asserted against live code
test/unit|fuzz|invariant  mock-based assurance suite
test/fork/                every load-bearing protocol fact asserted on a Base fork
script/                   CREATE2 deployment, zero post-deploy calls
verification/             salts, hashes, standard-JSON, reproduction commands
docs/                     threat model, G-facts diff log, design notes
audits/                   static-analysis triage; external audit reports land here
```

## Build & test

```
forge build                                   # pinned solc 0.8.30, no dependencies
forge test --no-match-path 'test/fork/*'      # unit + fuzz + invariants (no network)
BASE_RPC_URL=... forge test --match-path 'test/fork/*'   # live-protocol assertions
./scripts/banned-constructs.sh                # §5.1 gate
```
