// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CCIPLocalSimulator, IRouterClient} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import {BurnMintERC677Helper} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import {LinkToken} from "@chainlink/local/src/shared/LinkToken.sol";
import {KESYOmniBridge} from "../src/KESYOmniBridge.sol";
import {wKESY} from "../src/wKESY.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockKESY is ERC20 {
    constructor() ERC20("KESY", "KESY") {}
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract E2ETest is Test {
    CCIPLocalSimulator public ccipLocalSimulator;
    
    // Chains
    uint64 public chainSelector;
    
    // Tokens
    IERC20 public linkToken;
    MockKESY public nativeKesy;
    wKESY public wrappedKesy;

    // Bridges
    KESYOmniBridge public hederaBridge;
    KESYOmniBridge public sepoliaBridge;

    // Users
    address public user = makeAddr("user");

    function setUp() public {
        ccipLocalSimulator = new CCIPLocalSimulator();
        
        // Setup CCIP simulator context
        (
            uint64 _chainSelector,
            IRouterClient sourceRouter,
            IRouterClient destinationRouter,
            ,
            LinkToken linkToken_,
            ,
            
        ) = ccipLocalSimulator.configuration();
        
        chainSelector = _chainSelector;
        linkToken = IERC20(address(linkToken_));

        // Deploy Tokens
        nativeKesy = new MockKESY();
        wrappedKesy = new wKESY();

        // Deploy Bridges
        // Notice we pass the same router for both since LocalSimulator mocks a single environment
        hederaBridge = new KESYOmniBridge(address(sourceRouter), address(linkToken), address(nativeKesy), true);
        sepoliaBridge = new KESYOmniBridge(address(destinationRouter), address(linkToken), address(wrappedKesy), false);

        // Sepolia Spoke setup: give bridge rights to mint/burn wKESY
        wrappedKesy.grantRole(wrappedKesy.MINTER_ROLE(), address(sepoliaBridge));
        wrappedKesy.grantRole(wrappedKesy.BURNER_ROLE(), address(sepoliaBridge));

        // Configure Allowlists for both directions
        hederaBridge.allowlistDestinationChain(chainSelector, true);
        hederaBridge.allowlistReceiver(chainSelector, abi.encode(address(sepoliaBridge)), true);
        
        sepoliaBridge.allowlistSourceChain(chainSelector, true);
        sepoliaBridge.allowlistSender(chainSelector, abi.encode(address(hederaBridge)), true);

        sepoliaBridge.allowlistDestinationChain(chainSelector, true);
        sepoliaBridge.allowlistReceiver(chainSelector, abi.encode(address(hederaBridge)), true);
        
        hederaBridge.allowlistSourceChain(chainSelector, true);
        hederaBridge.allowlistSender(chainSelector, abi.encode(address(sepoliaBridge)), true);

        // Extra args
        bytes memory extraArgs = hex"97a657c90000000000000000000000000000000000000000000000000000000000030d40";
        hederaBridge.setDefaultExtraArgs(chainSelector, extraArgs);
        sepoliaBridge.setDefaultExtraArgs(chainSelector, extraArgs);

        // Distribute LINK tokens for fees
        ccipLocalSimulator.requestLinkFromFaucet(address(hederaBridge), 10e18);
        ccipLocalSimulator.requestLinkFromFaucet(address(sepoliaBridge), 10e18);

        // User gets raw KESY to start
        nativeKesy.mint(user, 1000e18);
    }

    function test_roundTripBridge() public {
        uint256 bridgeAmount = 100e18;

        // --- Step 1: Hedera -> Sepolia ---
        vm.startPrank(user);
        nativeKesy.approve(address(hederaBridge), bridgeAmount);
        
        uint256 hederaBalBefore = nativeKesy.balanceOf(user);
        uint256 sepoliaBalBefore = wrappedKesy.balanceOf(user);

        hederaBridge.bridgeKESY(chainSelector, abi.encode(address(sepoliaBridge)), bridgeAmount);
        vm.stopPrank();

        // LocalSimulator auto-routes it

        assertEq(nativeKesy.balanceOf(user), hederaBalBefore - bridgeAmount, "Hedera balance didn't decrease");
        assertEq(nativeKesy.balanceOf(address(hederaBridge)), bridgeAmount, "Hedera bridge didn't lock");
        assertEq(wrappedKesy.balanceOf(user), sepoliaBalBefore + bridgeAmount, "Sepolia wKESY didn't mint");

        // --- Step 2: Sepolia -> Hedera ---
        vm.startPrank(user);
        wrappedKesy.approve(address(sepoliaBridge), bridgeAmount);

        sepoliaBridge.bridgeKESY(chainSelector, abi.encode(address(hederaBridge)), bridgeAmount);
        vm.stopPrank();

        // Verification
        assertEq(wrappedKesy.balanceOf(user), 0, "wKESY not burned");
        assertEq(nativeKesy.balanceOf(user), hederaBalBefore, "Hedera native balance not restored");
        assertEq(nativeKesy.balanceOf(address(hederaBridge)), 0, "Hedera bridge vault not empty");
    }
}
