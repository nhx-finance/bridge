// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import {KESYOmniBridge} from "../src/KESYOmniBridge.sol";

/**
 * @title ConfigureAllowlists
 * @notice Configure allowlists on both the new Sepolia Spoke and the Hedera Hub
 *         so they recognize each other for cross-chain messaging.
 *
 * Run for Sepolia:
 *   forge script script/ConfigureAllowlists.s.sol --rpc-url $ETH_SEPOLIA_RPC_URL --broadcast
 * Run for Hedera:
 *   forge script script/ConfigureAllowlists.s.sol --sig "runHedera()" --rpc-url $HEDERA_TESTNET_RPC_URL --broadcast
 */
contract ConfigureAllowlists is Script {
    // Chain selectors
    uint64 constant HEDERA_CHAIN_SELECTOR = 222782988166878823;
    uint64 constant SEPOLIA_CHAIN_SELECTOR = 16015286601757825753;

    // Deployed contracts
    address constant HUB_BRIDGE    = 0xD27c613C9d8D52C7E0BAE118562fB6cae7cC3A38;
    address constant NEW_SPOKE     = 0x4B0D9839db5962022E17fa8d61F3b6Ac8BB82a48;

    bytes constant EXTRA_ARGS = hex"97a657c90000000000000000000000000000000000000000000000000000000000030d40";

    /// @notice Configure the new Sepolia Spoke to recognize the Hub
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        KESYOmniBridge spoke = KESYOmniBridge(NEW_SPOKE);
        
        // Allow Hedera as source chain (for inbound bridges)
        spoke.allowlistSourceChain(HEDERA_CHAIN_SELECTOR, true);
        spoke.allowlistSender(HEDERA_CHAIN_SELECTOR, abi.encode(HUB_BRIDGE), true);

        // Allow Hedera as destination chain (for outbound bridges)
        spoke.allowlistDestinationChain(HEDERA_CHAIN_SELECTOR, true);
        spoke.allowlistReceiver(HEDERA_CHAIN_SELECTOR, abi.encode(HUB_BRIDGE), true);
        spoke.setDefaultExtraArgs(HEDERA_CHAIN_SELECTOR, EXTRA_ARGS);

        vm.stopBroadcast();
        console.log("Sepolia Spoke configured for Hub:", HUB_BRIDGE);
    }

    /// @notice Update the Hedera Hub to recognize the new Spoke
    function runHedera() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        KESYOmniBridge hub = KESYOmniBridge(HUB_BRIDGE);

        // Remove old spoke if needed (allowlist new one)
        hub.allowlistReceiver(SEPOLIA_CHAIN_SELECTOR, abi.encode(NEW_SPOKE), true);
        hub.allowlistSender(SEPOLIA_CHAIN_SELECTOR, abi.encode(NEW_SPOKE), true);

        vm.stopBroadcast();
        console.log("Hedera Hub configured for new Spoke:", NEW_SPOKE);
    }
}
