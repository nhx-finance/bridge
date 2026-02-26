// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import {KESYOmniBridge} from "../src/KESYOmniBridge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title RecoverLink
 * @notice Recover LINK tokens from old Spoke Bridge contract before redeployment.
 * @dev Run with: forge script script/RecoverLink.s.sol --rpc-url sepolia --broadcast
 */
contract RecoverLink is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address link = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
        // Old Spoke Bridge that has LINK
        address oldSpoke = 0xbE6E85a565eE95Bb6bdFb8f98D5677f84e8686eE;

        uint256 linkBal = IERC20(link).balanceOf(oldSpoke);
        console.log("LINK balance in old Spoke:", linkBal);

        if (linkBal > 0) {
            vm.startBroadcast(deployerPrivateKey);
            KESYOmniBridge(oldSpoke).withdrawToken(link, deployer);
            vm.stopBroadcast();
            console.log("Recovered", linkBal, "LINK to:", deployer);
        } else {
            console.log("No LINK to recover.");
        }
    }
}
