// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import {KESYOmniBridge} from "../src/KESYOmniBridge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title LiveBridgeTest
 * @notice Bridge 100 KESY from Hedera → Sepolia via the new ACE-protected contracts.
 * @dev Run: source .env && forge script script/LiveBridgeTest.s.sol --rpc-url $HEDERA_TESTNET_RPC_URL --broadcast
 */
contract LiveBridgeTest is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // Contracts
        address hubBridge = 0xD27c613C9d8D52C7E0BAE118562fB6cae7cC3A38;
        address kesy = 0x00000000000000000000000000000000006E4dc3; // Native KESY on Hedera
        address newSpoke = 0x4B0D9839db5962022E17fa8d61F3b6Ac8BB82a48;

        // Sepolia chain selector
        uint64 sepoliaSelector = 16015286601757825753;

        // Amount: 100 KESY (6 decimals)
        uint256 amount = 100 * 1e6;

        // Check balance
        uint256 kesyBal = IERC20(kesy).balanceOf(deployer);
        console.log("Deployer KESY balance:", kesyBal);
        require(kesyBal >= amount, "Not enough KESY");

        vm.startBroadcast(pk);

        // 1. Approve Hub Bridge to spend KESY
        IERC20(kesy).approve(hubBridge, amount);
        console.log("Approved Hub Bridge to spend", amount, "KESY");

        // 2. Bridge KESY to Sepolia (receiver = new Spoke)
        bytes32 msgId = KESYOmniBridge(hubBridge).bridgeKESY(
            sepoliaSelector,
            abi.encode(newSpoke),
            amount
        );

        vm.stopBroadcast();

        console.log("Bridge TX sent! CCIP Message ID:");
        console.logBytes32(msgId);
        console.log("Track at: https://ccip.chain.link");
        console.log("Recipient on Sepolia:", deployer);
        console.log("Amount:", amount, "(6 decimals)");
    }
}
