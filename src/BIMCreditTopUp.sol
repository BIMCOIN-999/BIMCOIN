// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";

/// @title BIMCreditTopUp
/// @notice Lets a customer pay for off-chain, USD-denominated CBIONE / DaVinci credits with BIM.
///         The billing backend converts the USD list price (net of tax) at the market price and
///         signs a short-lived quote for the exact BIM amount. The contract enforces an on-chain
///         floor of `minBimPerUsd` BIM per US$1 of list price, single-use orders, payer binding,
///         and USD caps. It never holds BIM: every payment moves straight from the payer to
///         `revenueSafe` in the same transaction.
///         The floor is a safety net, not the price: it stops even a compromised backend from
///         crediting more than $1 per `minBimPerUsd` BIM.
/// @dev Admin (DEFAULT_ADMIN_ROLE) = an OpenZeppelin TimelockController (48 h) whose proposer,
///      executor and canceller is the ConstruBIM Safe. GUARDIAN_ROLE (ops Safe) can only stop
///      things: pause, revoke the quote signer, cancel an order, lower caps. RELAYER_ROLE
///      (granted by the admin) may submit `payWithPermit` on behalf of payers.
contract BIMCreditTopUp is EIP712, AccessControlDefaultAdminRules, Pausable {
    using SafeERC20 for IERC20;

    struct Quote {
        bytes32 orderId; // random 32 bytes from the billing DB, single use
        bytes32 accountRef; // HMAC(secret, orgId): no personal data on-chain
        address payer; // the only wallet the BIM can be pulled from
        uint256 bimAmount; // exact BIM (18 decimals) to pay
        uint64 usdCents; // USD value credited, NET of VAT/IVA/sales tax
        uint64 issuedAt; // unix seconds, at most MAX_CLOCK_SKEW in the future
        uint64 expiresAt; // unix seconds, at most MAX_QUOTE_TTL after issuedAt
    }

    /// @dev The daily and per-account caps are leaky buckets: each payment adds its USD value and
    ///      the level drains linearly at cap/window per second. A burst can never exceed the cap,
    ///      and any span of t seconds settles at most cap * (1 + t / window).
    struct Limits {
        uint64 maxUsdCentsPerPayment;
        uint64 maxUsdCentsPerDay; // all accounts; window 1 day
        uint64 maxUsdCentsPerAccountPerPeriod; // per accountRef; window ACCOUNT_PERIOD
    }

    struct Bucket {
        uint192 level; // USD cents
        uint64 updatedAt;
    }

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "Quote(bytes32 orderId,bytes32 accountRef,address payer,uint256 bimAmount,uint64 usdCents,uint64 issuedAt,uint64 expiresAt)"
    );
    uint64 public constant MAX_QUOTE_TTL = 30 minutes;
    uint64 public constant MAX_CLOCK_SKEW = 1 minutes;
    uint256 public constant MAX_FLOOR_DECREASE_BPS = 3_000; // at most -30% per step
    uint256 public constant FLOOR_DECREASE_INTERVAL = 30 days; // at most one decrease per 30 days
    uint256 public constant FLOOR_RAISE_INTERVAL = 7 days; // at most one raise (<= 2x) per 7 days
    uint256 public constant FLOOR_UNDO_WINDOW = 90 days; // a recent raise can be undone without limits
    uint256 public constant DAY = 1 days;
    uint256 public constant ACCOUNT_PERIOD = 30 days;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable BIM;

    uint256 public minBimPerUsd;
    uint256 public floorBeforeLastRaise;
    uint64 public lastFloorDecreaseAt;
    uint64 public lastFloorRaiseAt;
    address public quoteSigner;
    address public revenueSafe;
    Limits public limits;
    mapping(bytes32 orderId => bool) public settled;
    mapping(bytes32 orderId => bool) public cancelled;
    Bucket public dailyBucket;
    mapping(bytes32 accountRef => Bucket) public accountBuckets;

    event PaymentSettled(
        bytes32 indexed orderId,
        bytes32 indexed accountRef,
        address indexed payer,
        uint256 bimAmount,
        uint64 usdCents,
        uint256 minBimPerUsd
    );
    event OrderCancelled(bytes32 indexed orderId);
    event MinBimPerUsdUpdated(uint256 previous, uint256 current);
    event LimitsUpdated(uint64 maxUsdCentsPerPayment, uint64 maxUsdCentsPerDay, uint64 maxUsdCentsPerAccountPerPeriod);
    event QuoteSignerUpdated(address indexed previous, address indexed current);
    event RevenueSafeUpdated(address indexed previous, address indexed current);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroFloor();
    error InvalidRevenueSafe(address revenueSafe);
    error InvalidPayer(address payer);
    error ZeroAmount();
    error NotPayer(address caller, address payer);
    error SlippageExceeded(uint256 bimAmount, uint256 maxBim);
    error QuoteNotYetValid(uint64 issuedAt);
    error QuoteExpired(uint64 expiresAt);
    error QuoteTtlTooLong(uint64 issuedAt, uint64 expiresAt);
    error OrderAlreadySettled(bytes32 orderId);
    error OrderIsCancelled(bytes32 orderId);
    error BelowMinimumRate(uint256 bimAmount, uint256 minimumBim);
    error NoQuoteSigner();
    error InvalidQuoteSignature(address recovered);
    error PaymentTooLarge(uint256 usdCents, uint256 maxUsdCentsPerPayment);
    error DailyCapExceeded(uint256 dayLevelUsdCents, uint256 maxUsdCentsPerDay);
    error AccountCapExceeded(bytes32 accountRef, uint256 accountLevelUsdCents, uint256 maxUsdCentsPerAccountPerPeriod);
    error FloorUnchanged();
    error FloorStepTooLarge(uint256 current, uint256 proposed);
    error FloorDecreaseTooSoon(uint256 nextAllowedAt);
    error FloorRaiseTooSoon(uint256 nextAllowedAt);
    error LimitNotTightened();
    error NotGuardianOrAdmin(address caller);

    modifier onlyGuardianOrAdmin() {
        _checkGuardianOrAdmin();
        _;
    }

    constructor(
        IERC20 bim,
        address admin,
        uint48 adminTransferDelay,
        address[] memory guardians,
        address quoteSigner_,
        address revenueSafe_,
        uint256 initialMinBimPerUsd,
        Limits memory initialLimits
    ) EIP712("BIMCreditTopUp", "1") AccessControlDefaultAdminRules(adminTransferDelay, admin) {
        if (address(bim) == address(0) || quoteSigner_ == address(0)) revert ZeroAddress();
        if (initialMinBimPerUsd == 0) revert ZeroFloor();
        BIM = bim;
        for (uint256 i; i < guardians.length; ++i) {
            if (guardians[i] == address(0)) revert ZeroAddress();
            _grantRole(GUARDIAN_ROLE, guardians[i]);
        }
        _setRevenueSafe(revenueSafe_);
        quoteSigner = quoteSigner_;
        emit QuoteSignerUpdated(address(0), quoteSigner_);
        minBimPerUsd = initialMinBimPerUsd;
        floorBeforeLastRaise = initialMinBimPerUsd;
        lastFloorDecreaseAt = uint64(block.timestamp);
        emit MinBimPerUsdUpdated(0, initialMinBimPerUsd);
        _setLimits(initialLimits);
    }

    // ------------------------------------------------------------------ payments

    /// @notice Pay a quote from the caller's own wallet using an existing allowance
    ///         (EOA after `approve`, or a smart wallet batching approve + pay).
    function pay(Quote calldata q, bytes calldata signature, uint256 maxBim) external whenNotPaused {
        if (msg.sender != q.payer) revert NotPayer(msg.sender, q.payer);
        _settle(q, signature, maxBim);
    }

    /// @notice Pay with an EIP-2612 permit (value = maxBim) so an approved relayer can pay the gas.
    /// @dev Only the payer or a RELAYER_ROLE holder may call. A permit is not bound to a quote, so
    ///      letting anyone submit it would let a third party pair a leftover permit with another
    ///      of the payer's open quotes. If the permit fails (front-run or invalid), only the payer
    ///      may continue on an existing allowance: a relayer never spends a standing allowance.
    function payWithPermit(
        Quote calldata q,
        bytes calldata signature,
        uint256 maxBim,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external whenNotPaused {
        if (msg.sender != q.payer && !hasRole(RELAYER_ROLE, msg.sender)) revert NotPayer(msg.sender, q.payer);
        try IERC20Permit(address(BIM)).permit(q.payer, address(this), maxBim, permitDeadline, v, r, s) {}
        catch {
            if (msg.sender != q.payer) revert NotPayer(msg.sender, q.payer);
        }
        _settle(q, signature, maxBim);
    }

    function hashQuote(Quote calldata q) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    QUOTE_TYPEHASH, q.orderId, q.accountRef, q.payer, q.bimAmount, q.usdCents, q.issuedAt, q.expiresAt
                )
            )
        );
    }

    /// @notice Smallest BIM amount the floor allows for `usdCents` (rounded up).
    function minimumBimFor(uint64 usdCents) public view returns (uint256) {
        return Math.mulDiv(usdCents, minBimPerUsd, 100, Math.Rounding.Ceil);
    }

    /// @notice USD cents that can still settle right now across all accounts.
    function availableUsdCentsToday() external view returns (uint256) {
        uint64 cap = limits.maxUsdCentsPerDay;
        return cap - Math.min(cap, _drainedLevel(dailyBucket, cap, DAY));
    }

    /// @notice USD cents `accountRef` can still settle right now (ignoring the daily cap).
    function availableUsdCentsForAccount(bytes32 accountRef) external view returns (uint256) {
        uint64 cap = limits.maxUsdCentsPerAccountPerPeriod;
        return cap - Math.min(cap, _drainedLevel(accountBuckets[accountRef], cap, ACCOUNT_PERIOD));
    }

    function _settle(Quote calldata q, bytes calldata signature, uint256 maxBim) private {
        if (q.bimAmount == 0 || q.usdCents == 0) revert ZeroAmount();
        if (q.bimAmount > maxBim) revert SlippageExceeded(q.bimAmount, maxBim);
        if (q.issuedAt > block.timestamp + MAX_CLOCK_SKEW) revert QuoteNotYetValid(q.issuedAt);
        if (block.timestamp > q.expiresAt) revert QuoteExpired(q.expiresAt);
        if (q.expiresAt > q.issuedAt + MAX_QUOTE_TTL) revert QuoteTtlTooLong(q.issuedAt, q.expiresAt);
        if (settled[q.orderId]) revert OrderAlreadySettled(q.orderId);
        if (cancelled[q.orderId]) revert OrderIsCancelled(q.orderId);
        // A self-payment would emit PaymentSettled while no BIM moves.
        if (q.payer == revenueSafe) revert InvalidPayer(q.payer);

        uint256 minimumBim = minimumBimFor(q.usdCents);
        if (q.bimAmount < minimumBim) revert BelowMinimumRate(q.bimAmount, minimumBim);

        address signer = quoteSigner;
        if (signer == address(0)) revert NoQuoteSigner();
        address recovered = ECDSA.recoverCalldata(hashQuote(q), signature);
        if (recovered != signer) revert InvalidQuoteSignature(recovered);

        settled[q.orderId] = true;
        _consumeLimits(q.accountRef, q.usdCents);

        BIM.safeTransferFrom(q.payer, revenueSafe, q.bimAmount);
        emit PaymentSettled(q.orderId, q.accountRef, q.payer, q.bimAmount, q.usdCents, minBimPerUsd);
    }

    /// @dev Checks and records the per-payment cap and the daily and per-account leaky buckets.
    function _consumeLimits(bytes32 accountRef, uint64 usdCents) private {
        Limits memory l = limits;
        if (usdCents > l.maxUsdCentsPerPayment) revert PaymentTooLarge(usdCents, l.maxUsdCentsPerPayment);
        uint256 dayLevel = _drainedLevel(dailyBucket, l.maxUsdCentsPerDay, DAY) + usdCents;
        if (dayLevel > l.maxUsdCentsPerDay) revert DailyCapExceeded(dayLevel, l.maxUsdCentsPerDay);
        uint256 accountLevel =
            _drainedLevel(accountBuckets[accountRef], l.maxUsdCentsPerAccountPerPeriod, ACCOUNT_PERIOD) + usdCents;
        if (accountLevel > l.maxUsdCentsPerAccountPerPeriod) {
            revert AccountCapExceeded(accountRef, accountLevel, l.maxUsdCentsPerAccountPerPeriod);
        }
        // Both levels are at most a uint64 cap, so the casts cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        dailyBucket = Bucket({level: uint192(dayLevel), updatedAt: uint64(block.timestamp)});
        // forge-lint: disable-next-line(unsafe-typecast)
        accountBuckets[accountRef] = Bucket({level: uint192(accountLevel), updatedAt: uint64(block.timestamp)});
    }

    function _drainedLevel(Bucket memory b, uint256 cap, uint256 window) private view returns (uint256) {
        uint256 drained = Math.mulDiv(cap, block.timestamp - b.updatedAt, window);
        return b.level > drained ? b.level - drained : 0;
    }

    // --------------------------------------------------------- guardian (stop-only)

    function pause() external onlyGuardianOrAdmin {
        _pause();
    }

    function revokeQuoteSigner() external onlyGuardianOrAdmin {
        emit QuoteSignerUpdated(quoteSigner, address(0));
        quoteSigner = address(0);
    }

    /// @notice Void one open quote, e.g. after the BIM price moved, without pausing every payment.
    function cancelOrder(bytes32 orderId) external onlyGuardianOrAdmin {
        if (settled[orderId]) revert OrderAlreadySettled(orderId);
        cancelled[orderId] = true;
        emit OrderCancelled(orderId);
    }

    function tightenLimits(Limits calldata l) external onlyGuardianOrAdmin {
        Limits memory c = limits;
        if (
            l.maxUsdCentsPerPayment > c.maxUsdCentsPerPayment || l.maxUsdCentsPerDay > c.maxUsdCentsPerDay
                || l.maxUsdCentsPerAccountPerPeriod > c.maxUsdCentsPerAccountPerPeriod
        ) revert LimitNotTightened();
        _setLimits(l);
    }

    // ------------------------------------------------------ admin (timelock, 48 h)

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Raise the floor by at most 2x, once per 7 days. Lower it by at most 30%, once per
    ///         30 days, except that within 90 days of a raise it may return to any value not below
    ///         the floor before that raise.
    function setMinBimPerUsd(uint256 newFloor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 current = minBimPerUsd;
        if (newFloor == current) revert FloorUnchanged();
        if (newFloor > current) {
            if (newFloor > current * 2) revert FloorStepTooLarge(current, newFloor);
            if (lastFloorRaiseAt != 0) {
                uint256 nextRaiseAt = uint256(lastFloorRaiseAt) + FLOOR_RAISE_INTERVAL;
                if (block.timestamp < nextRaiseAt) revert FloorRaiseTooSoon(nextRaiseAt);
            }
            floorBeforeLastRaise = current;
            lastFloorRaiseAt = uint64(block.timestamp);
        } else if (!_isUndoOfRecentRaise(newFloor)) {
            if (newFloor * 10_000 < current * (10_000 - MAX_FLOOR_DECREASE_BPS)) {
                revert FloorStepTooLarge(current, newFloor);
            }
            uint256 nextDecreaseAt = uint256(lastFloorDecreaseAt) + FLOOR_DECREASE_INTERVAL;
            if (block.timestamp < nextDecreaseAt) revert FloorDecreaseTooSoon(nextDecreaseAt);
            lastFloorDecreaseAt = uint64(block.timestamp);
        }
        emit MinBimPerUsdUpdated(current, newFloor);
        minBimPerUsd = newFloor;
    }

    function setLimits(Limits calldata l) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setLimits(l);
    }

    function setQuoteSigner(address newSigner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSigner == address(0)) revert ZeroAddress();
        emit QuoteSignerUpdated(quoteSigner, newSigner);
        quoteSigner = newSigner;
    }

    function setRevenueSafe(address newRevenueSafe) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRevenueSafe(newRevenueSafe);
    }

    /// @notice Returns tokens (including BIM) sent to this contract by mistake. Payments never rest here.
    function rescueTokens(IERC20 token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit TokensRescued(address(token), to, amount);
    }

    function _isUndoOfRecentRaise(uint256 newFloor) private view returns (bool) {
        return lastFloorRaiseAt != 0 && block.timestamp <= uint256(lastFloorRaiseAt) + FLOOR_UNDO_WINDOW
            && newFloor >= floorBeforeLastRaise;
    }

    function _checkGuardianOrAdmin() private view {
        if (!hasRole(GUARDIAN_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotGuardianOrAdmin(msg.sender);
        }
    }

    function _setLimits(Limits memory l) private {
        limits = l;
        emit LimitsUpdated(l.maxUsdCentsPerPayment, l.maxUsdCentsPerDay, l.maxUsdCentsPerAccountPerPeriod);
    }

    function _setRevenueSafe(address newRevenueSafe) private {
        if (
            newRevenueSafe == address(0) || newRevenueSafe == DEAD || newRevenueSafe == address(this)
                || newRevenueSafe == address(BIM)
        ) revert InvalidRevenueSafe(newRevenueSafe);
        emit RevenueSafeUpdated(revenueSafe, newRevenueSafe);
        revenueSafe = newRevenueSafe;
    }
}
