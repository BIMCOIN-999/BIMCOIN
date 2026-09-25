// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title BIMCOIN
/// @notice Fixed-supply governance token of the BIMCOIN ecosystem.
/// @dev The full 21,000,000 supply is minted once, at deployment, to `treasury`.
///      There is no mint function, owner, pause or blacklist: after deployment nobody,
///      including the deployer, can create more tokens or freeze a holder's balance.
contract BIMCoin is ERC20, ERC20Permit, ERC20Votes {
    uint256 public constant MAX_SUPPLY = 21_000_000 * 10 ** 18;

    error ZeroTreasury();

    constructor(address treasury) ERC20("BIMCOIN", "BIMCOIN") ERC20Permit("BIMCOIN") {
        if (treasury == address(0)) revert ZeroTreasury();
        _mint(treasury, MAX_SUPPLY);
    }

    /// @dev Voting power is checkpointed by timestamp instead of block number, so
    ///      governance periods mean the same thing on every chain, including L2s.
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
