# Slither triage — EpochPilot (brief §7.6)

- Slither `0.11.5`, solc `0.8.36`, run: `slither . --filter-paths "test/|script/" --exclude-informational`
- Scope: `src/` only. Result: **39 findings, 0 accepted as bugs** — every one triaged below.
  Re-run on every source change; a new detector hit that is not in this table blocks merge.

| Detector | Hits | Verdict | Rationale |
|---|---|---|---|
| `reentrancy-no-eth` / `reentrancy-benign` | activate, claimRevenue, claimRebase, compound, deposit, revote, unwind | **False positive (mitigated by design)** | Every external entrypoint — including `transfer`/`transferFrom` — carries the transient-storage `nonReentrant` latch, which Slither does not model (hand-written, no OZ base it recognizes). Reentry from a malicious token's callback is exercised positively in unit tests: the latch's `Reentrancy()` selector is asserted from inside both a `claimUser` and a `transfer` reentry attempt. |
| `timestamp` | revote window, bounty ramp, lockEnd/expiry checks, unwind grace | **Accepted (inherent)** | Epoch voting *is* timestamp arithmetic; the protocol itself gates votes by `block.timestamp`. Validator skew (~seconds on Base's 2s blocks) is negligible against 1-hour window margins and a 1-week grace period. The bounty ramp moves 1 AERO per *week* of staleness — skew-scale manipulation is worthless. |
| `uninitialized-state` | `_balCps` | **False positive** | Mappings-to-dynamic-arrays have no initializer in Solidity; the empty array is the correct initial state (zero checkpoints ⇒ `_balanceAt` returns 0 by construction, asserted in fuzz suite). |
| `uninitialized-local` | `seen`, `u`, `covered` | **False positive** | Deliberate zero-defaults for accumulator locals; idiomatic and correct. |
| `incorrect-equality` | `delta == 0`, `bal == 0`, `minted == 0`, `m == 0` | **False positive** | These are zero-checks on unsigned quantities used to skip no-ops or reject dust — not equality-based state machines. `>` 0 vs `!=` 0 are equivalent for uint. |
| `write-after-write` | `_expectingMint` in `activate` | **False positive** | The two writes bracket the external `VE.createLock` call — the flag is read by `onERC721Received` *during* that call. Not a dead store. |
| `calls-loop` | Voter reads inside `revote`/`_deadWeight`/`claimRevenue` validation loops | **Accepted (bounded + trusted callee)** | Loops are bounded by live `maxVotingNum` / `MAX_CLAIM_TOKENS`; the callee is the protocol Voter (view functions). A reverting Voter halts the vault's strategy but can never touch principal (allocations persist). |

## Not yet run (tracked)

- **Echidna** second-corpus campaign (brief §7.3) — queued behind the Foundry invariant
  suite that already covers the same §5.4 properties.
- **halmos / SMTChecker** on the distributor arithmetic and share mint/burn paths (§7.4).
- **gambit** mutation testing, ≥95% kill target (§7.5).
- **External audit** (§7.7) — to be booked so the window overlaps Aero's Sherlock
  contest (Aug 24 – Sep 11, 2026).
