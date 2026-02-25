// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {wKESY} from "../src/wKESY.sol";

contract wKESYTest is Test {
    wKESY public token;
    address public admin;
    address public minter;
    address public user;

    function setUp() public {
        admin = address(this);
        minter = makeAddr("minter");
        user = makeAddr("user");

        token = new wKESY();
        token.grantRole(token.MINTER_ROLE(), minter);
    }

    // ─── Mint ───────────────────────────────────────────────

    function test_mint_withMinterRole() public {
        vm.prank(minter);
        token.mint(user, 1000e18);

        assertEq(token.balanceOf(user), 1000e18);
    }

    function test_mint_revertsWithoutRole() public {
        vm.prank(user);
        vm.expectRevert();
        token.mint(user, 1000e18);
    }

    function testFuzz_mint_arbitraryAmount(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        vm.prank(minter);
        token.mint(user, amount);

        assertEq(token.balanceOf(user), amount);
    }

    // ─── Burn ───────────────────────────────────────────────

    function test_burnFrom_byBurnerRole() public {
        address burner = makeAddr("burner");
        token.grantRole(token.BURNER_ROLE(), burner);

        vm.prank(minter);
        token.mint(user, 500e18);

        vm.prank(user);
        token.approve(burner, 200e18);

        vm.prank(burner);
        token.burnFrom(user, 200e18);

        assertEq(token.balanceOf(user), 300e18);
    }

    function test_burnFrom_revertsIfInsufficientBalance() public {
        address burner = makeAddr("burner");
        token.grantRole(token.BURNER_ROLE(), burner);

        vm.prank(user);
        token.approve(burner, 1);

        vm.prank(burner);
        vm.expectRevert();
        token.burnFrom(user, 1);
    }

    // ─── Access Control ─────────────────────────────────────

    function test_grantMinterRole_onlyAdmin() public {
        address newMinter = makeAddr("newMinter");

        // Admin can grant
        token.grantRole(token.MINTER_ROLE(), newMinter);
        assertTrue(token.hasRole(token.MINTER_ROLE(), newMinter));
    }

    function test_grantMinterRole_revertsIfNotAdmin() public {
        address newMinter = makeAddr("newMinter");
        bytes32 minterRole = token.MINTER_ROLE();

        vm.prank(user);
        vm.expectRevert();
        token.grantRole(minterRole, newMinter);
    }

    // ─── Metadata ───────────────────────────────────────────

    function test_name() public view {
        assertEq(token.name(), "Wrapped KESY");
    }

    function test_symbol() public view {
        assertEq(token.symbol(), "wKESY");
    }
}
