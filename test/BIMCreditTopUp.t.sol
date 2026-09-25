// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BIMCoin} from "../src/BIMCoin.sol";
import {BIMCreditTopUp} from "../src/BIMCreditTopUp.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

abstract contract Base is Test {
    BIMCoin bim;
    BIMCreditTopUp topUp;
    TimelockController timelock;
    address safe = makeAddr("govSafe");
    address guardian = makeAddr("opsGuardian");
    address revenueSafe = makeAddr("revenueSafe");
    address relayer = makeAddr("relayer");
    address attacker = makeAddr("attacker");
    uint256 signerKey = 0xA11CE;
    uint256 payerKey = 0xB0B;
    address signer;
    address payer;
    bytes32 constant ACCOUNT = keccak256("org-42");
    /// BIM sells at $1 and AI usage is listed at 3x its AI cost, so the launch floor is
    /// 1 BIM per $1 of list price, i.e. 3 BIM per $1 of AI cost.
    uint256 constant FLOOR = 1e18;
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public virtual {
        vm.warp(1_790_000_000);
        signer = vm.addr(signerKey);
        payer = vm.addr(payerKey);
        bim = new BIMCoin(safe);
        address[] memory ps = new address[](1);
        ps[0] = safe;
        timelock = new TimelockController(48 hours, ps, ps, address(0));
        address[] memory gs = new address[](1);
        gs[0] = guardian;
        topUp = new BIMCreditTopUp(
            IERC20(address(bim)),
            address(timelock),
            2 days,
            gs,
            signer,
            revenueSafe,
            FLOOR,
            BIMCreditTopUp.Limits(2_000_00, 3_000_00, 5_000_00) // $2k / payment, $3k / day, $5k / account / 30 d
        );
        vm.prank(safe);
        assertTrue(bim.transfer(payer, 100_000e18));
    }

    function _quote(bytes32 id, uint256 bimAmount, uint64 cents) internal view returns (BIMCreditTopUp.Quote memory) {
        return BIMCreditTopUp.Quote({
            orderId: id,
            accountRef: ACCOUNT,
            payer: payer,
            bimAmount: bimAmount,
            usdCents: cents,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 15 minutes)
        });
    }

    function _sign(BIMCreditTopUp.Quote memory q) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, topUp.hashQuote(q));
        return abi.encodePacked(r, s, v);
    }

    function _permit(uint256 value, uint256 deadline) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, payer, address(topUp), value, bim.nonces(payer), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", bim.DOMAIN_SEPARATOR(), structHash));
        return vm.sign(payerKey, digest);
    }

    function _approveAndPay(BIMCreditTopUp.Quote memory q) internal {
        bytes memory sig = _sign(q);
        vm.startPrank(payer);
        bim.approve(address(topUp), q.bimAmount);
        topUp.pay(q, sig, q.bimAmount);
        vm.stopPrank();
    }

    function _viaTimelock(bytes memory data) internal {
        vm.prank(safe);
        timelock.schedule(address(topUp), 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(safe);
        timelock.execute(address(topUp), 0, data, bytes32(0), bytes32(0));
    }
}

