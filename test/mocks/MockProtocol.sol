// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev Minimal mock of the Aerodrome v2 surface EpochPilot touches, faithful
///      to the gates asserted in the fork suite: epoch arithmetic, one vote
///      per epoch, distribute-window and last-hour blocks, weight
///      normalization, voted-flag semantics, expired-lock withdraw, and
///      rebase auto-compounding. Test-only code — never deployed.

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) public virtual returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) public virtual returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amt, "allow");
            allowance[from][msg.sender] -= amt;
        }
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }
}

/// @dev Takes a cut on every transfer — weird-erc20 "fee on transfer".
contract FeeOnTransferToken is MockERC20 {
    uint256 public constant FEE_BPS = 100; // 1%

    constructor() MockERC20("Fee Token", "FEE") {}

    function transfer(address to, uint256 amt) public override returns (bool) {
        uint256 fee = amt * FEE_BPS / 10_000;
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt - fee;
        totalSupply -= fee; // burn the fee
        return true;
    }
}

/// @dev Reverts on every transfer once tripped — weird-erc20 "reverting".
contract RevertingToken is MockERC20 {
    bool public bricked;

    constructor() MockERC20("Brick Token", "BRICK") {}

    function setBricked(bool b) external {
        bricked = b;
    }

    function transfer(address to, uint256 amt) public override returns (bool) {
        require(!bricked, "bricked");
        return super.transfer(to, amt);
    }
}

/// @dev Burns an EXTRA 1% from the sender on every transfer (beyond the
///      amount delivered) — the weird-erc20 case where the vault's balance
///      falls by more than it pays out, leaving naive credits unbacked.
contract BurnySenderToken is MockERC20 {
    uint256 public constant BURN_BPS = 100; // extra 1% torched from sender

    constructor() MockERC20("Burny Token", "BURNY") {}

    function transfer(address to, uint256 amt) public override returns (bool) {
        uint256 burn = amt * BURN_BPS / 10_000;
        require(balanceOf[msg.sender] >= amt + burn, "bal");
        balanceOf[msg.sender] -= amt + burn;
        balanceOf[to] += amt;
        totalSupply -= burn;
        return true;
    }
}

/// @dev Lies about its balance: reported balance grows with gas consumed so
///      far in the transaction, so a later (post-claim) read always exceeds an
///      earlier (pre-claim) read and any delta measurement sees a phantom
///      inflow — without touching state (balanceOf is STATICCALLed through the
///      view interface). Models a malicious "token" a claim caller sneaks
///      into their own token list.
contract PhantomBalanceToken {
    function balanceOf(address) external view returns (uint256) {
        return (type(uint64).max - gasleft()) * 1e12;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }
}

/// @dev Reenters the vault from inside its own transfer — the reentrancy probe.
///      Same gas-based phantom balance so the vault owes it a bounty push.
///      Records whether the reentry attempt was blocked instead of bubbling
///      the revert, so tests can assert the latch tripped.
contract ReentrantToken {
    address public target;
    bytes public payload;
    bool public attempted;
    bool public blocked;
    bytes4 public blockReason;

    function arm(address target_, address token_) external {
        target = target_;
        payload = abi.encodeWithSignature("claimUser(address,uint256)", token_, 0);
    }

    /// @dev Generic variant: reenter with arbitrary calldata.
    function armCall(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function balanceOf(address) external view returns (uint256) {
        return (type(uint64).max - gasleft()) * 1e12;
    }

    function transfer(address, uint256) external returns (bool) {
        // bounce straight back into the vault; the transient latch must trip
        attempted = true;
        (bool ok, bytes memory ret) = target.call(payload);
        if (!ok) {
            blocked = true;
            if (ret.length >= 4) blockReason = bytes4(ret);
        }
        return true;
    }
}

/// @dev Returns nothing on transfer (USDT-style) — weird-erc20 "missing return".
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        // no return value
    }
}

