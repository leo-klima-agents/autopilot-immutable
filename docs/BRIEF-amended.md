<!--
  AMENDED BRIEF — the living specification.
  This is docs/BRIEF.md (the verbatim baseline) with inline amendment blocks
  wherever implementation has superseded or corrected it. Each amendment cites
  the design-notes finding that justifies it.

  Convention: an amendment appears as a blockquote immediately after the text
  it modifies:

  > **⟢ AMENDED — finding N.** <what changed and why>

  The baseline prose is left intact beneath/around the amendment so the
  original intent stays legible. When a claim is fully retracted the amendment
  says so explicitly. If this file and docs/BRIEF.md disagree, THIS file is
  current for the shipped `EpochPilot`; docs/BRIEF.md is the historical record.
-->

# Tranche Pilot: Build Brief — Amended

**Product:** an immutable, fully on-chain allocation autopilot for the Aero economy on Base.
**Baseline date:** 2026-07-23 · **Amendments:** through the P0 code review (see `docs/design-notes.md` findings 1–11).

## Amendment summary

| # | Section(s) touched | Change |
|---|---|---|
| 1 | §3.5, §5.3 | Reward-debt accumulator is unsound for transferable shares + unbounded tokens → **event-sourced distribution**. |
| 2 | §2 (G9), §3.3 | Read every protocol value live; live `maxVotingNum` is **60**, not 30. |
| 3 | §3.2, §5.3, §5.4-2 | Principal is **derived from the escrow every call**, never shadowed in storage. |
| 4 | §9 | `unwind()` must not depend on protocol upkeep; it touches only Voter + escrow. Grace week added. |
| 6 | §3.2 | Mint prices against **net assets** (locked + loose AERO), not principal alone. |
| 7 | §3.6, §9 | A deposit cap bounds **cumulative deposits**, not TVL. |
| 8 | §3.1, §9 | Activation gate binds the **share supply**, not the raw balance. |
| 9 | §3.5, §5.4-3 | Credits **coalesce between balance changes** to bound history growth. |
| 10 | §5.1 | Banned constructs enforced on **compiled opcodes**, not source vocabulary. |
| 11 | §4.3, §9 | Mirror earns the weight-average **only against settled votes**; v2 carries an end-of-epoch tracking error. |

(Finding 5 — test-harness self-sufficiency — is an implementation note, not a spec change.)

---

## 0. Mission and philosophy

Build a vault that pools users' AERO into staked (sAERO) positions and continuously re-allocates
them toward productive pools, with **no owner, no keeper, no oracle, no upgrade path, and no
off-chain computation**. Every state transition is either user-initiated (deposit) or
permissionless-with-bounty (claim, compound, propose, rebalance) — and because reallocation rides
as a side-effect hook on the self-funding claim/compound calls (§3.4), the strategy stays live
without anyone being *assigned* to run it. The deployer's keys are worthless the moment the
constructor returns.

The design discipline is borrowed from high-assurance systems (seL4, Qubes OS): make the trusted
computing base so small that it can be audited exhaustively, prove or fuzz every invariant, and
accept *less functionality* as the price of *verifiable correctness*. Concretely:

- **One contract per protocol generation**, target ≤ 700 lines including NatSpec. No proxy, no
  diamond, no library deployment, no inheritance tower.
- **Immutability is the security model, not a limitation.** Bugs are forever, so the assurance
  budget dominates the build budget. Improvements ship as *new deployments* ("release series");
  users migrate voluntarily. There is no in-place upgrade, ever.
- **Minimal strategy, honestly framed.** The vault attempts exactly one thing: beat the
  weight-average allocator return ("the market") by being *more reactive* than the crowd.
- **Zero fees, zero privileged parties.** Callers of permissionless functions earn small in-kind
  bounties; that is the entire incentive layer.

Two deliverables: **`TranchePilot`** (Aero v3, gated on the Aug 3 code drop) and **`EpochPilot`**
(the Aerodrome v2 PoC, shipped).

---

## 1. Required reading

Unchanged from the baseline (`docs/BRIEF.md §1`). **Never take a contract address from any
document — resolve on-chain at the moment of use** (this repo does: `verification/addresses.md`
walks the link graph from the AERO token).

---

## 2. Load-bearing protocol facts and kill criteria

