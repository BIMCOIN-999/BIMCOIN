# BIMCOIN

Smart contracts for BIMCOIN, the construction-finance token described in the BIMCOIN white paper.

## The live token is on Solana

BIMCOIN already exists as a Solana SPL token:

| | |
|---|---|
| Mint address | `8NPiM567PBD4izq1kK7DVnejSjEWgyUTn7bayvszBWsD` |
| Name / symbol | BIMCOIN / BIM |
| Supply | 21,000,000, fixed: mint authority revoked |
| Freeze authority | Revoked |
| Metadata | Immutable |
| Liquidity pool | LP tokens 100% burned |

The EVM contracts below are reference designs. Do not deploy `BIMCoin.sol` on any chain:
it would create a second, unrelated token with the same name.

## EVM reference token (not deployed)

| | |
|---|---|
| Name / symbol | BIMCOIN / BIMCOIN |
| Standard | ERC-20 with EIP-2612 permit and ERC20Votes (for DAO governance) |
| Supply | 21,000,000 BIMCOIN, fixed |
| Decimals | 18 |
| Chains | Any EVM chain. Recommended: Base |

The entire supply is minted once, at deployment, to a treasury address. The contract has
no mint function, owner, pause or blacklist, so after deployment nobody, including the
founders, can create more BIMCOIN or freeze anyone's balance. Voting power is tracked by
timestamp (`CLOCK_MODE() == "mode=timestamp"`) so a future Governor contract behaves the
same on every chain.

Source: [`src/BIMCoin.sol`](src/BIMCoin.sol). Apart from the fixed supply and the
timestamp clock, all logic comes unchanged from OpenZeppelin Contracts 5.6.1.

### Not in this version: the $1 "stable" token

The white paper also describes a USD-pegged token (SBIM / SBM) for paying project costs.
That is deliberately not implemented. A token only holds $1 if every unit is backed by
$1 of reserves held by a regulated issuer, and minting milestone bonuses in that token
would break the peg. Project payments should use an existing regulated stablecoin
(USDC) held in a milestone escrow contract, which is the planned next component.

## Paying for CBIONE and DaVinci with BIMCOIN

CBIONE and DaVinci bill AI usage at 3x its AI cost, in US dollars. Customers can pay that bill
in BIMCOIN at the market price. BIMCOIN trades in a public pool that nobody can close, so a
fixed rate such as "1 BIMCOIN = $1" would let customers buy BIMCOIN cheaply there and pay
bills at a discount.

[`src/BIMCreditTopUp.sol`](src/BIMCreditTopUp.sol) is an EVM reference design for the on-chain part.
On Solana the same rules apply to each payment:

1. The billing backend measures usage and keeps each customer's USD credit balance. It converts
   the dollar amount at the current market price and signs a 15-minute quote: "this wallet pays
   exactly N BIMCOIN for $X of credit".
2. The customer submits the quote with `pay`, or with `payWithPermit`, which the customer or an
   approved relayer (`RELAYER_ROLE`) can send so the customer pays no gas. A relayer must submit
   a permit for exactly the quote's amount that expires no later than the quote. The BIMCOIN
   moves straight from the customer to the revenue Safe; the contract never holds it.
3. The backend credits the account only when a `PaymentSettled` event's `orderId`, `accountRef`,
   `payer`, `bimAmount` and `usdCents` all match a quote it stored, and credits exactly the
   event's `usdCents`. On any mismatch it credits nothing, alerts, and revokes the quote signer.

### What the contract enforces

- **Floor.** No payment settles below `minBimPerUsd` BIMCOIN per $1 of list price, so a leaked
  quote-signing key cannot settle a payment for less. It does not protect the backend's own
  credit ledger. The floor is a safety net, not the price: set it a little below the market
  amount. When BIMCOIN trades above the price the floor implies, BIMCOIN payers pay more than
  the USD list price until governance lowers the floor, so the backend quotes the larger of the
  market amount and `minimumBimFor(usdCents)`.
