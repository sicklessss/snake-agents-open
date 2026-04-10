// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/**
 * @title BotMarketplace
 * @notice NFT escrow marketplace for SnakeBot NFTs.
 *         Seller lists → NFT escrowed in contract.
 *         Buyer pays   → NFT transferred to buyer, ETH to seller (minus fee).
 *         Seller cancels → NFT returned.
 */
contract BotMarketplace is Ownable, ReentrancyGuard, Pausable, IERC721Receiver {
    IERC721 public nftContract;
    uint256 public feePercent = 250; // 2.5% in basis points
    uint256 public accumulatedFees;

    struct Listing {
        address seller;
        uint256 price;
    }

    mapping(uint256 => Listing) public listings; // tokenId => Listing
    uint256[] public activeTokenIds;
    mapping(uint256 => uint256) private activeIndex; // tokenId => index in activeTokenIds (O(1) removal)

    event Listed(uint256 indexed tokenId, address indexed seller, uint256 price);
    event Sold(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 price);
    event Cancelled(uint256 indexed tokenId, address indexed seller);

    constructor(address _nftContract) Ownable(msg.sender) {
        nftContract = IERC721(_nftContract);
    }

    /// @notice IERC721Receiver — accept NFT transfers
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /**
     * @notice List an NFT for sale. Caller must have approved this contract first.
     *         NFT is transferred into escrow (this contract).
     */
    function list(uint256 tokenId, uint256 price) external nonReentrant whenNotPaused {
        require(price > 0, "Price must be > 0");
        require(nftContract.ownerOf(tokenId) == msg.sender, "Not NFT owner");

        // Transfer NFT to this contract (escrow)
        nftContract.transferFrom(msg.sender, address(this), tokenId);

        listings[tokenId] = Listing(msg.sender, price);
        activeIndex[tokenId] = activeTokenIds.length;
        activeTokenIds.push(tokenId);

        emit Listed(tokenId, msg.sender, price);
    }

    /**
     * @notice Buy a listed NFT. Sends ETH to seller minus platform fee.
     */
    function buy(uint256 tokenId) external payable nonReentrant whenNotPaused {
        Listing memory item = listings[tokenId];
        require(item.price > 0, "Not listed");
        require(msg.value == item.price, "Payment must equal price");
        require(item.seller != msg.sender, "Cannot buy own");

        uint256 fee = (item.price * feePercent) / 10000;
        uint256 sellerProceeds = item.price - fee;
        accumulatedFees += fee;

        delete listings[tokenId];
        _removeFromActive(tokenId);

        // Transfer NFT to buyer
        nftContract.safeTransferFrom(address(this), msg.sender, tokenId);

        // Pay seller
        (bool ok, ) = payable(item.seller).call{value: sellerProceeds}("");
        require(ok, "Payment failed");

        emit Sold(tokenId, item.seller, msg.sender, item.price);
    }

    /**
     * @notice Cancel a listing. Only the original seller can cancel.
     *         NFT is returned to the seller.
     */
    function cancel(uint256 tokenId) external nonReentrant {
        require(listings[tokenId].seller == msg.sender, "Not seller");

        delete listings[tokenId];
        _removeFromActive(tokenId);

        nftContract.safeTransferFrom(address(this), msg.sender, tokenId);

        emit Cancelled(tokenId, msg.sender);
    }

    /**
     * @notice Get all active listings (tokenIds, sellers, prices).
     */
    function getActiveListings() external view returns (
        uint256[] memory tokenIds,
        address[] memory sellers,
        uint256[] memory prices
    ) {
        uint256 len = activeTokenIds.length;
        tokenIds = new uint256[](len);
        sellers = new address[](len);
        prices = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            uint256 tid = activeTokenIds[i];
            tokenIds[i] = tid;
            sellers[i] = listings[tid].seller;
            prices[i] = listings[tid].price;
        }
    }

    /**
     * @notice Update the platform fee (basis points, max 10%).
     */
    function setFeePercent(uint256 _fee) external onlyOwner {
        require(_fee <= 1000, "Max 10%");
        feePercent = _fee;
    }

    /**
     * @notice Withdraw only accumulated platform fees (not escrowed funds).
     */
    function withdrawFees() external onlyOwner {
        uint256 amount = accumulatedFees;
        require(amount > 0, "No fees");
        accumulatedFees = 0;
        (bool ok, ) = payable(owner()).call{value: amount}("");
        require(ok, "Withdraw failed");
    }

    // ============ Pausable ============

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // --- Internal ---

    function _removeFromActive(uint256 tokenId) internal {
        uint256 idx = activeIndex[tokenId];
        uint256 lastIdx = activeTokenIds.length - 1;
        if (idx != lastIdx) {
            uint256 lastTokenId = activeTokenIds[lastIdx];
            activeTokenIds[idx] = lastTokenId;
            activeIndex[lastTokenId] = idx;
        }
        activeTokenIds.pop();
        delete activeIndex[tokenId];
    }
}
