// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {KESYOmniBridge} from "../src/KESYOmniBridge.sol";
import {wKESY} from "../src/wKESY.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";

contract MockRouter {
    function getFee(uint64, Client.EVM2AnyMessage memory) external pure returns (uint256) {
        return 1e18; // 1 LINK fee
    }

    function ccipSend(uint64, Client.EVM2AnyMessage memory) external pure returns (bytes32) {
        return keccak256("mock_message_id");
    }
}

contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {}
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract KESYOmniBridgeTest is Test {
    KESYOmniBridge public hubBridge;
    KESYOmniBridge public spokeBridge;
    MockRouter public router;
    MockToken public link;
    MockToken public nativeKesy;
    wKESY public wrappedKesy;

    address public admin = address(this);
    address public user = address(0x111);
    
    uint64 public constant DEST_CHAIN = 16015286601757825753; // Sepolia
    uint64 public constant SRC_CHAIN = 222782988166878823;    // Hedera

    function setUp() public {
        router = new MockRouter();
        link = new MockToken();
        nativeKesy = new MockToken();
        wrappedKesy = new wKESY(address(new PolicyManager()));

        // Deploy Hub (Hedera)
        hubBridge = new KESYOmniBridge(address(router), address(link), address(nativeKesy), true);
        
        // Deploy Spoke (EVM)
        spokeBridge = new KESYOmniBridge(address(router), address(link), address(wrappedKesy), false);

        // Grant roles to spokeBridge
        wrappedKesy.grantRole(wrappedKesy.MINTER_ROLE(), address(spokeBridge));
        wrappedKesy.grantRole(wrappedKesy.BURNER_ROLE(), address(spokeBridge));

        // Setup common config for Hub
        hubBridge.allowlistDestinationChain(DEST_CHAIN, true);
        hubBridge.allowlistReceiver(DEST_CHAIN, abi.encode(address(spokeBridge)), true);
        hubBridge.setDefaultExtraArgs(DEST_CHAIN, hex"97a657c90000000000000000000000000000000000000000000000000000000000030d40");

        // Distribute funds
        link.mint(address(hubBridge), 10e18);
        link.mint(address(spokeBridge), 10e18);
        
        nativeKesy.mint(user, 1000e18);
        vm.prank(user);
        nativeKesy.approve(address(hubBridge), type(uint256).max);

        // User gets wKESY for spoke tests
        wrappedKesy.grantRole(wrappedKesy.MINTER_ROLE(), address(this));
        wrappedKesy.mint(user, 1000e18);
        vm.prank(user);
        wrappedKesy.approve(address(spokeBridge), type(uint256).max);
    }

    function test_hubBridgeSend() public {
        vm.prank(user);
        bytes32 msgId = hubBridge.bridgeKESY(DEST_CHAIN, abi.encode(address(spokeBridge)), 100e18);
        
        assertEq(msgId, keccak256("mock_message_id"));
        assertEq(nativeKesy.balanceOf(user), 900e18); // locked
        assertEq(nativeKesy.balanceOf(address(hubBridge)), 100e18);
    }

    function test_spokeBridgeReceive() public {
        // Setup spoke to allow hub
        spokeBridge.allowlistSourceChain(SRC_CHAIN, true);
        spokeBridge.allowlistSender(SRC_CHAIN, abi.encode(address(hubBridge)), true);

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("mock_message_id"),
            sourceChainSelector: SRC_CHAIN,
            sender: abi.encode(address(hubBridge)),
            data: abi.encode(user, 100e18),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        // Only router can call ccipReceive
        vm.prank(address(router));
        spokeBridge.ccipReceive(message);

        // Original was 1000e18, plus 100e18 minted
        assertEq(wrappedKesy.balanceOf(user), 1100e18);
    }
    
    function test_spokeBridgeSend() public {
        // Setup spoke to send to hub
        spokeBridge.allowlistDestinationChain(SRC_CHAIN, true);
        spokeBridge.allowlistReceiver(SRC_CHAIN, abi.encode(address(hubBridge)), true);
        spokeBridge.setDefaultExtraArgs(SRC_CHAIN, hex"97a657c90000000000000000000000000000000000000000000000000000000000030d40");

        vm.prank(user);
        bytes32 msgId = spokeBridge.bridgeKESY(SRC_CHAIN, abi.encode(address(hubBridge)), 100e18);
        
        assertEq(msgId, keccak256("mock_message_id"));
        assertEq(wrappedKesy.balanceOf(user), 900e18); // burned
    }
    
    function test_hubBridgeReceive() public {
        hubBridge.allowlistSourceChain(DEST_CHAIN, true);
        hubBridge.allowlistSender(DEST_CHAIN, abi.encode(address(spokeBridge)), true);

        // Pretend hubBridge already has some KESY locked
        nativeKesy.mint(address(hubBridge), 100e18);
        uint256 userBalBefore = nativeKesy.balanceOf(user);

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("mock_message_id"),
            sourceChainSelector: DEST_CHAIN,
            sender: abi.encode(address(spokeBridge)),
            data: abi.encode(user, 100e18),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(address(router));
        hubBridge.ccipReceive(message);

        assertEq(nativeKesy.balanceOf(user), userBalBefore + 100e18); // unlocked
        assertEq(nativeKesy.balanceOf(address(hubBridge)), 0);
    }
}
