# Slither triage — EpochPilot (brief §7.6)

- Slither `0.11.5`, solc `0.8.30`, run: `slither . --filter-paths "test/|script/" --exclude-informational`
- Scope: `src/` only. Result: **33 findings, 0 accepted as bugs** — every one triaged below.
  Re-run on every source change; a new detector hit that is not in this table blocks merge.

| Detector | Hits | Verdict | Rationale |
|---|---|---|---|
| `reentrancy-no-eth` / `reentrancy-benign` | activate, claimRevenue, claimRebase, compound, deposit, revote, unwind | **False positive (mitigated by design)** | Every external entrypoint carries the transient-storage `nonReentrant` latch, which Slither does not model (hand-written, no OZ base it recognizes). Within each function the only post-call writes are to vault-internal accounting that a reentrant call could not observe inconsistently *because reentry is impossible*. Adversarial-token reentry is additionally exercised in unit tests (bricked/fee-on-transfer/no-return tokens). |
| `timestamp` | revote window, bounty ramp, lockEnd/expiry checks, unwind grace | **Accepted (inherent)** | Epoch voting *is* timestamp arithmetic; the protocol itself gates votes by `block.timestamp`. Validator skew (~seconds on Base's 2s blocks) is negligible against 1-hour window margins and a 1-week grace period. The bounty ramp moves 1 AERO per *week* of staleness — skew-scale manipulation is worthless. |
| `uninitialized-state` | `_balCps` | **False positive** | Mappings-to-dynamic-arrays have no initializer in Solidity; the empty array is the correct initial state (zero checkpoints ⇒ `_balanceAt` returns 0 by construction, asserted in fuzz suite). |
| `uninitialized-local` | `seen`, `u`, `covered` | **False positive** | Deliberate zero-defaults for accumulator locals; idiomatic and correct. |
| `incorrect-equality` | `delta == 0`, `bal == 0`, `minted == 0`, `m == 0` | **False positive** | These are zero-checks on unsigned quantities used to skip no-ops or reject dust — not equality-based state machines. `>` 0 vs `!=` 0 are equivalent for uint. |
| `divide-before-multiply` | `(block.timestamp / WEEK) * WEEK` in `unwind` | **Accepted (intentional)** | Week-flooring — the truncation *is* the computation, mirroring the RewardsDistributor's own staleness check bit-for-bit. |
| `unused-return` | `DIST.claim(tokenId)` in `unwind` | **Accepted (intentional)** | The final-rebase amount is not needed: whatever arrived is captured by the balance-based redemption pool. Return value is used where it matters (`claimRebase`). |
| `calls-loop` | Voter reads inside `revote`/`claimRevenue` validation loops | **Accepted (bounded + trusted callee)** | Loops are bounded by live `maxVotingNum` / `MAX_CLAIM_TOKENS`; the callee is the protocol Voter (view functions). A reverting Voter halts the vault's strategy but can never touch principal (allocations persist). |
| `shadowing-local` | `IVoter.vote` param named `weights` | **Fixed** | Renamed to `poolWeights` in the hand-written interface. |

## Not yet run (tracked)

- **Echidna** second-corpus campaign (brief §7.3) — queued behind the Foundry invariant
  suite that already covers the same §5.4 properties.
- **halmos / SMTChecker** on the distributor arithmetic and share mint/burn paths (§7.4).
- **gambit** mutation testing, ≥95% kill target (§7.5).
- **External audit** (§7.7) — to be booked so the window overlaps Aero's Sherlock
  contest (Aug 24 – Sep 11, 2026).