The G-table is reproduced in `docs/BRIEF.md §2`; live/verified status is tracked in
`docs/g-facts.md`. One amendment to the v2 facts:

> **⟢ AMENDED — finding 2 (G9).** The brief states `maxVotingNum = 30`. The live Base Voter
> returns **60** (governance raised it after the launch docs). This is not a code change — it is
> the reason the brief's own rule exists: **every protocol-side value is read at call time and
> never compiled in.** `EpochPilot.revote` reads `maxVotingNum()` live. See `docs/g-facts.md` G9f.

> **⟢ AMENDED — finding 11 (G9 window).** The whitelist-only final hour (G9c) is where vote
> weights move most, and the vault — not whitelisted, one vote per epoch — cannot act in it. This
> is not just a liveness constraint; it bounds the *strategy* (see §4.3 amendment). The vault
> closes its window at the Voter's live `epochVoteEnd`, not a compiled-in offset.

**Spec-freeze gate** for `TranchePilot` (G1, G3, G4, G6, G7 in published code; G11 decides Model P
vs S) is unchanged and still pending the Aug 3 drop.

---

## 3. Product specification — `TranchePilot` (Aero v3)

### 3.1 Lifecycle

Deploy (CREATE2, no privileges) → seed (`deposit`, 1:1, `withdrawSeed` refunds) → `activate()`
once seed clears `ACTIVATION_MIN` (creates the K permanent stakes) → steady-state permissionless
ops. No step 5: no pause, no admin unwind.

> **⟢ AMENDED — finding 8 (activation gate).** `activate()` must gate on the **share supply**
> (`totalShares`, 1:1 with net deposits during seeding), **not** on the raw AERO balance.
> Balance-gating lets donations satisfy the threshold with a near-zero share supply, which voids
> the `totalShares ≥ ACTIVATION_MIN` premise that proves the distributor's fixed-point narrowing
> safe. Rule: every arithmetic-safety proof premise must be enforced by the exact variable the
> proof quantifies over. (`EpochPilot.activate` gates on `totalShares`.)

> **⟢ NOTE — finding 8 corollary (activation is permissionless).** Because `activate()` is
> callable by anyone once the threshold clears, a pending `withdrawSeed` can be front-run by
> activation and the refund window closed. Inherent, not a bug — disclosed in the deposit/
> withdrawSeed NatSpec and threat model: only seed what you are prepared to have locked.

### 3.2 Shares and exit

Shares are a minimal in-file ERC-20. Principal is permanently staked and never withdrawable as
liquid AERO; guaranteed exit is selling shares; conditional exit to a position is `exitToNFT` if
the `withdraw-to-NFT` role lands (§3.7 / G11).

The baseline mint formula: `shares = amount × totalShares / totalPrincipal`.

> **⟢ AMENDED — finding 6 (net-asset pricing).** The mint denominator must be **net assets**, not
> principal alone: `shares = amount × totalShares / (lockedPrincipal + looseAero)`, where
> `looseAero` is claimed-but-uncompounded AERO revenue held by the vault. Pricing against locked
> principal only lets a depositor slipping in between `claimRevenue` and `compound` buy below net
> asset value and capture revenue earned before them. State the v3 formula in terms of net assets.
> (`EpochPilot.deposit` uses `_lockedAmount() + looseAero`.)

> **⟢ AMENDED — finding 3 (derive principal).** "principal = AERO ever staked + compounded" must
> be **read from the escrow** (`VE.locked(tokenId).amount`) at every mint, never tracked in a
> storage counter. Third parties can grow the lock directly (`depositFor`, permissionless rebase
> `claim`) outside the vault's wrappers, silently staling any shadowed counter and over-minting
> new depositors. Invariant 2 already defines principal via escrow-reported amounts; make the
> code match. Rule: any state a third-party call can move must be read from the protocol, not
> shadowed.

### 3.3 Tranches and the reactivity edge

Unchanged in structure (K permanent positions, slot grid `Δ = C/K`, cooldown `C` read live).
Finding 2's "read everything live" applies to `C`, minimum weights, and every governance-settable
value — none is compiled in.

### 3.4 Permissionless operations and bounties

Unchanged: the opportunistic rebalance hook, the revert-free coupling, and the escalating
staleness bounty stand as written. (The v2 PoC field-tests the escalating bounty as its *sole*
liveness mechanism — §9.)

### 3.5 Revenue distribution

