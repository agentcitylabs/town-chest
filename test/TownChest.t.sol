// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TownChest as Chest} from "../src/TownChest.sol";
import {FeeOnTransferToken, MockCity, RejectsEth} from "./Mocks.sol";

contract TownChestTest is Test {
    uint64 constant DAY = 1 days;
    uint256 constant SUPPLY = 1_000_000_000 ether;

    Chest chest;
    MockCity city;
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address treasury = makeAddr("treasury");
    address pool = makeAddr("pool");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address[] agents;

    function setUp() public {
        vm.warp(1_700_000_000);
        city = new MockCity();
        address[] memory excluded = new address[](1);
        excluded[0] = pool;
        chest = new Chest(owner, keeper, IERC20(address(city)), [DAY, DAY, DAY], excluded);
        // The supply: most of it in the pool and a few holders, the treasury has what it deposits.
        city.mint(pool, 200_000_000 ether);
        city.mint(alice, 300_000_000 ether);
        city.mint(bob, 200_000_000 ether);
        city.mint(carol, 100_000_000 ether);
        city.mint(treasury, 200_000_000 ether);
        assertEq(city.totalSupply(), SUPPLY);
        vm.prank(treasury);
        city.approve(address(chest), type(uint256).max);
    }

    function deposit(uint256 amount) internal {
        vm.prank(treasury);
        chest.deposit(amount, keccak256("order"));
    }

    function pots() internal view returns (uint256 b, uint256 h, uint256 a) {
        return (chest.pots(0), chest.pots(1), chest.pots(2));
    }

    // ---------------------------------------------------------------- deposit

    function test_depositSplitsIntoThreePots() public {
        vm.expectEmit(true, true, false, true);
        emit Chest.Deposited(keccak256("order"), treasury, 1_000 ether, 250 ether, 500 ether, 250 ether);
        deposit(1_000 ether);
        (uint256 b, uint256 h, uint256 a) = pots();
        assertEq(b, 250 ether);
        assertEq(h, 500 ether);
        assertEq(a, 250 ether);
        assertEq(city.balanceOf(address(chest)), 1_000 ether);
    }

    function testFuzz_depositNeverLosesADust(uint256 amount) public {
        amount = bound(amount, 1, 100_000_000 ether);
        deposit(amount);
        (uint256 b, uint256 h, uint256 a) = pots();
        assertEq(b + h + a, amount, "every wei lands in a pot");
        assertEq(h, (amount * 5_000) / 10_000);
        assertEq(a, (amount * 2_500) / 10_000);
        assertGe(b, (amount * 2_500) / 10_000, "the dust burns");
    }

    function test_depositCountsWhatArrived() public {
        FeeOnTransferToken taxed = new FeeOnTransferToken();
        Chest taxedChest = new Chest(owner, keeper, IERC20(address(taxed)), [DAY, DAY, DAY], new address[](0));
        taxed.mint(treasury, 1_000 ether);
        vm.startPrank(treasury);
        taxed.approve(address(taxedChest), type(uint256).max);
        taxedChest.deposit(1_000 ether, bytes32(0));
        vm.stopPrank();
        assertEq(taxedChest.pots(0) + taxedChest.pots(1) + taxedChest.pots(2), 990 ether);
    }

    function test_depositRefusesNothing() public {
        vm.prank(treasury);
        vm.expectRevert(Chest.BadAmount.selector);
        chest.deposit(0, bytes32(0));
    }

    function test_depositWorksWhilePaused() public {
        vm.prank(owner);
        chest.pause();
        deposit(10 ether);
        assertEq(chest.pots(1), 5 ether);
    }

    function test_sweepPotsStrayTokens() public {
        vm.prank(alice);
        city.transfer(address(chest), 100 ether);
        vm.expectEmit(false, false, false, true);
        emit Chest.Swept(100 ether, 25 ether, 50 ether, 25 ether);
        chest.sweep();
        assertEq(chest.pots(1), 50 ether);
        vm.expectRevert(Chest.NothingToDo.selector);
        chest.sweep();
    }

    // ------------------------------------------------------------------- burn

    function test_burnWaitsForTheLockThenSendsToDead() public {
        deposit(1_000 ether);
        vm.expectRevert(abi.encodeWithSelector(Chest.Locked.selector, Chest.Pot.Burn, uint64(block.timestamp) + DAY));
        chest.burn();
        vm.warp(block.timestamp + DAY);
        assertTrue(chest.releasable(Chest.Pot.Burn));
        vm.prank(alice); // anyone
        vm.expectEmit(false, false, false, true);
        emit Chest.Burned(250 ether);
        chest.burn();
        assertEq(city.balanceOf(chest.DEAD()), 250 ether);
        assertEq(chest.pots(0), 0);
        assertEq(chest.lastReleaseAt(0), uint64(block.timestamp), "the next lock starts now");
        vm.expectRevert(Chest.NothingToDo.selector);
        chest.burn();
    }

    function test_releaseLocksRunFromTheLastRelease() public {
        deposit(1_000 ether);
        vm.warp(block.timestamp + DAY);
        chest.burn();
        deposit(1_000 ether);
        vm.warp(block.timestamp + DAY - 1);
        assertFalse(chest.releasable(Chest.Pot.Burn));
        vm.warp(block.timestamp + 1);
        assertTrue(chest.releasable(Chest.Pot.Burn));
    }

    // ---------------------------------------------------------------- holders

    function snapshot() internal view returns (address[] memory to, uint256[] memory amounts) {
        // Pro rata among alice, bob and carol (the pool and the treasury are left out): 600M in all.
        to = new address[](3);
        amounts = new uint256[](3);
        to[0] = alice;
        to[1] = bob;
        to[2] = carol;
        uint256 amount = chest.pots(1);
        amounts[0] = (amount * 300) / 600;
        amounts[1] = (amount * 200) / 600;
        amounts[2] = (amount * 100) / 600;
    }

    function openRound() internal returns (uint256 roundId, address[] memory to, uint256[] memory amounts) {
        (to, amounts) = snapshot();
        bytes32 hash = keccak256(abi.encode(to, amounts));
        vm.prank(keeper);
        roundId = chest.openHoldersRound(uint64(block.number), uint32(to.length), hash);
    }

    function test_holdersRoundPaysTheSnapshotInBatchesAndCloses() public {
        deposit(1_200 ether); // 600 to holders
        vm.warp(block.timestamp + DAY);
        (uint256 roundId, address[] memory to, uint256[] memory amounts) = openRound();
        assertEq(roundId, 1);
        Chest.Round memory r = chest.rounds(1);
        assertEq(r.amount, 600 ether);
        assertEq(r.remaining, 600 ether);
        assertTrue(r.open);
        assertEq(chest.pots(1), 0, "the pot is frozen into the round");

        // Deposits during the round fill the next pot, not this round.
        deposit(100 ether);
        assertEq(chest.pots(1), 50 ether);
        assertEq(chest.rounds(1).remaining, 600 ether);

        // Two batches.
        address[] memory first = new address[](2);
        uint256[] memory firstAmounts = new uint256[](2);
        (first[0], first[1], firstAmounts[0], firstAmounts[1]) = (to[0], to[1], amounts[0], amounts[1]);
        address[] memory second = new address[](1);
        uint256[] memory secondAmounts = new uint256[](1);
        (second[0], secondAmounts[0]) = (to[2], amounts[2]);
        vm.startPrank(keeper);
        chest.payHolders(1, first, firstAmounts);
        chest.payHolders(1, second, secondAmounts);
        vm.stopPrank();
        assertEq(city.balanceOf(alice), 300_000_000 ether + 300 ether);
        assertEq(city.balanceOf(bob), 200_000_000 ether + 200 ether);
        assertEq(city.balanceOf(carol), 100_000_000 ether + 100 ether);
        assertEq(chest.rounds(1).paid, 3);
        assertEq(chest.rounds(1).remaining, 0);

        vm.prank(keeper);
        vm.expectEmit(true, false, false, true);
        emit Chest.HoldersRoundClosed(1, 3, 0);
        chest.closeHoldersRound(1);
        assertFalse(chest.rounds(1).open);
    }

    function test_holdersRoundSkipsAHolderPaidTwiceAndReturnsTheRest() public {
        deposit(1_200 ether);
        vm.warp(block.timestamp + DAY);
        (uint256 roundId, address[] memory to, uint256[] memory amounts) = openRound();
        vm.startPrank(keeper);
        chest.payHolders(roundId, to, amounts);
        // The same batch again (a lost reply, resent): nobody is paid twice.
        vm.expectEmit(true, true, false, true);
        emit Chest.HolderSkipped(roundId, alice, 1);
        chest.payHolders(roundId, to, amounts);
        vm.stopPrank();
        assertEq(city.balanceOf(alice), 300_000_000 ether + 300 ether);

        // A round where one holder is never paid: its share goes back to the pot.
        deposit(1_200 ether);
        vm.warp(block.timestamp + DAY);
        vm.prank(keeper);
        chest.closeHoldersRound(1);
        (uint256 round2, address[] memory to2, uint256[] memory amounts2) = openRound();
        address[] memory some = new address[](1);
        uint256[] memory someAmounts = new uint256[](1);
        (some[0], someAmounts[0]) = (to2[0], amounts2[0]);
        vm.startPrank(keeper);
        chest.payHolders(round2, some, someAmounts);
        chest.closeHoldersRound(round2);
        vm.stopPrank();
        assertEq(chest.pots(1), 600 ether - amounts2[0], "what was not paid is back in the pot");
    }

    function test_holdersRoundFairnessBound() public {
        deposit(1_200 ether);
        vm.warp(block.timestamp + DAY);
        (uint256 roundId,,) = openRound();
        // Carol holds 10% of supply. Pro rata of the round among the three is 1/6 = 100; the
        // bound is 2 × 10% × 600 = 120. 120 passes, 121 is skipped.
        address[] memory to = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        to[0] = carol;
        amounts[0] = 121 ether;
        vm.startPrank(keeper);
        vm.expectEmit(true, true, false, true);
        emit Chest.HolderSkipped(roundId, carol, 2);
        chest.payHolders(roundId, to, amounts);
        assertEq(city.balanceOf(carol), 100_000_000 ether, "an oversized share is skipped");
        amounts[0] = 120 ether;
        chest.payHolders(roundId, to, amounts);
        assertEq(city.balanceOf(carol), 100_000_000 ether + 120 ether);
        vm.stopPrank();

        // A holder who sold everything after the snapshot is skipped too.
        vm.prank(bob);
        city.transfer(alice, 200_000_000 ether);
        to[0] = bob;
        amounts[0] = 1 ether;
        vm.prank(keeper);
        vm.expectEmit(true, true, false, true);
        emit Chest.HolderSkipped(roundId, bob, 2);
        chest.payHolders(roundId, to, amounts);
    }

    function test_holdersRoundRefusesKeeperMistakes() public {
        deposit(1_200 ether);
        vm.warp(block.timestamp + DAY);
        (uint256 roundId,,) = openRound();
        address[] memory to = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        vm.startPrank(keeper);
        to[0] = pool;
        amounts[0] = 1 ether;
        vm.expectRevert(abi.encodeWithSelector(Chest.Excluded.selector, pool));
        chest.payHolders(roundId, to, amounts);
        to[0] = address(0);
        vm.expectRevert(Chest.BadAddress.selector);
        chest.payHolders(roundId, to, amounts);
        to[0] = alice;
        amounts[0] = 601 ether;
        vm.expectRevert(Chest.OverRemaining.selector);
        chest.payHolders(roundId, to, amounts);
        amounts[0] = 0;
        vm.expectRevert(Chest.BadAmount.selector);
        chest.payHolders(roundId, to, amounts);
        uint256[] memory two = new uint256[](2);
        vm.expectRevert(Chest.LengthMismatch.selector);
        chest.payHolders(roundId, to, two);
        vm.expectRevert(Chest.NoRound.selector);
        chest.payHolders(99, to, amounts);
        vm.expectRevert(Chest.RoundOpen.selector);
        chest.openHoldersRound(uint64(block.number), 1, bytes32(0));
        vm.stopPrank();
        vm.expectRevert(Chest.NotKeeper.selector);
        chest.payHolders(roundId, to, amounts);
        vm.expectRevert(Chest.NotKeeper.selector);
        chest.closeHoldersRound(roundId);
    }

    function test_openHoldersRoundNeedsAnUnlockedPotAndASaneSnapshot() public {
        vm.startPrank(keeper);
        vm.expectRevert(Chest.NothingToDo.selector);
        chest.openHoldersRound(uint64(block.number), 1, bytes32(0));
        vm.stopPrank();
        deposit(100 ether);
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Chest.Locked.selector, Chest.Pot.Holders, uint64(block.timestamp) + DAY));
        chest.openHoldersRound(uint64(block.number), 1, bytes32(0));
        vm.warp(block.timestamp + DAY);
        vm.expectRevert(Chest.FutureBlock.selector);
        chest.openHoldersRound(uint64(block.number) + 1, 1, bytes32(0));
        vm.expectRevert(Chest.BadAmount.selector);
        chest.openHoldersRound(uint64(block.number), 0, bytes32(0));
        vm.stopPrank();
        vm.expectRevert(Chest.NotKeeper.selector);
        chest.openHoldersRound(uint64(block.number), 1, bytes32(0));
    }

    function test_payHoldersRefusesABatchOverTheLimit() public {
        deposit(1_200 ether);
        vm.warp(block.timestamp + DAY);
        (uint256 roundId,,) = openRound();
        address[] memory to = new address[](301);
        uint256[] memory amounts = new uint256[](301);
        vm.prank(keeper);
        vm.expectRevert(Chest.TooMany.selector);
        chest.payHolders(roundId, to, amounts);
    }

    // ----------------------------------------------------------------- agents

    function test_shareAgentsSplitsEquallyAndLeavesTheDust() public {
        deposit(1_000 ether); // 250 to agents
        vm.warp(block.timestamp + DAY);
        agents.push(alice);
        agents.push(bob);
        agents.push(carol);
        bytes32 period = keccak256("day 1");
        uint256 pot = chest.pots(2);
        uint256 each = pot / 3;
        vm.prank(keeper);
        vm.expectEmit(true, false, false, true);
        emit Chest.AgentsShared(period, 3, each);
        chest.shareAgents(period, agents);
        assertEq(city.balanceOf(alice), 300_000_000 ether + each);
        assertEq(city.balanceOf(carol), 100_000_000 ether + each);
        assertEq(chest.pots(2), 250 ether - each * 3, "the dust stays");
        assertTrue(chest.agentsPaid(period));
        assertEq(chest.lastReleaseAt(2), uint64(block.timestamp));

        // The same period again is refused; the next one waits for the lock.
        deposit(1_000 ether);
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Chest.PeriodPaid.selector, period));
        chest.shareAgents(period, agents);
        vm.expectRevert(abi.encodeWithSelector(Chest.Locked.selector, Chest.Pot.Agents, uint64(block.timestamp) + DAY));
        chest.shareAgents(keccak256("day 2"), agents);
        vm.stopPrank();
    }

    function test_shareAgentsOneAgentGetsTheWholePot() public {
        deposit(1_000 ether);
        vm.warp(block.timestamp + DAY);
        agents.push(bob);
        vm.prank(keeper);
        chest.shareAgents(keccak256("p"), agents);
        assertEq(city.balanceOf(bob), 200_000_000 ether + 250 ether);
        assertEq(chest.pots(2), 0);
    }

    function test_shareAgentsRefusesBadLists() public {
        deposit(1_000 ether);
        vm.warp(block.timestamp + DAY);
        vm.startPrank(keeper);
        vm.expectRevert(Chest.TooMany.selector);
        chest.shareAgents(keccak256("p"), agents);
        for (uint256 i; i < 11; ++i) {
            agents.push(makeAddr(string(abi.encodePacked("agent", i))));
        }
        vm.expectRevert(Chest.TooMany.selector);
        chest.shareAgents(keccak256("p"), agents);
        agents.pop();
        agents[3] = agents[1];
        vm.expectRevert(abi.encodeWithSelector(Chest.Duplicate.selector, agents[1]));
        chest.shareAgents(keccak256("p"), agents);
        agents[3] = pool;
        vm.expectRevert(abi.encodeWithSelector(Chest.Excluded.selector, pool));
        chest.shareAgents(keccak256("p"), agents);
        agents[3] = address(0);
        vm.expectRevert(Chest.BadAddress.selector);
        chest.shareAgents(keccak256("p"), agents);
        vm.stopPrank();
        agents[3] = makeAddr("fine");
        vm.expectRevert(Chest.NotKeeper.selector);
        chest.shareAgents(keccak256("p"), agents);
        vm.prank(keeper);
        chest.shareAgents(keccak256("p"), agents);
        assertEq(chest.pots(2), 0, "250 splits by 10");
    }

    // ------------------------------------------------------------------ pause

    function test_pauseStopsMoneyLeavingOnly() public {
        deposit(1_000 ether);
        vm.warp(block.timestamp + DAY);
        vm.prank(owner);
        chest.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        chest.burn();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        chest.sweep();
        agents.push(alice);
        vm.startPrank(keeper);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        chest.shareAgents(keccak256("p"), agents);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        chest.openHoldersRound(uint64(block.number), 1, bytes32(0));
        vm.stopPrank();
        deposit(10 ether);
        vm.prank(owner);
        chest.unpause();
        chest.burn();
        assertEq(city.balanceOf(chest.DEAD()), 252.5 ether);
    }

    // ----------------------------------------------------------------- rescue

    function test_rescueIsPublicDelayedAndCancellable() public {
        deposit(1_000 ether);
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit Chest.RescueProposed(address(city), owner, 1_000 ether, uint64(block.timestamp) + 48 hours);
        chest.proposeRescue(address(city), owner, 1_000 ether);
        vm.expectRevert(Chest.TooEarly.selector);
        chest.executeRescue();
        vm.warp(block.timestamp + 48 hours - 1);
        vm.expectRevert(Chest.TooEarly.selector);
        chest.executeRescue();
        chest.cancelRescue();
        vm.expectRevert(Chest.NoRescue.selector);
        chest.executeRescue();
        vm.expectRevert(Chest.NoRescue.selector);
        chest.cancelRescue();
        vm.stopPrank();
        assertEq(city.balanceOf(address(chest)), 1_000 ether, "nothing moved");
    }

    function test_rescueOfTheTokenEmptiesThePotsAndClosesTheRound() public {
        deposit(1_200 ether);
        vm.warp(block.timestamp + DAY);
        (uint256 roundId,,) = openRound();
        vm.startPrank(owner);
        chest.proposeRescue(address(city), owner, 1_000 ether);
        vm.warp(block.timestamp + 48 hours);
        vm.expectEmit(true, true, false, true);
        emit Chest.RescueExecuted(address(city), owner, 1_000 ether);
        chest.executeRescue();
        vm.stopPrank();
        assertEq(city.balanceOf(owner), 1_000 ether);
        assertEq(chest.pots(0) + chest.pots(1) + chest.pots(2), 0);
        assertFalse(chest.rounds(roundId).open);
        // What is left is re-potted by sweep().
        chest.sweep();
        assertEq(chest.pots(0) + chest.pots(1) + chest.pots(2), 200 ether);
    }

    function test_rescueOfAnotherTokenAndOfEth() public {
        FeeOnTransferToken other = new FeeOnTransferToken();
        other.mint(address(chest), 100 ether);
        vm.deal(address(chest), 1 ether);
        vm.startPrank(owner);
        chest.proposeRescue(address(other), alice, 100 ether);
        vm.warp(block.timestamp + 48 hours);
        chest.executeRescue();
        assertEq(other.balanceOf(alice), 99 ether);
        RejectsEth rejects = new RejectsEth();
        chest.proposeRescue(address(0), address(rejects), 1 ether);
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(Chest.TransferFailed.selector);
        chest.executeRescue();
        chest.proposeRescue(address(0), alice, 1 ether);
        vm.warp(block.timestamp + 48 hours);
        chest.executeRescue();
        vm.stopPrank();
        assertEq(alice.balance, 1 ether);
    }

    function test_rescueDelayOnlyGrows() public {
        vm.startPrank(owner);
        vm.expectRevert(Chest.BadDelay.selector);
        chest.setRescueDelay(47 hours);
        vm.expectRevert(Chest.BadDelay.selector);
        chest.setRescueDelay(31 days);
        chest.setRescueDelay(7 days);
        assertEq(chest.rescueDelay(), 7 days);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ owner

    function test_ownerSettersAndTheirBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(Chest.BadLock.selector);
        chest.setLock(Chest.Pot.Burn, 59 minutes);
        vm.expectRevert(Chest.BadLock.selector);
        chest.setLock(Chest.Pot.Burn, 31 days);
        chest.setLock(Chest.Pot.Holders, 7 days);
        assertEq(chest.lockSeconds(1), 7 days);
        vm.expectRevert(Chest.BadSplit.selector);
        chest.setSplit(2_500, 5_000, 2_501);
        chest.setSplit(5_000, 2_500, 2_500);
        assertEq(chest.splitBps(0), 5_000);
        vm.expectRevert(Chest.BadAddress.selector);
        chest.setKeeper(address(0));
        chest.setKeeper(alice);
        assertEq(chest.keeper(), alice);
        address[] memory list = new address[](1);
        list[0] = chest.DEAD();
        vm.expectRevert(Chest.BadAddress.selector);
        chest.setExcluded(list, false);
        list[0] = bob;
        chest.setExcluded(list, true);
        assertTrue(chest.excluded(bob));
        chest.setExcluded(list, false);
        assertFalse(chest.excluded(bob));
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        chest.setKeeper(alice);
        // A new split applies to the next deposit.
        deposit(1_000 ether);
        assertEq(chest.pots(0), 500 ether);
    }

    function test_constructorExcludesItselfTheDeadAddressAndTheKeeper() public view {
        assertTrue(chest.excluded(address(chest)));
        assertTrue(chest.excluded(chest.DEAD()));
        assertTrue(chest.excluded(keeper));
        assertTrue(chest.excluded(pool));
        assertFalse(chest.excluded(alice));
        assertEq(chest.rescueDelay(), 48 hours);
    }

    function test_constructorRefusesBadArguments() public {
        vm.expectRevert(Chest.BadAddress.selector);
        new Chest(owner, address(0), IERC20(address(city)), [DAY, DAY, DAY], new address[](0));
        vm.expectRevert(Chest.BadLock.selector);
        new Chest(owner, keeper, IERC20(address(city)), [DAY, DAY, uint64(31 days)], new address[](0));
    }

    function test_stateReadsEverythingAtOnce() public {
        deposit(1_000 ether);
        Chest.State memory s = chest.state();
        assertEq(s.pots[1], 500 ether);
        assertEq(s.lockSeconds[0], DAY);
        assertEq(s.splitBps[2], 2_500);
        assertEq(s.keeper, keeper);
        assertFalse(s.paused);
        assertEq(s.roundCount, 0);
        assertEq(s.balance, 1_000 ether);
        assertEq(s.timestamp, uint64(block.timestamp));
        assertEq(chest.unlocksAt(Chest.Pot.Agents), uint64(block.timestamp) + DAY);
    }

    function test_ownershipHandsOverInTwoSteps() public {
        vm.prank(owner);
        chest.transferOwnership(alice);
        assertEq(chest.owner(), owner);
        vm.prank(alice);
        chest.acceptOwnership();
        assertEq(chest.owner(), alice);
    }

    /// The vector tests/chest.test.js in the Agentcity server checks its snapshotHash against.
    function test_snapshotHashVector() public pure {
        address[] memory to = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        to[0] = 0x1111111111111111111111111111111111111111;
        to[1] = 0x2222222222222222222222222222222222222222;
        amounts[0] = 1 ether;
        amounts[1] = 2;
        assertEq(keccak256(abi.encode(to, amounts)), 0x0f2d3ee3aaf581048492fdfc8a77bff03246a9dd56ca8dd80c4cbedddc519c56);
    }
}
