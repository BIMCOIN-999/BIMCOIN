// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {BIMCoin} from "../src/BIMCoin.sol";
import {BIMCreditTopUp} from "../src/BIMCreditTopUp.sol";
import {DeployBIMCreditTopUp} from "../script/DeployBIMCreditTopUp.s.sol";

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
            minBimPerUsd: 1e18,
            limits: BIMCreditTopUp.Limits(2_000_00, 20_000_00, 5_000_00),
            allowEoaSafes: false
        });
    }

    function test_ValidConfigDeploysWiredContracts() public {
        DeployBIMCreditTopUp.Config memory c = _config();
        script.validate(c);
        (TimelockController timelock, BIMCreditTopUp topUp) = script.deploy(c);
        assertEq(address(topUp.BIM()), address(bim));
        assertEq(topUp.defaultAdmin(), address(timelock));
        assertEq(topUp.minBimPerUsd(), 1e18);
        assertEq(topUp.quoteSigner(), signer);
        assertEq(topUp.revenueSafe(), revenue);
        assertTrue(topUp.hasRole(topUp.GUARDIAN_ROLE(), ops));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), gov));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), gov));
        assertEq(timelock.getMinDelay(), 48 hours);
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

    function test_RevertWhen_QuoteSignerIsContract() public {
        DeployBIMCreditTopUp.Config memory c = _config();
        c.quoteSigner = makeAddr("signerSafe");
        vm.etch(c.quoteSigner, hex"00");
        vm.expectRevert(bytes("QUOTE_SIGNER must be a plain key (EOA), not a contract"));
        script.validate(c);
    }

    function test_RevertWhen_QuoteSignerReusesASafeKey() public {
        DeployBIMCreditTopUp.Config memory c = _config();
        c.allowEoaSafes = true;
        c.opsSafe = signer;
        vm.expectRevert(bytes("QUOTE_SIGNER must be a separate key"));
        script.validate(c);
    }

    function test_SafesWithoutCodeNeedExplicitTestnetFlag() public {
        DeployBIMCreditTopUp.Config memory c = _config();
        c.governanceSafe = makeAddr("plainWallet");
        vm.expectRevert(bytes("a Safe address has no code; set ALLOW_EOA_SAFES=true only on testnets"));
        script.validate(c);
        c.allowEoaSafes = true;
        script.validate(c);
    }

    function test_RevertWhen_FloorIsNotInWei() public {
        DeployBIMCreditTopUp.Config memory c = _config();
        c.minBimPerUsd = 1; // "1 BIM" typed without 18 decimals
        vm.expectRevert(bytes("MIN_BIM_PER_USD must be in BIM wei (18 decimals) per US$1"));
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
    /// The only test that touches these environment variables.
    function test_ReadConfigRejectsMalformedAndOverflowingValues() public {
        vm.setEnv("BIMCOIN_ADDRESS", vm.toString(address(bim)));
        vm.setEnv("GOVERNANCE_SAFE", vm.toString(gov));
        vm.setEnv("OPS_SAFE", vm.toString(ops));
        vm.setEnv("QUOTE_SIGNER", vm.toString(signer));
        vm.setEnv("REVENUE_SAFE", vm.toString(revenue));
        vm.setEnv("MIN_BIM_PER_USD", "22600000000000000000000"); // BIM at about $0.0000442
        vm.setEnv("MAX_USD_CENTS_PER_DAY", "3000000");

        DeployBIMCreditTopUp.Config memory c = script.readConfig();
        assertEq(c.minBimPerUsd, 22_600e18);
        assertEq(c.limits.maxUsdCentsPerDay, 30_000_00);

        vm.setEnv("MAX_USD_CENTS_PER_DAY", "30_000_00"); // not a plain integer: must not fall back to the default
        vm.expectRevert();
        script.readConfig();

        vm.setEnv("MAX_USD_CENTS_PER_DAY", "18446744073709551616"); // 2^64 would wrap to a zero cap
        vm.expectRevert();
        script.readConfig();

        vm.setEnv("MAX_USD_CENTS_PER_DAY", "3000000");
        vm.setEnv("MIN_BIM_PER_USD", "one BIM");
        vm.expectRevert();
        script.readConfig();
    }
    // forge-lint: disable-end(unsafe-cheatcode)
}
