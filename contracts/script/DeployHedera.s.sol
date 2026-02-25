// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import {KESYOmniBridge} from "../src/KESYOmniBridge.sol";

contract DeployHedera is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        address router = 0x802C5F84eAD128Ff36fD6a3f8a418e339f467Ce4; // CCIP Router on Hedera Testnet
        address link = 0x90a386d59b9A6a4795a011e8f032Fc21ED6FEFb6;   // LINK on Hedera Testnet
        address kesy = 0x00000000000000000000000000000000006E4dc3;   // Real KESY Token on Hedera Testnet

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Hub Bridge on Hedera (isHub = true)
        KESYOmniBridge hubBridge = new KESYOmniBridge(router, link, kesy, true);

        // Note: Hedera deployments require the token to be associated with the contract 
        // before it can receive it. You must call `associateToken(kesy)` via cast afterwards.

        vm.stopBroadcast();
        
        // Log address
        console.log("Deployed KESYOmniBridge (Hub) to:", address(hubBridge));
    }
}
