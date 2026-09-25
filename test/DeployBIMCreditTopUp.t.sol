// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {BIMCoin} from "../src/BIMCoin.sol";
import {BIMCreditTopUp} from "../src/BIMCreditTopUp.sol";
import {DeployBIMCreditTopUp} from "../script/DeployBIMCreditTopUp.s.sol";

contract SixDecimalToken is ERC20("Six", "SIX") {
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract DeployBIMCreditTopUpTest is Test {
    DeployBIMCreditTopUp script;
    BIMCoin bim;
    address gov = makeAddr("govSafe");
    address ops = makeAddr("opsSafe");
    address revenue = makeAddr("revenueSafe");
    address signer = makeAddr("quoteSigner");

    function setUp() public {
        script = new DeployBIMCreditTopUp();
        bim = new BIMCoin(makeAddr("treasury"));
        // Stand-ins for deployed Safes: any code at the address.
        vm.etch(gov, hex"00");
        vm.etch(ops, hex"00");
        vm.etch(revenue, hex"00");
    }

    function _config() internal view returns (DeployBIMCreditTopUp.Config memory) {
        return DeployBIMCreditTopUp.Config({
            bim: IERC20(address(bim)),
            governanceSafe: gov,
            opsSafe: ops,
            quoteSigner: signer,
            revenueSafe: revenue,
            marketBimPerUsd: 2e18,
            minBimPerUsd: 1.6e18,
            limits: BIMCreditTopUp.Limits(2_000_00, 20_000_00, 5_000_00),
            allowEoaSafes: false
        });
    }

    function _setSafe(DeployBIMCreditTopUp.Config memory c, uint256 which, address value) internal pure {
        if (which == 0) c.governanceSafe = value;
        if (which == 1) c.opsSafe = value;
        if (which == 2) c.revenueSafe = value;
    }

    function test_ValidConfigDeploysWiredContracts() public {
        DeployBIMCreditTopUp.Config memory c = _config();
        script.validate(c);
        (TimelockController timelock, BIMCreditTopUp topUp) = script.deploy(c);
        assertEq(address(topUp.BIM()), address(bim));
        assertEq(topUp.defaultAdmin(), address(timelock));
        assertEq(topUp.defaultAdminDelay(), 3 days);
        assertEq(topUp.minBimPerUsd(), 1.6e18);
        assertEq(topUp.quoteSigner(), signer);
        assertEq(topUp.revenueSafe(), revenue);
        assertTrue(topUp.hasRole(topUp.GUARDIAN_ROLE(), ops));
        assertFalse(topUp.hasRole(topUp.GUARDIAN_ROLE(), gov));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), gov));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), gov));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), gov));
        assertEq(timelock.getMinDelay(), 48 hours);
        // Only the timelock itself administers the timelock: no deployer or Safe shortcut.
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        assertTrue(timelock.hasRole(adminRole, address(timelock)));
        assertFalse(timelock.hasRole(adminRole, address(this)));
        assertFalse(timelock.hasRole(adminRole, address(script)));
        assertFalse(timelock.hasRole(adminRole, gov));
        (uint64 perPayment, uint64 perDay, uint64 perAccount) = topUp.limits();
        assertEq(perPayment, 2_000_00);
        assertEq(perDay, 20_000_00);
        assertEq(perAccount, 5_000_00);
    }

    function test_RevertWhen_TokenHasNoCode() public {
        DeployBIMCreditTopUp.Config memory c = _config();
        c.bim = IERC20(makeAddr("wrongChainToken"));
        vm.expectRevert(bytes("BIMCOIN_ADDRESS has no code on this chain"));
        script.validate(c);
    }

    function test_RevertWhen_TokenIsNot18Decimals() public {
        DeployBIMCreditTopUp.Config memory c = _config();
        c.bim = IERC20(address(new SixDecimalToken()));
        vm.expectRevert(bytes("BIMCOIN_ADDRESS is not an 18-decimal token"));
        script.validate(c);
    }

    function test_RevertWhen_QuoteSignerIsContract() public {
        DeployBIMCreditTopUp.Config memory c = _config();
        c.quoteSigner = makeAddr("signerSafe");
        vm.etch(c.quoteSigner, hex"00");
        vm.expectRevert(bytes("QUOTE_SIGNER must be a plain key (EOA), not a contract"));
        script.validate(c);
    }

    function test_RevertWhen_QuoteSignerReusesAnySafeKey() public {
        for (uint256 which; which < 3; ++which) {
            DeployBIMCreditTopUp.Config memory c = _config();
            c.allowEoaSafes = true;
            _setSafe(c, which, signer);
            vm.expectRevert(bytes("QUOTE_SIGNER must be a separate key"));
            script.validate(c);
        }
    }

    function test_SafesWithoutCodeNeedExplicitTestnetFlag() public {
        for (uint256 which; which < 3; ++which) {
            DeployBIMCreditTopUp.Config memory c = _config();
            _setSafe(c, which, makeAddr("plainWallet"));
            vm.expectRevert(bytes("a Safe address has no code; set ALLOW_EOA_SAFES=true only on testnets"));
            script.validate(c);
            c.allowEoaSafes = true;
            script.validate(c);
        }
    }

    function test_RevertWhen_SafeIsZeroEvenOnTestnets() public {
        for (uint256 which; which < 3; ++which) {
            DeployBIMCreditTopUp.Config memory c = _config();
            c.allowEoaSafes = true;
            _setSafe(c, which, address(0));
            vm.expectRevert(bytes("a Safe address is zero"));
            script.validate(c);
        }
    }

    function test_FloorMustSitBetweenHalfAndAllOfTheMarketAmount() public {
        DeployBIMCreditTopUp.Config memory c = _config();
        c.marketBimPerUsd = 1;
        vm.expectRevert(bytes("MARKET_BIM_PER_USD must be in BIM wei (18 decimals) per US$1"));
        script.validate(c);
        c = _config();
        c.minBimPerUsd = 3e18; // above the 2e18 market amount: every customer would be overcharged
        vm.expectRevert(bytes("MIN_BIM_PER_USD above the market amount would overcharge"));
        script.validate(c);
        c.minBimPerUsd = 0.99e18;
        vm.expectRevert(bytes("MIN_BIM_PER_USD below half the market amount protects little"));
        script.validate(c);
        c.minBimPerUsd = 1e18; // exactly half
        script.validate(c);
        c.minBimPerUsd = 2e18; // equal to market
        script.validate(c);
    }

    function test_RevertWhen_CapsAreInconsistent() public {
        DeployBIMCreditTopUp.Config memory c = _config();
        c.limits = BIMCreditTopUp.Limits(0, 20_000_00, 5_000_00);
        vm.expectRevert(bytes("payment cap is zero"));
        script.validate(c);
        c.limits = BIMCreditTopUp.Limits(6_000_00, 20_000_00, 5_000_00);
        vm.expectRevert(bytes("payment cap above account cap"));
        script.validate(c);
        c.limits = BIMCreditTopUp.Limits(2_000_00, 5_000_00, 5_000_00);
        vm.expectRevert(bytes("account cap must be below the daily cap, or one account can block everyone"));
        script.validate(c);
        c.limits = BIMCreditTopUp.Limits(2_000_00, 1e8 + 1, 5_000_00);
        vm.expectRevert(bytes("daily cap above $1M: were the caps given in cents?"));
        script.validate(c);
    }

    // forge-lint: disable-start(unsafe-cheatcode)
    /// The only test that touches these environment variables. It sets every one of them, so the
    /// result does not depend on the shell, and no other test may read them.
    function test_EnvConfigAndRunEndToEnd() public {
        vm.setEnv("BIMCOIN_ADDRESS", vm.toString(address(bim)));
        vm.setEnv("GOVERNANCE_SAFE", vm.toString(gov));
        vm.setEnv("OPS_SAFE", vm.toString(ops));
        vm.setEnv("QUOTE_SIGNER", vm.toString(signer));
        vm.setEnv("REVENUE_SAFE", vm.toString(revenue));
        vm.setEnv("MARKET_BIM_PER_USD", "22614000000000000000000"); // BIM at about $0.0000442
        vm.setEnv("MIN_BIM_PER_USD", "18000000000000000000000");
        vm.setEnv("MAX_USD_CENTS_PER_PAYMENT", "100000");
        vm.setEnv("MAX_USD_CENTS_PER_DAY", "3000000");
        vm.setEnv("MAX_USD_CENTS_PER_ACCOUNT_PER_PERIOD", "400000");
        vm.setEnv("ALLOW_EOA_SAFES", "false");

        DeployBIMCreditTopUp.Config memory c = script.readConfig();
        assertEq(address(c.bim), address(bim));
        assertEq(c.governanceSafe, gov);
        assertEq(c.opsSafe, ops);
        assertEq(c.quoteSigner, signer);
        assertEq(c.revenueSafe, revenue);
        assertEq(c.marketBimPerUsd, 22_614e18);
        assertEq(c.minBimPerUsd, 18_000e18);
        assertEq(c.limits.maxUsdCentsPerPayment, 1_000_00);
        assertEq(c.limits.maxUsdCentsPerDay, 30_000_00);
        assertEq(c.limits.maxUsdCentsPerAccountPerPeriod, 4_000_00);
        assertFalse(c.allowEoaSafes);

        // run() validates before deploying: a plain-wallet ops Safe is refused without the flag.
        vm.setEnv("OPS_SAFE", vm.toString(makeAddr("plainWallet")));
        vm.expectRevert(bytes("a Safe address has no code; set ALLOW_EOA_SAFES=true only on testnets"));
        script.run();
        vm.setEnv("ALLOW_EOA_SAFES", "true");
        (, BIMCreditTopUp topUp) = script.run();
        assertEq(topUp.minBimPerUsd(), 18_000e18);
        (uint64 perPayment, uint64 perDay, uint64 perAccount) = topUp.limits();
        assertEq(perPayment, 1_000_00);
        assertEq(perDay, 30_000_00);
        assertEq(perAccount, 4_000_00);

        // Malformed or overflowing values revert instead of falling back to a default.
        string[3] memory capKeys =
            ["MAX_USD_CENTS_PER_PAYMENT", "MAX_USD_CENTS_PER_DAY", "MAX_USD_CENTS_PER_ACCOUNT_PER_PERIOD"];
        for (uint256 i; i < 3; ++i) {
            vm.setEnv(capKeys[i], "30_000_00");
            vm.expectRevert();
            script.readConfig();
            vm.setEnv(capKeys[i], "18446744073709551616"); // 2^64 would wrap to a zero cap
            vm.expectRevert();
            script.readConfig();
            vm.setEnv(capKeys[i], "100000");
        }
        vm.setEnv("ALLOW_EOA_SAFES", "maybe");
        vm.expectRevert();
        script.readConfig();
        vm.setEnv("ALLOW_EOA_SAFES", "false");
        vm.setEnv("MIN_BIM_PER_USD", "one BIM");
        vm.expectRevert();
        script.readConfig();
    }
    // forge-lint: disable-end(unsafe-cheatcode)
}