contract MockVotingEscrow {
    struct LockedBalance {
        int128 amount;
        uint256 end;
        bool isPermanent;
    }

    uint256 internal constant WEEK = 7 days;
    MockERC20 public immutable aero;
    address public voter;
    address public distributor;
    uint256 public nextId = 1;
    mapping(uint256 => LockedBalance) internal _locked;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => bool) public voted;

    constructor(MockERC20 aero_) {
        aero = aero_;
    }

    function setVoter(address v) external {
        voter = v;
    }

    function setDistributor(address d) external {
        distributor = d;
    }

    function token() external view returns (address) {
        return address(aero);
    }

    function locked(uint256 id) external view returns (LockedBalance memory) {
        return _locked[id];
    }

    function createLock(uint256 value, uint256 duration) external returns (uint256 id) {
        require(value > 0, "zero");
        uint256 end = (block.timestamp + duration) / WEEK * WEEK;
        require(end > block.timestamp, "short");
        aero.transferFrom(msg.sender, address(this), value);
        id = nextId++;
        _locked[id] = LockedBalance(int128(int256(value)), end, false);
        ownerOf[id] = msg.sender;
        // Mirrors the live escrow: safe-mint callback into contract receivers.
        if (msg.sender.code.length > 0) {
            (bool ok, bytes memory ret) = msg.sender.call(
                abi.encodeWithSignature(
                    "onERC721Received(address,address,uint256,bytes)", msg.sender, address(0), id, ""
                )
            );
            require(ok && ret.length >= 32, "unsafe receiver");
        }
    }

    function increaseAmount(uint256 id, uint256 value) external {
        require(ownerOf[id] == msg.sender, "auth");
        require(value > 0, "zero");
        LockedBalance storage l = _locked[id];
        require(l.end > block.timestamp, "expired");
        aero.transferFrom(msg.sender, address(this), value);
        l.amount += int128(int256(value));
    }

    /// @dev Permissionless top-up, as on the live escrow (used by the distributor).
    function depositFor(uint256 id, uint256 value) external {
        LockedBalance storage l = _locked[id];
        require(l.end > block.timestamp, "expired");
        aero.transferFrom(msg.sender, address(this), value);
        l.amount += int128(int256(value));
    }

    function withdraw(uint256 id) external {
        require(ownerOf[id] == msg.sender, "auth");
        require(!voted[id], "voted");
        LockedBalance memory l = _locked[id];
        require(l.end <= block.timestamp, "not expired");
        delete _locked[id];
        delete ownerOf[id];
        aero.transfer(msg.sender, uint256(uint128(l.amount)));
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == msg.sender && from == msg.sender, "auth");
        ownerOf[id] = to;
        if (to.code.length > 0) {
            (bool ok, bytes memory ret) = to.call(
                abi.encodeWithSignature(
                    "onERC721Received(address,address,uint256,bytes)", msg.sender, from, id, ""
                )
            );
            require(ok && ret.length >= 32, "unsafe receiver");
        }
    }

    function balanceOfNFT(uint256 id) public view returns (uint256) {
        LockedBalance memory l = _locked[id];
        if (l.end <= block.timestamp) return 0;
        return uint256(uint128(l.amount)) * (l.end - block.timestamp) / (4 * 365 days);
    }

    function isApprovedOrOwner(address who, uint256 id) external view returns (bool) {
        return ownerOf[id] == who;
    }

    function setVoted(uint256 id, bool v) external {
        require(msg.sender == voter, "auth");
        voted[id] = v;
    }
}