contract BIMCreditTopUpTest is Base {
    // ---------------------------------------------------------------- rate
    function test_LaunchFloorIsOneBimPerDollarOfListPrice() public view {
        assertEq(topUp.minBimPerUsd(), 1e18);
        assertEq(topUp.minimumBimFor(100), 1e18); // $1.00
        assertEq(topUp.minimumBimFor(1), 1e16); // $0.01, no rounding
        assertEq(topUp.minimumBimFor(10_000), 100e18); // $100
    }

    /// $0.20 of AI cost is listed at $0.60 (3x), which costs 0.6 BIM: 3 BIM per $1 of AI cost.
    function test_ThreeBimPerDollarOfAiCost() public view {
        uint64 aiCostCents = 20;
        uint64 listPriceCents = aiCostCents * 3;
        assertEq(topUp.minimumBimFor(listPriceCents), 0.6e18);
    }

    function test_RevertWhen_ZeroFloor() public {
        address[] memory none = new address[](0);
        vm.expectRevert(BIMCreditTopUp.ZeroFloor.selector);
        new BIMCreditTopUp(
            IERC20(address(bim)),
            address(timelock),
            2 days,
            none,
            signer,
            revenueSafe,
            0,
            BIMCreditTopUp.Limits(1, 1, 1)
        );
    }

    function test_PayHundredDollarsWithHundredBim() public {
        BIMCreditTopUp.Quote memory q = _quote("o1", 100e18, 10_000);
        bytes memory sig = _sign(q);
        vm.startPrank(payer);
        bim.approve(address(topUp), 100e18);
        vm.expectEmit(address(topUp));
        emit BIMCreditTopUp.PaymentSettled("o1", ACCOUNT, payer, 100e18, 10_000, FLOOR);
        topUp.pay(q, sig, 100e18);
        vm.stopPrank();
        assertEq(bim.balanceOf(revenueSafe), 100e18);
        assertEq(bim.balanceOf(address(topUp)), 0);
        assertEq(bim.allowance(payer, address(topUp)), 0);
        assertEq(bim.totalSupply(), 21_000_000e18);
        assertEq(bim.getVotes(address(topUp)), 0);
        assertTrue(topUp.settled("o1"));
    }

    function test_RevertWhen_SignedQuoteBelowFloor() public {
        BIMCreditTopUp.Quote memory q = _quote("o1", 100e18 - 1, 10_000); // compromised signer undercharges by 1 wei
        bytes memory sig = _sign(q);
        vm.startPrank(payer);
        bim.approve(address(topUp), q.bimAmount);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.BelowMinimumRate.selector, 100e18 - 1, 100e18));
        topUp.pay(q, sig, q.bimAmount);
        vm.stopPrank();
    }

    function test_MarketRateAboveFloorAccepted() public {
        _approveAndPay(_quote("o1", 1_000e18, 10_000)); // BIM trading at $0.10 => 10 BIM per $1
        assertEq(bim.balanceOf(revenueSafe), 1_000e18);
    }

    function testFuzz_FloorNeverBreached(uint64 cents, uint256 bimAmount) public {
        cents = uint64(bound(cents, 1, 2_000_00));
        bimAmount = bound(bimAmount, 1, 100_000e18);
        BIMCreditTopUp.Quote memory q = _quote("f", bimAmount, cents);
        bytes memory sig = _sign(q);
        vm.startPrank(payer);
        bim.approve(address(topUp), bimAmount);
        uint256 minimum = uint256(cents) * FLOOR / 100;
        if (bimAmount < minimum) {
            vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.BelowMinimumRate.selector, bimAmount, minimum));
            topUp.pay(q, sig, bimAmount);
        } else {
            topUp.pay(q, sig, bimAmount);
            assertEq(bim.balanceOf(revenueSafe), bimAmount);
            assertGe(bimAmount * 100, uint256(cents) * topUp.minBimPerUsd());
        }
        vm.stopPrank();
    }

    // ------------------------------------------------------ quote integrity
    function test_RevertWhen_Replay() public {
        BIMCreditTopUp.Quote memory q = _quote("o1", 100e18, 10_000);
        bytes memory sig = _sign(q);
        vm.startPrank(payer);
        bim.approve(address(topUp), 200e18);
        topUp.pay(q, sig, 100e18);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.OrderAlreadySettled.selector, q.orderId));
        topUp.pay(q, sig, 100e18);
        vm.stopPrank();
    }

    function test_RevertWhen_FieldTampered() public {
        BIMCreditTopUp.Quote memory q = _quote("o1", 900e18, 20_000);
        bytes memory sig = _sign(q);
        q.usdCents = 30_000; // claim more USD credit than signed (still at/above floor)
        vm.startPrank(payer);
        bim.approve(address(topUp), 900e18);
        vm.expectPartialRevert(BIMCreditTopUp.InvalidQuoteSignature.selector);
        topUp.pay(q, sig, 900e18);
        vm.stopPrank();
    }

    function test_RevertWhen_OtherChain() public {
        BIMCreditTopUp.Quote memory q = _quote("o1", 100e18, 10_000);
        bytes memory sig = _sign(q); // signed for chain 31337
        vm.chainId(8453);
        vm.startPrank(payer);
        bim.approve(address(topUp), 100e18);
        vm.expectPartialRevert(BIMCreditTopUp.InvalidQuoteSignature.selector);
        topUp.pay(q, sig, 100e18);
        vm.stopPrank();
    }

    function test_RevertWhen_ExpiredFutureOrLongTtl() public {
        BIMCreditTopUp.Quote memory q = _quote("o1", 100e18, 10_000);
        bytes memory sig = _sign(q);
        vm.prank(payer);
        bim.approve(address(topUp), type(uint256).max);

        vm.warp(block.timestamp + 16 minutes);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.QuoteExpired.selector, q.expiresAt));
        topUp.pay(q, sig, 100e18);

        q = _quote("o2", 100e18, 10_000);
        q.issuedAt += 60;
        sig = _sign(q);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.QuoteNotYetValid.selector, q.issuedAt));
        topUp.pay(q, sig, 100e18);

        q = _quote("o3", 100e18, 10_000);
        q.expiresAt = q.issuedAt + 31 minutes;
        sig = _sign(q);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.QuoteTtlTooLong.selector, q.issuedAt, q.expiresAt));
        topUp.pay(q, sig, 100e18);
    }

    function test_RevertWhen_SlippageAboveMaxBim() public {
        BIMCreditTopUp.Quote memory q = _quote("o1", 100e18, 10_000);
        bytes memory sig = _sign(q);
        vm.startPrank(payer);
        bim.approve(address(topUp), 100e18);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.SlippageExceeded.selector, 100e18, 99e18));
        topUp.pay(q, sig, 99e18);
        vm.stopPrank();
    }

    // ------------------------------------------------------ payer binding
    function test_RevertWhen_ThirdPartyCallsPay() public {
        BIMCreditTopUp.Quote memory q = _quote("o1", 100e18, 10_000);
        bytes memory sig = _sign(q);
        vm.prank(payer);
        bim.approve(address(topUp), 100e18);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.NotPayer.selector, attacker, payer));
        topUp.pay(q, sig, 100e18);
    }

    /// Regression for the draft's bug: a failed permit must not let a third party spend a standing allowance.
    function test_RevertWhen_BogusPermitUsesStandingAllowance() public {
        BIMCreditTopUp.Quote memory q = _quote("o1", 100e18, 10_000);
        bytes memory sig = _sign(q);
        vm.prank(payer);
        bim.approve(address(topUp), type(uint256).max); // leftover allowance
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.NotPayer.selector, attacker, payer));
        topUp.payWithPermit(q, sig, 100e18, block.timestamp + 1 hours, 27, bytes32(0), bytes32(0));
        assertEq(bim.balanceOf(payer), 100_000e18);
    }

    function test_RelayerPaysWithFreshPermit() public {
        BIMCreditTopUp.Quote memory q = _quote("o1", 100e18, 10_000);
        bytes memory sig = _sign(q);
        (uint8 v, bytes32 r, bytes32 s) = _permit(100e18, block.timestamp + 15 minutes);
        vm.prank(relayer);
        topUp.payWithPermit(q, sig, 100e18, block.timestamp + 15 minutes, v, r, s);
        assertEq(bim.balanceOf(revenueSafe), 100e18);
        assertEq(bim.allowance(payer, address(topUp)), 0); // exact-amount permit leaves nothing behind
    }

    function test_FrontRunPermitOnlyPayerCanContinue() public {
        BIMCreditTopUp.Quote memory q = _quote("o1", 100e18, 10_000);
        bytes memory sig = _sign(q);
        uint256 deadline = block.timestamp + 15 minutes;
        (uint8 v, bytes32 r, bytes32 s) = _permit(100e18, deadline);
        bim.permit(payer, address(topUp), 100e18, deadline, v, r, s); // griefer front-runs the permit
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.NotPayer.selector, relayer, payer));
        topUp.payWithPermit(q, sig, 100e18, deadline, v, r, s);
        vm.prank(payer); // payer recovers using the allowance the griefer set
        topUp.payWithPermit(q, sig, 100e18, deadline, v, r, s);
        assertEq(bim.balanceOf(revenueSafe), 100e18);
    }

    // ------------------------------------------------------------ caps
    function test_Caps() public {
        vm.prank(payer);
        bim.approve(address(topUp), type(uint256).max);

        BIMCreditTopUp.Quote memory q = _quote("big", 2_001e18, 2_001_00);
        bytes memory sig = _sign(q);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.PaymentTooLarge.selector, 2_001_00, 2_000_00));
        topUp.pay(q, sig, q.bimAmount);

        _payAs("d1", ACCOUNT, 2_000_00);
        q = _quoteFor("d2", keccak256("org-43"), 1_000_01);
        sig = _sign(q);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.DailyCapExceeded.selector, 3_000_01, 3_000_00));
        topUp.pay(q, sig, q.bimAmount);

        vm.warp(block.timestamp + 1 days); // new UTC day
        _payAs("d3", ACCOUNT, 2_000_00);
        vm.warp(block.timestamp + 1 days);
        q = _quoteFor("d4", ACCOUNT, 1_000_01);
        sig = _sign(q);
        vm.prank(payer);
        vm.expectPartialRevert(BIMCreditTopUp.AccountCapExceeded.selector); // same 30-day period
        topUp.pay(q, sig, q.bimAmount);
    }

    function _quoteFor(bytes32 id, bytes32 acct, uint64 cents) internal view returns (BIMCreditTopUp.Quote memory q) {
        q = _quote(id, uint256(cents) * FLOOR / 100, cents);
        q.accountRef = acct;
    }

    function _payAs(bytes32 id, bytes32 acct, uint64 cents) internal {
        BIMCreditTopUp.Quote memory q = _quoteFor(id, acct, cents);
        bytes memory sig = _sign(q);
        vm.prank(payer);
        topUp.pay(q, sig, q.bimAmount);
    }

    // ------------------------------------------------------ guardian powers
    function test_GuardianCanOnlyStop() public {
        vm.startPrank(guardian);
        topUp.pause();
        vm.expectPartialRevert(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")));
        topUp.unpause();
        topUp.revokeQuoteSigner();
        topUp.tightenLimits(BIMCreditTopUp.Limits(1_000_00, 1_000_00, 1_000_00));
        vm.expectRevert(BIMCreditTopUp.LimitNotTightened.selector);
        topUp.tightenLimits(BIMCreditTopUp.Limits(1_000_00, 1_000_01, 1_000_00));
        vm.expectPartialRevert(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")));
        topUp.setMinBimPerUsd(2e18);
        vm.expectPartialRevert(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")));
        topUp.setQuoteSigner(guardian);
        vm.expectPartialRevert(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")));
        topUp.setRevenueSafe(guardian);
        vm.stopPrank();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.NotGuardianOrAdmin.selector, attacker));
        topUp.pause();
    }

    function test_PausedAndRevokedBlockPayments() public {
        BIMCreditTopUp.Quote memory q = _quote("o1", 100e18, 10_000);
        bytes memory sig = _sign(q);
        vm.prank(payer);
        bim.approve(address(topUp), 100e18);
        vm.prank(guardian);
        topUp.pause();
        vm.prank(payer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        topUp.pay(q, sig, 100e18);

        _viaTimelock(abi.encodeCall(BIMCreditTopUp.unpause, ()));
        q = _quote("o2", 100e18, 10_000);
        sig = _sign(q);
        vm.prank(guardian);
        topUp.revokeQuoteSigner();
        vm.prank(payer);
        vm.expectRevert(BIMCreditTopUp.NoQuoteSigner.selector);
        topUp.pay(q, sig, 100e18);
    }

    // ------------------------------------------------------ floor governance
    bytes32 constant SALT = "floor-decrease";

    function test_FloorChangesOnlyThroughTimelockAndWithinBounds() public {
        vm.prank(safe); // the Safe alone cannot bypass the timelock
        vm.expectPartialRevert(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")));
        topUp.setMinBimPerUsd(0.7e18);

        // lowering is not allowed within 30 days of launch
        vm.prank(safe);
        timelock.schedule(
            address(topUp), 0, abi.encodeCall(BIMCreditTopUp.setMinBimPerUsd, (0.7e18)), 0, SALT, 48 hours
        );
        vm.warp(block.timestamp + 48 hours);
        vm.prank(safe);
        vm.expectRevert(); // FloorDecreaseTooSoon bubbled through TimelockController
        timelock.execute(address(topUp), 0, abi.encodeCall(BIMCreditTopUp.setMinBimPerUsd, (0.7e18)), 0, SALT);

        vm.warp(block.timestamp + 30 days);
        _viaTimelock(abi.encodeCall(BIMCreditTopUp.setMinBimPerUsd, (0.7e18))); // -30% exactly
        assertEq(topUp.minBimPerUsd(), 0.7e18);
    }

    function test_FloorStepBounds() public {
        vm.startPrank(address(timelock)); // call as the admin directly to test the math
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.FloorStepTooLarge.selector, 1e18, 2e18 + 1));
        topUp.setMinBimPerUsd(2e18 + 1);
        topUp.setMinBimPerUsd(2e18); // raise up to 2x at any time
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.FloorStepTooLarge.selector, 2e18, 1.4e18 - 1));
        topUp.setMinBimPerUsd(1.4e18 - 1);
        topUp.setMinBimPerUsd(1.4e18);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.FloorDecreaseTooSoon.selector, block.timestamp + 30 days));
        topUp.setMinBimPerUsd(1.3e18);
        vm.expectRevert(BIMCreditTopUp.FloorUnchanged.selector);
        topUp.setMinBimPerUsd(1.4e18);
        vm.stopPrank();
    }

    function test_RevenueSafeValidation() public {
        address dead = topUp.DEAD();
        vm.startPrank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.InvalidRevenueSafe.selector, address(0)));
        topUp.setRevenueSafe(address(0));
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.InvalidRevenueSafe.selector, dead));
        topUp.setRevenueSafe(dead);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.InvalidRevenueSafe.selector, address(topUp)));
        topUp.setRevenueSafe(address(topUp));
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.InvalidRevenueSafe.selector, address(bim)));
        topUp.setRevenueSafe(address(bim));
        vm.stopPrank();
    }

    function test_RescueMistakenTransfer() public {
        vm.prank(payer);
        assertTrue(bim.transfer(address(topUp), 5e18)); // customer sends BIM directly by mistake
        vm.prank(address(timelock));
        topUp.rescueTokens(IERC20(address(bim)), payer, 5e18);
        assertEq(bim.balanceOf(address(topUp)), 0);
    }
}

