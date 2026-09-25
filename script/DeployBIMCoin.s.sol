// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BIMCoin} from "../src/BIMCoin.sol";

/// @notice Deploys BIMCOIN and sends the full supply to `BIMCOIN_TREASURY`.
/// @dev Use a multisig (e.g. a Safe) as the treasury, never a single personal wallet.
contract DeployBIMCoin is Script {
    function run() external returns (BIMCoin token) {
        address treasury = vm.envAddress("BIMCOIN_TREASURY");

        vm.startBroadcast();
        token = new BIMCoin(treasury);
        vm.stopBroadcast();

        console.log("BIMCOIN deployed at:", address(token));
        console.log("Treasury:", treasury);
    }
}
