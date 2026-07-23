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

## Finding 4 — unwind needs a grace period (v2-specific)

`unwind()` burns the veNFT; every claim path needs the NFT alive. A permissionless
unwind callable at expiry would let a griefer torch the final epoch's unclaimed
revenue. `UNWIND_GRACE = 1 week` gives bounty-hunters a full epoch to drain claims
first. TranchePilot has no unwind (permanent stakes), so this does not carry over —
recorded for completeness.

## Finding 5 — test-harness self-sufficiency

This environment could not fetch forge-std (network egress policy), so
`test/utils/TestBase.sol` hand-declares the cheatcode interface and assertions.
This is philosophically consistent with the project (zero dependencies) and keeps
the whole repo building from a clean clone with nothing but `forge`.
