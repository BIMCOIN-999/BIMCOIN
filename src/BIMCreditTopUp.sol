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
///         The billing backend signs a short-lived quote (exact BIM amount for a USD list price, net
///         of tax). The contract enforces an on-chain floor of `minBimPerUsd` BIM per US$1 of list
///         price, single-use orders, payer binding, and USD caps. It never holds BIM: every payment
///         moves straight from the payer to `revenueSafe` in the same transaction.
///         Example: AI usage is listed at 3x its AI cost and BIM sells at $1, so the launch floor is
///         1 BIM per $1 of list price, i.e. 3 BIM per $1 of AI cost. If BIM trades below $1 the
///         backend quotes more BIM; the floor stops it from ever quoting fewer.
/// @dev Admin (DEFAULT_ADMIN_ROLE) = an OpenZeppelin TimelockController (48 h) whose proposer,
///      executor and canceller is the ConstruBIM Safe. GUARDIAN_ROLE (ops Safe + monitoring bot)
///      can only stop things: pause, revoke the quote signer, lower caps.
contract BIMCreditTopUp is EIP712, AccessControlDefaultAdminRules, Pausable {
    using SafeERC20 for IERC20;

    struct Quote {
        bytes32 orderId; // random 32 bytes from the billing DB, single use
        bytes32 accountRef; // HMAC(secret, orgId): no personal data on-chain
        address payer; // the only wallet the BIM can be pulled from
        uint256 bimAmount; // exact BIM (18 decimals) to pay
        uint64 usdCents; // USD value credited, NET of VAT/IVA/sales tax
        uint64 issuedAt; // unix seconds, must not be in the future
        uint64 expiresAt; // unix seconds, at most MAX_QUOTE_TTL after issuedAt
    }

    struct Limits {
        uint64 maxUsdCentsPerPayment;
        uint64 maxUsdCentsPerDay; // all accounts, per UTC day
        uint64 maxUsdCentsPerAccountPerPeriod; // per accountRef, per fixed 30-day period
    }

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "Quote(bytes32 orderId,bytes32 accountRef,address payer,uint256 bimAmount,uint64 usdCents,uint64 issuedAt,uint64 expiresAt)"
    );
    uint64 public constant MAX_QUOTE_TTL = 30 minutes;
    uint256 public constant MAX_FLOOR_DECREASE_BPS = 3_000; // at most -30% per step
    uint256 public constant FLOOR_DECREASE_INTERVAL = 30 days; // at most one decrease per 30 days
    uint256 public constant ACCOUNT_PERIOD = 30 days;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable BIM;

    uint256 public minBimPerUsd;
    uint64 public lastFloorDecreaseAt;
    address public quoteSigner;
    address public revenueSafe;
    Limits public limits;
    mapping(bytes32 orderId => bool) public settled;
    mapping(uint256 day => uint256 usdCents) public usdCentsSettledOnDay;
    mapping(bytes32 accountRef => mapping(uint256 period => uint256 usdCents)) public usdCentsSettledByAccount;

    event PaymentSettled(
        bytes32 indexed orderId,
        bytes32 indexed accountRef,
        address indexed payer,
        uint256 bimAmount,
        uint64 usdCents,
        uint256 minBimPerUsd
    );
    event MinBimPerUsdUpdated(uint256 previous, uint256 current);
    event LimitsUpdated(uint64 maxUsdCentsPerPayment, uint64 maxUsdCentsPerDay, uint64 maxUsdCentsPerAccountPerPeriod);
    event QuoteSignerUpdated(address indexed previous, address indexed current);
    event RevenueSafeUpdated(address indexed previous, address indexed current);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroFloor();
    error InvalidRevenueSafe(address revenueSafe);
    error ZeroAmount();
    error NotPayer(address caller, address payer);
    error SlippageExceeded(uint256 bimAmount, uint256 maxBim);
    error QuoteNotYetValid(uint64 issuedAt);
    error QuoteExpired(uint64 expiresAt);
    error QuoteTtlTooLong(uint64 issuedAt, uint64 expiresAt);
    error OrderAlreadySettled(bytes32 orderId);
    error BelowMinimumRate(uint256 bimAmount, uint256 minimumBim);
    error NoQuoteSigner();
    error InvalidQuoteSignature(address recovered);
    error PaymentTooLarge(uint256 usdCents, uint256 maxUsdCentsPerPayment);
    error DailyCapExceeded(uint256 dayTotalUsdCents, uint256 maxUsdCentsPerDay);
    error AccountCapExceeded(bytes32 accountRef, uint256 periodTotalUsdCents, uint256 maxUsdCentsPerAccountPerPeriod);
    error FloorUnchanged();
    error FloorStepTooLarge(uint256 current, uint256 proposed);
    error FloorDecreaseTooSoon(uint256 nextAllowedAt);
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

    /// @notice Pay with an EIP-2612 permit (value = maxBim) so a relayer can pay the gas.
    /// @dev If the permit fails (front-run or invalid), only the payer may continue on an
    ///      existing allowance. A relayer can never spend a standing allowance.
    function payWithPermit(
        Quote calldata q,
        bytes calldata signature,
        uint256 maxBim,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external whenNotPaused {
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

    function _settle(Quote calldata q, bytes calldata signature, uint256 maxBim) private {
        if (q.bimAmount == 0 || q.usdCents == 0) revert ZeroAmount();
        if (q.bimAmount > maxBim) revert SlippageExceeded(q.bimAmount, maxBim);
        if (q.issuedAt > block.timestamp) revert QuoteNotYetValid(q.issuedAt);
        if (block.timestamp > q.expiresAt) revert QuoteExpired(q.expiresAt);
        if (q.expiresAt > q.issuedAt + MAX_QUOTE_TTL) revert QuoteTtlTooLong(q.issuedAt, q.expiresAt);
        if (settled[q.orderId]) revert OrderAlreadySettled(q.orderId);

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

    /// @dev Checks and records the per-payment, per-UTC-day and per-account-period USD caps.
    function _consumeLimits(bytes32 accountRef, uint64 usdCents) private {
        Limits memory l = limits;
        if (usdCents > l.maxUsdCentsPerPayment) revert PaymentTooLarge(usdCents, l.maxUsdCentsPerPayment);
        uint256 day = block.timestamp / 1 days;
        uint256 dayTotal = usdCentsSettledOnDay[day] + usdCents;
        if (dayTotal > l.maxUsdCentsPerDay) revert DailyCapExceeded(dayTotal, l.maxUsdCentsPerDay);
        uint256 period = block.timestamp / ACCOUNT_PERIOD;
        uint256 accountTotal = usdCentsSettledByAccount[accountRef][period] + usdCents;
        if (accountTotal > l.maxUsdCentsPerAccountPerPeriod) {
            revert AccountCapExceeded(accountRef, accountTotal, l.maxUsdCentsPerAccountPerPeriod);
        }
        usdCentsSettledOnDay[day] = dayTotal;
        usdCentsSettledByAccount[accountRef][period] = accountTotal;
    }

    // --------------------------------------------------------- guardian (stop-only)

    function pause() external onlyGuardianOrAdmin {
        _pause();
    }

    function revokeQuoteSigner() external onlyGuardianOrAdmin {
        emit QuoteSignerUpdated(quoteSigner, address(0));
        quoteSigner = address(0);
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

    /// @notice Raise the floor by at most 2x per call, or lower it by at most 30%, once per 30 days.
    function setMinBimPerUsd(uint256 newFloor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 current = minBimPerUsd;
        if (newFloor == current) revert FloorUnchanged();
        if (newFloor > current) {
            if (newFloor > current * 2) revert FloorStepTooLarge(current, newFloor);
        } else {
            if (newFloor * 10_000 < current * (10_000 - MAX_FLOOR_DECREASE_BPS)) {
                revert FloorStepTooLarge(current, newFloor);
            }
            uint256 nextAllowedAt = uint256(lastFloorDecreaseAt) + FLOOR_DECREASE_INTERVAL;
            if (block.timestamp < nextAllowedAt) revert FloorDecreaseTooSoon(nextAllowedAt);
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
