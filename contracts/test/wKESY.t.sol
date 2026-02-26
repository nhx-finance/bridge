// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {wKESY} from "../src/wKESY.sol";
import {KESYExtractor} from "../src/KESYExtractor.sol";
import {PolicyEngine} from "@chainlink/policy-management/core/PolicyEngine.sol";
import {RejectPolicy} from "@chainlink/policy-management/policies/RejectPolicy.sol";
import {VolumePolicy} from "@chainlink/policy-management/policies/VolumePolicy.sol";
import {Policy} from "@chainlink/policy-management/core/Policy.sol";
import {IPolicyEngine} from "@chainlink/policy-management/interfaces/IPolicyEngine.sol";

contract wKESYTest is Test {
    wKESY public token;
    PolicyEngine public policyEngine;
    RejectPolicy public rejectPolicy;
    VolumePolicy public volumePolicy;
    KESYExtractor public extractor;

    address public admin;
    address public minter;
    address public user;

    function setUp() public {
        admin = address(this);
        minter = makeAddr("minter");
        user = makeAddr("user");

        // 1. Deploy PolicyEngine via proxy
        PolicyEngine engineImpl = new PolicyEngine();
        ERC1967Proxy engineProxy = new ERC1967Proxy(
            address(engineImpl),
            abi.encodeWithSelector(PolicyEngine.initialize.selector, true, admin)
        );
        policyEngine = PolicyEngine(address(engineProxy));

        // 2. Deploy wKESY (attaches to PolicyEngine in constructor)
        token = new wKESY(address(policyEngine));
        token.grantRole(token.MINTER_ROLE(), minter);

        // 3. Deploy KESYExtractor
        extractor = new KESYExtractor();

        // 4. Set extractor for all 4 wKESY selectors
        bytes4 transferSel = bytes4(keccak256("transfer(address,uint256)"));
        bytes4 transferFromSel = bytes4(keccak256("transferFrom(address,address,uint256)"));
        bytes4 mintSel = bytes4(keccak256("mint(address,uint256)"));
        bytes4 burnFromSel = bytes4(keccak256("burnFrom(address,uint256)"));

        policyEngine.setExtractor(transferSel, address(extractor));
        policyEngine.setExtractor(transferFromSel, address(extractor));
        policyEngine.setExtractor(mintSel, address(extractor));
        policyEngine.setExtractor(burnFromSel, address(extractor));

        // 5. Deploy RejectPolicy (blacklist) via proxy
        RejectPolicy rejectImpl = new RejectPolicy();
        ERC1967Proxy rejectProxy = new ERC1967Proxy(
            address(rejectImpl),
            abi.encodeWithSelector(
                Policy.initialize.selector,
                address(policyEngine),
                admin,
                ""
            )
        );
        rejectPolicy = RejectPolicy(address(rejectProxy));

        // 6. Attach RejectPolicy to wKESY for all selectors
        bytes32[] memory accountParam = new bytes32[](1);
        accountParam[0] = extractor.PARAM_ACCOUNT();

        policyEngine.addPolicy(address(token), transferSel, address(rejectPolicy), accountParam);
        policyEngine.addPolicy(address(token), transferFromSel, address(rejectPolicy), accountParam);
        policyEngine.addPolicy(address(token), mintSel, address(rejectPolicy), accountParam);
        policyEngine.addPolicy(address(token), burnFromSel, address(rejectPolicy), accountParam);

        // 7. Deploy VolumePolicy via proxy (unconfigured — no limits by default)
        VolumePolicy volumeImpl = new VolumePolicy();
        ERC1967Proxy volumeProxy = new ERC1967Proxy(
            address(volumeImpl),
            abi.encodeWithSelector(
                Policy.initialize.selector,
                address(policyEngine),
                admin,
                abi.encode(uint256(0), uint256(0)) // no min/max by default
            )
        );
        volumePolicy = VolumePolicy(address(volumeProxy));

        // 8. Attach VolumePolicy to wKESY transfer selector
        bytes32[] memory amountParam = new bytes32[](1);
        amountParam[0] = extractor.PARAM_AMOUNT();

        policyEngine.addPolicy(address(token), transferSel, address(volumePolicy), amountParam);
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

    // ─── ACE: RejectPolicy (Blacklist) ──────────────────────

    function test_mint_revertsIfRecipientRejected() public {
        rejectPolicy.rejectAddress(user);

        vm.prank(minter);
        vm.expectRevert();
        token.mint(user, 100e6);
    }

    function test_transfer_revertsIfRecipientRejected() public {
        vm.prank(minter);
        token.mint(user, 500e6);

        rejectPolicy.rejectAddress(minter);

        vm.prank(user);
        vm.expectRevert();
        token.transfer(minter, 100e6);
    }

    function test_transfer_succeedsAfterUnrejecting() public {
        vm.prank(minter);
        token.mint(user, 500e6);

        // Reject then unreject
        rejectPolicy.rejectAddress(user);
        rejectPolicy.unrejectAddress(user);

        vm.prank(user);
        token.transfer(minter, 100e6);

        assertEq(token.balanceOf(minter), 100e6);
    }

    // ─── ACE: VolumePolicy (Volume Limits) ──────────────────

    function test_transfer_blockedByMaxVolume() public {
        vm.prank(minter);
        token.mint(user, 1000e6);

        // Set max at 500 KESY
        volumePolicy.setMax(500e6);

        vm.prank(user);
        vm.expectRevert();
        token.transfer(minter, 501e6);
    }

    function test_transfer_blockedByMinVolume() public {
        vm.prank(minter);
        token.mint(user, 1000e6);

        // Set min at 10 KESY (need max > min)
        volumePolicy.setMax(1000e6);
        volumePolicy.setMin(10e6);

        vm.prank(user);
        vm.expectRevert();
        token.transfer(minter, 5e6);
    }

    function test_transfer_allowedWithinVolumeLimits() public {
        vm.prank(minter);
        token.mint(user, 1000e6);

        volumePolicy.setMax(500e6);
        volumePolicy.setMin(1e6);

        vm.prank(user);
        token.transfer(minter, 100e6); // within [1, 500] — succeeds

        assertEq(token.balanceOf(minter), 100e6);
    }
}