The baseline: a per-token Synthetix accumulator (`accPerShare[token] += claimed·1e27/totalShares`)
with reward-debt accounting updated on every share mint/transfer/burn, one token per call, no
token loops.

> **⟢ AMENDED — finding 1 (the accumulator is unsound as specified).** Reward-debt accounting and
> the ban on token-list loops are **mutually exclusive** for transferable shares over an unbounded
> heterogeneous token set: `pending = balance·accPerShare − debt` is only correct if `debt(u,t)`
> is re-based for *every* token `t` on every balance change — which is precisely the banned loop
> (and a poisonable global registry). Skipping it is theft or loss, not rounding.
>
> **Replacement (implemented, proposed for v3):** event-sourced distribution.
> - Each credited claim appends one `(seq, perShare)` event to that token's history.
> - Each share-balance change appends one `(seq, balance)` checkpoint for the user — O(1),
>   token-independent.
> - `claimUser(token, maxEvents)` integrates the caller's checkpointed balance over that token's
>   events via a two-pointer merge, advancing a per-`(user, token)` cursor. One token per call,
>   batched, resumable; a bonus the naive pattern lacks: burning/redeeming shares does not forfeit
>   accrued-but-unclaimed revenue.

> **⟢ AMENDED — finding 9 (bound the history).** Because claims are permissionless and
> bounty-paid, an unbounded append-only credit array is attacker-paced on an immutable contract.
> The sequence counter advances on **share-balance changes**, not on credits; credits landing
> between two balance changes share a `seq` and **coalesce into one entry** (identical applicable
> balances make the merge exact). History growth is bounded by transfer interleavings, not claim
> frequency.

> **⟢ AMENDED — finding 6 (AERO handling).** AERO revenue is still never distributed — it becomes
> `looseAero` and is compounded — but note it is now also part of the mint denominator (§3.2), so
> claimed-not-yet-compounded AERO cannot be captured by a JIT depositor.

> **⟢ NOTE — finding (sender-burn tokens).** Credits are re-measured after the caller's bounty
> push, so they are fully backed at credit time even for fee-on-transfer tokens. A token that
> burns *extra* from the sender on every transfer still erodes backing as holders claim — late
> claimants of such a pathological token may come up short. Isolated to that token; no honest
> token or AERO affected.

### 3.6 Constants

Unchanged, with one clarification carried from the PoC:

> **⟢ AMENDED — finding 7 (`SERIES_CAP` / `DEPOSIT_CAP` semantics).** The hard deposit cap bounds
> **cumulative `deposit()` inflow** (a monotone `totalDeposited` counter, refunds excluded), NOT
> live TVL. Enforcing it against escrow-reported principal would let ordinary vault growth
> (rebases, compounding, third-party `depositFor`) consume cap room and permanently lock out new
> depositors — and the "blast-radius" reading was never enforceable against TVL anyway, since
> third parties can grow the position directly. (The derive-don't-track rule of finding 3 applies
> to values third parties can move; a deposits-only counter is not one of them.)

### 3.7 Custody model (Model P vs Model S)

Unchanged. Model P (pooled, fungible shares, `exitToNFT` iff the `withdraw-to-NFT` role lands) vs
Model S (one position per depositor, role-free whole-NFT exit, smaller TCB). G11 decides the
default at the Aug 3 drop. The event-sourced distributor (finding 1) is a Model P concern; Model S
has no share/accumulator subsystem.

---

## 4. Strategy specification

### 4.1 Objective

Maximize expected return relative to the weight-average allocator. Unchanged.

### 4.2 Primary signal: gauge caps

Unchanged, and worth emphasising against a common misreading (see §4.3 amendment): the v3 primary
signal is **not other voters' votes** — it is the protocol's **gauge caps** (`cap ≈ κ × projected
revenue`), a maintained revenue projection read on-chain. Allocating by caps *is* allocating by
projected revenue. Mirror (§4.3) is only the fallback.

### 4.3 Fallback mode: mirror

The baseline claims mirror-ex-self "earns the weight-average return identically by construction …
it is a fixed point."

