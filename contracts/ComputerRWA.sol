// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract ComputerRWA {
    struct Machine {
        address owner;
        string specHash;
        uint256 ratePerHour;
        bool active;
    }

    struct Lease {
        address renter;
        uint256 expiresAt;
        uint256 escrow;
    }

    uint256 public nextId;
    mapping(uint256 => Machine) public machines;
    mapping(uint256 => Lease) public leases;

    function register(string calldata specHash, uint256 ratePerHour) external returns (uint256) {
        uint256 id = nextId++;
        machines[id] = Machine(msg.sender, specHash, ratePerHour, true);
        return id;
    }

    function rent(uint256 id, uint256 hoursCount) external payable {
        Machine memory m = machines[id];
        require(m.active, "inactive");
        require(block.timestamp >= leases[id].expiresAt, "leased");
        require(msg.value == m.ratePerHour * hoursCount, "bad amount");

        leases[id] = Lease(msg.sender, block.timestamp + (hoursCount * 1 hours), msg.value);
    }

    function settle(uint256 id) external {
        Lease storage l = leases[id];
        require(l.escrow > 0 && block.timestamp >= l.expiresAt, "active");
        uint256 amount = l.escrow;
        l.escrow = 0;
        (bool ok, ) = payable(machines[id].owner).call{value: amount}("");
        require(ok, "transfer failed");
    }
}
