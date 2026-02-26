// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {wKESY} from "../src/wKESY.sol";
import {PolicyManager} from "../src/PolicyManager.sol";

contract wKESYTest is Test {
    wKESY public token;
    PolicyManager public policyManager;
    address public admin;
    address public minter;
    address public user;

    function setUp() public {
        admin = address(this);
        minter = makeAddr("minter");
        user = makeAddr("user");

        policyManager = new PolicyManager();
        token = new wKESY(address(policyManager));
        token.grantRole(token.MINTER_ROLE(), minter);
    }

    // ─── Mint ───────────────────────────────────────────────

    function test_mint_withMinterRole() public {
        vm.prank(minter);
        token.mint(user, 1000e6);

        assertEq(token.balanceOf(user), 1000e6);
    }

    function test_mint_revertsWithoutRole() public {
        vm.prank(user);
        vm.expectRevert();
        token.mint(user, 1000e6);
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
        token.mint(user, 500e6);

        vm.prank(user);
        token.approve(burner, 200e6);

        vm.prank(burner);
        token.burnFrom(user, 200e6);

        assertEq(token.balanceOf(user), 300e6);
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

    // ─── PolicyManager / ACE Integration ─────────────────────

    function test_mint_revertsIfRecipientBlacklisted() public {
        policyManager.setBlacklisted(user, true);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(wKESY.NonCompliantOperation.selector, address(0), user, 100e6));
        token.mint(user, 100e6);
    }

    function test_transfer_revertsIfSenderBlacklisted() public {
        vm.prank(minter);
        token.mint(user, 500e6);

        policyManager.setBlacklisted(user, true);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(wKESY.NonCompliantOperation.selector, user, minter, 100e6));
        token.transfer(minter, 100e6);
    }

    function test_transfer_revertsIfRecipientBlacklisted() public {
        vm.prank(minter);
        token.mint(user, 500e6);

        policyManager.setBlacklisted(minter, true);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(wKESY.NonCompliantOperation.selector, user, minter, 100e6));
        token.transfer(minter, 100e6);
    }

    function test_transfer_succeedsAfterRemovingFromBlacklist() public {
        vm.prank(minter);
        token.mint(user, 500e6);

        // Blacklist then un-blacklist
        policyManager.setBlacklisted(user, true);
        policyManager.setBlacklisted(user, false);

        vm.prank(user);
        token.transfer(minter, 100e6);

        assertEq(token.balanceOf(minter), 100e6);
    }

    function test_batchBlacklist() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        address[] memory accounts = new address[](2);
        accounts[0] = alice;
        accounts[1] = bob;

        policyManager.batchSetBlacklisted(accounts, true);

        assertTrue(policyManager.blacklisted(alice));
        assertTrue(policyManager.blacklisted(bob));

        vm.prank(minter);
        vm.expectRevert();
        token.mint(alice, 100e6);
    }
}
