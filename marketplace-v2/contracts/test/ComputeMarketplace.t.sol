// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ComputeMarketplace} from "../src/ComputeMarketplace.sol";

contract ComputeMarketplaceTest is Test {
    ComputeMarketplace marketplace;
    address provider = makeAddr("provider");
    address consumer = makeAddr("consumer");

    function setUp() public {
        marketplace = new ComputeMarketplace();
        vm.deal(provider, 10 ether);
        vm.deal(consumer, 10 ether);
    }

    function testProviderCanList() public {
        vm.prank(provider);
        uint256 id = marketplace.registerListing("provider-01.example", 0.01 ether, 3600);
        (address payable owner, string memory machine, uint256 price, uint256 duration, bool active) = marketplace.listings(id);
        assertEq(owner, payable(provider));
        assertEq(machine, "provider-01.example");
        assertEq(price, 0.01 ether);
        assertEq(duration, 3600);
        assertTrue(active);
    }

    function testRentalPaysProviderAndStoresEntitlement() public {
        vm.prank(provider);
        uint256 listingId = marketplace.registerListing("provider-01.example", 0.01 ether, 3600);
        uint256 beforeBalance = provider.balance;

        vm.prank(consumer);
        uint256 rentalId = marketplace.rent{value: 0.01 ether}(listingId);

        (uint256 storedListingId, address storedConsumer, address storedProvider, string memory machine,
            uint256 expiresAt, uint256 paid) = marketplace.rentals(rentalId);
        assertEq(storedListingId, listingId);
        assertEq(storedConsumer, consumer);
        assertEq(storedProvider, provider);
        assertEq(machine, "provider-01.example");
        assertEq(expiresAt, block.timestamp + 3600);
        assertEq(paid, 0.01 ether);
        assertEq(provider.balance, beforeBalance + 0.01 ether);
    }

    function testCannotRentWithWrongPayment() public {
        vm.prank(provider);
        uint256 listingId = marketplace.registerListing("provider-01.example", 0.01 ether, 3600);
        vm.prank(consumer);
        vm.expectRevert("incorrect payment");
        marketplace.rent{value: 0.02 ether}(listingId);
    }

    function testProviderCanDeactivateListing() public {
        vm.prank(provider);
        uint256 listingId = marketplace.registerListing("provider-01.example", 0.01 ether, 3600);
        vm.prank(provider);
        marketplace.updateListing(listingId, 0.01 ether, 3600, false);
        vm.prank(consumer);
        vm.expectRevert("listing inactive or missing");
        marketplace.rent{value: 0.01 ether}(listingId);
    }
}

contract ComputeMarketplaceEdgeCasesTest is Test {
    ComputeMarketplace marketplace;
    address provider = makeAddr("edge-provider");
    address consumer = makeAddr("edge-consumer");

    function setUp() public {
        marketplace = new ComputeMarketplace();
        vm.deal(provider, 10 ether);
        vm.deal(consumer, 10 ether);
    }

    function testProviderCannotRentOwnListing() public {
        vm.prank(provider);
        uint256 listingId = marketplace.registerListing("provider-edge.example", 0.01 ether, 3600);
        vm.prank(provider);
        vm.expectRevert("provider cannot rent own listing");
        marketplace.rent{value: 0.01 ether}(listingId);
    }

    function testCannotRegisterZeroPriceListing() public {
        vm.prank(provider);
        vm.expectRevert("price must be positive");
        marketplace.registerListing("provider-edge.example", 0, 3600);
    }

    function testOnlyProviderCanUpdateListing() public {
        vm.prank(provider);
        uint256 listingId = marketplace.registerListing("provider-edge.example", 0.01 ether, 3600);
        vm.prank(consumer);
        vm.expectRevert("not listing provider");
        marketplace.updateListing(listingId, 0.02 ether, 7200, true);
    }
}
