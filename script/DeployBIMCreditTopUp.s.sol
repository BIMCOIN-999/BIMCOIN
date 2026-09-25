// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {BIMCreditTopUp} from "../src/BIMCreditTopUp.sol";

/// @notice Deploys a 48-hour TimelockController controlled by the governance Safe, then
///         BIMCreditTopUp with that timelock as its admin.
/// @dev Required env: BIMCOIN_ADDRESS, GOVERNANCE_SAFE, OPS_SAFE, QUOTE_SIGNER, REVENUE_SAFE, and
///      MIN_BIM_PER_USD: the floor in BIM wei (18 decimals) per US$1 of list price. Set it below the
///      market amount at deployment, e.g. BIM at $0.50 (2 BIM per $1) => 1.6e18.
///      Optional env: MAX_USD_CENTS_PER_PAYMENT / _PER_DAY / _PER_ACCOUNT_PER_PERIOD (defaults
///      $2k / $20k / $5k) and ALLOW_EOA_SAFES=true on testnets where plain wallets stand in for Safes.
contract DeployBIMCreditTopUp is Script {
    uint256 internal constant TIMELOCK_DELAY = 48 hours;
    uint48 internal constant ADMIN_TRANSFER_DELAY = 3 days;
    uint256 internal constant MIN_SANE_FLOOR = 1e12; // below this the value was almost certainly not in wei
    uint256 internal constant MAX_SANE_CAP_CENTS = 1e8; // $1M

    struct Config {
        IERC20 bim;
        address governanceSafe;
        address opsSafe;
        address quoteSigner;
        address revenueSafe;
        uint256 minBimPerUsd;
        BIMCreditTopUp.Limits limits;
        bool allowEoaSafes;
    }

    function run() external returns (TimelockController timelock, BIMCreditTopUp topUp) {
        Config memory c = readConfig();
        validate(c);
        console.log("chainid:", block.chainid);
        console.log("minBimPerUsd (BIM wei per US$1 of list price):", c.minBimPerUsd);
        console.log("caps in US cents (payment, day, account per 30 days):");
        console.log(c.limits.maxUsdCentsPerPayment, c.limits.maxUsdCentsPerDay, c.limits.maxUsdCentsPerAccountPerPeriod);

        vm.startBroadcast();
        (timelock, topUp) = deploy(c);
        vm.stopBroadcast();

        console.log("TimelockController:", address(timelock));
        console.log("BIMCreditTopUp:", address(topUp));
    }

    function readConfig() public view returns (Config memory c) {
        c.bim = IERC20(vm.envAddress("BIMCOIN_ADDRESS"));
        c.governanceSafe = vm.envAddress("GOVERNANCE_SAFE");
        c.opsSafe = vm.envAddress("OPS_SAFE");
        c.quoteSigner = vm.envAddress("QUOTE_SIGNER");
        c.revenueSafe = vm.envAddress("REVENUE_SAFE");
        c.minBimPerUsd = vm.envUint("MIN_BIM_PER_USD");
        c.limits = BIMCreditTopUp.Limits({
            maxUsdCentsPerPayment: SafeCast.toUint64(_envUintOr("MAX_USD_CENTS_PER_PAYMENT", 2_000_00)),
            maxUsdCentsPerDay: SafeCast.toUint64(_envUintOr("MAX_USD_CENTS_PER_DAY", 20_000_00)),
            maxUsdCentsPerAccountPerPeriod: SafeCast.toUint64(
                _envUintOr("MAX_USD_CENTS_PER_ACCOUNT_PER_PERIOD", 5_000_00)
            )
        });
        c.allowEoaSafes = vm.envExists("ALLOW_EOA_SAFES") && vm.envBool("ALLOW_EOA_SAFES");
    }

    /// @notice Rejects configurations that would deploy an unusable or unsafe contract.
    function validate(Config memory c) public view {
        require(address(c.bim).code.length > 0, "BIMCOIN_ADDRESS has no code on this chain");
        require(IERC20Metadata(address(c.bim)).decimals() == 18, "BIMCOIN_ADDRESS is not an 18-decimal token");
        require(c.quoteSigner.code.length == 0, "QUOTE_SIGNER must be a plain key (EOA), not a contract");
        require(
            c.quoteSigner != c.governanceSafe && c.quoteSigner != c.opsSafe && c.quoteSigner != c.revenueSafe,
            "QUOTE_SIGNER must be a separate key"
        );
        if (!c.allowEoaSafes) {
            require(
                c.governanceSafe.code.length > 0 && c.opsSafe.code.length > 0 && c.revenueSafe.code.length > 0,
                "a Safe address has no code; set ALLOW_EOA_SAFES=true only on testnets"
            );
        }
        require(c.minBimPerUsd >= MIN_SANE_FLOOR, "MIN_BIM_PER_USD must be in BIM wei (18 decimals) per US$1");
        BIMCreditTopUp.Limits memory l = c.limits;
        require(l.maxUsdCentsPerPayment > 0, "payment cap is zero");
        require(l.maxUsdCentsPerPayment <= l.maxUsdCentsPerAccountPerPeriod, "payment cap above account cap");
        require(
            l.maxUsdCentsPerAccountPerPeriod < l.maxUsdCentsPerDay,
            "account cap must be below the daily cap, or one account can block everyone"
        );
        require(l.maxUsdCentsPerDay <= MAX_SANE_CAP_CENTS, "daily cap above $1M: were the caps given in cents?");
    }

    function deploy(Config memory c) public returns (TimelockController timelock, BIMCreditTopUp topUp) {
        address[] memory safeOnly = new address[](1);
        safeOnly[0] = c.governanceSafe;
        address[] memory guardians = new address[](1);
        guardians[0] = c.opsSafe;
        // No separate timelock admin: only the timelock itself can change its own roles.
        timelock = new TimelockController(TIMELOCK_DELAY, safeOnly, safeOnly, address(0));
        topUp = new BIMCreditTopUp(
            c.bim,
            address(timelock),
            ADMIN_TRANSFER_DELAY,
            guardians,
            c.quoteSigner,
            c.revenueSafe,
            c.minBimPerUsd,
            c.limits
        );
    }

    /// @dev Unlike vm.envOr, a set but malformed value reverts instead of silently using the default.
    function _envUintOr(string memory key, uint256 defaultValue) internal view returns (uint256) {
        return vm.envExists(key) ? vm.envUint(key) : defaultValue;
    }
}