contract MockReward {
    MockVotingEscrow public immutable ve;
    // token => tokenId => earned
    mapping(address => mapping(uint256 => uint256)) public earned;

    constructor(MockVotingEscrow ve_) {
        ve = ve_;
    }

    function notify(address token, uint256 tokenId, uint256 amt) external {
        earned[token][tokenId] += amt;
    }

    function getReward(uint256 tokenId, address[] calldata tokens) external {
        address owner = ve.ownerOf(tokenId);
        for (uint256 i; i < tokens.length; ++i) {
            uint256 amt = earned[tokens[i]][tokenId];
            if (amt == 0) continue;
            earned[tokens[i]][tokenId] = 0;
            // tolerate no-return tokens like the live SafeERC20 does
            (bool ok,) = tokens[i].call(abi.encodeWithSignature("transfer(address,uint256)", owner, amt));
            require(ok, "reward xfer");
        }
    }
}

/// @dev Weekly-emissions minter stub: only the staleness signal matters here.
contract MockMinter {
    uint256 internal constant WEEK = 7 days;
    uint256 public activePeriod;
    bool public halted;

    function setHalted(bool h) external {
        halted = h;
    }

    /// @dev Anyone may roll the period forward, exactly like the live Minter.
    function updatePeriod() external {
        if (!halted) activePeriod = (block.timestamp / WEEK) * WEEK;
    }
}

contract MockVoter {
    uint256 internal constant WEEK = 7 days;
    uint256 internal constant HOUR = 1 hours;

    MockVotingEscrow public immutable escrow;
    address public minter;
    uint256 public maxVotingNum = 60;
    uint256 public totalWeight;
    mapping(address => uint256) public weights;
    mapping(uint256 => mapping(address => uint256)) public votes;
    mapping(uint256 => uint256) public usedWeights;
    mapping(uint256 => uint256) public lastVoted;
    mapping(address => address) public gauges;
    mapping(address => bool) public isGauge;
    mapping(address => bool) public isAlive;
    mapping(address => address) public gaugeToFees;
    mapping(address => address) public gaugeToBribe;
    mapping(address => address) public poolForGauge;
    mapping(uint256 => address[]) internal _poolVote;

    constructor(MockVotingEscrow ve_) {
        escrow = ve_;
    }

    function ve() external view returns (address) {
        return address(escrow);
    }

    function setMinter(address m) external {
        minter = m;
    }

    function setMaxVotingNum(uint256 n) external {
        maxVotingNum = n;
    }

    /// @dev Registers a pool+gauge with fee/bribe reward contracts and seeds
    ///      external market weight on it.
    function addGauge(address pool, address gauge, address feesC, address bribeC, uint256 marketWeight)
        external
    {
        gauges[pool] = gauge;
        isGauge[gauge] = true;
        isAlive[gauge] = true;
        gaugeToFees[gauge] = feesC;
        gaugeToBribe[gauge] = bribeC;
        poolForGauge[gauge] = pool;
        weights[pool] += marketWeight;
        totalWeight += marketWeight;
    }

    function killGauge(address gauge) external {
        isAlive[gauge] = false;
    }

    function epochStart(uint256 ts) public pure returns (uint256) {
        return ts - (ts % WEEK);
    }

    function epochNext(uint256 ts) public pure returns (uint256) {
        return epochStart(ts) + WEEK;
    }

    function epochVoteStart(uint256 ts) public pure returns (uint256) {
        return epochStart(ts) + HOUR;
    }

    function epochVoteEnd(uint256 ts) public pure returns (uint256) {
        return epochNext(ts) - HOUR;
    }

    /// @dev Live-Voter gates: once per epoch, not in the first hour, not in
    ///      the last hour (mock has no whitelist), weight normalization over
    ///      the NFT's current balance.
    function vote(uint256 tokenId, address[] calldata poolVote, uint256[] calldata weights_) external {
        require(escrow.isApprovedOrOwner(msg.sender, tokenId), "auth");
        require(lastVoted[tokenId] < epochStart(block.timestamp), "already voted");
        require(block.timestamp > epochVoteStart(block.timestamp), "distribute window");
        require(block.timestamp <= epochVoteEnd(block.timestamp), "not whitelisted");
        require(poolVote.length == weights_.length, "len");
        require(poolVote.length <= maxVotingNum, "max");
        uint256 balance = escrow.balanceOfNFT(tokenId);
        require(balance > 0, "zero balance");
        _reset(tokenId);
        uint256 totalVoteWeight;
        for (uint256 i; i < poolVote.length; ++i) {
            totalVoteWeight += weights_[i];
        }
        for (uint256 i; i < poolVote.length; ++i) {
            address gauge = gauges[poolVote[i]];
            require(gauge != address(0) && isAlive[gauge], "gauge");
            uint256 w = weights_[i] * balance / totalVoteWeight;
            require(w > 0, "zero vote");
            require(votes[tokenId][poolVote[i]] == 0, "dup");
            votes[tokenId][poolVote[i]] = w;
            weights[poolVote[i]] += w;
            totalWeight += w;
            usedWeights[tokenId] += w;
            _poolVote[tokenId].push(poolVote[i]);
        }
        lastVoted[tokenId] = block.timestamp;
        escrow.setVoted(tokenId, true);
    }

    function reset(uint256 tokenId) external {
        require(escrow.isApprovedOrOwner(msg.sender, tokenId), "auth");
        require(lastVoted[tokenId] < epochStart(block.timestamp), "already voted");
        require(block.timestamp > epochVoteStart(block.timestamp), "distribute window");
        _reset(tokenId);
        lastVoted[tokenId] = block.timestamp;
        escrow.setVoted(tokenId, false);
    }

    function _reset(uint256 tokenId) internal {
        address[] storage pools = _poolVote[tokenId];
        for (uint256 i; i < pools.length; ++i) {
            uint256 v = votes[tokenId][pools[i]];
            weights[pools[i]] -= v;
            totalWeight -= v;
            votes[tokenId][pools[i]] = 0;
        }
        delete _poolVote[tokenId];
        usedWeights[tokenId] = 0;
    }

    function claimFees(address[] calldata fees, address[][] calldata tokens, uint256 tokenId) external {
        require(escrow.isApprovedOrOwner(msg.sender, tokenId), "auth");
        for (uint256 i; i < fees.length; ++i) {
            MockReward(fees[i]).getReward(tokenId, tokens[i]);
        }
    }

    function claimBribes(address[] calldata bribes, address[][] calldata tokens, uint256 tokenId) external {
        require(escrow.isApprovedOrOwner(msg.sender, tokenId), "auth");
        for (uint256 i; i < bribes.length; ++i) {
            MockReward(bribes[i]).getReward(tokenId, tokens[i]);
        }
    }
}

