# Coverage report & residual-gap triage (brief §7.1)

Command: `forge coverage --ir-minimum --no-match-path 'test/fork/*' --no-match-coverage '(test|script)'`
(`--ir-minimum` is required because coverage instrumentation disables the optimizer and
the plain pipeline runs out of stack; Foundry warns its source mappings can be
slightly inaccurate in this mode.)

| Metric | Result |
|---|---|
| Lines | 98.85% (258/261) |
| Statements | 98.37% (362/368) |
| Branches | 92.19% (59/64) |
| Functions | 100.00% (32/32) |

The brief's target is 100% branches. Every residual gap is enumerated and justified
below; none is an untested behavior — each is either **provably unreachable** (with the
proof in the source NatSpec) or an artifact of reverted-subframe hit accounting. A gap
appearing here without a justification blocks release.

## Residual items

1. **`deposit`: `if (minted == 0) revert BelowMinimum()`** — defensive; provably
   unreachable under the shipped constants. `minted = amount × totalShares / principal`
   with `amount ≥ MIN_DEPOSIT = 1e18` and `totalShares ≥ ACTIVATION_MIN = 1e20` gives a
   numerator ≥ 1e38, so `minted == 0` would require locked principal > 1e38 AERO —
   twenty orders of magnitude above total supply. Kept as an invariant tripwire: if the
   mint math is ever edited badly, dust deposits fail loudly instead of minting zero.

2. **`nonReentrant`: `revert Reentrancy()`** — executed only inside frames that revert
   by definition, which the coverage collector does not accumulate. The behavior itself
   is asserted positively: `test_reentrancy_latchBlocksTokenCallback` reenters from a
   malicious token's `transfer`, records the inner failure, and asserts the revert
   selector is exactly `Reentrancy()`.

3. **`_push`: `if (token.code.length == 0) revert TransferFailed()`** — defense in
   depth; unreachable through public paths today because every credited token has had
   `balanceOf` decoded successfully first (impossible for a codeless address), and
   post-Cancun contracts cannot lose code. Kept because an immutable contract should
   not silently "succeed" transfers to codeless addresses if a future reasoning error
   ever creates such a path.

4. **`_pull` / `_approveAero` failure arms** — the `!ok` arm of `_pull` is exercised by
   `test_deposit_withoutApprovalFailsLoudly`; the residual uncovered arm is the
   `ret.length != 0 && !abi.decode(...)` false-return decode against AERO, which the
   real AERO (asserted well-behaved in the fork suite) cannot produce. The identical
   decode logic in `_push` *is* fully exercised by the weird-token unit tests.

5. **`_collect` inner `break`** — flagged at zero hits despite
   `test_claimRevenue_duplicateTokensCountedOnce` demonstrably deduplicating through
   exactly this path (one credit event from four duplicate mentions); attributed to
   `--ir-minimum` source-mapping inaccuracy.

## Higher-intensity runs

CI uses the `ci` profile: 4096 fuzz runs, 256 invariant runs × depth 128.
