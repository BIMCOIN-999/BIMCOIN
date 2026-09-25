// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BIMCoin} from "../src/BIMCoin.sol";
import {BIMCreditTopUp} from "../src/BIMCreditTopUp.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
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
    /// Launch floor used by the tests: 1 BIM per $1 of list price (list price = 3x AI cost).
    uint256 constant FLOOR = 1e18;
    uint64 constant PER_PAYMENT = 2_000_00;
    uint64 constant PER_DAY = 20_000_00;
    uint64 constant PER_ACCOUNT = 5_000_00;
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant QUOTE_TYPEHASH = keccak256(
        "Quote(bytes32 orderId,bytes32 accountRef,address payer,uint256 bimAmount,uint64 usdCents,uint64 issuedAt,uint64 expiresAt)"
    );

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
            BIMCreditTopUp.Limits(PER_PAYMENT, PER_DAY, PER_ACCOUNT)
        );
        vm.prank(safe);
        assertTrue(bim.transfer(payer, 1_000_000e18));
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

    function _quoteFor(bytes32 id, bytes32 acct, uint64 cents) internal view returns (BIMCreditTopUp.Quote memory q) {
        q = _quote(id, uint256(cents) * FLOOR / 100, cents);
        q.accountRef = acct;
    }

    /// EIP-712 digest built from the literal type strings, independent of the contract's code.
    function _digest(BIMCreditTopUp.Quote memory q) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("BIMCreditTopUp"), keccak256("1"), block.chainid, address(topUp))
        );
        bytes32 structHash = keccak256(
            abi.encode(
                QUOTE_TYPEHASH, q.orderId, q.accountRef, q.payer, q.bimAmount, q.usdCents, q.issuedAt, q.expiresAt
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _signWith(uint256 key, BIMCreditTopUp.Quote memory q) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(q));
        return abi.encodePacked(r, s, v);
    }

    function _sign(BIMCreditTopUp.Quote memory q) internal view returns (bytes memory) {
        return _signWith(signerKey, q);
    }

    function _permit(uint256 value, uint256 deadline) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, payer, address(topUp), value, bim.nonces(payer), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", bim.DOMAIN_SEPARATOR(), structHash));
        return vm.sign(payerKey, digest);
    }

    function _approveAndPay(BIMCreditTopUp.Quote memory q) internal {
        bytes memory sig = _sign(q);
        vm.startPrank(q.payer);
        bim.approve(address(topUp), q.bimAmount);
        topUp.pay(q, sig, q.bimAmount);
        vm.stopPrank();
    }

    function _payAs(bytes32 id, bytes32 acct, uint64 cents) internal {
        _approveAndPay(_quoteFor(id, acct, cents));
    }

    function _viaTimelock(bytes memory data) internal {
        _viaTimelock(data, bytes32(0));
    }

    function _viaTimelock(bytes memory data, bytes32 salt) internal {
        vm.prank(safe);
        timelock.schedule(address(topUp), 0, data, bytes32(0), salt, 48 hours);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(safe);
        timelock.execute(address(topUp), 0, data, bytes32(0), salt);
    }

    function _grantRelayer() internal {
        _viaTimelock(abi.encodeCall(IAccessControl.grantRole, (topUp.RELAYER_ROLE(), relayer)), "relayer");
    }
}

