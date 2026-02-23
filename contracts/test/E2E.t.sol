// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    CCIPLocalSimulator,
    IRouterClient,
    LinkToken
} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {BridgeSender} from "../src/BridgeSender.sol";
import {BridgeReceiver} from "../src/BridgeReceiver.sol";
import {KESY} from "../src/KESY.sol";
import {wKESY} from "../src/wKESY.sol";

/**
 * @title E2E Bridge Test
 * @notice Full end-to-end: User bridges KESY → CCIP message auto-delivered →
 *         BridgeReceiver mints wKESY to user.
 * @dev Uses CCIPLocalSimulator which auto-delivers messages within a single tx.
 */
contract E2ETest is Test {
    CCIPLocalSimulator public ccipSimulator;
    BridgeSender public sender;
    BridgeReceiver public receiver;
    KESY public kesy;
    wKESY public wkesy;

    IRouterClient public router;
    LinkToken public linkToken;
    uint64 public chainSelector;

    address public deployer;
    address public user;

    function setUp() public {
        deployer = address(this);
        user = makeAddr("user");

        // 1. Deploy CCIP simulator
        ccipSimulator = new CCIPLocalSimulator();
        (uint64 selector, IRouterClient sourceRouter,,, LinkToken link,,) = ccipSimulator.configuration();
        chainSelector = selector;
        router = sourceRouter;
        linkToken = link;

        // 2. Deploy tokens
        kesy = new KESY();
        wkesy = new wKESY();

        // 3. Deploy bridge contracts
        sender = new BridgeSender(address(router), address(linkToken), address(kesy));
        receiver = new BridgeReceiver(address(router), address(wkesy));

        // 4. Configure permissions
        wkesy.grantRole(wkesy.MINTER_ROLE(), address(receiver));

        // 5. Configure allowlists on sender
        bytes memory receiverBytes = abi.encode(address(receiver));
        sender.allowlistDestinationChain(chainSelector, true);
        sender.allowlistReceiver(chainSelector, receiverBytes, true);

        bytes memory extraArgs = Client._argsToBytes(
            Client.GenericExtraArgsV2({gasLimit: 200_000, allowOutOfOrderExecution: true})
        );
        sender.setDefaultExtraArgs(chainSelector, extraArgs);

        // 6. Configure allowlists on receiver
        receiver.allowlistSourceChain(chainSelector, true);
        receiver.allowlistSender(chainSelector, abi.encode(address(sender)), true);

        // 7. Fund sender with LINK
        ccipSimulator.requestLinkFromFaucet(address(sender), 10 ether);

        // 8. Give user KESY tokens
        kesy.mint(user, 5_000e18);
    }

    function test_fullBridgeFlow() public {
        uint256 bridgeAmount = 1_000e18;

        // Pre-state
        assertEq(kesy.balanceOf(user), 5_000e18);
        assertEq(wkesy.balanceOf(user), 0);

        // User approves and bridges
        vm.startPrank(user);
        kesy.approve(address(sender), bridgeAmount);
        sender.bridgeKESY(chainSelector, abi.encode(address(receiver)), bridgeAmount);
        vm.stopPrank();

        // Post-state: KESY locked in sender
        assertEq(kesy.balanceOf(user), 5_000e18 - bridgeAmount);
        assertEq(kesy.balanceOf(address(sender)), bridgeAmount);

        // Post-state: wKESY minted to user via auto-delivered CCIP message
        assertEq(wkesy.balanceOf(user), bridgeAmount);
    }

    function test_fullBridgeFlow_multipleBridges() public {
        vm.startPrank(user);
        kesy.approve(address(sender), type(uint256).max);

        bytes memory receiverBytes = abi.encode(address(receiver));

        // Bridge 3 times
        sender.bridgeKESY(chainSelector, receiverBytes, 100e18);
        sender.bridgeKESY(chainSelector, receiverBytes, 200e18);
        sender.bridgeKESY(chainSelector, receiverBytes, 300e18);
        vm.stopPrank();

        // Total: 600 KESY locked, 600 wKESY minted
        assertEq(kesy.balanceOf(address(sender)), 600e18);
        assertEq(wkesy.balanceOf(user), 600e18);
        assertEq(kesy.balanceOf(user), 5_000e18 - 600e18);
    }

    function testFuzz_fullBridgeFlow(uint256 amount) public {
        amount = bound(amount, 1, 5_000e18);

        vm.startPrank(user);
        kesy.approve(address(sender), amount);
        sender.bridgeKESY(chainSelector, abi.encode(address(receiver)), amount);
        vm.stopPrank();

        assertEq(kesy.balanceOf(address(sender)), amount);
        assertEq(wkesy.balanceOf(user), amount);
    }
}
