// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {BIMCreditTopUp} from "../src/BIMCreditTopUp.sol";

/// @notice Deploys a 48-hour TimelockController controlled by the governance Safe, then
///         BIMCreditTopUp with that timelock as its admin.
/// @dev Required env: BIMCOIN_ADDRESS, GOVERNANCE_SAFE, OPS_SAFE, QUOTE_SIGNER, REVENUE_SAFE.
///      Optional env: MIN_BIM_PER_USD (default 1e18: BIM sold at $1, usage listed at 3x AI cost),
///      MAX_USD_CENTS_PER_PAYMENT / _PER_DAY / _PER_ACCOUNT_PER_PERIOD (defaults $2k / $3k / $5k).
contract DeployBIMCreditTopUp is Script {
    uint256 internal constant TIMELOCK_DELAY = 48 hours;
    uint48 internal constant ADMIN_TRANSFER_DELAY = 3 days;

    function run() external returns (TimelockController timelock, BIMCreditTopUp topUp) {
        IERC20 bim = IERC20(vm.envAddress("BIMCOIN_ADDRESS"));
        address governanceSafe = vm.envAddress("GOVERNANCE_SAFE");
        address opsSafe = vm.envAddress("OPS_SAFE");
        address quoteSigner = vm.envAddress("QUOTE_SIGNER");
        address revenueSafe = vm.envAddress("REVENUE_SAFE");
        uint256 minBimPerUsd = vm.envOr("MIN_BIM_PER_USD", uint256(1e18));
        BIMCreditTopUp.Limits memory limits = BIMCreditTopUp.Limits({
            maxUsdCentsPerPayment: uint64(vm.envOr("MAX_USD_CENTS_PER_PAYMENT", uint256(2_000_00))),
            maxUsdCentsPerDay: uint64(vm.envOr("MAX_USD_CENTS_PER_DAY", uint256(3_000_00))),
            maxUsdCentsPerAccountPerPeriod: uint64(vm.envOr("MAX_USD_CENTS_PER_ACCOUNT_PER_PERIOD", uint256(5_000_00)))
        });

        address[] memory safeOnly = new address[](1);
        safeOnly[0] = governanceSafe;
        address[] memory guardians = new address[](1);
        guardians[0] = opsSafe;

        vm.startBroadcast();
        // No separate timelock admin: only the timelock itself can change its own roles.
        timelock = new TimelockController(TIMELOCK_DELAY, safeOnly, safeOnly, address(0));
        topUp = new BIMCreditTopUp(
            bim, address(timelock), ADMIN_TRANSFER_DELAY, guardians, quoteSigner, revenueSafe, minBimPerUsd, limits
        );
        vm.stopBroadcast();

        console.log("TimelockController:", address(timelock));
        console.log("BIMCreditTopUp:", address(topUp));
    }
}