contract BIMCreditTopUpTest is Base {
    bytes4 constant UNAUTHORIZED = bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)"));

    // ---------------------------------------------------------------- rate
    function test_LaunchFloorIsOneBimPerDollarOfListPrice() public view {
        assertEq(topUp.minBimPerUsd(), 1e18);
        assertEq(topUp.minimumBimFor(100), 1e18); // $1.00
        assertEq(topUp.minimumBimFor(1), 1e16); // $0.01, no rounding
        assertEq(topUp.minimumBimFor(10_000), 100e18); // $100
    }

    /// $0.20 of AI cost is listed at $0.60 (3x), which costs at least 0.6 BIM at this floor.
    function test_ThreeBimPerDollarOfAiCostAtFloor() public view {
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

    /// Market-referenced pricing: BIM trading at $0.10 means 10 BIM per $1, above the floor.
    function test_MarketRateAboveFloorAccepted() public {
        _approveAndPay(_quote("o1", 1_000e18, 10_000));
        assertEq(bim.balanceOf(revenueSafe), 1_000e18);
    }

    function testFuzz_FloorNeverBreached(uint64 cents, uint256 bimAmount) public {
        cents = uint64(bound(cents, 1, PER_PAYMENT));
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
    function test_HashQuoteMatchesIndependentDigest() public view {
        BIMCreditTopUp.Quote memory q = _quote("o1", 123e18, 4_567);
        q.accountRef = keccak256("org-7");
        assertEq(topUp.hashQuote(q), _digest(q));
    }

    function test_RevertWhen_AnySignedFieldIsTampered() public {
        vm.prank(payer);
        bim.approve(address(topUp), type(uint256).max);
        address otherPayer = vm.addr(0xC0FFEE);
        vm.prank(safe);
        assertTrue(bim.transfer(otherPayer, 1_000e18));
        vm.prank(otherPayer);
        bim.approve(address(topUp), type(uint256).max);

        for (uint256 field; field < 7; ++field) {
            BIMCreditTopUp.Quote memory q = _quote(bytes32(field + 1), 200e18, 10_000);
            bytes memory sig = _sign(q);
            address caller = payer;
            if (field == 0) q.orderId = keccak256("other order");
            if (field == 1) q.accountRef = keccak256("other account");
            if (field == 2) (q.payer, caller) = (otherPayer, otherPayer);
            if (field == 3) q.bimAmount = 150e18;
            if (field == 4) q.usdCents = 5_000;
            if (field == 5) q.issuedAt -= 1;
            if (field == 6) q.expiresAt -= 1;
            vm.prank(caller);
            vm.expectPartialRevert(BIMCreditTopUp.InvalidQuoteSignature.selector);
            topUp.pay(q, sig, q.bimAmount);
        }
    }

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
        q.issuedAt += 61; // more than the 60 s clock skew allowance
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

    /// A backend clock slightly ahead of the chain must not break payments.
    function test_QuoteIssuedUpToOneMinuteAheadIsAccepted() public {
        BIMCreditTopUp.Quote memory q = _quote("o1", 100e18, 10_000);
        q.issuedAt += 60;
        q.expiresAt = q.issuedAt + 15 minutes;
        _approveAndPay(q);
        assertTrue(topUp.settled("o1"));
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

    function test_RevertWhen_PayerIsRevenueSafe() public {
        vm.prank(safe);
        assertTrue(bim.transfer(revenueSafe, 100e18));
        BIMCreditTopUp.Quote memory q = _quote("o1", 100e18, 10_000);
        q.payer = revenueSafe;
        bytes memory sig = _sign(q);
        vm.startPrank(revenueSafe);
        bim.approve(address(topUp), 100e18);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.InvalidPayer.selector, revenueSafe));
        topUp.pay(q, sig, 100e18);
        vm.stopPrank();
        assertFalse(topUp.settled("o1"));
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

    /// A failed permit must not let a third party spend a standing allowance.
    function test_RevertWhen_BogusPermitUsesStandingAllowance() public {
        _grantRelayer();
        BIMCreditTopUp.Quote memory q = _quote("o1", 100e18, 10_000);
        bytes memory sig = _sign(q);
        vm.prank(payer);
        bim.approve(address(topUp), type(uint256).max);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.NotPayer.selector, attacker, payer));
        topUp.payWithPermit(q, sig, 100e18, block.timestamp + 1 hours, 27, bytes32(0), bytes32(0));
        vm.prank(relayer); // even an approved relayer cannot fall back to the allowance
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.NotPayer.selector, relayer, payer));
        topUp.payWithPermit(q, sig, 100e18, block.timestamp + 1 hours, 27, bytes32(0), bytes32(0));
        assertEq(bim.balanceOf(payer), 1_000_000e18);
    }

    /// A leftover valid permit plus another open quote cannot be used by a third party.
    function test_RevertWhen_ThirdPartyReplaysLeftoverPermit() public {
        BIMCreditTopUp.Quote memory qA = _quote("A", 100e18, 10_000);
        bytes memory sigA = _sign(qA);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permit(100e18, deadline);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.NotPayer.selector, attacker, payer));
        topUp.payWithPermit(qA, sigA, 100e18, deadline, v, r, s);
        assertFalse(topUp.settled("A"));
    }

    function test_ApprovedRelayerPaysWithFreshPermit() public {
        _grantRelayer();
        BIMCreditTopUp.Quote memory q = _quote("o1", 100e18, 10_000);
        bytes memory sig = _sign(q);
        (uint8 v, bytes32 r, bytes32 s) = _permit(100e18, block.timestamp + 15 minutes);
        vm.prank(relayer);
        topUp.payWithPermit(q, sig, 100e18, block.timestamp + 15 minutes, v, r, s);
        assertEq(bim.balanceOf(revenueSafe), 100e18);
        assertEq(bim.allowance(payer, address(topUp)), 0); // exact-amount permit leaves nothing behind
    }

    function test_PayerPaysWithOwnPermit() public {
        BIMCreditTopUp.Quote memory q = _quote("o1", 100e18, 10_000);
        bytes memory sig = _sign(q);
        (uint8 v, bytes32 r, bytes32 s) = _permit(100e18, block.timestamp + 15 minutes);
        vm.prank(payer);
        topUp.payWithPermit(q, sig, 100e18, block.timestamp + 15 minutes, v, r, s);
        assertEq(bim.balanceOf(revenueSafe), 100e18);
    }

    function test_FrontRunPermitOnlyPayerCanContinue() public {
        _grantRelayer();
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
    function test_RevertWhen_PaymentAboveCap() public {
        BIMCreditTopUp.Quote memory q = _quoteFor("big", ACCOUNT, PER_PAYMENT + 1);
        bytes memory sig = _sign(q);
        vm.startPrank(payer);
        bim.approve(address(topUp), q.bimAmount);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.PaymentTooLarge.selector, PER_PAYMENT + 1, PER_PAYMENT));
        topUp.pay(q, sig, q.bimAmount);
        vm.stopPrank();
    }

    function test_AccountCapExactlyFilledThenOneCentReverts() public {
        _payAs("a1", ACCOUNT, 2_000_00);
        _payAs("a2", ACCOUNT, 2_000_00);
        _payAs("a3", ACCOUNT, 1_000_00);
        assertEq(topUp.availableUsdCentsForAccount(ACCOUNT), 0);
        BIMCreditTopUp.Quote memory q = _quoteFor("a4", ACCOUNT, 1);
        bytes memory sig = _sign(q);
        vm.startPrank(payer);
        bim.approve(address(topUp), q.bimAmount);
        vm.expectRevert(
            abi.encodeWithSelector(BIMCreditTopUp.AccountCapExceeded.selector, ACCOUNT, PER_ACCOUNT + 1, PER_ACCOUNT)
        );
        topUp.pay(q, sig, q.bimAmount);
        vm.stopPrank();
    }

    function test_DailyCapExactlyFilledThenOneCentReverts() public {
        for (uint256 i; i < 10; ++i) {
            _payAs(bytes32(i + 1), keccak256(abi.encode("org", i)), 2_000_00); // 10 accounts x $2,000 = $20,000
        }
        assertEq(topUp.availableUsdCentsToday(), 0);
        BIMCreditTopUp.Quote memory q = _quoteFor("late", keccak256("org-late"), 1);
        bytes memory sig = _sign(q);
        vm.startPrank(payer);
        bim.approve(address(topUp), q.bimAmount);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.DailyCapExceeded.selector, PER_DAY + 1, PER_DAY));
        topUp.pay(q, sig, q.bimAmount);
        vm.stopPrank();
    }

    /// One account using its whole allowance cannot block other customers.
    function test_OneAccountCannotLockOutOthers() public {
        _payAs("x1", ACCOUNT, 2_000_00);
        _payAs("x2", ACCOUNT, 2_000_00);
        _payAs("x3", ACCOUNT, 1_000_00);
        _payAs("y1", keccak256("org-43"), 1_00);
        assertTrue(topUp.settled("y1"));
    }

    /// Caps drain continuously: no double allowance just after a day or period boundary.
    function test_NoDoubleAllowanceAtBoundary() public {
        for (uint256 i; i < 10; ++i) {
            _payAs(bytes32(i + 1), keccak256(abi.encode("org", i)), 2_000_00);
        }
        vm.warp((block.timestamp / 1 days + 1) * 1 days); // the next UTC midnight
        uint256 available = topUp.availableUsdCentsToday();
        assertLt(available, PER_DAY); // not a fresh $20,000
        assertEq(available, uint256(PER_DAY) * (block.timestamp - 1_790_000_000) / 1 days);
    }

    function test_CapsRefillOverTime() public {
        _payAs("a1", ACCOUNT, 2_000_00);
        _payAs("a2", ACCOUNT, 2_000_00);
        _payAs("a3", ACCOUNT, 1_000_00);
        vm.warp(block.timestamp + 15 days); // half of the 30-day window
        assertEq(topUp.availableUsdCentsForAccount(ACCOUNT), PER_ACCOUNT / 2);
        _payAs("a4", ACCOUNT, 2_000_00);
        vm.warp(block.timestamp + 30 days);
        assertEq(topUp.availableUsdCentsForAccount(ACCOUNT), PER_ACCOUNT);
    }

    // ------------------------------------------------------ guardian powers
    function test_GuardianCanOnlyStop() public {
        vm.startPrank(guardian);
        topUp.pause();
        vm.expectPartialRevert(UNAUTHORIZED);
        topUp.unpause();
        topUp.revokeQuoteSigner();
        topUp.tightenLimits(BIMCreditTopUp.Limits(1_000_00, 10_000_00, 4_000_00));
        vm.expectRevert(BIMCreditTopUp.LimitNotTightened.selector);
        topUp.tightenLimits(BIMCreditTopUp.Limits(1_000_01, 10_000_00, 4_000_00));
        vm.expectRevert(BIMCreditTopUp.LimitNotTightened.selector);
        topUp.tightenLimits(BIMCreditTopUp.Limits(1_000_00, 10_000_01, 4_000_00));
        vm.expectRevert(BIMCreditTopUp.LimitNotTightened.selector);
        topUp.tightenLimits(BIMCreditTopUp.Limits(1_000_00, 10_000_00, 4_000_01));
        vm.expectPartialRevert(UNAUTHORIZED);
        topUp.setLimits(BIMCreditTopUp.Limits(10_000_00, 10_000_00, type(uint64).max));
        vm.expectPartialRevert(UNAUTHORIZED);
        topUp.setMinBimPerUsd(2e18);
        vm.expectPartialRevert(UNAUTHORIZED);
        topUp.setQuoteSigner(guardian);
        vm.expectPartialRevert(UNAUTHORIZED);
        topUp.setRevenueSafe(guardian);
        vm.expectPartialRevert(UNAUTHORIZED);
        topUp.rescueTokens(IERC20(address(bim)), guardian, 1);
        bytes32 relayerRole = topUp.RELAYER_ROLE();
        vm.expectPartialRevert(UNAUTHORIZED);
        topUp.grantRole(relayerRole, guardian);
        vm.stopPrank();
        (uint64 perPayment, uint64 perDay, uint64 perAccount) = topUp.limits();
        assertEq(perPayment, 1_000_00);
        assertEq(perDay, 10_000_00);
        assertEq(perAccount, 4_000_00);
    }

    function test_AttackerCannotStopOrSetAnything() public {
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.NotGuardianOrAdmin.selector, attacker));
        topUp.pause();
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.NotGuardianOrAdmin.selector, attacker));
        topUp.cancelOrder("o1");
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.NotGuardianOrAdmin.selector, attacker));
        topUp.revokeQuoteSigner();
        vm.expectPartialRevert(UNAUTHORIZED);
        topUp.setLimits(BIMCreditTopUp.Limits(1, 1, 1));
        vm.expectPartialRevert(UNAUTHORIZED);
        topUp.rescueTokens(IERC20(address(bim)), attacker, 1);
        vm.stopPrank();
    }

    function test_PauseBlocksEveryPaymentPath() public {
        _grantRelayer();
        BIMCreditTopUp.Quote memory q = _quote("o1", 100e18, 10_000);
        bytes memory sig = _sign(q);
        uint256 deadline = block.timestamp + 15 minutes;
        (uint8 v, bytes32 r, bytes32 s) = _permit(100e18, deadline);
        vm.prank(payer);
        bim.approve(address(topUp), 100e18);
        vm.prank(guardian);
        topUp.pause();

        vm.prank(payer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        topUp.pay(q, sig, 100e18);
        vm.prank(relayer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        topUp.payWithPermit(q, sig, 100e18, deadline, v, r, s);
        vm.prank(payer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        topUp.payWithPermit(q, sig, 100e18, deadline, v, r, s);
        vm.prank(payer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        topUp.payWithPermit(q, sig, 100e18, deadline, 27, bytes32(0), bytes32(0));
        assertEq(bim.balanceOf(revenueSafe), 0);
        assertFalse(topUp.settled("o1"));

        _viaTimelock(abi.encodeCall(BIMCreditTopUp.unpause, ()));
        q = _quote("o2", 100e18, 10_000);
        sig = _sign(q);
        vm.prank(guardian);
        topUp.revokeQuoteSigner();
        vm.prank(payer);
        vm.expectRevert(BIMCreditTopUp.NoQuoteSigner.selector);
        topUp.pay(q, sig, 100e18);
    }

    function test_GuardianCancelsOneStaleQuoteWithoutPausing() public {
        BIMCreditTopUp.Quote memory stale = _quote("stale", 100e18, 10_000);
        bytes memory staleSig = _sign(stale);
        vm.prank(payer);
        bim.approve(address(topUp), type(uint256).max);
        vm.prank(guardian);
        vm.expectEmit(address(topUp));
        emit BIMCreditTopUp.OrderCancelled("stale");
        topUp.cancelOrder("stale");
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.OrderIsCancelled.selector, stale.orderId));
        topUp.pay(stale, staleSig, 100e18);
        BIMCreditTopUp.Quote memory fresh = _quote("fresh", 150e18, 10_000);
        _approveAndPay(fresh);
        assertTrue(topUp.settled(fresh.orderId));
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.OrderAlreadySettled.selector, fresh.orderId));
        topUp.cancelOrder(fresh.orderId);
    }

    // ------------------------------------------------------ admin recovery
    function test_SignerRotationAfterRevokeRestoresPayments() public {
        vm.prank(guardian);
        topUp.revokeQuoteSigner();
        uint256 newKey = 0x5157;
        _viaTimelock(abi.encodeCall(BIMCreditTopUp.setQuoteSigner, (vm.addr(newKey))));
        assertEq(topUp.quoteSigner(), vm.addr(newKey));

        BIMCreditTopUp.Quote memory q = _quote("old", 100e18, 10_000);
        bytes memory oldSig = _sign(q);
        vm.startPrank(payer);
        bim.approve(address(topUp), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.InvalidQuoteSignature.selector, signer));
        topUp.pay(q, oldSig, 100e18);
        topUp.pay(q, _signWith(newKey, q), 100e18);
        vm.stopPrank();
        assertTrue(topUp.settled("old"));
    }

    function test_RevenueSafeRotationRedirectsPayments() public {
        address newSafe = makeAddr("newRevenueSafe");
        _viaTimelock(abi.encodeCall(BIMCreditTopUp.setRevenueSafe, (newSafe)));
        assertEq(topUp.revenueSafe(), newSafe);
        _approveAndPay(_quote("o1", 100e18, 10_000));
        assertEq(bim.balanceOf(newSafe), 100e18);
        assertEq(bim.balanceOf(revenueSafe), 0);
    }

    function test_SetLimitsViaTimelockCanRaiseCaps() public {
        _viaTimelock(abi.encodeCall(BIMCreditTopUp.setLimits, (BIMCreditTopUp.Limits(4_000_00, 40_000_00, 9_000_00))));
        (uint64 perPayment, uint64 perDay, uint64 perAccount) = topUp.limits();
        assertEq(perPayment, 4_000_00);
        assertEq(perDay, 40_000_00);
        assertEq(perAccount, 9_000_00);
    }

    function test_RevertWhen_SetQuoteSignerToZero() public {
        vm.prank(address(timelock));
        vm.expectRevert(BIMCreditTopUp.ZeroAddress.selector);
        topUp.setQuoteSigner(address(0));
    }

    function test_DefaultAdminCannotBeGrantedDirectly() public {
        bytes32 adminRole = topUp.DEFAULT_ADMIN_ROLE();
        vm.prank(address(timelock));
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        topUp.grantRole(adminRole, attacker);
    }

    // ------------------------------------------------------ floor governance
    function test_FloorChangesOnlyThroughTimelock() public {
        vm.prank(safe); // the Safe alone cannot bypass the timelock
        vm.expectPartialRevert(UNAUTHORIZED);
        topUp.setMinBimPerUsd(0.7e18);

        // lowering is not allowed within 30 days of launch
        bytes memory lower = abi.encodeCall(BIMCreditTopUp.setMinBimPerUsd, (0.7e18));
        vm.prank(safe);
        timelock.schedule(address(topUp), 0, lower, bytes32(0), "early", 48 hours);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(safe);
        vm.expectRevert(); // FloorDecreaseTooSoon bubbled through TimelockController
        timelock.execute(address(topUp), 0, lower, bytes32(0), "early");

        vm.warp(block.timestamp + 30 days);
        _viaTimelock(lower, "later"); // -30% exactly
        assertEq(topUp.minBimPerUsd(), 0.7e18);
    }

    function test_FloorStepBounds() public {
        vm.startPrank(address(timelock)); // call as the admin directly to test the math
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.FloorStepTooLarge.selector, 1e18, 2e18 + 1));
        topUp.setMinBimPerUsd(2e18 + 1);
        topUp.setMinBimPerUsd(2e18); // raise up to 2x
        vm.warp(block.timestamp + 91 days); // past the undo window: normal decrease rules apply
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.FloorStepTooLarge.selector, 2e18, 1.4e18 - 1));
        topUp.setMinBimPerUsd(1.4e18 - 1);
        topUp.setMinBimPerUsd(1.4e18);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.FloorDecreaseTooSoon.selector, block.timestamp + 30 days));
        topUp.setMinBimPerUsd(1.3e18);
        vm.expectRevert(BIMCreditTopUp.FloorUnchanged.selector);
        topUp.setMinBimPerUsd(1.4e18);
        vm.stopPrank();
    }

    /// Several raises batched into one timelock operation cannot exceed 2x.
    function test_BatchedRaisesAreLimitedToTwoX() public {
        vm.startPrank(address(timelock));
        topUp.setMinBimPerUsd(2e18);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.FloorRaiseTooSoon.selector, block.timestamp + 7 days));
        topUp.setMinBimPerUsd(4e18);
        vm.warp(block.timestamp + 7 days);
        topUp.setMinBimPerUsd(4e18);
        vm.stopPrank();
        assertEq(topUp.minBimPerUsd(), 4e18);
    }

    /// A mistaken or outdated raise can be undone at once, but never below the pre-raise floor.
    function test_RecentRaiseCanBeUndoneImmediately() public {
        vm.startPrank(address(timelock));
        topUp.setMinBimPerUsd(2e18);
        topUp.setMinBimPerUsd(1e18); // back to the pre-raise floor, same day, no -30% limit
        assertEq(topUp.minBimPerUsd(), 1e18);
        vm.expectRevert(abi.encodeWithSelector(BIMCreditTopUp.FloorDecreaseTooSoon.selector, 1_790_000_000 + 30 days));
        topUp.setMinBimPerUsd(0.9e18); // below the pre-raise floor: normal rules
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

/// Random payments by an honest signer, a signer that undercharges, strangers and governance.
/// Violations are recorded as ghost flags and asserted by the invariants, so a handler revert
/// can never hide one.
contract Handler is Test {
    BIMCreditTopUp topUp;
    BIMCoin bim;
    address timelock;
    address guardian;
    address public relayer = makeAddr("handlerRelayer");
    uint256 signerKey;
    uint256[] payerKeys;
    uint256 nonce;

    uint256 public payCalls;
    uint256 public ghostSettledBim;
    uint256 public ghostSettledCount;
    bool public ghostBelowFloor;
    bool public ghostReplay;
    bool public ghostCancelledSettled;
    bool public ghostStrangerSpent;
    bool public ghostDailyOverCap;
    bool public ghostAccountOverCap;
    mapping(bytes32 => bool) ghostSettledIds;
    mapping(bytes32 => bool) ghostCancelledIds;
    // Independent leaky-bucket model of the caps.
    uint256 modelDayLevel;
    uint256 modelDayAt;
    mapping(bytes32 => uint256) modelAccountLevel;
    mapping(bytes32 => uint256) modelAccountAt;

    constructor(BIMCreditTopUp t, BIMCoin b, address tl, address g, uint256 sk, uint256[] memory pks) {
        topUp = t;
        bim = b;
        timelock = tl;
        guardian = g;
        signerKey = sk;
        payerKeys = pks;
    }

    function pay(uint256 who, uint64 cents, uint256 bimAmount, uint8 acct, bool reuseId, uint32 dt) external {
        vm.warp(block.timestamp + (dt % 2 days));
        ++payCalls;
        cents = uint64(bound(cents, 1, 2_000_00));
        // Mostly valid amounts, with about 5% below the floor so rejections are exercised too.
        uint256 minimum = topUp.minimumBimFor(cents);
        bimAmount = bound(bimAmount, minimum * 9 / 10, minimum * 3);
        bool replay = reuseId && dt % 4 == 0 && nonce > 0;
        BIMCreditTopUp.Quote memory q = BIMCreditTopUp.Quote({
            orderId: replay ? bytes32(nonce - 1) : bytes32(nonce++),
            accountRef: bytes32(uint256(acct % 16)),
            payer: vm.addr(payerKeys[who % payerKeys.length]),
            bimAmount: bimAmount,
            usdCents: cents,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 900)
        });
        _attemptPayment(q);
    }

    /// Several $2,000 payments at the same moment, to push the caps hard.
    function payBurst(uint8 acct, uint8 count, uint256 who) external {
        count = uint8(bound(count, 1, 12));
        for (uint256 i; i < count; ++i) {
            ++payCalls;
            BIMCreditTopUp.Quote memory q = BIMCreditTopUp.Quote({
                orderId: bytes32(nonce++),
                accountRef: bytes32(uint256((acct + i / 3) % 16)),
                payer: vm.addr(payerKeys[who % payerKeys.length]),
                bimAmount: topUp.minimumBimFor(2_000_00),
                usdCents: 2_000_00,
                issuedAt: uint64(block.timestamp),
                expiresAt: uint64(block.timestamp + 900)
            });
            _attemptPayment(q);
        }
    }

    function _attemptPayment(BIMCreditTopUp.Quote memory q) internal {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, topUp.hashQuote(q));
        uint256 floor = topUp.minBimPerUsd();
        vm.startPrank(q.payer);
        bim.approve(address(topUp), q.bimAmount);
        try topUp.pay(q, abi.encodePacked(r, s, v), q.bimAmount) {
            ghostSettledBim += q.bimAmount;
            ++ghostSettledCount;
            if (q.bimAmount * 100 < uint256(q.usdCents) * floor) ghostBelowFloor = true;
            if (ghostSettledIds[q.orderId]) ghostReplay = true;
            if (ghostCancelledIds[q.orderId]) ghostCancelledSettled = true;
            ghostSettledIds[q.orderId] = true;
            _recordCaps(q.accountRef, q.usdCents);
        } catch {}
        bim.approve(address(topUp), 0);
        vm.stopPrank();
    }

    function strangerPays(uint256 who, uint64 cents) external {
        address p = vm.addr(payerKeys[who % payerKeys.length]);
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
        vm.prank(who % 2 == 0 ? address(0xBAD) : relayer);
        try topUp.payWithPermit(q, abi.encodePacked(r, s, v), q.bimAmount, 0, 0, 0, 0) {
            ghostStrangerSpent = true;
        } catch {}
        vm.prank(p);
        bim.approve(address(topUp), 0);
    }

    function cancel(uint256 idSeed) external {
        bytes32 id = bytes32(nonce + (idSeed % 3)); // upcoming ids, so some cancelled ids get quoted later
        vm.prank(guardian);
        try topUp.cancelOrder(id) {
            ghostCancelledIds[id] = true;
        } catch {}
    }

    function changeFloor(uint256 newFloor) external {
        newFloor = bound(newFloor, 0.5e18, 4e18);
        vm.prank(timelock);
        try topUp.setMinBimPerUsd(newFloor) {} catch {}
    }

    function _recordCaps(bytes32 accountRef, uint64 cents) internal {
        (, uint64 perDay, uint64 perAccount) = topUp.limits();
        modelDayLevel = _drain(modelDayLevel, modelDayAt, perDay, 1 days) + cents;
        modelDayAt = block.timestamp;
        if (modelDayLevel > perDay) ghostDailyOverCap = true;
        modelAccountLevel[accountRef] =
            _drain(modelAccountLevel[accountRef], modelAccountAt[accountRef], perAccount, 30 days) + cents;
        modelAccountAt[accountRef] = block.timestamp;
        if (modelAccountLevel[accountRef] > perAccount) ghostAccountOverCap = true;
    }

    function _drain(uint256 level, uint256 at, uint256 cap, uint256 window) internal view returns (uint256) {
        uint256 drained = cap * (block.timestamp - at) / window;
        return level > drained ? level - drained : 0;
    }
}

