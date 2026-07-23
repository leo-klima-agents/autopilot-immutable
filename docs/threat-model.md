# EpochPilot threat model (brief §6, instantiated for the v2 PoC)

Written before implementation, updated during. Every row names the concrete
mitigation *in this codebase* and the test that exercises it.

## Assets

1. Locked principal (the veNFT's AERO) — must return to shareholders at term end.
2. Undistributed revenue (reward-token balances backing the accumulator).
3. Loose AERO awaiting compound (also the bounty budget).
4. The vote itself (misdirected weight = lost revenue, never lost principal).

## Adversaries

Anyone: every mutating function is public by design. The interesting adversary is a
*caller* crafting inputs (candidate sets, gauge lists, token lists) or a *token* with
adversarial code, since no privileged role exists to attack.

| Threat | Mitigation | Evidence |
|---|---|---|
| Self-serving candidate subset at `revote` (steer weight to attacker's pool) | Coverage check: `Σ weights(pool) ≥ 80% × totalWeight` on-chain, plus per-pool validation (registered gauge, alive, no duplicates, ≤ live `maxVotingNum`). Worst case inside the check ≈ the market portfolio ± 20% tail — never principal risk. | `test_revote_coverageCheckDefeatsSubsets`, `test_fork_revote_rejectsLowCoverageSubset` |
| Malicious/weird reward token (fee-on-transfer, reverting, blocklisting, no-return, phantom balances) | Balance-delta accounting; one-token-per-call `claimUser`; no token loops in any state-changing path (event-sourced distributor); `_push` tolerates missing return data and rejects codeless addresses; a fake token in a caller's own list can only poison *its own* accumulator entry. | `test_claimRevenue_feeOnTransferToken_balanceDeltaSafe`, `test_claimUser_tokenIsolation_brickedTokenOnlyBlocksItself`, `test_claimUser_noReturnToken_paysOut` |
| Free-form claim-target injection | `claimRevenue` takes *gauges*, not reward addresses; fee/bribe contracts are derived from `Voter.gaugeToFees/gaugeToBribe`; `isGauge` asserted. | `test_claimRevenue_rejectsUnregisteredGauge` |
| Share inflation / first depositor | Seed phase is 1:1 with refunds (no ratio to manipulate); `SEED_BURN` dead shares at activation; `MIN_DEPOSIT`; post-activation mint ratio reads *live* locked principal, so donations to the lock only raise share value. | `test_activate_locksSeed_mintsDeadShares`, `invariant_shareValueMonotone` |
| Donation manipulation of the accumulator | Credits come only from measured claim deltas net of bounty; raw-balance donations of reward tokens increase the balance side of invariant 3 only (gift). AERO donations are swept by `compound` into principal. | `invariant_pendingCoveredByBalance`, `test_compound_stakesEverything_paysBounty` |
| Reentrancy via token callbacks | Checks-effects-interactions plus one transient-storage `nonReentrant` latch on every external entrypoint. | reentrancy latch on all entrypoints; adversarial-token unit tests |
| Bounty draining (dust loops) | Claim/compound bounties are proportional (bps of moved value) — dust pays dust. The revote bounty ramps *from zero since the last vote* and the protocol enforces once-per-epoch voting, so rapid repeat calls revert and the ramp cannot be farmed. Paid only from `looseAero`, skipped when empty. | `test_revote_bountyRampsAndIsCappedByLooseAero`, `test_revote_onceLivePerEpoch_protocolEnforced` |
| Third-party `poke` / cooldown griefing (v2 analog) | `Voter.poke` re-casts our existing relative weights at current decayed balance; it does not change `lastVoted` and cannot redirect the vote. Mirror weights are re-derived fresh at each revote. Residual effect: cosmetic. | live-code reading; `lastVoted` semantics asserted in fork suite |
| Unwind-before-final-claim griefing (permissionless `unwind` burns the NFT, unclaimed revenue with it) | `UNWIND_GRACE` = 1 week after lock end: a full epoch to claim the final revenue (bounty-incentivized) before unwind is even callable. | `test_unwind_graceEnforced_thenRedeemProRata` |
| Protocol governance changes (`maxVotingNum`, whitelist windows) | Read live at every call; nothing protocol-side is cached or hardcoded (found live `maxVotingNum` = 60 vs documented 30 — see `docs/g-facts.md`). | `test_fork_G9_maxVotingNumLiveValue` |
| Protocol death mid-term | Votes and locks persist; worst case the vault waits out the term and `unwind` still returns principal (escrow withdrawal depends on no live emissions). | design (G5 analog); `test_fork_lifecycle` warp past term |
| Immutability itself (bug = forever) | 10,000 AERO hard cap; TCB = one file, zero dependencies; the assurance stack below; series pattern for successors. | this repo |

## Non-threats (accepted, disclosed)

- **Vote staleness** if no caller shows up: allocations persist; returns degrade toward
  the (mirrored) market average — which is the strategy's floor anyway. Never unsafe.
- **Weight decay** over the 26-week term (v2 locks decay): accepted for a demonstrator;
  refreshed at each weekly revote checkpoint.
- **Secondary-market illiquidity of shares** pre-term-end: disclosed above the fold.
- **MEV**: the vault never swaps; there is nothing to sandwich. Bounty races are
  first-come-first-served by design.
