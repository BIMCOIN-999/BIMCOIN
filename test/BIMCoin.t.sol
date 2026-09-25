// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BIMCoin} from "../src/BIMCoin.sol";

contract BIMCoinTest is Test {
    BIMCoin internal token;
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public {
        token = new BIMCoin(treasury);
    }

    function test_Metadata() public view {
        assertEq(token.name(), "BIMCOIN");
        assertEq(token.symbol(), "BIMCOIN");
        assertEq(token.decimals(), 18);
    }

    function test_EntireSupplyMintedToTreasury() public view {
        assertEq(token.MAX_SUPPLY(), 21_000_000e18);
        assertEq(token.totalSupply(), 21_000_000e18);
        assertEq(token.balanceOf(treasury), 21_000_000e18);
    }

    function test_RevertWhen_TreasuryIsZero() public {
        vm.expectRevert(BIMCoin.ZeroTreasury.selector);
        new BIMCoin(address(0));
    }

    /// Guards the fixed-supply promise: the contract exposes no way to mint.
    function test_HasNoMintFunction() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), token.MAX_SUPPLY());
    }

    function testFuzz_TransferPreservesTotalSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != treasury);
        amount = bound(amount, 0, token.MAX_SUPPLY());

        vm.prank(treasury);
        assertTrue(token.transfer(to, amount));

        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(treasury), token.MAX_SUPPLY() - amount);
        assertEq(token.totalSupply(), token.MAX_SUPPLY());
    }

    function test_ClockIsTimestamp() public {
        vm.warp(1_800_000_000);
        assertEq(token.clock(), 1_800_000_000);
        assertEq(token.CLOCK_MODE(), "mode=timestamp");
    }

    function test_VotingPowerRequiresDelegation() public {
        vm.prank(treasury);
        assertTrue(token.transfer(alice, 1_000e18));
        assertEq(token.getVotes(alice), 0);

        vm.prank(alice);
        token.delegate(alice);
        assertEq(token.getVotes(alice), 1_000e18);
    }

    function test_PastVotesFollowTimestamps() public {
        vm.warp(1_000);
        vm.prank(treasury);
        token.delegate(treasury);

        vm.warp(2_000);
        vm.prank(treasury);
        assertTrue(token.transfer(alice, 5_000_000e18));

        vm.warp(3_000);
        assertEq(token.getPastVotes(treasury, 1_500), 21_000_000e18);
        assertEq(token.getPastVotes(treasury, 2_500), 16_000_000e18);
        assertEq(token.getPastTotalSupply(2_500), 21_000_000e18);
    }

    function test_Permit() public {
        (address owner, uint256 ownerKey) = makeAddrAndKey("owner");
        vm.prank(treasury);
        assertTrue(token.transfer(owner, 100e18));

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, alice, 40e18, token.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        token.permit(owner, alice, 40e18, deadline, v, r, s);

        assertEq(token.allowance(owner, alice), 40e18);
        assertEq(token.nonces(owner), 1);

        vm.prank(alice);
        assertTrue(token.transferFrom(owner, alice, 40e18));
        assertEq(token.balanceOf(alice), 40e18);
    }
}