/// forge-config: default.invariant.fail-on-revert = true
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
        handler = new Handler(topUp, bim, address(timelock), guardian, signerKey, pks);
        bytes32 relayerRole = topUp.RELAYER_ROLE();
        address handlerRelayer = handler.relayer();
        vm.prank(address(timelock));
        topUp.grantRole(relayerRole, handlerRelayer);
        targetContract(address(handler));
    }

    /// Guards against vacuous runs: with most generated payments valid, a run with many payment
    /// attempts and no settlement means payments are broken, not unlucky.
    function afterInvariant() external view {
        if (handler.payCalls() >= 16) {
            assertGt(handler.ghostSettledCount(), 0, "no payment ever settled: invariants would be vacuous");
        }
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

    function invariant_NeverBelowFloor() public view {
        assertFalse(handler.ghostBelowFloor());
    }

    function invariant_NoOrderSettlesTwice() public view {
        assertFalse(handler.ghostReplay());
    }

    function invariant_CancelledOrdersNeverSettle() public view {
        assertFalse(handler.ghostCancelledSettled());
    }

    function invariant_StrangerNeverSpendsAllowance() public view {
        assertFalse(handler.ghostStrangerSpent());
    }

    function invariant_CapsHoldAgainstIndependentModel() public view {
        assertFalse(handler.ghostDailyOverCap());
        assertFalse(handler.ghostAccountOverCap());
    }
}
