# Design notes & spec findings

Findings made during EpochPilot implementation that feed back into the
TranchePilot (v3) spec freeze. Numbered so `docs/g-facts.md` can reference them.

## Finding 1 — brief §3.5's reward-debt accounting is unsound as written

The brief specifies: *"Per-token Synthetix-style accumulator … users pull with standard
reward-debt accounting, updated on every share mint/transfer/burn"* while also (correctly)
banning *"loops over token lists in any state-changing path."*

These two requirements are mutually exclusive. With the MasterChef/Synthetix debt pattern,
`pending(u,t) = balance(u) × accPerShare(t) − debt(u,t)` is only correct if `debt(u,t)` is
re-based **for every token t** whenever `balance(u)` changes. With one reward token that is
an O(1) update; with an unbounded heterogeneous token set (G8) it requires iterating a
token registry on every mint/transfer/burn — exactly the banned loop, and a poisonable
global registry besides. Skipping the settlement is not a rounding issue: a transfer
after a credit event either lets the recipient claim revenue accrued before they held
shares (theft) or strands the sender's accrued revenue (loss), depending on direction.

**Resolution implemented in EpochPilot (and proposed for TranchePilot §3.5):**
event-sourced distribution.

- Each credited claim appends one `(seq, perShare)` event to that token's history.
- Each share-balance change appends/overwrites one `(seq, balance)` checkpoint for the
  affected users — O(1), token-independent.
- `claimUser(token, maxEvents)` integrates the caller's checkpointed balance over that
  token's events (binary search per event), advancing a per-(user, token) cursor.
  Batched, resumable, one token per call.

Properties: exact (`testFuzz_distributorExactUnderTransfers` proves bit-equality with a
reference model under random interleavings), O(1) transfers, no token registry, perfect
token isolation, and — a bonus the naive pattern lacks — **redeeming/burning shares does
not forfeit accrued-but-unclaimed revenue**, because history is preserved.

Cost: ~120 lines instead of ~40, and claim gas grows with event count since last claim
(bounded by `maxEvents` batching). For v3 with K tranches and many claim calls, event
counts per token stay modest (one event per token per `claimRevenue` call).

**Action for spec freeze:** rewrite §3.5 and the §5.3 state list (`accPerShare[token]`,
`rewardDebt[user][token]`) in these terms, and re-derive invariant 3.

## Finding 2 — the live protocol drifts from its own docs; read everything live

`maxVotingNum` on the live Base Voter is 60, not the 30 in the launch-era documentation
(see `docs/g-facts.md` G9f). Confirms the brief's own rule: every protocol-side value
(`maxVotingNum`, epoch boundaries, cooldown lengths in v3) is read at call time and
never compiled in.

## Finding 3 — principal must be derived, not tracked

