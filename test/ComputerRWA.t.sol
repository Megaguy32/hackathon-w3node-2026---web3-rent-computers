// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ComputerRWA} from "../contracts/ComputerRWA.sol";

contract ComputerRWATest is Test {
    ComputerRWA rwa;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint256 constant RATE = 0.01 ether;

    function setUp() public {
        rwa = new ComputerRWA();
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.prank(owner);
        rwa.register("spec-hash", RATE);
    }

    function testRentThenSettlePaysOwner() public {
        vm.prank(alice);
        rwa.rent{value: 2 * RATE}(0, 2);
        vm.warp(block.timestamp + 2 hours);
        rwa.settle(0);
        assertEq(owner.balance, 2 * RATE);
        assertEq(address(rwa).balance, 0);
    }

    function testCannotRentWhileLeaseActive() public {
        vm.prank(alice);
        rwa.rent{value: RATE}(0, 1);
        vm.prank(bob);
        vm.expectRevert(bytes("leased"));
        rwa.rent{value: RATE}(0, 1);
    }

    // Regression: after a lease expires but before settle(), a second rent used to overwrite
    // the lease and permanently strand the first renter's escrow in the contract.
    function testCannotOverwriteUnsettledLease() public {
        vm.prank(alice);
        rwa.rent{value: RATE}(0, 1);
        vm.warp(block.timestamp + 1 hours);

        vm.prank(bob);
        vm.expectRevert(bytes("settle previous lease first"));
        rwa.rent{value: RATE}(0, 1);
    }

    function testRentAfterSettleWorksAndNoFundsStranded() public {
        vm.prank(alice);
        rwa.rent{value: RATE}(0, 1);
        vm.warp(block.timestamp + 1 hours);
        rwa.settle(0);

        vm.prank(bob);
        rwa.rent{value: 3 * RATE}(0, 3);
        vm.warp(block.timestamp + 3 hours);
        rwa.settle(0);

        assertEq(owner.balance, 4 * RATE);
        assertEq(address(rwa).balance, 0);
    }

    function testCannotSettleBeforeExpiry() public {
        vm.prank(alice);
        rwa.rent{value: RATE}(0, 1);
        vm.expectRevert(bytes("lease active"));
        rwa.settle(0);
    }

    function testCannotSettleTwice() public {
        vm.prank(alice);
        rwa.rent{value: RATE}(0, 1);
        vm.warp(block.timestamp + 1 hours);
        rwa.settle(0);
        vm.expectRevert(bytes("nothing to settle"));
        rwa.settle(0);
    }

    function testCannotSettleUnknownMachine() public {
        vm.expectRevert(bytes("nothing to settle"));
        rwa.settle(99);
    }

    function testZeroHoursReverts() public {
        vm.prank(alice);
        vm.expectRevert(bytes("hours must be positive"));
        rwa.rent{value: 0}(0, 0);
    }

    function testZeroRateRegistrationReverts() public {
        vm.expectRevert(bytes("rate must be positive"));
        rwa.register("free", 0);
    }

    function testWrongAmountReverts() public {
        vm.prank(alice);
        vm.expectRevert(bytes("bad amount"));
        rwa.rent{value: RATE - 1}(0, 1);
    }

    // Invariant-style check: contract balance always equals unsettled escrow.
    function testFuzzNoStrandedFunds(uint8 h1, uint8 h2) public {
        h1 = uint8(bound(h1, 1, 48));
        h2 = uint8(bound(h2, 1, 48));
        vm.prank(alice);
        rwa.rent{value: RATE * h1}(0, h1);
        vm.warp(block.timestamp + uint256(h1) * 1 hours);
        vm.prank(bob);
        try rwa.rent{value: RATE * h2}(0, h2) { fail("should require settle first"); } catch {}
        rwa.settle(0);
        vm.prank(bob);
        rwa.rent{value: RATE * h2}(0, h2);
        vm.warp(block.timestamp + uint256(h2) * 1 hours);
        rwa.settle(0);
        assertEq(owner.balance, RATE * (uint256(h1) + uint256(h2)));
        assertEq(address(rwa).balance, 0);
    }
}