- **Single use.** Each `orderId` settles once. A guardian can `cancelOrder` open quotes, for
  example after the price moves, without pausing everyone. Cancelling an order that has already
  settled does nothing, so a batch of cancellations still goes through.
- **Caps**, in US cents: per payment, a daily cap across all accounts, and a per-account cap over
  30 days. The daily and account caps are leaky buckets: each payment fills the bucket and it
  drains at cap/window per second. A burst never exceeds the cap and there is no fresh
  allowance at midnight, but over a full window just under 2x the cap can settle, so set each
  cap to half the exposure you accept per window. Lowering a cap takes effect at once. Read
  `availableUsdCentsToday()` and `availableUsdCentsForAccount()` before quoting. Keep each
  account's cap below the daily cap, or one customer can use up a whole day.
- **Clock tolerance.** A quote may be issued up to 60 seconds ahead of the chain's clock.

### Governance

The contract's admin is a 48-hour `TimelockController` run by the governance Safe. Guardians
(the ops Safe) can only stop things: pause, revoke the quote signer or a relayer, cancel orders,
lower the caps. Unpausing, raising caps, rotating the signer or revenue Safe, and granting
relayers all take 48 hours, so launch caps must already cover peak demand.

The floor can rise at most 2x once every 7 days, and fall at most 30% once every 7 days. Within
90 days of the latest raise it can be returned to any value at or above the lowest floor before
that series of raises, so a multi-step defensive raise can be undone in one step.

### Deploy

`MARKET_BIM_PER_USD` and `MIN_BIM_PER_USD` are required, both in BIMCOIN wei (18 decimals) per
US$1 of list price: the market amount at deployment, and the floor, which must lie between 50%
and 100% of it. For example, with BIMCOIN at $0.50 the market amount is 2 BIMCOIN per $1; a floor
of `1600000000000000000` (1.6) lets the price rise 25% before the floor binds, and limits what a
leaked quote-signing key could undercharge to 20%. The script refuses zero or code-less Safe
addresses (code-less only allowed with `ALLOW_EOA_SAFES=true`, for testnets), a token address
with no code or without 18 decimals, a quote signer that is a contract or reuses a Safe, and
inconsistent caps.

```sh
export BIMCOIN_ADDRESS=0x... GOVERNANCE_SAFE=0x... OPS_SAFE=0x... QUOTE_SIGNER=0x... REVENUE_SAFE=0x...
export MARKET_BIM_PER_USD=2000000000000000000 MIN_BIM_PER_USD=1600000000000000000
forge script script/DeployBIMCreditTopUp.s.sol --rpc-url base_sepolia --account deployer --broadcast
```

Optional caps, in US cents: `MAX_USD_CENTS_PER_PAYMENT` (default 200000), `MAX_USD_CENTS_PER_DAY`
(default 2000000) and `MAX_USD_CENTS_PER_ACCOUNT_PER_PERIOD` (default 500000).

Not in this repository: the price book, usage metering, the credit ledger, the quote signer and
the payment watcher. They belong to the CBIONE and DaVinci backends.

## Develop

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```sh
git clone --recurse-submodules https://github.com/BIMCOIN-999/BIMCOIN.git
cd BIMCOIN
forge build
forge test
```

## Deploy to a testnet (reference designs only)

Deploy the EVM contracts only to testnets, to try out the billing flow. The live BIMCOIN is
the Solana token above.

```sh
# 1. Store the deployer key in an encrypted keystore (never in a file or shell history)
cast wallet import deployer --interactive

# 2. Choose the test treasury
export BIMCOIN_TREASURY=0xYourTestWallet

# 3. Deploy to Base Sepolia. The deployer wallet needs a little test ETH.
forge script script/DeployBIMCoin.s.sol \
  --rpc-url base_sepolia --account deployer --broadcast
```

Before selling or promoting BIMCOIN, get legal advice on how it is offered. A token sold
with an expected return from the founders' work is likely to be treated as a security.
