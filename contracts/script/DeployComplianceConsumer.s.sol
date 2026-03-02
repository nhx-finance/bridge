// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import {ComplianceConsumer} from "../src/ComplianceConsumer.sol";
import {RejectPolicy} from "@chainlink/policy-management/policies/RejectPolicy.sol";

/**
 * @title DeployComplianceConsumer
 * @notice Deploy ComplianceConsumer and transfer RejectPolicy ownership to it.
 * @dev Run: source .env && forge script script/DeployComplianceConsumer.s.sol --rpc-url $ETH_SEPOLIA_RPC_URL --broadcast
 */
contract DeployComplianceConsumer is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        // Existing RejectPolicy proxy on Sepolia
        address rejectPolicy = 0x366491aB0a574385B1795E24477D91BF2840c301;

        vm.startBroadcast(pk);

        // 1. Deploy ComplianceConsumer
        ComplianceConsumer consumer = new ComplianceConsumer(rejectPolicy);

        // 2. Transfer RejectPolicy ownership from deployer EOA → ComplianceConsumer
        RejectPolicy(rejectPolicy).transferOwnership(address(consumer));

        vm.stopBroadcast();

        console.log("ComplianceConsumer:", address(consumer));
        console.log("RejectPolicy ownership transferred to ComplianceConsumer");
    }
}
