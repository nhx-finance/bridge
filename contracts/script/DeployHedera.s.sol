// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {BridgeSender} from "../src/BridgeSender.sol";

/**
 * @title DeployHedera
 * @notice Deploy BridgeSender on Hedera Testnet.
 *
 * Prerequisites:
 *   - BridgeReceiver already deployed on Sepolia (set BRIDGE_RECEIVER_ADDRESS)
 *
 * Usage:
 *   source .env
 *   forge script script/DeployHedera.s.sol:DeployHedera \
 *     --rpc-url $HEDERA_TESTNET_RPC_URL \
 *     --broadcast \
 *     -vvvv
 *
 * After deployment, go back to Sepolia and call:
 *   receiver.allowlistSender(HEDERA_SELECTOR, abi.encode(senderAddr), true)
 */
contract DeployHedera is Script {
    // ── Hedera Testnet constants from ARCHITECTURE.md ──
    address constant HEDERA_ROUTER = 0x802C5F84eAD128Ff36fD6a3f8a418e339f467Ce4;
    address constant HEDERA_LINK = 0x90a386d59b9A6a4795a011e8f032Fc21ED6FEFb6;
    address constant KESY_TOKEN = 0x00000000000000000000000000000000006E4dc3;

    uint64 constant ETH_SEPOLIA_SELECTOR = 16015286601757825753;

    // Default gas limit for CCIP message execution on Sepolia
    uint256 constant DEFAULT_GAS_LIMIT = 200_000;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // BridgeReceiver address on Sepolia (must be set)
        address bridgeReceiverAddr = vm.envAddress("BRIDGE_RECEIVER_ADDRESS");

        console.log("Deployer:", deployer);
        console.log("Hedera Router:", HEDERA_ROUTER);
        console.log("KESY Token:", KESY_TOKEN);
        console.log("BridgeReceiver (Sepolia):", bridgeReceiverAddr);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy BridgeSender
        BridgeSender sender = new BridgeSender(HEDERA_ROUTER, HEDERA_LINK, KESY_TOKEN);
        console.log("BridgeSender deployed at:", address(sender));

        // 2. Allowlist Sepolia as destination chain
        sender.allowlistDestinationChain(ETH_SEPOLIA_SELECTOR, true);
        console.log("Sepolia allowlisted as destination chain");

        // 3. Allowlist BridgeReceiver on Sepolia
        bytes memory receiverBytes = abi.encode(bridgeReceiverAddr);
        sender.allowlistReceiver(ETH_SEPOLIA_SELECTOR, receiverBytes, true);
        console.log("BridgeReceiver allowlisted");

        // 4. Set default extraArgs for Sepolia
        bytes memory extraArgs = Client._argsToBytes(
            Client.GenericExtraArgsV2({
                gasLimit: DEFAULT_GAS_LIMIT,
                allowOutOfOrderExecution: true
            })
        );
        sender.setDefaultExtraArgs(ETH_SEPOLIA_SELECTOR, extraArgs);
        console.log("Default extraArgs set (gasLimit:", DEFAULT_GAS_LIMIT, ")");

        vm.stopBroadcast();

        console.log("");
        console.log("=== NEXT STEPS ===");
        console.log("1. Fund BridgeSender with LINK tokens at:", address(sender));
        console.log("2. On Sepolia, call receiver.allowlistSender() with this sender address");
    }
}