> **⟢ AMENDED — finding 11 (mirror's guarantee is conditional).** Mirror earns the weight-average
> **only against the settled vote distribution**. The identity holds iff the vault mirrors final
> weights `Tₚ`: revenue `= Σ(vₚ/Tₚ)·Rₚ = (V/ΣT)·ΣRₚ`. Mirroring an *earlier* snapshot `Tₚᵗ`
> yields `(V/ΣTᵗ)·Σ(Tₚᵗ/Tₚ^final)·Rₚ` — a tracking error whose factor `< 1` precisely for pools
> that gain votes after time *t*.
>
> In **v2 this bias is real and systematic**: voting is a claim on fixed per-epoch bribes, so the
> crowd rushes the highest reward-per-vote pools in the whitelist-only final hour, and the vault
> (one vote per epoch, not whitelisted) is forced to mirror a pre-final-hour snapshot the final
> hour then reshapes — away from exactly the pools the late money concentrates in. Realized return
> is the weight-average **with a negatively-biased tracking error**. No on-chain v2 strategy
> escapes this.
>
> **Voting "by revenue" does not fix it in v2:** reward-per-vote `(fees+bribes)/votes` divides by
> the same volatile end-of-epoch vote count, amplifying the sensitivity, and a mechanical
> reward-per-vote rule is a bribe magnet the coverage check does not defend (it is also §4.4's
> out-of-scope predictive alpha).
>
> **v3 removes the phenomenon:** no synchronized flip means no shared settlement instant to be
> stale against, and the primary signal is already revenue-based via caps (§4.2), not a live
> contested vote denominator. State mirror's guarantee in v3 as "weight-average against settled
> weights," and confirm continuous allocation makes the mirror snapshot effectively the
> settlement snapshot.

### 4.4 Out of scope

Predictive/forecasting signals, LP automation, USDC conversion, cross-chain, governance, MEV
protection beyond not swapping. Unchanged.

---

## 5. Contract specification

### 5.1 Banned constructs

No proxy/`delegatecall`, no `selfdestruct`, no inline assembly, no external imports (interfaces
hand-written into `src/interfaces/`), no oracles, no swaps, no `payable`/`receive`, no
signatures/permit, no `try/catch`, **zero `onlyX` modifiers**. `onERC721Received` accepts only the
escrow collection.

> **⟢ AMENDED — finding 10 (enforce on artifacts, not vocabulary).** A source grep for `only[A-Z]`
> / `ecrecover` / upgrade identifiers bans *naming conventions*, not *properties* — a
> differently-named privileged check or a precompile `staticcall` slips through. The gate now also
> disassembles the compiled runtime (metadata-stripped) and fails on any DELEGATECALL /
> SELFDESTRUCT / CALLCODE **opcode**, and the no-privilege property is exercised behaviorally by
> the fork suite's fresh-EOA probe. Greps remain a lint layer only.

> **⟢ AMENDED — finding (onERC721Received scope).** "accepts only the escrow collection" is
> necessary but not sufficient: accepting *any* escrow NFT at *any* time lets a user freeze their
> own position by safe-transferring it into a rescueless contract. The hook accepts the mint
> **only while `activate()` is mid-`createLock`** (a transient flag); every other transfer reverts.

### 5.2 Repository layout

As built: `src/EpochPilot.sol` + `src/interfaces/`; `test/{unit,fuzz,invariant,fork}` with a
shared `test/utils/` fixture (finding 5); `script/DeployEpochPilot.s.sol`; `verification/`;
`docs/`; `audits/`. `TranchePilot.sol` / `SeparatePilot.sol` are not yet written (spec-freeze gate).

### 5.3 State

> **⟢ AMENDED — findings 1, 3.** The Model P distributor state `accPerShare[token]` /
> `rewardDebt[user][token]` is replaced by the event-sourced structures: `eventSeq`,
> per-token credit history, per-user balance checkpoints, and `claimCursor[user][token]`.
> `totalPrincipal` is **not** a stored variable — principal is read from the escrow. A
> `totalDeposited` counter backs the deposit cap (finding 7).

### 5.4 Invariants

The baseline list stands. Amendments: invariant 2 (principal = escrow-reported, non-decreasing)
is now *enforced by derivation* rather than by careful bookkeeping (finding 3); invariant 3
(accumulator no-loss) is re-derived for the event-sourced distributor and proven bit-exact against
a reference model under fuzzing (finding 1); the fixed-point narrowing bound in the distributor is
guaranteed by the activation share-supply gate (finding 8).

### 5.5 Events

Unchanged in spirit. `EpochPilot` emits `Deposited`, `SeedWithdrawn`, `Activated`, `Revoted`,
`RevenueClaimed`, `RebaseClaimed`, `Compounded`, `Unwound`, `Redeemed`, `UserClaimed`, plus ERC-20.

---

## 6. Threat model

The baseline table stands; `docs/threat-model.md` is the instantiated, test-linked version and
carries the review-round additions (net-asset pricing, halt-proof unwind, stray-NFT rejection,
dead-gauge coverage relief, credit-coalescing, sender-burn tokens).

---

## 7. Assurance plan

Unchanged targets. Status: unit + fuzz + invariant + fork suites green (85 tests at CI intensity);
coverage ~97% lines / 100% funcs with residuals triaged (`docs/coverage-notes.md`); Slither
triaged (`audits/slither.md`); Echidna / halmos / gambit / external audit still tracked as pending.

---

## 8. Reproducibility and verification

Unchanged as a gate. Realized: pinned solc 0.8.30 / optimizer 200 / cancun / `bytecode_hash=ipfs`;
CREATE2 via the canonical proxy; machine-readable record in `verification/bytecode-hashes.json`
(CI-enforced against a clean build for runtime hash, init-code hash, and derived address).

> **⟢ NOTE (post-deploy byte-diff).** The baseline's `diff <(cast code) <(local runtime)` cannot
> match verbatim — immutable-reference sites are zeroed in the artifact and filled at construction.
> Equality is instead proven by CREATE2 address derivation (the address commits to the full init
> code) plus Sourcify full-match. See `verification/README.md`.

---

## 9. `EpochPilot` — the Aerodrome v2 proof of concept (shipped)

One veNFT, `TERM = 26 weeks`, `DEPOSIT_CAP = 10,000 AERO`, weekly permissionless `revote`
(mirror-ex-self with the 80% coverage check), `claimRevenue` / `claimRebase` / `compound`, and a
`unwind → redeem` exit. The escalating-from-loose-AERO bounty is the sole liveness mechanism.
The baseline §9 stands, with these realizations from the P0 review:

> **⟢ AMENDED — finding 4 (`unwind` is halt-proof).** `unwind()` touches **only** `Voter.reset` +
> escrow `withdraw` — never the RewardsDistributor. The distributor's claim gate depends on
> protocol upkeep (minter period / time cursor) that can be permanently stale if the protocol
> halts; principal recovery must not sit behind it. The final rebase is claimable via
> `claimRebase` throughout a **1-week `UNWIND_GRACE`** after expiry; any unclaimed remainder is
> forfeited (bounded, disclosed). A mirrored copy of the distributor's precondition is *not* an
> acceptable substitute — it validates only against a mock written to match it.

> **⟢ AMENDED — finding 11 (revote window & return).** The window closes at the Voter's **live
> `epochVoteEnd`**, not a compiled-in `flip − 1h`. Realized mirror return carries the end-of-epoch
> tracking error described in §4.3; this is a v2-structural limit disclosed in the README and
> threat model, not a defect, and it is the reason the real (revenue/caps-based) strategy is
> reserved for v3.

> **⟢ AMENDED — findings 2, 3, 6, 7, 8.** `revote` reads `maxVotingNum` live (60, not 30);
> principal is read from the escrow every mint; deposits price against `locked + looseAero`; the
> cap bounds cumulative deposits; `activate()` gates on `totalShares`. A `revote(pools, deadPools)`
> second argument lets callers exclude validated-dead gauges from the coverage denominator so a
> large gauge kill cannot brick the strategy.

**Explicit non-goal** (unchanged): the PoC does not migrate to v3; it runs out its term and unwinds.

---

## 10. Milestones

Unchanged. P0 (the PoC) is implemented and under review; deployment/seeding awaits a funded
broadcast key and the verification gate. P1 (spec freeze) begins at the Aug 3 code drop.

---

## 11. Definition of done

Unchanged as the bar. Against it, P0 currently has: contract implemented, 85 tests green incl. 15
mainnet-fork assertions of the G-facts, zero admin surface (opcode-enforced), reproducible build
with CREATE2-derivable address. Still open: mainnet deploy + Sourcify/Basescan verification + one
full permissionless cycle on mainnet; 100% branch coverage (residuals triaged, not yet closed);
mutation ≥95%; external audit. `TranchePilot` is deliberately unstarted pending the spec-freeze gate.
