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
| Share inflation / first depositor | Seed phase is 1:1 with refunds (no ratio to manipulate); `SEED_BURN` dead shares at activation; `MIN_DEPOSIT`; post-activation mint ratio reads *live* net assets (locked principal + loose AERO), so donations only raise share value and a depositor sliding in between claim and compound pays full NAV. Activation gates on `totalShares`, so donations cannot conjure a near-zero-share activation. | `test_activate_locksSeed_mintsDeadShares`, `test_deposit_pricedAgainstLooseAeroToo`, `test_activate_donationsAloneCannotActivate`, `invariant_shareValueMonotone` |
| Donation manipulation of the accumulator | Credits come only from measured claim deltas net of bounty; raw-balance donations of reward tokens increase the balance side of invariant 3 only (gift). AERO donations are swept by `compound` into principal. | `invariant_pendingCoveredByBalance`, `test_compound_stakesEverything_paysBounty` |
| Reentrancy via token callbacks | Checks-effects-interactions plus one transient-storage `nonReentrant` latch on every external entrypoint. | reentrancy latch on all entrypoints; adversarial-token unit tests |
| Bounty draining (dust loops) | Claim/compound bounties are proportional (bps of moved value) — dust pays dust. The revote bounty ramps *from zero since the last vote* and the protocol enforces once-per-epoch voting, so rapid repeat calls revert and the ramp cannot be farmed. Paid only from `looseAero`, skipped when empty. | `test_revote_bountyRampsAndIsCappedByLooseAero`, `test_revote_onceLivePerEpoch_protocolEnforced` |
| Third-party `poke` / cooldown griefing (v2 analog) | `Voter.poke` re-casts our existing relative weights at current decayed balance; it does not change `lastVoted` and cannot redirect the vote. Mirror weights are re-derived fresh at each revote. Residual effect: cosmetic. | live-code reading; `lastVoted` semantics asserted in fork suite |
| Unwind-before-final-claim griefing (permissionless `unwind` burns the NFT, unclaimed revenue with it) | `UNWIND_GRACE` = 1 week after lock end: a full epoch to claim the final revenue and rebase (bounty-incentivized) before unwind is even callable. | `test_unwind_graceEnforced_thenRedeemProRata` |
| Principal recovery depending on protocol upkeep (a halted minter/distributor bricking `unwind`) | `unwind()` never touches the RewardsDistributor: principal recovery depends only on `Voter.reset` + escrow `withdraw`. An unclaimed final rebase is forfeited — bounded, disclosed, and claimable all grace week. | `test_unwind_succeedsEvenIfProtocolHalted` |
| Stray veNFT frozen by safe-transfer into the vault | `onERC721Received` accepts the escrow collection only while `activate()` is mid-`createLock` (transient flag); every other transfer reverts, so a user cannot freeze their own position in an ownerless contract. | `test_strayVeNFT_isRejected` |
| Coverage-denominator brick after a large gauge kill (killed pools keep their `totalWeight` share but may not be candidates) | `revote(pools, deadPools)`: callers may exclude pools *validated on-chain as dead* (registered gauge, not alive, no duplicates) from the denominator. Live pools and duplicates revert, so the relief cannot be abused to shrink coverage. | `test_revote_deadPoolExclusionRestoresLiveness`, `test_revote_deadPoolExclusion_rejectsAbuse` |
| Credit-history growth grief (claim-spam appending unbounded credit events to an immutable contract) | Credits between two share-balance changes coalesce into one entry (the sequence advances on balance changes, not claims), so history growth is bounded by transfer interleavings, not claim frequency. | `test_credits_coalesceBetweenBalanceChanges` |
| Protocol governance changes (`maxVotingNum`, whitelist windows) | Read live at every call; nothing protocol-side is cached or hardcoded (found live `maxVotingNum` = 60 vs documented 30 — see `docs/g-facts.md`). | `test_fork_G9_maxVotingNumLiveValue` |
| Protocol death mid-term | Votes and locks persist; worst case the vault waits out the term and `unwind` still returns principal (escrow withdrawal depends on no live emissions). | design (G5 analog); `test_fork_lifecycle` warp past term |
| Immutability itself (bug = forever) | 10,000 AERO hard cap; TCB = one file, zero dependencies; the assurance stack below; series pattern for successors. | this repo |

## Non-threats (accepted, disclosed)

- **Dividend-timing (JIT) deposits.** A depositor entering just before a `claimRevenue`
  call shares in that claim's credit despite not having held through the epoch that
  earned it — inherent to pooled vaults without accrual-period accounting. Bounded by
  one inter-claim interval of revenue (claims are bounty-incentivized to be frequent),
  and the deposit itself is locked for the remaining term. AERO-denominated revenue is
  priced into the mint ratio (`looseAero` in the denominator), so the exposure is
  non-AERO reward tokens only.
- **Activation front-running.** `activate()` is permissionless, so once the pool clears
  `ACTIVATION_MIN` a pending `withdrawSeed` can be front-run by activation and the
  refund window closed. Disclosed in the deposit/withdrawSeed NatSpec and README: only
  seed what you are prepared to have locked at any moment.
- **Sender-side-burn tokens.** Credits are re-measured after the bounty push so they are
  fully backed at credit time, but a token that torches extra from the sender on every
  transfer erodes backing with each payout — late claimants of such a token may be
  unable to claim. Isolated to that token alone; no honest token or AERO is affected.

- **Vote staleness** if no caller shows up: allocations persist; returns degrade toward
  the (mirrored) market average — which is the strategy's floor anyway. Never unsafe.
- **Weight decay** over the 26-week term (v2 locks decay): accepted for a demonstrator;
  refreshed at each weekly revote checkpoint.
- **Secondary-market illiquidity of shares** pre-term-end: disclosed above the fold.
- **MEV**: the vault never swaps; there is nothing to sandwich. Bounty races are
  first-come-first-served by design.
