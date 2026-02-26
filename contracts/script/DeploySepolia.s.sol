// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KESYOmniBridge} from "../src/KESYOmniBridge.sol";
import {wKESY} from "../src/wKESY.sol";
import {KESYExtractor} from "../src/KESYExtractor.sol";
import {PolicyEngine} from "@chainlink/policy-management/core/PolicyEngine.sol";
import {RejectPolicy} from "@chainlink/policy-management/policies/RejectPolicy.sol";
import {VolumePolicy} from "@chainlink/policy-management/policies/VolumePolicy.sol";
import {Policy} from "@chainlink/policy-management/core/Policy.sol";

contract DeploySepolia is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        address router = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59; // CCIP Router on Sepolia
        address link = 0x779877A7B0D9E8603169DdbD7836e478b4624789;   // LINK on Sepolia

        vm.startBroadcast(deployerPrivateKey);

        // 1. PolicyEngine (proxy)
        address policyEngine = address(new ERC1967Proxy(
            address(new PolicyEngine()),
            abi.encodeWithSelector(PolicyEngine.initialize.selector, true, deployer)
        ));

        // 2. RejectPolicy (proxy)
        address rejectPolicy = address(new ERC1967Proxy(
            address(new RejectPolicy()),
            abi.encodeWithSelector(Policy.initialize.selector, policyEngine, deployer, "")
        ));

        // 3. VolumePolicy (proxy)
        address volumePolicy = address(new ERC1967Proxy(
            address(new VolumePolicy()),
            abi.encodeWithSelector(Policy.initialize.selector, policyEngine, deployer, abi.encode(uint256(0), uint256(0)))
        ));

        // 4. KESYExtractor
        KESYExtractor extractor = new KESYExtractor();

        // 5. wKESY
        wKESY wrappedKesy = new wKESY(policyEngine);

        // 6. Spoke Bridge
        KESYOmniBridge spokeBridge = new KESYOmniBridge(router, link, address(wrappedKesy), false);

        // 7. Grant bridge roles
        wrappedKesy.grantRole(wrappedKesy.MINTER_ROLE(), address(spokeBridge));
        wrappedKesy.grantRole(wrappedKesy.BURNER_ROLE(), address(spokeBridge));

        // 8. Configure extractors for all 4 selectors
        bytes4[4] memory sels = [
            bytes4(keccak256("transfer(address,uint256)")),
            bytes4(keccak256("transferFrom(address,address,uint256)")),
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("burnFrom(address,uint256)"))
        ];

        for (uint256 i = 0; i < sels.length; i++) {
            PolicyEngine(policyEngine).setExtractor(sels[i], address(extractor));
        }

        // 9. Attach RejectPolicy to wKESY (all 4 selectors, checks account)
        bytes32[] memory accountParam = new bytes32[](1);
        accountParam[0] = extractor.PARAM_ACCOUNT();

        for (uint256 i = 0; i < sels.length; i++) {
            PolicyEngine(policyEngine).addPolicy(address(wrappedKesy), sels[i], rejectPolicy, accountParam);
        }

        // 10. Attach VolumePolicy to wKESY transfers only (checks amount)
        bytes32[] memory amountParam = new bytes32[](1);
        amountParam[0] = extractor.PARAM_AMOUNT();

        PolicyEngine(policyEngine).addPolicy(address(wrappedKesy), sels[0], volumePolicy, amountParam);
        PolicyEngine(policyEngine).addPolicy(address(wrappedKesy), sels[1], volumePolicy, amountParam);

        vm.stopBroadcast();

        // Log addresses
        console.log("PolicyEngine:", policyEngine);
        console.log("RejectPolicy:", rejectPolicy);
        console.log("VolumePolicy:", volumePolicy);
        console.log("KESYExtractor:", address(extractor));
        console.log("wKESY:", address(wrappedKesy));
        console.log("SpokeBridge:", address(spokeBridge));
    }
}
