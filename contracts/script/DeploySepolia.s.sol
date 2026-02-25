// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import {KESYOmniBridge} from "../src/KESYOmniBridge.sol";
import {wKESY} from "../src/wKESY.sol";

contract DeploySepolia is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        address router = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59; // CCIP Router on Sepolia
        address link = 0x779877A7B0D9E8603169DdbD7836e478b4624789;   // LINK on Sepolia

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy the wrapped KESY standard (BurnMintERC20 compatible)
        wKESY wrappedKesy = new wKESY();

        // 2. Deploy Spoke Bridge on Sepolia (isHub = false)
        KESYOmniBridge spokeBridge = new KESYOmniBridge(router, link, address(wrappedKesy), false);

        // 3. Grant Spoke Bridge the right to MINT and BURN
        wrappedKesy.grantRole(wrappedKesy.MINTER_ROLE(), address(spokeBridge));
        wrappedKesy.grantRole(wrappedKesy.BURNER_ROLE(), address(spokeBridge));

        vm.stopBroadcast();
        
        // Log addresses
        console.log("Deployed wKESY to:", address(wrappedKesy));
        console.log("Deployed KESYOmniBridge (Spoke) to:", address(spokeBridge));
    }
}
