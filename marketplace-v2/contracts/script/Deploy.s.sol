// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {ComputeMarketplace} from "../src/ComputeMarketplace.sol";

contract Deploy is Script {
    function run() external returns (ComputeMarketplace marketplace) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        marketplace = new ComputeMarketplace();
        vm.stopBroadcast();
        console2.log("ComputeMarketplace:", address(marketplace));
    }
}
