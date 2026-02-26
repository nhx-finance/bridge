// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title FundSpoke
 * @notice Transfer LINK from deployer wallet to new Spoke Bridge.
 */
contract FundSpoke is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address link = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
        address newSpoke = 0x4B0D9839db5962022E17fa8d61F3b6Ac8BB82a48;

        uint256 linkBal = IERC20(link).balanceOf(deployer);
        console.log("Deployer LINK balance:", linkBal);

        // Send 2 LINK to new Spoke for bridge fees
        uint256 amount = 2 ether;
        require(linkBal >= amount, "Not enough LINK");

        vm.startBroadcast(deployerPrivateKey);
        IERC20(link).transfer(newSpoke, amount);
        vm.stopBroadcast();

        console.log("Sent", amount, "LINK to new Spoke:", newSpoke);
    }
}