/// Stateful invariants: random payments by an honest signer, a malicious signer and random callers.
contract Handler is Test {
    BIMCreditTopUp topUp;
    BIMCoin bim;
    uint256 signerKey;
    uint256[] payerKeys;
    uint256 public ghostSettledBim;
    uint256 public ghostMaxDay;
    uint256 nonce;

    constructor(BIMCreditTopUp t, BIMCoin b, uint256 sk, uint256[] memory pks) {
        topUp = t;
        bim = b;
        signerKey = sk;
        payerKeys = pks;
    }

    function pay(uint256 who, uint64 cents, uint256 bimAmount, uint8 acct, bool reuseId, uint32 dt) external {
        vm.warp(block.timestamp + (dt % 2 days));
        uint256 pk = payerKeys[who % payerKeys.length];
        address p = vm.addr(pk);
        cents = uint64(bound(cents, 1, 3_000_00));
        bimAmount = bound(bimAmount, 1, 20_000e18);
        bytes32 id = reuseId && nonce > 0 ? bytes32(nonce - 1) : bytes32(nonce++);
        BIMCreditTopUp.Quote memory q = BIMCreditTopUp.Quote(
            id, bytes32(uint256(acct % 4)), p, bimAmount, cents, uint64(block.timestamp), uint64(block.timestamp + 900)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, topUp.hashQuote(q));
        vm.startPrank(p);
        bim.approve(address(topUp), bimAmount);
        try topUp.pay(q, abi.encodePacked(r, s, v), bimAmount) {
            ghostSettledBim += bimAmount;
            uint256 day = topUp.usdCentsSettledOnDay(block.timestamp / 1 days);
            if (day > ghostMaxDay) ghostMaxDay = day;
            assertGe(bimAmount * 100, uint256(cents) * topUp.minBimPerUsd());
        } catch {}
        bim.approve(address(topUp), 0);
        vm.stopPrank();
    }

    function strangerPays(uint256 who, uint64 cents) external {
        uint256 pk = payerKeys[who % payerKeys.length];
        address p = vm.addr(pk);
        vm.prank(p);
        bim.approve(address(topUp), type(uint256).max); // standing allowance
        cents = uint64(bound(cents, 1, 1_000_00));
        BIMCreditTopUp.Quote memory q = BIMCreditTopUp.Quote(
            bytes32(nonce++),
            bytes32(0),
            p,
            topUp.minimumBimFor(cents),
            cents,
            uint64(block.timestamp),
            uint64(block.timestamp + 900)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, topUp.hashQuote(q));
        vm.prank(address(0xBAD));
        try topUp.payWithPermit(q, abi.encodePacked(r, s, v), q.bimAmount, 0, 0, 0, 0) {
            revert("stranger spent a standing allowance");
        } catch {}
        vm.prank(p);
        bim.approve(address(topUp), 0);
    }
}

