// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TownChest} from "../src/TownChest.sol";
import {Deployer} from "./Deployer.s.sol";

/// @notice Deploys the Town Chest, excludes the addresses that must never receive
/// a share, and starts the handover to the admin.
///
///   CHEST_ADMIN        owner after acceptOwnership() (the multisig)
///   CHEST_KEEPER       the Agentcity server's Agent Job treasury: a hot key
///                        that triggers releases and can never take funds
///   CHEST_TOKEN        the town's token (AGENT CITY)
///   CHEST_LOCK_HOURS   how long each pot stays locked between releases (default 24)
///   CHEST_EXCLUDED     more addresses that never receive a share, comma-separated
///                        (the pool, the router, the gate, Permit2, the dead
///                        address and the keeper are always excluded)
///
///   forge script script/DeployTownChest.s.sol --tc DeployTownChest --rpc-url deploy --broadcast
contract DeployTownChest is Deployer {
    /// Uniswap v4's PoolManager on Robinhood Chain: it holds the pool's AGENT CITY.
    address public constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    /// Hookr's router and the pool's Agent gate.
    address public constant HOOKR_ROUTER = 0xC2Bc9a3fe6c4Ce8C2F7EB4655b0869b01D8c93C9;
    address public constant AGENT_GATE = 0x3b1aC66a6Fd9e9d8F063d145003cf29eac4Fb0C9;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external virtual returns (TownChest chest) {
        address admin = vm.envAddress("CHEST_ADMIN");
        address keeper = vm.envAddress("CHEST_KEEPER");
        address token = vm.envAddress("CHEST_TOKEN");
        require(keeper != admin, "DeployTownChest: the keeper is a hot key, never the admin");
        uint64 lock = uint64(vm.envOr("CHEST_LOCK_HOURS", uint256(24)) * 1 hours);
        address[] memory extra = vm.envOr("CHEST_EXCLUDED", ",", new address[](0));
        address[] memory excluded = new address[](4 + extra.length);
        excluded[0] = POOL_MANAGER;
        excluded[1] = HOOKR_ROUTER;
        excluded[2] = AGENT_GATE;
        excluded[3] = PERMIT2;
        for (uint256 i; i < extra.length; ++i) {
            excluded[4 + i] = extra[i];
        }

        // The deployer owns it for the setup, then hands it over.
        address deployer = _start();
        chest = new TownChest(deployer, keeper, IERC20(token), [lock, lock, lock], excluded);
        chest.transferOwnership(admin);
        vm.stopBroadcast();

        console.log("TownChest", address(chest));
        console.log("Keeper", keeper);
        console.log("Lock (hours)", lock / 1 hours);
        console.log("Next: the admin calls acceptOwnership() on the Town Chest.");
    }
}
