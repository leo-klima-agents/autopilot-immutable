# Address resolution record — Aerodrome v2 on Base (chain id 8453)

**Rule (build brief §1):** no contract address is ever taken from a document or article.
The sole root of trust is the canonical AERO token address; its identity is asserted
on-chain (`symbol() == "AERO"`, `name() == "Aerodrome"`), and every protocol contract is
resolved by walking the on-chain link graph and cross-checking every back-reference.
The same walk is executed by `test/fork/AerodromeFacts.t.sol` on every fork-test run and
by `script/DeployEpochPilot.s.sol` at the moment of deployment.

## Resolution procedure (reproduce with `cast`, any Base RPC)

```
AERO   = 0x940181a94A35A4569E4529A3CDfB74e38FD98631   # root of trust
assert cast call $AERO  'symbol()(string)'            == "AERO"
MINTER = cast call $AERO  'minter()(address)'
VOTER  = cast call $MINTER 'voter()(address)'
VE     = cast call $MINTER 've()(address)'
DIST   = cast call $MINTER 'rewardsDistributor()(address)'

# closure checks — every edge must point back
assert cast call $VOTER 've()(address)'          == $VE
assert cast call $VOTER 'minter()(address)'      == $MINTER
assert cast call $VE    'token()(address)'       == $AERO
assert cast call $VE    'voter()(address)'       == $VOTER
assert cast call $VE    'distributor()(address)' == $DIST
assert cast call $DIST  've()(address)'          == $VE
assert cast call $DIST  'minter()(address)'      == $MINTER
```

## Resolved values (block 49,016,010 · 2026-07-23 — re-resolve at every use)

| Contract | Address |
|---|---|
| AERO (root of trust) | `0x940181a94A35A4569E4529A3CDfB74e38FD98631` |
| Minter | `0xeB018363F0a9Af8f91F06FEe6613a751b2A33FE5` |
| Voter | `0x16613524e02ad97eDfeF371bC883F2F5d6C480A5` |
| VotingEscrow | `0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4` |
| RewardsDistributor | `0x227f65131A261548b057215bB1D5Ab2997964C7d` |

All seven closure checks above passed at the recorded block. The `EpochPilot`
constructor takes only the Voter and re-derives + re-checks VE, the distributor and
AERO itself, so even a wrong deployment argument cannot produce a plausible-but-wrong
vault — it reverts.
