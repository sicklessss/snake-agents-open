// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MatchRecordStore
 * @notice Stores hashes of batch match summaries on-chain for data integrity verification.
 *         Full summary data is kept off-chain; the hash proves it hasn't been tampered with.
 *
 *         Authorization model: `owner` can grant `authorizedRecorder` status to hot wallets
 *         (e.g., the backend wallet). Previously storeRecord() was strictly `onlyOwner`,
 *         which meant VPS-side batch summaries would always revert because the owner key
 *         is kept off-server. The recorder allowlist lets the backend anchor summaries
 *         without exposing the owner key.
 */
contract MatchRecordStore {
    address public owner;
    mapping(address => bool) public authorizedRecorders;

    event RecordStored(
        bytes32 indexed dataHash,
        uint256 fromTime,
        uint256 toTime,
        uint256 totalMatches
    );
    event RecorderAuthorized(address indexed recorder);
    event RecorderRevoked(address indexed recorder);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyRecorder() {
        require(msg.sender == owner || authorizedRecorders[msg.sender], "Not recorder");
        _;
    }

    constructor() {
        owner = msg.sender;
        authorizedRecorders[msg.sender] = true;
    }

    function storeRecord(
        bytes32 dataHash,
        uint256 fromTime,
        uint256 toTime,
        uint256 totalMatches
    ) external onlyRecorder {
        emit RecordStored(dataHash, fromTime, toTime, totalMatches);
    }

    function authorizeRecorder(address recorder) external onlyOwner {
        require(recorder != address(0), "Zero address");
        authorizedRecorders[recorder] = true;
        emit RecorderAuthorized(recorder);
    }

    function revokeRecorder(address recorder) external onlyOwner {
        authorizedRecorders[recorder] = false;
        emit RecorderRevoked(recorder);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }
}
