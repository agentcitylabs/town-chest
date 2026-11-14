// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TownChest} from "../src/TownChest.sol";
import {DeployTownChest} from "../script/DeployTownChest.s.sol";
import {MockCity} from "./Mocks.sol";

contract DeployTownChestTest is Test {
    uint256 constant KEY = 0xA11CE;
    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address placementTreasury = makeAddr("placementTreasury");

    function setUp() public {
        vm.chainId(31337);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(bytes32(KEY)));
        vm.setEnv("CHEST_ADMIN", vm.toString(admin));
        vm.setEnv("CHEST_KEEPER", vm.toString(keeper));
        vm.setEnv("CHEST_TOKEN", vm.toString(address(new MockCity())));
        vm.setEnv("CHEST_EXCLUDED", vm.toString(placementTreasury));
    }

    // One test: vm.setEnv is process-wide, so parallel tests would race on it.
    function test_deployWiresTheChest() public {
        // The keeper is a hot key on the server, never the admin.
        vm.setEnv("CHEST_KEEPER", vm.toString(admin));
        DeployTownChest refused = new DeployTownChest();
        vm.expectRevert("DeployTownChest: the keeper is a hot key, never the admin");
        refused.run();

        vm.setEnv("CHEST_KEEPER", vm.toString(keeper));
        DeployTownChest script = new DeployTownChest();
        TownChest chest = script.run();
        assertEq(chest.keeper(), keeper);
        assertEq(chest.pendingOwner(), admin);
        assertEq(chest.lockSeconds(0), 24 hours);
        assertEq(chest.lockSeconds(2), 24 hours);
        assertTrue(chest.excluded(script.POOL_MANAGER()));
        assertTrue(chest.excluded(script.HOOKR_ROUTER()));
        assertTrue(chest.excluded(script.AGENT_GATE()));
        assertTrue(chest.excluded(script.PERMIT2()));
        assertTrue(chest.excluded(keeper));
        assertTrue(chest.excluded(placementTreasury), "the list from the environment");
        assertTrue(chest.excluded(chest.DEAD()));

        vm.setEnv("CHEST_LOCK_HOURS", "168");
        TownChest weekly = new DeployTownChest().run();
        assertEq(weekly.lockSeconds(1), 7 days);
        vm.setEnv("CHEST_LOCK_HOURS", "24");
    }
}