An early draft tracked `totalPrincipal` in storage, incremented by our own
deposit/compound/rebase wrappers. But v2's `RewardsDistributor.claim` and the escrow's
`depositFor` are callable by **anyone** directly on our tokenId, growing the lock outside
our wrappers and silently staling the mint ratio (new depositors would be over-minted at
existing holders' expense). EpochPilot therefore derives principal from
`VE.locked(tokenId).amount` at every mint. TranchePilot should do the same
(`§5.4` invariant 2 already hints at this by defining principal via escrow-reported
amounts): **any state that can be moved by a third-party call must be read from the
protocol, never shadowed.**

## Finding 4 — unwind needs a grace period, and must not depend on protocol upkeep

`unwind()` burns the veNFT; every claim path needs the NFT alive. A permissionless
unwind callable at expiry would let a griefer torch the final epoch's unclaimed
revenue. `UNWIND_GRACE = 1 week` gives bounty-hunters a full epoch to drain claims
first.

The second half was found in review: an early version claimed the final rebase inside
`unwind()`, first unconditionally (bricked on a fork reproducing a halted protocol —
the distributor refuses claims while the minter's period is stale), then behind a
hand-copied mirror of the distributor's staleness precondition. The mirror was still
wrong in kind: it replicated *one* observed guard (`activePeriod`) of a foreign
contract whose real gate is time-cursor-based, and the only thing validating the copy
was a mock written to match it. The fix is architectural, not a better mirror:
**principal recovery must depend on nothing but `Voter.reset` + escrow `withdraw`**.
The final rebase is claimable via `claimRebase` all grace week; unclaimed remainder is
forfeited — bounded and disclosed. TranchePilot has no unwind (permanent stakes), but
the principle — never let a recoverable-value call sit on the principal-recovery path —
carries over directly.

## Finding 5 — test-harness self-sufficiency

This environment could not fetch forge-std (network egress policy), so
`test/utils/TestBase.sol` hand-declares the cheatcode interface and assertions.
This is philosophically consistent with the project (zero dependencies) and keeps
the whole repo building from a clean clone with nothing but `forge`.

## Finding 6 — share pricing must use net assets, not just principal

Found in review: post-activation deposits were priced against locked principal only.
Claimed-but-uncompounded AERO (`looseAero`) is part of net asset value, so a depositor
sliding in between `claimRevenue` and `compound` bought shares below NAV and captured
revenue earned before them (three independent review angles converged on this). The
mint denominator is now `locked + looseAero`. For TranchePilot: the §3.2 mint formula
must be stated in terms of **net assets**, not "principal".

## Finding 7 — a deposit cap is not a TVL cap

`DEPOSIT_CAP` enforced against live locked principal meant vault growth (rebases,
compounding, third-party `depositFor`) consumed cap room and could permanently close
the vault to depositors; conversely the "blast-radius" reading was never enforceable
anyway because third parties can grow the position directly. The cap now bounds
cumulative `deposit()` inflow (`totalDeposited`, monotone up, refunds excluded), and
the docs say exactly that. The derive-don't-track rule (Finding 3) applies to values
third parties can move — a deposits-only counter is not one of them.

## Finding 8 — the activation gate must bind the share supply, not the balance

`activate()` gating on `AERO.balanceOf` let donations satisfy the threshold with a
near-zero share supply, silently voiding the `totalShares ≥ ACTIVATION_MIN` premise
that proves the distributor's uint192 narrowing safe. The gate now reads `totalShares`
(1:1 with net deposits during seeding). Donations still get locked — they just cannot
substitute for committed depositors. Rule for TranchePilot: **every arithmetic-safety
proof premise must be enforced by the exact variable the proof quantifies over.**

## Finding 9 — credit coalescing bounds an immutable contract's history growth

`claimRevenue` is permissionless and bounty-incentivized, so credit-event history
growth was attacker/caller-paced — an unbounded append-only array in a contract with
no compaction path. The sequence counter now advances on share-balance changes rather
than credits; credits between two balance changes share a seq and coalesce into one
entry (identical applicable balances make the merge exact). History growth is bounded
by transfer interleavings. Claims walk credits and checkpoints with a two-pointer
merge, O(events + checkpoints), shared by `claimUser` and `pendingUser` so the view
can never diverge from the payout.

## Finding 10 — enforce properties on artifacts, not vocabulary

The banned-constructs gate greps source identifiers, which filters an honest author's
vocabulary, not the property (`only[A-Z]` bans a naming convention; a differently-named
privileged check would pass). The gate now also disassembles the compiled runtime
(metadata-stripped) and fails on any DELEGATECALL / SELFDESTRUCT / CALLCODE opcode,
and the no-privilege property is exercised behaviorally by the fork suite's
fresh-EOA probe. Greps remain as a lint layer only.

## Finding 11 — mirror-ex-self earns the weight-average only against *settled* votes

The brief (§4.3) and an earlier draft of this repo claimed mirror-ex-self "earns the
weight-average return by construction." That is only true if the vault mirrors the
**settlement** vote distribution. The identity: if the vault sets `vₚ ∝ Tₚ` (final
total votes on pool p), its revenue is `Σ (vₚ/Tₚ)·Rₚ = (V/ΣT)·ΣRₚ` = exactly the
weight-average per unit weight. Mirror any *earlier* snapshot `Tₚᵗ` and the realized
share is `vₚ/Tₚ^final`, giving `(V/ΣTᵗ)·Σ(Tₚᵗ/Tₚ^final)·Rₚ` — a tracking error whose
factor `Tₚᵗ/Tₚ^final < 1` precisely for the pools that gain votes after time *t*.

In v2 this bias is not hypothetical and it is not small. Voting is a claim on fixed
per-epoch bribes, so voters (and off-chain vote markets) rush the highest
reward-per-vote pools in the **final hour** to equalise `Rₚ/Tₚ`. The vault votes
**once** per epoch (`onlyNewEpoch`, G9a) and cannot vote in the whitelist-only final
hour (G9c), so it is structurally forced to mirror a pre-final-hour snapshot that the
final hour then reshapes — away from exactly the pools the late money concentrates in.
Realized return is therefore the weight-average **with a negatively-biased tracking
error**, not the weight-average itself. No on-chain v2 strategy escapes this: the
decisive repricing happens in a window the vault cannot act in, and it gets one shot
before then.

Two consequences, both recorded rather than fixed (the PoC's job is to demonstrate
machinery honestly, §9, not to win v2's vote market):

- **Voting "by revenue" instead of by votes does not help in v2.** The
  return-maximising quantity is reward-per-vote `(feesₚ+bribesₚ)/votesₚ`, but the
  denominator *is* the volatile end-of-epoch vote count — optimising on it makes the
  vault more sensitive to the final-hour reshaping, not less, and a mechanical
  reward-per-vote rule is a bribe magnet that the coverage check does not defend. It is
  also §4.4's explicitly out-of-scope predictive alpha.
- **This is a v2-structural limitation that v3 removes.** v3 has no synchronised flip,
  so the final-hour snipe dynamic — an artifact of the shared settlement instant —
  largely disappears; and v3's *primary* signal is already revenue-based, but via the
  protocol's **gauge caps** (`capₚ ≈ κ × projected revenue`, §4.2), a maintained
  revenue projection read on-chain, not a live contested vote denominator. The v3 edge
  is tracking the fresh cap vector faster than the laggards (the staggered-tranche
  reactivity edge), which sidesteps both the crowding problem and the settlement-timing
  problem above.

**Action for spec freeze:** state mirror's guarantee in §4.3 as "weight-average
against settled weights" and note that on a synchronised-epoch protocol the fallback's
realized return carries this tracking error; confirm v3's continuous allocation makes
mirror's snapshot effectively the settlement snapshot (no shared flip to be stale
against).
