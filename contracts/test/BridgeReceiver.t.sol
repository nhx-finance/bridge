// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    CCIPLocalSimulator,
    IRouterClient,
    LinkToken
} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {BridgeReceiver} from "../src/BridgeReceiver.sol";
import {wKESY} from "../src/wKESY.sol";

contract BridgeReceiverTest is Test {
    CCIPLocalSimulator public ccipSimulator;
    BridgeReceiver public receiver;
    wKESY public wkesy;

    address public router;
    uint64 public chainSelector;
    address public owner;
    address public user;

    function setUp() public {
        owner = address(this);
        user = makeAddr("user");

        ccipSimulator = new CCIPLocalSimulator();

        (uint64 selector, IRouterClient sourceRouter,,,,, ) = ccipSimulator.configuration();
        chainSelector = selector;
        router = address(sourceRouter);

        // Deploy wKESY and receiver
        wkesy = new wKESY();
        receiver = new BridgeReceiver(router, address(wkesy));

        // Grant MINTER_ROLE to receiver
        wkesy.grantRole(wkesy.MINTER_ROLE(), address(receiver));

        // Allowlist source chain + sender
        receiver.allowlistSourceChain(chainSelector, true);
        receiver.allowlistSender(chainSelector, abi.encode(address(this)), true);
    }

    // ─── _ccipReceive ───────────────────────────────────────

    function test_ccipReceive_mintsWKESY() public {
        uint256 amount = 500e18;
        bytes memory data = abi.encode(user, amount);

        // Build message that the router would deliver
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("test-message"),
            sourceChainSelector: chainSelector,
            sender: abi.encode(address(this)),
            data: data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        // Simulate router calling ccipReceive
        vm.prank(router);
        receiver.ccipReceive(message);

        assertEq(wkesy.balanceOf(user), amount);
    }

    function test_ccipReceive_revertsIfNotRouter() public {
        bytes memory data = abi.encode(user, 100e18);

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("test"),
            sourceChainSelector: chainSelector,
            sender: abi.encode(address(this)),
            data: data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(user); // not the router
        vm.expectRevert();
        receiver.ccipReceive(message);
    }

    function test_ccipReceive_revertsIfSourceChainNotAllowlisted() public {
        uint64 badSelector = 999;
        bytes memory data = abi.encode(user, 100e18);

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("test"),
            sourceChainSelector: badSelector,
            sender: abi.encode(address(this)),
            data: data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(BridgeReceiver.SourceChainNotAllowlisted.selector, badSelector));
        receiver.ccipReceive(message);
    }

    function test_ccipReceive_revertsIfSenderNotAllowlisted() public {
        address badSender = makeAddr("badSender");
        bytes memory senderBytes = abi.encode(badSender);
        bytes memory data = abi.encode(user, 100e18);

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("test"),
            sourceChainSelector: chainSelector,
            sender: senderBytes,
            data: data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(BridgeReceiver.SenderNotAllowlisted.selector, senderBytes));
        receiver.ccipReceive(message);
    }

    // ─── Access Control ─────────────────────────────────────

    function test_allowlistSourceChain_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        receiver.allowlistSourceChain(chainSelector, false);
    }

    function test_allowlistSender_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        receiver.allowlistSender(chainSelector, abi.encode(address(this)), false);
    }
}
