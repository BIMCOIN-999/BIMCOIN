# BIMCOIN

Smart contracts for BIMCOIN, the construction-finance token described in the BIMCOIN white paper.

## The token

| | |
|---|---|
| Name / symbol | BIMCOIN / BIM |
| Standard | ERC-20 with EIP-2612 permit and ERC20Votes (for DAO governance) |
| Supply | 21,000,000 BIM, fixed |
| Decimals | 18 |
| Chains | Any EVM chain. Recommended: Base |

The entire supply is minted once, at deployment, to a treasury address. The contract has
no mint function, owner, pause or blacklist, so after deployment nobody, including the
founders, can create more BIM or freeze anyone's balance. Voting power is tracked by
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

## Develop

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```sh
git clone --recurse-submodules https://github.com/BIMCOIN-999/BIMCOIN.git
cd BIMCOIN
forge build
forge test
```

## Deploy

Always deploy to a testnet first. The treasury receives all 21,000,000 BIM, so it
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

- Get legal advice on how BIM will be offered. A token sold with an expected return from
  the founders' work is likely to be treated as a security.
- Confirm the `BIM` ticker is not already used by a listed token.
- Create the treasury Safe and decide who its signers are.
