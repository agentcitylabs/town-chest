// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title The Agentcity Town Chest
/// @notice Where the Agentcity job market's cut goes. Every deposit is split
/// into three pots that each stay locked for a while, then go back to the
/// town: one is burned, one is spread to the holders of the town's token by
/// their balances, one is shared equally among the agents that completed the
/// most jobs in the period.
///
/// Who can do what, so a stolen server key can never take the money:
/// - Anyone can deposit, burn an unlocked Burn pot, and sweep stray tokens
///   into the pots.
/// - The keeper (the Agentcity server, a hot key) opens a holders' round
///   with a snapshot it computed, pays it out in batches, closes it, and
///   shares the Agents pot among at most ten addresses. It can only move pot
///   money, only once a pot's lock has passed, only to holders within the
///   fairness bound (no address gets more than SHARE_SLACK times what its
///   on-chain balance entitles it to) and never to an excluded address.
/// - The owner sets the keeper, the locks, the split, the exclusions, and
///   can pause. Pausing stops money leaving; deposits keep working, so the
///   market is never broken by a paused Town Chest.
/// - The owner's only way to move money elsewhere is a rescue: proposed in
///   public, executable after a delay that can only grow, cancellable until
///   then. It exists for a broken pot, not for a quiet exit, and its name
///   says what it is.
contract TownChest is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Pot {
        Burn,
        Holders,
        Agents
    }

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint16 public constant BPS = 10_000;
    uint8 public constant MOST_AGENTS = 10;
    uint16 public constant MOST_PER_BATCH = 300;
    /// @notice A holder may receive at most this many times its pro-rata share
    /// of the round, measured against the token's total supply at payment.
    uint8 public constant SHARE_SLACK = 2;
    uint64 public constant MIN_LOCK = 1 hours;
    uint64 public constant MAX_LOCK = 30 days;
    uint64 public constant INITIAL_RESCUE_DELAY = 48 hours;
    uint64 public constant MAX_RESCUE_DELAY = 30 days;

    struct Round {
        uint256 amount; // frozen when the round opened
        uint256 remaining; // not yet paid; goes back to the pot at close
        uint64 snapshotBlock; // the block the keeper read balances at
        uint32 holders; // how many the snapshot holds
        uint32 paid; // how many were paid so far
        bool open;
        bytes32 snapshotHash; // keccak256(abi.encode(address[] holders, uint256[] amounts))
    }

    struct Rescue {
        address token; // address(0) for ETH
        address to;
        uint256 amount;
        uint64 executableAt; // 0 when nothing is proposed
    }

    struct State {
        uint256[3] pots;
        uint64[3] lockSeconds;
        uint64[3] lastReleaseAt;
        uint16[3] splitBps;
        address keeper;
        bool paused;
        uint256 roundCount;
        Round round; // the latest round, open or not
        uint256 balance; // the token held here
        uint64 timestamp; // the chain's clock, for whoever reads this
    }

    IERC20 public immutable token;
    address public keeper;
    /// @notice Of each deposit, in basis points: Burn, Holders, Agents. They add up to BPS.
    uint16[3] public splitBps;
    uint64[3] public lockSeconds;
    uint64[3] public lastReleaseAt;
    uint256[3] public pots;
    /// @notice Addresses that never receive a holders' share or an agents' prize.
    mapping(address account => bool) public excluded;
    uint256 public roundCount;
    mapping(uint256 roundId => Round) internal _rounds;
    mapping(uint256 roundId => mapping(address holder => bool)) public paidIn;
    mapping(bytes32 periodId => bool) public agentsPaid;
    uint64 public rescueDelay;
    Rescue public pendingRescue;

    event Deposited(bytes32 indexed ref, address indexed from, uint256 amount, uint256 toBurn, uint256 toHolders, uint256 toAgents);
    event Swept(uint256 amount, uint256 toBurn, uint256 toHolders, uint256 toAgents);
    event Burned(uint256 amount);
    event HoldersRoundOpened(uint256 indexed roundId, uint256 amount, uint64 snapshotBlock, uint32 holders, bytes32 snapshotHash);
    event HolderPaid(uint256 indexed roundId, address indexed holder, uint256 amount);
    /// @notice A holder left out of a batch: already paid in this round (1), or over the fairness bound (2).
    event HolderSkipped(uint256 indexed roundId, address indexed holder, uint8 reason);
    event HoldersRoundClosed(uint256 indexed roundId, uint32 paid, uint256 returned);
    event AgentsShared(bytes32 indexed periodId, uint8 agents, uint256 each);
    event AgentPaid(bytes32 indexed periodId, address indexed agent, uint256 amount);
    event KeeperSet(address keeper);
    event LockSet(Pot pot, uint64 lockSeconds);
    event SplitSet(uint16 burnBps, uint16 holdersBps, uint16 agentsBps);
    event ExcludedSet(address indexed account, bool excluded);
    event RescueProposed(address indexed token, address indexed to, uint256 amount, uint64 executableAt);
    event RescueCancelled();
    event RescueExecuted(address indexed token, address indexed to, uint256 amount);
    event RescueDelaySet(uint64 rescueDelay);

    error NotKeeper();
    error BadAddress();
    error BadAmount();
    error BadLock();
    error BadSplit();
    error BadDelay();
    error Locked(Pot pot, uint64 until);
    error NothingToDo();
    error RoundOpen();
    error NoRound();
    error FutureBlock();
    error LengthMismatch();
    error TooMany();
    error Excluded(address account);
    error Duplicate(address account);
    error OverRemaining();
    error PeriodPaid(bytes32 periodId);
    error NoRescue();
    error TooEarly();
    error TransferFailed();

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    /// @param owner_ owns the Town Chest (sets the keeper, locks, split, exclusions, pause, rescue)
    /// @param keeper_ triggers releases: the Agentcity server's treasury, a hot key
    /// @param token_ the town's token
    /// @param locks how long each pot stays locked after a release: Burn, Holders, Agents
    /// @param excluded_ addresses that never receive a share (the pool, the router, the treasuries)
    constructor(address owner_, address keeper_, IERC20 token_, uint64[3] memory locks, address[] memory excluded_)
        Ownable(owner_)
    {
        if (keeper_ == address(0) || address(token_) == address(0)) revert BadAddress();
        token = token_;
        keeper = keeper_;
        emit KeeperSet(keeper_);
        splitBps = [uint16(2_500), uint16(5_000), uint16(2_500)];
        emit SplitSet(2_500, 5_000, 2_500);
        uint64 now_ = uint64(block.timestamp);
        for (uint256 i; i < 3; ++i) {
            if (locks[i] < MIN_LOCK || locks[i] > MAX_LOCK) revert BadLock();
            lockSeconds[i] = locks[i];
            lastReleaseAt[i] = now_;
            emit LockSet(Pot(i), locks[i]);
        }
        rescueDelay = INITIAL_RESCUE_DELAY;
        _exclude(address(this), true);
        _exclude(DEAD, true);
        _exclude(keeper_, true);
        for (uint256 i; i < excluded_.length; ++i) {
            _exclude(excluded_[i], true);
        }
    }

    // ------------------------------------------------------------------ views

    function rounds(uint256 roundId) external view returns (Round memory) {
        return _rounds[roundId];
    }

    /// @notice When a pot may next be released: its last release plus its lock.
    function unlocksAt(Pot pot) public view returns (uint64) {
        return lastReleaseAt[uint8(pot)] + lockSeconds[uint8(pot)];
    }

    /// @notice Whether a pot holds something and its lock has passed.
    function releasable(Pot pot) public view returns (bool) {
        return pots[uint8(pot)] > 0 && block.timestamp >= unlocksAt(pot);
    }

    /// @notice Everything a reader needs in one call.
    function state() external view returns (State memory s) {
        s.pots = pots;
        s.lockSeconds = lockSeconds;
        s.lastReleaseAt = lastReleaseAt;
        s.splitBps = splitBps;
        s.keeper = keeper;
        s.paused = paused();
        s.roundCount = roundCount;
        s.round = _rounds[roundCount];
        s.balance = token.balanceOf(address(this));
        s.timestamp = uint64(block.timestamp);
    }

    // ----------------------------------------------------------------- anyone

    /// @notice Puts `amount` of the token into the pots. Approve this contract
    /// first. `ref` is the depositor's own reference (Agentcity: the order).
    /// Deposits work while paused: the market must never be stopped by the
    /// Chest.
    function deposit(uint256 amount, bytes32 ref) external nonReentrant {
        if (amount == 0) revert BadAmount();
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 got = token.balanceOf(address(this)) - before;
        if (got == 0) revert BadAmount();
        (uint256 toBurn, uint256 toHolders, uint256 toAgents) = _pot(got);
        emit Deposited(ref, msg.sender, got, toBurn, toHolders, toAgents);
    }

    /// @notice Sends the Burn pot to the dead address once its lock has passed.
    function burn() external whenNotPaused nonReentrant {
        uint256 amount = _release(Pot.Burn);
        token.safeTransfer(DEAD, amount);
        emit Burned(amount);
    }

    /// @notice Puts tokens that arrived outside deposit() into the pots, so
    /// nothing sent here by hand is ever stuck.
    function sweep() external whenNotPaused nonReentrant {
        uint256 balance = token.balanceOf(address(this));
        uint256 held = pots[0] + pots[1] + pots[2] + _openRemaining();
        if (balance <= held) revert NothingToDo();
        uint256 stray = balance - held;
        (uint256 toBurn, uint256 toHolders, uint256 toAgents) = _pot(stray);
        emit Swept(stray, toBurn, toHolders, toAgents);
    }

    // ----------------------------------------------------------------- keeper

    /// @notice Freezes the Holders pot into a round the keeper then pays out
    /// in batches. `snapshotBlock` is the block the keeper read balances at,
    /// `holders` how many it will pay, `snapshotHash` the hash of its list,
    /// so anyone can check the published list against what was paid.
    function openHoldersRound(uint64 snapshotBlock, uint32 holders, bytes32 snapshotHash)
        external
        onlyKeeper
        whenNotPaused
        returns (uint256 roundId)
    {
        if (_rounds[roundCount].open) revert RoundOpen();
        if (snapshotBlock > block.number) revert FutureBlock();
        if (holders == 0) revert BadAmount();
        uint256 amount = _release(Pot.Holders);
        roundId = ++roundCount;
        _rounds[roundId] = Round({
            amount: amount,
            remaining: amount,
            snapshotBlock: snapshotBlock,
            holders: holders,
            paid: 0,
            open: true,
            snapshotHash: snapshotHash
        });
        emit HoldersRoundOpened(roundId, amount, snapshotBlock, holders, snapshotHash);
    }

    /// @notice Pays one batch of a round. A holder already paid in this round
    /// is skipped, so a batch sent twice pays once; a holder whose share is
    /// over the fairness bound (it sold since the snapshot, or the list is
    /// wrong) is skipped too, and its share goes back to the pot at close.
    /// An excluded or zero address, or more than the round holds, is a
    /// keeper mistake and reverts the batch.
    function payHolders(uint256 roundId, address[] calldata to, uint256[] calldata amounts)
        external
        onlyKeeper
        whenNotPaused
        nonReentrant
    {
        Round storage round = _rounds[roundId];
        if (!round.open) revert NoRound();
        if (to.length != amounts.length) revert LengthMismatch();
        if (to.length == 0 || to.length > MOST_PER_BATCH) revert TooMany();
        uint256 supply = token.totalSupply();
        uint256 bound = uint256(SHARE_SLACK) * round.amount;
        for (uint256 i; i < to.length; ++i) {
            address holder = to[i];
            uint256 amount = amounts[i];
            if (holder == address(0)) revert BadAddress();
            if (excluded[holder]) revert Excluded(holder);
            // Skipped before the amount is checked: a batch sent again after
            // it landed has nothing left in the round and must still pass.
            if (paidIn[roundId][holder]) {
                emit HolderSkipped(roundId, holder, 1);
                continue;
            }
            if (amount == 0) revert BadAmount();
            if (amount > round.remaining) revert OverRemaining();
            if (amount * supply > bound * token.balanceOf(holder)) {
                emit HolderSkipped(roundId, holder, 2);
                continue;
            }
            paidIn[roundId][holder] = true;
            round.remaining -= amount;
            round.paid += 1;
            token.safeTransfer(holder, amount);
            emit HolderPaid(roundId, holder, amount);
        }
    }

    /// @notice Ends a round: what was not paid goes back to the Holders pot
    /// for the next one.
    function closeHoldersRound(uint256 roundId) external onlyKeeper {
        Round storage round = _rounds[roundId];
        if (!round.open) revert NoRound();
        round.open = false;
        uint256 returned = round.remaining;
        round.remaining = 0;
        pots[uint8(Pot.Holders)] += returned;
        emit HoldersRoundClosed(roundId, round.paid, returned);
    }

    /// @notice Shares the Agents pot equally among at most ten addresses, once
    /// per period. Rounding dust stays in the pot.
    function shareAgents(bytes32 periodId, address[] calldata agents) external onlyKeeper whenNotPaused nonReentrant {
        if (agentsPaid[periodId]) revert PeriodPaid(periodId);
        uint256 n = agents.length;
        if (n == 0 || n > MOST_AGENTS) revert TooMany();
        for (uint256 i; i < n; ++i) {
            address agent = agents[i];
            if (agent == address(0)) revert BadAddress();
            if (excluded[agent]) revert Excluded(agent);
            for (uint256 j; j < i; ++j) {
                if (agents[j] == agent) revert Duplicate(agent);
            }
        }
        uint8 pot = uint8(Pot.Agents);
        if (pots[pot] == 0) revert NothingToDo();
        uint64 until = unlocksAt(Pot.Agents);
        if (block.timestamp < until) revert Locked(Pot.Agents, until);
        uint256 each = pots[pot] / n;
        if (each == 0) revert NothingToDo();
        pots[pot] -= each * n;
        lastReleaseAt[pot] = uint64(block.timestamp);
        agentsPaid[periodId] = true;
        emit AgentsShared(periodId, uint8(n), each);
        for (uint256 i; i < n; ++i) {
            token.safeTransfer(agents[i], each);
            emit AgentPaid(periodId, agents[i], each);
        }
    }

    // ------------------------------------------------------------------ owner

    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert BadAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setLock(Pot pot, uint64 lockSeconds_) external onlyOwner {
        if (lockSeconds_ < MIN_LOCK || lockSeconds_ > MAX_LOCK) revert BadLock();
        lockSeconds[uint8(pot)] = lockSeconds_;
        emit LockSet(pot, lockSeconds_);
    }

    /// @notice How each deposit is split, in basis points. Applies to deposits
    /// from now on; the pots already filled keep what they have.
    function setSplit(uint16 burnBps, uint16 holdersBps, uint16 agentsBps) external onlyOwner {
        if (uint256(burnBps) + holdersBps + agentsBps != BPS) revert BadSplit();
        splitBps = [burnBps, holdersBps, agentsBps];
        emit SplitSet(burnBps, holdersBps, agentsBps);
    }

    /// @notice Addresses that never receive a share. This contract and the
    /// dead address stay excluded.
    function setExcluded(address[] calldata accounts, bool flag) external onlyOwner {
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            if (!flag && (account == address(this) || account == DEAD)) revert BadAddress();
            _exclude(account, flag);
        }
    }

    /// @notice Stops money leaving: burns, rounds, shares and sweeps. Deposits keep working.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Proposes to move `amount` of `token_` (address(0): ETH) to
    /// `to`, in public, executable after rescueDelay. For a pot that cannot
    /// be released because something broke, never a shortcut.
    function proposeRescue(address token_, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert BadAddress();
        if (amount == 0) revert BadAmount();
        uint64 executableAt = uint64(block.timestamp) + rescueDelay;
        pendingRescue = Rescue({token: token_, to: to, amount: amount, executableAt: executableAt});
        emit RescueProposed(token_, to, amount, executableAt);
    }

    function cancelRescue() external onlyOwner {
        if (pendingRescue.executableAt == 0) revert NoRescue();
        delete pendingRescue;
        emit RescueCancelled();
    }

    /// @notice Carries out the proposed rescue once its delay has passed. A
    /// rescue of the town's token empties the pots and closes any open round:
    /// the accounting starts over, and sweep() puts whatever is left back
    /// into the pots.
    function executeRescue() external onlyOwner nonReentrant {
        Rescue memory rescue = pendingRescue;
        if (rescue.executableAt == 0) revert NoRescue();
        if (block.timestamp < rescue.executableAt) revert TooEarly();
        delete pendingRescue;
        if (rescue.token == address(0)) {
            (bool ok,) = rescue.to.call{value: rescue.amount}("");
            if (!ok) revert TransferFailed();
        } else {
            if (rescue.token == address(token)) _emptyPots();
            IERC20(rescue.token).safeTransfer(rescue.to, rescue.amount);
        }
        emit RescueExecuted(rescue.token, rescue.to, rescue.amount);
    }

    /// @notice The rescue delay can only grow.
    function setRescueDelay(uint64 rescueDelay_) external onlyOwner {
        if (rescueDelay_ < rescueDelay || rescueDelay_ > MAX_RESCUE_DELAY) revert BadDelay();
        rescueDelay = rescueDelay_;
        emit RescueDelaySet(rescueDelay_);
    }

    // --------------------------------------------------------------- internal

    function _pot(uint256 amount) private returns (uint256 toBurn, uint256 toHolders, uint256 toAgents) {
        toHolders = (amount * splitBps[1]) / BPS;
        toAgents = (amount * splitBps[2]) / BPS;
        toBurn = amount - toHolders - toAgents; // rounding dust burns
        pots[0] += toBurn;
        pots[1] += toHolders;
        pots[2] += toAgents;
    }

    /// Takes a whole pot out once its lock has passed, and starts the next lock.
    function _release(Pot pot) private returns (uint256 amount) {
        uint8 p = uint8(pot);
        amount = pots[p];
        if (amount == 0) revert NothingToDo();
        uint64 until = unlocksAt(pot);
        if (block.timestamp < until) revert Locked(pot, until);
        pots[p] = 0;
        lastReleaseAt[p] = uint64(block.timestamp);
    }

    function _openRemaining() private view returns (uint256) {
        Round storage round = _rounds[roundCount];
        return round.open ? round.remaining : 0;
    }

    function _emptyPots() private {
        pots = [uint256(0), 0, 0];
        Round storage round = _rounds[roundCount];
        if (round.open) {
            round.open = false;
            round.remaining = 0;
            emit HoldersRoundClosed(roundCount, round.paid, 0);
        }
    }

    function _exclude(address account, bool flag) private {
        if (account == address(0)) revert BadAddress();
        excluded[account] = flag;
        emit ExcludedSet(account, flag);
    }
}
