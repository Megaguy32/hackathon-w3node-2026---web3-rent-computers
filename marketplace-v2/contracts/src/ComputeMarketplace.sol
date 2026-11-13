// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ComputeMarketplace
/// @notice Minimal direct-payment marketplace for time-bound access to an HTCondor machine.
/// @dev This is a hackathon prototype. It does not provide escrow, metering, or dispute handling.
contract ComputeMarketplace {
    struct Listing {
        address payable provider;
        string machineName;
        uint256 priceWei;
        uint256 durationSeconds;
        bool active;
    }

    struct Rental {
        uint256 listingId;
        address consumer;
        address provider;
        string machineName;
        uint256 expiresAt;
        uint256 paidWei;
    }

    uint256 public nextListingId = 1;
    uint256 public nextRentalId = 1;
    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Rental) public rentals;

    bool private entered;

    event ListingCreated(
        uint256 indexed listingId,
        address indexed provider,
        string machineName,
        uint256 priceWei,
        uint256 durationSeconds
    );
    event ListingUpdated(uint256 indexed listingId, uint256 priceWei, uint256 durationSeconds, bool active);
    event RentalCreated(
        uint256 indexed rentalId,
        uint256 indexed listingId,
        address indexed consumer,
        address provider,
        string machineName,
        uint256 expiresAt,
        uint256 paidWei
    );

    modifier nonReentrant() {
        require(!entered, "reentrant call");
        entered = true;
        _;
        entered = false;
    }

    function registerListing(
        string calldata machineName,
        uint256 priceWei,
        uint256 durationSeconds
    ) external returns (uint256 listingId) {
        require(bytes(machineName).length > 0, "machine name required");
        require(priceWei > 0, "price must be positive");
        require(durationSeconds > 0, "duration must be positive");

        listingId = nextListingId++;
        listings[listingId] = Listing({
            provider: payable(msg.sender),
            machineName: machineName,
            priceWei: priceWei,
            durationSeconds: durationSeconds,
            active: true
        });
        emit ListingCreated(listingId, msg.sender, machineName, priceWei, durationSeconds);
    }

    function updateListing(
        uint256 listingId,
        uint256 priceWei,
        uint256 durationSeconds,
        bool active
    ) external {
        Listing storage listing = listings[listingId];
        require(listing.provider == msg.sender, "not listing provider");
        require(priceWei > 0, "price must be positive");
        require(durationSeconds > 0, "duration must be positive");
        listing.priceWei = priceWei;
        listing.durationSeconds = durationSeconds;
        listing.active = active;
        emit ListingUpdated(listingId, priceWei, durationSeconds, active);
    }

    /// @notice Pays the provider directly and creates a rental entitlement.
    function rent(uint256 listingId) external payable nonReentrant returns (uint256 rentalId) {
        Listing storage listing = listings[listingId];
        require(listing.active, "listing inactive or missing");
        require(msg.value == listing.priceWei, "incorrect payment");
        require(listing.provider != msg.sender, "provider cannot rent own listing");

        rentalId = nextRentalId++;
        uint256 expiresAt = block.timestamp + listing.durationSeconds;
        rentals[rentalId] = Rental({
            listingId: listingId,
            consumer: msg.sender,
            provider: listing.provider,
            machineName: listing.machineName,
            expiresAt: expiresAt,
            paidWei: msg.value
        });

        (bool sent, ) = listing.provider.call{value: msg.value}("");
        require(sent, "provider payment failed");

        emit RentalCreated(
            rentalId,
            listingId,
            msg.sender,
            listing.provider,
            listing.machineName,
            expiresAt,
            msg.value
        );
    }

    function getListing(uint256 listingId) external view returns (Listing memory) {
        return listings[listingId];
    }

    function getRental(uint256 rentalId) external view returns (Rental memory) {
        return rentals[rentalId];
    }
}