contract BIMCreditTopUpInvariants is Base {
    Handler handler;

    function setUp() public override {
        super.setUp();
        uint256[] memory pks = new uint256[](3);
        pks[0] = payerKey;
        pks[1] = 0xC0C;
        pks[2] = 0xD0D;
        vm.startPrank(safe);
        assertTrue(bim.transfer(vm.addr(0xC0C), 1_000_000e18));
        assertTrue(bim.transfer(vm.addr(0xD0D), 1_000_000e18));
        vm.stopPrank();
        handler = new Handler(topUp, bim, signerKey, pks);
        targetContract(address(handler));
    }

    function afterInvariant() external view {
        assertGt(handler.ghostSettledBim(), 0, "no payment ever settled: invariants would be vacuous");
    }

    function invariant_ContractNeverHoldsBim() public view {
        assertEq(bim.balanceOf(address(topUp)), 0);
    }

    function invariant_RevenueEqualsSettled() public view {
        assertEq(bim.balanceOf(revenueSafe), handler.ghostSettledBim());
    }

    function invariant_SupplyFixed() public view {
        assertEq(bim.totalSupply(), 21_000_000e18);
    }

    function invariant_DailyCapNeverExceeded() public view {
        assertLe(handler.ghostMaxDay(), 3_000_00);
    }
}
