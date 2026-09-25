# BIMCOIN

Smart contracts for BIMCOIN, the construction-finance token described in the BIMCOIN white paper.

## The token

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
in BIMCOIN. At launch BIMCOIN sells at $1, so $1 of AI cost costs 3 BIMCOIN.

[`src/BIMCreditTopUp.sol`](src/BIMCreditTopUp.sol) handles the on-chain part:

1. The billing backend measures usage, keeps each customer's USD credit balance, and signs a
   15-minute quote: "this wallet pays exactly N BIMCOIN for $X of credit".
2. The customer submits the quote (`pay`, or `payWithPermit` so a relayer can pay the gas).
   The BIMCOIN moves straight from the customer to the revenue Safe; the contract never holds it.
3. The backend credits the account when it sees the `PaymentSettled` event for its own quote.

The contract refuses any quote below `minBimPerUsd` BIMCOIN per $1 of list price (1 BIMCOIN at launch),
so even a compromised backend cannot sell credit for less. If BIMCOIN trades below $1, the backend
quotes more BIMCOIN so the dollar price holds. Quotes are single-use, bound to the paying wallet and
capped per payment, per day and per account.

Governance: the contract's admin is a 48-hour `TimelockController` run by the governance Safe.
Guardians (the ops Safe) can only stop things: pause, revoke the quote signer, lower the caps.
The floor can be lowered at most 30% once every 30 days.

```sh
export BIMCOIN_ADDRESS=0x... GOVERNANCE_SAFE=0x... OPS_SAFE=0x... QUOTE_SIGNER=0x... REVENUE_SAFE=0x...
forge script script/DeployBIMCreditTopUp.s.sol --rpc-url base_sepolia --account deployer --broadcast
```

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

## Deploy

Always deploy to a testnet first. The treasury receives all 21,000,000 BIMCOIN, so it
should be a multisig wallet such as a [Safe](https://safe.global), never a single
personal wallet.

```sh
# 1. Store the deployer key in an encrypted keystore (never in a file or shell history)
cast wallet import deployer --interactive

# 2. Choose the treasury
export BIMCOIN_TREASURY=0xYourSafeAddress

# 3. Deploy to Base Sepolia (testnet). The deployer wallet needs a little test ETH.
forge script script/DeployBIMCoin.s.sol \
  --rpc-url base_sepolia --account deployer --broadcast \
  --verify --etherscan-api-key "$ETHERSCAN_API_KEY"

# 4. Mainnet: the same command with --rpc-url base
```

The deployment is permanent. Name, symbol and supply cannot be changed afterwards, so
confirm them in `src/BIMCoin.sol` before the mainnet deployment.

### Before the mainnet deployment

- Get legal advice on how BIMCOIN will be offered. A token sold with an expected return from
  the founders' work is likely to be treated as a security.
- Create the treasury Safe and decide who its signers are.
