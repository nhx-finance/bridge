// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {wKESY} from "../src/wKESY.sol";
import {BridgeReceiver} from "../src/BridgeReceiver.sol";

/**
 * @title DeploySepolia
 * @notice Deploy wKESY + BridgeReceiver on Ethereum Sepolia.
 *
 * Usage:
 *   source .env
 *   forge script script/DeploySepolia.s.sol:DeploySepolia \
 *     --rpc-url $ETH_SEPOLIA_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 *
 * After deployment, note the addresses and use them in DeployHedera.
 */
contract DeploySepolia is Script {
    // ── Sepolia constants from ARCHITECTURE.md ──
    address constant SEPOLIA_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
    uint64 constant HEDERA_TESTNET_SELECTOR = 222782988166878823;

    function run() external {
        // Expects PRIVATE_KEY in env
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Optional: if BridgeSender is already deployed on Hedera, pass its address
        // to allowlist it as a sender. Otherwise, set it after Hedera deploy.
        address bridgeSenderAddr = vm.envOr("BRIDGE_SENDER_ADDRESS", address(0));

        console.log("Deployer:", deployer);
        console.log("Sepolia Router:", SEPOLIA_ROUTER);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy wKESY
        wKESY wkesy = new wKESY();
        console.log("wKESY deployed at:", address(wkesy));

        // 2. Deploy BridgeReceiver
        BridgeReceiver receiver = new BridgeReceiver(SEPOLIA_ROUTER, address(wkesy));
        console.log("BridgeReceiver deployed at:", address(receiver));

        // 3. Grant MINTER_ROLE on wKESY to BridgeReceiver
        wkesy.grantRole(wkesy.MINTER_ROLE(), address(receiver));
        console.log("MINTER_ROLE granted to BridgeReceiver");

        // 4. Allowlist Hedera Testnet as source chain
        receiver.allowlistSourceChain(HEDERA_TESTNET_SELECTOR, true);
        console.log("Hedera Testnet allowlisted as source chain");

        // 5. Allowlist BridgeSender if address provided
        if (bridgeSenderAddr != address(0)) {
            receiver.allowlistSender(HEDERA_TESTNET_SELECTOR, abi.encode(bridgeSenderAddr), true);
            console.log("BridgeSender allowlisted:", bridgeSenderAddr);
        } else {
            console.log("NOTE: Set BRIDGE_SENDER_ADDRESS env var after Hedera deploy, then call:");
            console.log("  receiver.allowlistSender(HEDERA_TESTNET_SELECTOR, abi.encode(senderAddr), true)");
        }

        vm.stopBroadcast();
    }
}