contract MockRewardsDistributor {
    uint256 internal constant WEEK = 7 days;
    MockVotingEscrow public immutable escrow;
    MockERC20 public immutable aero;
    MockMinter public immutable minterC;
    mapping(uint256 => uint256) public claimable;

    constructor(MockVotingEscrow ve_, MockERC20 aero_, MockMinter minter_) {
        escrow = ve_;
        aero = aero_;
        minterC = minter_;
    }

    function ve() external view returns (address) {
        return address(escrow);
    }

    function minter() external view returns (address) {
        return address(minterC);
    }

    function setClaimable(uint256 id, uint256 amt) external {
        claimable[id] = amt;
    }

    /// @dev Live semantics (G10): permissionless; unexpired → depositFor
    ///      (auto-compound), expired → transfer to owner. Refuses claims
    ///      while the minter's period is stale, exactly like the deployed
    ///      distributor (observed revert "FZ5" on mainnet).
    function claim(uint256 id) external returns (uint256 amt) {
        require(minterC.activePeriod() >= (block.timestamp / WEEK) * WEEK, "FZ5");
        amt = claimable[id];
        if (amt == 0) return 0;
        claimable[id] = 0;
        MockVotingEscrow.LockedBalance memory l = escrow.locked(id);
        if (l.end > block.timestamp) {
            aero.approve(address(escrow), amt);
            escrow.depositFor(id, amt);
        } else {
            aero.transfer(escrow.ownerOf(id), amt);
        }
    }
}
