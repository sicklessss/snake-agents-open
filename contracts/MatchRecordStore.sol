// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MatchRecordStore
 * @notice Stores hashes of batch match summaries on-chain for data integrity verification.
 *         Full summary data is kept off-chain; the hash proves it hasn't been tampered with.
 */
contract MatchRecordStore {
    address public owner;

    event RecordStored(
        bytes32 indexed dataHash,
        uint256 fromTime,
        uint256 toTime,
        uint256 totalMatches
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function storeRecord(
        bytes32 dataHash,
        uint256 fromTime,
        uint256 toTime,
        uint256 totalMatches
    ) external onlyOwner {
        emit RecordStored(dataHash, fromTime, toTime, totalMatches);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }
}
