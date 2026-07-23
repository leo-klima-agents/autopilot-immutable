// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "./interfaces/IERC20.sol";
import {IVoter} from "./interfaces/IVoter.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";
import {IMinter} from "./interfaces/IMinter.sol";

/// @title  EpochPilot — immutable pooled voting pilot on Aerodrome v2 (Base)
/// @notice Pools AERO into one fixed-term veNFT, mirrors the market's vote
///         weekly (mirror-ex-self, §4.3), claims fees/bribes/rebases through
///         permissionless bountied calls, and unwinds trustlessly at term end.
///
///         ████ READ BEFORE DEPOSITING ████
///         • Deposited AERO is LOCKED for the full remaining term (26 weeks
///           from activation). There is no early exit. Exit before term end is
///           selling your transferable shares; exit at term end is `redeem()`.
///         • This contract has NO owner, NO admin, NO pause, NO upgrade path.
///           Nobody — including the deployer — can change or rescue anything.
///         • Hard deposit cap: 10,000 AERO. This is a demonstrator.
///
/// @dev    Design rules enforced here (§5.1): no proxy, no delegatecall, no
///         selfdestruct, no inline assembly, no imports outside
///         src/interfaces/, no oracles, no swaps, no payable/receive, no
///         signatures, no try/catch, zero caller-restricted functions except
///         by arithmetic (phase, epoch window, share ownership).
///
///         Revenue distribution is event-sourced rather than the naive
///         MasterChef debt pattern: with transferable shares and an unbounded
///         heterogeneous reward-token set, per-token debt cannot be settled on
///         transfer without looping over a token list (banned). Instead each
///         credited claim appends a per-token (seq, perShare) event, every
///         share balance change appends a per-user (seq, balance) checkpoint,
///         and a user's claim for one token integrates their checkpointed
///         balance over that token's events. Exact, O(1) transfers, one token
///         per claim call, no global token registry to poison.
contract EpochPilot {
    // ─────────────────────────────────────────────────────────────────────────
    // Constants (all fixed at compile time; §3.6 scaled for the PoC)
    // ─────────────────────────────────────────────────────────────────────────

    string public constant name = "Epoch Pilot Share";
    string public constant symbol = "epAERO";
    uint8 public constant decimals = 18;

    /// @notice Lock term created at activation. The term IS the exit schedule.
    uint256 public constant TERM = 26 weeks;
    /// @notice Aerodrome epoch length.
    uint256 public constant WEEK = 7 days;
    /// @notice Hard cap on principal ever entering via deposit() — blast-radius bound.
    uint256 public constant DEPOSIT_CAP = 10_000e18;
    /// @notice Minimum pooled AERO before activate() may lock.
    uint256 public constant ACTIVATION_MIN = 100e18;
    /// @notice Dust / accumulator-precision hygiene.
    uint256 public constant MIN_DEPOSIT = 1e18;
    /// @notice Dead shares minted to 0xdead at activation (share-inflation guard).
    uint256 public constant SEED_BURN = 1e3;
    /// @notice In-kind bounty on claimed/compounded flows, in basis points.
    uint256 public constant BOUNTY_BPS = 30;
    /// @notice Escalating revote bounty accrued per full epoch of staleness (§3.4 ramp).
    uint256 public constant BOUNTY_RAMP_AERO = 1e18;
    /// @notice Ceiling on the escalating revote bounty.
    uint256 public constant BOUNTY_MAX_AERO = 5e18;
    /// @notice Mirror coverage threshold: candidate pools must carry ≥ 80% of totalWeight.
    uint256 public constant COVERAGE_BPS = 8_000;
    /// @notice revote() opens this long before the epoch flip…
    uint256 public constant REVOTE_OPEN = 6 hours;
    /// @notice …and closes this long before it (strictly clear of the
    ///         whitelist-only final hour enforced by the Voter).
    uint256 public constant REVOTE_CLOSE = 1 hours;
    /// @notice unwind() waits this long past lock expiry so the final epoch's
    ///         revenue can be claimed before the veNFT is burned.
    uint256 public constant UNWIND_GRACE = 1 weeks;
    /// @notice Upper bound on distinct reward tokens per claimRevenue call (gas bound).
    uint256 public constant MAX_CLAIM_TOKENS = 32;
    /// @notice Accumulator precision.
    uint256 private constant ACC = 1e27;
    address private constant DEAD = address(0xdEaD);

    // ─────────────────────────────────────────────────────────────────────────
    // Immutables — resolved and cross-checked from the Voter at deploy time
    // ─────────────────────────────────────────────────────────────────────────

    IVoter public immutable VOTER;
    IVotingEscrow public immutable VE;
    IRewardsDistributor public immutable DIST;
    IMinter public immutable MINTER;
    IERC20 public immutable AERO;

    // ─────────────────────────────────────────────────────────────────────────
    // State (complete list, §5.3)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Total shares in existence. Invariant: equals Σ balanceOf.
    uint256 public totalShares;
    /// @notice Share balances (18 decimals, transferable).
    mapping(address => uint256) public balanceOf;
    /// @notice ERC-20 allowances.
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice False until activate(); deposits are 1:1 refundable before it.
    bool public activated;
    /// @notice True once unwind() has burned the lock; redeem() is then live.
    bool public unwound;
    /// @notice The vault's single veNFT (set at activation).
    uint256 public tokenId;
    /// @notice Week-aligned lock expiry (set at activation).
    uint256 public lockEnd;
    /// @notice Timestamp of the last successful revote (drives the bounty ramp).
    uint256 public lastVoteAt;
    /// @notice AERO on hand from claims, awaiting compound(). Invariant:
    ///         post-activation, pre-unwind: AERO.balanceOf(this) ≥ looseAero
    ///         (strict surplus = donations / directly-claimed rebases, swept
    ///         into the lock by the next compound()).
    uint256 public looseAero;

    /// @dev One credit event per (token, claim): cumulative-order sequence
    ///      number and the per-share amount credited (scaled by ACC).
    struct Credit {
        uint64 seq;
        uint192 perShare;
    }
    /// @dev Balance checkpoint: user's share balance while eventSeq == seq.
    struct BalCp {
        uint64 seq;
        uint192 bal;
    }

    /// @notice Global sequence; increments once per credit event.
    uint64 public eventSeq;
    /// @dev token ⇒ append-only credit history.
    mapping(address => Credit[]) private _credits;
    /// @dev user ⇒ append-only balance-checkpoint history.
    mapping(address => BalCp[]) private _balCps;
    /// @notice user ⇒ token ⇒ index of the next unclaimed credit event.
    mapping(address => mapping(address => uint256)) public claimCursor;

    /// @dev Hand-written reentrancy latch (transient storage; §6).
    bool transient _entered;

    // ─────────────────────────────────────────────────────────────────────────
    // Events (§5.5)
    // ─────────────────────────────────────────────────────────────────────────

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposited(address indexed user, uint256 amount, uint256 shares);
    event SeedWithdrawn(address indexed user, uint256 amount);
    event Activated(uint256 indexed tokenId, uint256 principal, uint256 lockEnd);
    event Revoted(address indexed caller, address[] pools, uint256[] weights, uint256 bounty);
    event RevenueClaimed(address indexed caller, address indexed token, uint256 amount, uint256 bounty);
    event RebaseClaimed(address indexed caller, uint256 amount, uint256 bounty);
    event Compounded(address indexed caller, uint256 amount, uint256 bounty);
    event Unwound(address indexed caller, uint256 redeemPool);
    event Redeemed(address indexed user, uint256 shares, uint256 amount);
    event UserClaimed(address indexed user, address indexed token, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error AlreadyActivated();
    error BadCandidateSet();
    error BadDeployment();
    error BelowMinimum();
    error CapExceeded();
    error CoverageTooLow();
    error Expired();
    error InsufficientShares();
    error LengthMismatch();
    error NotActive();
    error NotEscrow();
    error NotUnwound();
    error NothingToCompound();
    error OutsideWindow();
    error Reentrancy();
    error TooEarly();
    error TransferFailed();
    error ZeroAmount();

    // ─────────────────────────────────────────────────────────────────────────
    // Construction — the deployer passes only the Voter; everything else is
    // resolved on-chain and the link graph is self-checked, so a bad or
    // malicious constructor argument cannot produce a plausible-but-wrong
    // deployment.
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address voter_) {
        IVoter v = IVoter(voter_);
        IVotingEscrow ve_ = IVotingEscrow(v.ve());
        IRewardsDistributor dist_ = IRewardsDistributor(ve_.distributor());
        address minter_ = v.minter();
        if (dist_.ve() != address(ve_) || dist_.minter() != minter_) revert BadDeployment();
        VOTER = v;
        VE = ve_;
        DIST = dist_;
        MINTER = IMinter(minter_);
        AERO = IERC20(ve_.token());
    }

    modifier nonReentrant() {
        if (_entered) revert Reentrancy();
        _entered = true;
        _;
        _entered = false;
    }

    /// @notice Accepts veNFT mints from the escrow collection only (§5.1).
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(VE)) revert NotEscrow();
        return this.onERC721Received.selector;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Deposits, seeding, activation (§3.1, §3.2)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deposit AERO for shares. Before activation: 1:1 and refundable
    ///         via withdrawSeed(). After activation: locked irrevocably until
    ///         term end; shares minted pro-rata against live locked principal.
    function deposit(uint256 amount) external nonReentrant {
        if (unwound) revert NotActive();
        if (amount < MIN_DEPOSIT) revert BelowMinimum();
        uint256 minted;
        if (!activated) {
            if (totalShares + amount > DEPOSIT_CAP) revert CapExceeded();
            minted = amount;
            _pull(msg.sender, amount);
        } else {
            // Live locked amount is the principal (rebases, compounds and
            // direct depositFor donations all accrue to it, so the mint ratio
            // can never go stale in depositors' favor).
            uint256 principal = _lockedAmount();
            if (principal + amount > DEPOSIT_CAP) revert CapExceeded();
            minted = amount * totalShares / principal;
            if (minted == 0) revert BelowMinimum();
            _pull(msg.sender, amount);
            _approveAero(address(VE), amount);
            VE.increaseAmount(tokenId, amount);
        }
        _mint(msg.sender, minted);
        emit Deposited(msg.sender, amount, minted);
    }

    /// @notice Refund a seed deposit 1:1 — only before activation. Depositors
    ///         are not committed until the vault is.
    function withdrawSeed(uint256 shares) external nonReentrant {
        if (activated) revert AlreadyActivated();
        if (shares == 0) revert ZeroAmount();
        _burn(msg.sender, shares);
        _push(address(AERO), msg.sender, shares);
        emit SeedWithdrawn(msg.sender, shares);
    }

    /// @notice Locks the entire pooled seed into one veNFT for TERM. Anyone
    ///         may call once the seed clears ACTIVATION_MIN. Irreversible;
    ///         refunds end here.
    function activate() external nonReentrant {
        if (activated) revert AlreadyActivated();
        uint256 bal = AERO.balanceOf(address(this));
        if (bal < ACTIVATION_MIN) revert BelowMinimum();
        activated = true;
        _approveAero(address(VE), bal);
        uint256 id = VE.createLock(bal, TERM);
        tokenId = id;
        lockEnd = VE.locked(id).end;
        lastVoteAt = block.timestamp;
        _mint(DEAD, SEED_BURN);
        emit Activated(id, bal, lockEnd);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Strategy: weekly mirror-ex-self revote (§4.3, §9)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Re-votes the vault's weight to mirror every other participant's
    ///         allocation. Callable by anyone inside [flip−6h, flip−1h), i.e.
    ///         after the epoch's information is in and safely before the
    ///         whitelist-only final hour. The Voter enforces once-per-epoch.
    /// @param  pools Candidate pool set. Validated on-chain: gauge exists and
    ///         is alive, no duplicates, count ≤ live maxVotingNum, and the set
    ///         carries ≥ COVERAGE_BPS of total vote weight — the coverage
    ///         check is what defeats self-serving subsets.
    function revote(address[] calldata pools) external nonReentrant {
        if (!activated || unwound) revert NotActive();
        uint256 flip = VOTER.epochNext(block.timestamp);
        if (block.timestamp < flip - REVOTE_OPEN || block.timestamp >= flip - REVOTE_CLOSE) {
            revert OutsideWindow();
        }
        uint256 n = pools.length;
        if (n == 0 || n > VOTER.maxVotingNum()) revert BadCandidateSet();
        uint256 id = tokenId;
        uint256[] memory mirror = new uint256[](n);
        uint256 covered;
        for (uint256 i; i < n; ++i) {
            address pool = pools[i];
            for (uint256 j; j < i; ++j) {
                if (pools[j] == pool) revert BadCandidateSet();
            }
            address gauge = VOTER.gauges(pool);
            if (gauge == address(0) || !VOTER.isAlive(gauge)) revert BadCandidateSet();
            uint256 w = VOTER.weights(pool);
            covered += w;
            // Mirror-ex-self: track everyone's weight but our own.
            uint256 m = w - VOTER.votes(id, pool);
            if (m == 0) revert BadCandidateSet();
            mirror[i] = m;
        }
        if (covered * 10_000 < VOTER.totalWeight() * COVERAGE_BPS) revert CoverageTooLow();
        VOTER.vote(id, pools, mirror);
        uint256 bounty = _revoteBounty();
        lastVoteAt = block.timestamp;
        if (bounty != 0) {
            looseAero -= bounty;
            _push(address(AERO), msg.sender, bounty);
        }
        emit Revoted(msg.sender, pools, mirror, bounty);
    }

    /// @notice The escalating revote bounty (§3.4): ramps with staleness,
    ///         capped by BOUNTY_MAX_AERO and by AERO on hand. Skipped — never
    ///         reverted — when no loose AERO is available.
    function _revoteBounty() internal view returns (uint256 bounty) {
        bounty = BOUNTY_RAMP_AERO * (block.timestamp - lastVoteAt) / WEEK;
        if (bounty > BOUNTY_MAX_AERO) bounty = BOUNTY_MAX_AERO;
        uint256 available = looseAero;
        if (bounty > available) bounty = available;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Permissionless revenue operations (§3.4, §3.5)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Claims fee and bribe revenue. Claim targets are derived from
    ///         the Voter's own gauge registry (never free-form reward
    ///         addresses); received amounts are measured by balance delta
    ///         (fee-on-transfer safe). AERO revenue becomes loose AERO for
    ///         compounding; every other token is credited to the per-token
    ///         distributor. Caller earns BOUNTY_BPS of each claimed token,
    ///         in kind.
    /// @param  gauges      Gauges to claim for; each must be Voter-registered.
    /// @param  feeTokens   Per-gauge token lists for the fees contract.
    /// @param  bribeTokens Per-gauge token lists for the bribe contract.
    function claimRevenue(
        address[] calldata gauges,
        address[][] calldata feeTokens,
        address[][] calldata bribeTokens
    ) external nonReentrant {
        if (!activated || unwound) revert NotActive();
        uint256 n = gauges.length;
        if (n == 0 || feeTokens.length != n || bribeTokens.length != n) revert LengthMismatch();

        address[] memory fees = new address[](n);
        address[] memory bribes = new address[](n);
        for (uint256 i; i < n; ++i) {
            if (!VOTER.isGauge(gauges[i])) revert BadCandidateSet();
            fees[i] = VOTER.gaugeToFees(gauges[i]);
            bribes[i] = VOTER.gaugeToBribe(gauges[i]);
        }

        // Union of all named tokens, deduplicated, gas-bounded.
        address[] memory uniq = new address[](MAX_CLAIM_TOKENS);
        uint256 u;
        for (uint256 i; i < n; ++i) {
            u = _collect(uniq, u, feeTokens[i]);
            u = _collect(uniq, u, bribeTokens[i]);
        }
        if (u == 0) revert LengthMismatch();

        uint256[] memory pre = new uint256[](u);
        for (uint256 k; k < u; ++k) {
            pre[k] = IERC20(uniq[k]).balanceOf(address(this));
        }

        VOTER.claimFees(fees, feeTokens, tokenId);
        VOTER.claimBribes(bribes, bribeTokens, tokenId);

        for (uint256 k; k < u; ++k) {
            address token = uniq[k];
            uint256 delta = IERC20(token).balanceOf(address(this)) - pre[k];
            if (delta == 0) continue;
            uint256 bounty = delta * BOUNTY_BPS / 10_000;
            if (token == address(AERO)) {
                looseAero += delta - bounty;
            } else {
                _credit(token, delta - bounty);
            }
            if (bounty != 0) _push(token, msg.sender, bounty);
            emit RevenueClaimed(msg.sender, token, delta, bounty);
        }
    }

    /// @notice Claims the weekly rebase. While the lock lives, the distributor
    ///         auto-compounds it into the lock (G10) — principal grows and
    ///         share value rises. After expiry the AERO arrives liquid and
    ///         waits for unwind(). Caller bounty is paid from loose AERO,
    ///         capped by what is on hand.
    function claimRebase() external nonReentrant returns (uint256 amount) {
        if (!activated || unwound) revert NotActive();
        amount = DIST.claim(tokenId);
        if (block.timestamp >= lockEnd) looseAero += amount;
        uint256 bounty = amount * BOUNTY_BPS / 10_000;
        uint256 available = looseAero;
        if (bounty > available) bounty = available;
        if (bounty != 0) {
            looseAero -= bounty;
            _push(address(AERO), msg.sender, bounty);
        }
        emit RebaseClaimed(msg.sender, amount, bounty);
    }

    /// @notice Stakes the vault's entire AERO balance (claimed revenue plus
    ///         any donations) into the lock, raising share value — the
    ///         vault's only growth loop. Caller earns BOUNTY_BPS of the
    ///         compounded amount.
    function compound() external nonReentrant {
        if (!activated || unwound) revert NotActive();
        if (block.timestamp >= lockEnd) revert Expired();
        uint256 bal = AERO.balanceOf(address(this));
        if (bal == 0) revert NothingToCompound();
        uint256 bounty = bal * BOUNTY_BPS / 10_000;
        uint256 amount = bal - bounty;
        looseAero = 0;
        if (bounty != 0) _push(address(AERO), msg.sender, bounty);
        _approveAero(address(VE), amount);
        VE.increaseAmount(tokenId, amount);
        emit Compounded(msg.sender, amount, bounty);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // End of term (§9): unwind and redeem
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Burns the expired lock and converts it back to liquid AERO,
    ///         opening redeem(). Callable by anyone, but only UNWIND_GRACE
    ///         after expiry so the final epoch's revenue can be claimed first
    ///         (claims need the veNFT alive).
    function unwind() external nonReentrant {
        if (!activated || unwound) revert NotActive();
        if (block.timestamp < lockEnd + UNWIND_GRACE) revert TooEarly();
        unwound = true;
        // Final rebase — arrives liquid (lock is expired). The distributor
        // refuses claims while the minter's weekly period is stale, which is
        // permanent if the protocol has halted; principal must never hang on
        // a rebase claim, so mirror the distributor's own precondition and
        // skip (the rebase, worth little, is forfeited — the principal,
        // worth everything, comes home regardless).
        if (MINTER.activePeriod() >= (block.timestamp / WEEK) * WEEK) {
            DIST.claim(tokenId);
        }
        VOTER.reset(tokenId); // clear the voted flag; escrow requires it
        VE.withdraw(tokenId); // principal comes home
        looseAero = 0; // everything on hand is now the redemption pool
        emit Unwound(msg.sender, AERO.balanceOf(address(this)));
    }

    /// @notice Burns shares for a pro-rata slice of the redemption pool.
    ///         Non-AERO revenue stays claimable via claimUser() forever —
    ///         redemption does not forfeit it (balance history is preserved).
    function redeem(uint256 shares) external nonReentrant returns (uint256 amount) {
        if (!unwound) revert NotUnwound();
        if (shares == 0) revert ZeroAmount();
        amount = AERO.balanceOf(address(this)) * shares / totalShares;
        _burn(msg.sender, shares);
        if (amount != 0) _push(address(AERO), msg.sender, amount);
        emit Redeemed(msg.sender, shares, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Event-sourced revenue distribution (§3.5, reformulated — see @dev above)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Pulls the caller's accrued revenue for one token. One token per
    ///         call — a bricked or malicious reward token can block only its
    ///         own claims. `maxEvents` bounds gas (0 = no bound); the cursor
    ///         persists, so long histories are claimable in batches.
    function claimUser(address token, uint256 maxEvents) external nonReentrant returns (uint256 owed) {
        Credit[] storage credits = _credits[token];
        uint256 cursor = claimCursor[msg.sender][token];
        uint256 end = credits.length;
        if (maxEvents != 0 && cursor + maxEvents < end) end = cursor + maxEvents;
        BalCp[] storage cps = _balCps[msg.sender];
        for (; cursor < end; ++cursor) {
            Credit storage c = credits[cursor];
            owed += _balanceAt(cps, c.seq) * c.perShare / ACC;
        }
        claimCursor[msg.sender][token] = cursor;
        if (owed != 0) _push(token, msg.sender, owed);
        emit UserClaimed(msg.sender, token, owed);
    }

    /// @notice View: what claimUser(token, 0) would pay `user` right now.
    function pendingUser(address user, address token) external view returns (uint256 owed) {
        Credit[] storage credits = _credits[token];
        BalCp[] storage cps = _balCps[user];
        uint256 len = credits.length;
        for (uint256 i = claimCursor[user][token]; i < len; ++i) {
            owed += _balanceAt(cps, credits[i].seq) * credits[i].perShare / ACC;
        }
    }

    /// @notice Number of credit events recorded for `token`.
    function creditCount(address token) external view returns (uint256) {
        return _credits[token].length;
    }

    /// @notice Number of balance checkpoints recorded for `user`.
    function checkpointCount(address user) external view returns (uint256) {
        return _balCps[user].length;
    }

    /// @dev Appends a credit event for `token`. totalShares > 0 is guaranteed
    ///      post-activation (dead shares are never redeemable).
    ///
    ///      The uint192 narrowing cannot truncate: `amount * ACC` reverts on
    ///      256-bit overflow first, bounding `amount ≤ 2^256/1e27 ≈ 1.16e50`,
    ///      and post-activation `totalShares ≥ ACTIVATION_MIN = 1e20`, so
    ///      `perShare ≤ 1.16e50 × 1e27 / 1e20 ≈ 1.16e57 < 2^192 ≈ 6.28e57`.
    function _credit(address token, uint256 amount) internal {
        uint256 perShare = amount * ACC / totalShares;
        _credits[token].push(Credit({seq: ++eventSeq, perShare: uint192(perShare)}));
    }

    /// @dev The user's share balance as of credit event `seq`: the latest
    ///      checkpoint written strictly before the sequence reached `seq`.
    function _balanceAt(BalCp[] storage cps, uint64 seq) internal view returns (uint256) {
        uint256 hi = cps.length;
        uint256 lo;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (cps[mid].seq < seq) lo = mid + 1;
            else hi = mid;
        }
        return lo == 0 ? 0 : cps[lo - 1].bal;
    }

    /// @dev Records `user`'s new balance at the current sequence. Same-seq
    ///      checkpoints overwrite (only the last balance before the next
    ///      credit event matters).
    ///
    ///      The uint192 narrowing cannot truncate: seed-phase shares are
    ///      capped at DEPOSIT_CAP = 1e22 (1:1), and every post-activation
    ///      mint preserves the shares:principal ratio (which only *falls* as
    ///      rebases/compounds/donations grow principal without minting), so
    ///      totalShares — and a fortiori any balance — stays within a few
    ///      parts in 1e17 of principal ≤ cap + compounded growth ≪ 2^192.
    function _checkpoint(address user, uint256 newBal) internal {
        BalCp[] storage cps = _balCps[user];
        uint256 len = cps.length;
        uint64 seq = eventSeq;
        if (len != 0 && cps[len - 1].seq == seq) {
            cps[len - 1].bal = uint192(newBal);
        } else {
            cps.push(BalCp({seq: seq, bal: uint192(newBal)}));
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Minimal ERC-20 shares (in-file per §5.1), checkpoint-aware
    // ─────────────────────────────────────────────────────────────────────────

    function totalSupply() external view returns (uint256) {
        return totalShares;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientShares();
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        if (to == address(0) || to == address(this)) revert TransferFailed();
        uint256 fromBal = balanceOf[from];
        if (fromBal < amount) revert InsufficientShares();
        balanceOf[from] = fromBal - amount;
        balanceOf[to] += amount;
        _checkpoint(from, fromBal - amount);
        _checkpoint(to, balanceOf[to]);
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        totalShares += amount;
        balanceOf[to] += amount;
        _checkpoint(to, balanceOf[to]);
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientShares();
        balanceOf[from] = bal - amount;
        totalShares -= amount;
        _checkpoint(from, bal - amount);
        emit Transfer(from, address(0), amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Token plumbing — low-level, weird-erc20 tolerant, no assembly
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Union-collect `add` into `set[0..count)`, reverting past the cap.
    function _collect(address[] memory set, uint256 count, address[] calldata add)
        internal
        pure
        returns (uint256)
    {
        for (uint256 i; i < add.length; ++i) {
            address t = add[i];
            bool seen;
            for (uint256 j; j < count; ++j) {
                if (set[j] == t) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                if (count == MAX_CLAIM_TOKENS) revert LengthMismatch();
                set[count++] = t;
            }
        }
        return count;
    }

    /// @dev Outbound transfer tolerating missing return data; rejects
    ///      addresses with no code (a codeless "token" would silently
    ///      succeed otherwise).
    function _push(address token, address to, uint256 amount) internal {
        if (token.code.length == 0) revert TransferFailed();
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    /// @dev Inbound AERO. AERO is a well-behaved ERC-20 (asserted in the fork
    ///      suite); the low-level pattern is used anyway for uniformity.
    function _pull(address from, uint256 amount) internal {
        (bool ok, bytes memory ret) =
            address(AERO).call(abi.encodeCall(IERC20.transferFrom, (from, address(this), amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    /// @dev Transient exact-amount approval AERO→escrow; consumed in full by
    ///      the follow-up escrow call (invariant 7).
    function _approveAero(address spender, uint256 amount) internal {
        (bool ok, bytes memory ret) = address(AERO).call(abi.encodeCall(IERC20.approve, (spender, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    /// @dev Live locked principal, straight from the escrow.
    function _lockedAmount() internal view returns (uint256) {
        int128 amt = VE.locked(tokenId).amount;
        return uint256(uint128(amt));
    }
}
