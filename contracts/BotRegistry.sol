// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface ISnakeBotNFT {
    function mintBotNFT(address _to, bytes32 _botId, string calldata _botName) external returns (uint256);
    function updateBotStats(bytes32 _botId, uint256 _matchesPlayed, uint256 _totalEarnings) external;
}

/**
 * @title BotRegistry
 * @notice Bot registration, ownership, and marketplace
 */
contract BotRegistry is Ownable, ReentrancyGuard, Pausable {
    
    // ============ Constants ============
    uint256 public constant MAX_BOTS_PER_USER = 5;
    uint256 public constant MAX_BOT_NAME_LEN = 15;
    
    // ============ NFT Contract ============
    ISnakeBotNFT public nftContract;
    
    // ============ Structs ============
    
    struct Bot {
        bytes32 botId;
        string botName;
        address owner;
        bool registered;      // Paid registration
        uint256 registeredAt;
        uint256 matchesPlayed;
        uint256 totalEarnings;
        uint256 salePrice;    // 0 = not for sale
    }
    
    // ============ State ============
    
    uint256 public registrationFee = 0.01 ether;
    uint256 public marketplaceFeePercent = 250; // 2.5% platform fee (basis points)
    uint256 public accumulatedFees;
    
    // Backend wallet for creating bots
    address public backendWallet;
    
    // botId => Bot info
    mapping(bytes32 => Bot) public bots;
    
    // botName => botId (ensure unique names)
    mapping(string => bytes32) public nameToBot;
    
    // owner => list of botIds
    mapping(address => bytes32[]) public ownerBots;
    
    // All registered bot IDs (for iteration)
    bytes32[] public allBots;
    
    // ============ Events ============
    
    event BotCreated(bytes32 indexed botId, string botName, address indexed creator);
    event BotRegistered(bytes32 indexed botId, address indexed owner, uint256 fee);
    event BotCodeUpdated(bytes32 indexed botId, bytes32 newCodeHash, uint256 timestamp);
    event BotListedForSale(bytes32 indexed botId, uint256 price);
    event BotDelisted(bytes32 indexed botId);
    event BotSold(
        bytes32 indexed botId, 
        address indexed seller, 
        address indexed buyer, 
        uint256 price
    );
    event RegistrationFeeUpdated(uint256 newFee);
    event MarketplaceFeeUpdated(uint256 newFee);
    event FeesWithdrawn(uint256 amount);
    
    // ============ Modifiers ============
    
    modifier onlyBotOwner(bytes32 _botId) {
        require(bots[_botId].owner == msg.sender, "Not bot owner");
        _;
    }
    
    modifier botExists(bytes32 _botId) {
        require(bots[_botId].botId != bytes32(0), "Bot does not exist");
        _;
    }
    
    modifier onlyBackend() {
        require(msg.sender == backendWallet || msg.sender == owner(), "Not backend or owner");
        _;
    }
    
    // ============ Constructor ============

    constructor() Ownable(msg.sender) {}

    // ============ Core Functions ============

    /**
     * @notice Set the backend wallet address (only owner)
     * @param _backendWallet New backend wallet address
     */
    function setBackendWallet(address _backendWallet) external onlyOwner {
        backendWallet = _backendWallet;
    }
    
    /**
     * @notice Create a bot entry (called by backend when user uploads)
     * @param _botId Unique bot ID
     * @param _botName Display name
     * @param _creator Initial creator address (can be 0 for unclaimed)
     */
    function createBot(
        bytes32 _botId,
        string calldata _botName,
        address _creator
    ) external onlyBackend whenNotPaused {
        require(bots[_botId].owner == address(0), "Bot exists");
        require(bytes(_botName).length > 0 && bytes(_botName).length <= MAX_BOT_NAME_LEN, "Invalid name");
        require(nameToBot[_botName] == bytes32(0), "Name taken");
        
        bots[_botId] = Bot({
            botId: _botId,
            botName: _botName,
            owner: _creator,  // Can be address(0) initially
            registered: false,
            registeredAt: 0,
            matchesPlayed: 0,
            totalEarnings: 0,
            salePrice: 0
        });
        
        nameToBot[_botName] = _botId;
        
        if (_creator != address(0)) {
            ownerBots[_creator].push(_botId);
        }
        
        emit BotCreated(_botId, _botName, _creator);
    }
    
    // Referral contract for tracking
    address public referralContract;
    
    // Track first registration for referral binding
    mapping(address => bool) public hasRegistered;
    
    /**
     * @notice Register (claim) a bot with payment
     * @param _botId Bot to register
     * @param _inviter Optional inviter address for referral (address(0) if none)
     */
    function registerBot(bytes32 _botId, address _inviter) external payable nonReentrant botExists(_botId) whenNotPaused {
        require(!bots[_botId].registered, "Already registered");
        require(msg.value >= registrationFee, "Insufficient fee");
        require(_inviter != msg.sender, "Cannot invite self");
        
        Bot storage bot = bots[_botId];
        
        // If unclaimed, transfer ownership
        if (bot.owner == address(0)) {
            // Check max bots per user
            require(ownerBots[msg.sender].length < MAX_BOTS_PER_USER, "Max 5 bots per user");
            bot.owner = msg.sender;
            ownerBots[msg.sender].push(_botId);
        } else {
            require(bot.owner == msg.sender, "Bot owned by another");
        }
        
        bot.registered = true;
        bot.registeredAt = block.timestamp;
        accumulatedFees += msg.value;

        allBots.push(_botId);
        
        // Mint NFT if NFT contract is set
        if (address(nftContract) != address(0)) {
            nftContract.mintBotNFT(msg.sender, _botId, bot.botName);
        }
        
        // Track first registration for referral
        if (!hasRegistered[msg.sender]) {
            hasRegistered[msg.sender] = true;
            // Emit event for backend to track referral
            emit ReferralBound(msg.sender, _inviter, block.timestamp);
        }
        
        emit BotRegistered(_botId, msg.sender, msg.value);
    }
    
    /**
     * @notice Set referral contract address
     */
    function setReferralContract(address _referralContract) external onlyOwner {
        referralContract = _referralContract;
    }
    
    event ReferralBound(address indexed user, address indexed inviter, uint256 timestamp);
    
    /**
     * @notice Set NFT contract address
     */
    function setNFTContract(address _nftContract) external onlyOwner {
        nftContract = ISnakeBotNFT(_nftContract);
    }
    
    /**
     * @notice Update bot code hash (allows script updates)
     * @param _botId Bot to update
     * @param _newCodeHash New code hash
     */
    function updateBotCode(bytes32 _botId, bytes32 _newCodeHash) 
        external 
        onlyBotOwner(_botId) 
        botExists(_botId) 
    {
        require(bots[_botId].registered, "Bot not registered");
        // In production, you might want to track code versions
        // For now, just emit event for backend to track
        emit BotCodeUpdated(_botId, _newCodeHash, block.timestamp);
    }
    
    /**
     * @notice List bot for sale
     * @param _botId Bot to sell
     * @param _price Sale price in wei
     */
    function listForSale(bytes32 _botId, uint256 _price) 
        external 
        onlyBotOwner(_botId) 
        botExists(_botId) 
    {
        require(_price > 0, "Price must be > 0");
        bots[_botId].salePrice = _price;
        emit BotListedForSale(_botId, _price);
    }
    
    /**
     * @notice Cancel sale listing
     */
    function cancelSale(bytes32 _botId) external onlyBotOwner(_botId) botExists(_botId) {
        bots[_botId].salePrice = 0;
        emit BotDelisted(_botId);
    }
    
    /**
     * @notice Buy a listed bot
     */
    function buyBot(bytes32 _botId) external payable nonReentrant botExists(_botId) {
        Bot storage bot = bots[_botId];
        require(bot.salePrice > 0, "Not for sale");
        require(msg.value >= bot.salePrice, "Insufficient payment");
        require(bot.owner != msg.sender, "Cannot buy own bot");
        
        address seller = bot.owner;
        uint256 price = bot.salePrice;
        
        // Calculate fees
        uint256 platformFee = (price * marketplaceFeePercent) / 10000;
        uint256 sellerProceeds = price - platformFee;
        accumulatedFees += platformFee;
        
        // Transfer ownership
        _transferBotOwnership(_botId, seller, msg.sender);
        bot.salePrice = 0;
        
        // Pay seller
        (bool success, ) = payable(seller).call{value: sellerProceeds}("");
        require(success, "Payment to seller failed");
        
        emit BotSold(_botId, seller, msg.sender, price);
    }
    
    /**
     * @notice Internal: Transfer bot ownership
     */
    function _transferBotOwnership(bytes32 _botId, address _from, address _to) internal {
        Bot storage bot = bots[_botId];
        bot.owner = _to;
        
        // Remove from old owner
        bytes32[] storage fromBots = ownerBots[_from];
        for (uint i = 0; i < fromBots.length; i++) {
            if (fromBots[i] == _botId) {
                fromBots[i] = fromBots[fromBots.length - 1];
                fromBots.pop();
                break;
            }
        }
        
        // Add to new owner
        ownerBots[_to].push(_botId);
    }
    
    // ============ Admin Functions ============
    
    function setRegistrationFee(uint256 _fee) external onlyBackend {
        registrationFee = _fee;
        emit RegistrationFeeUpdated(_fee);
    }
    
    function setMarketplaceFee(uint256 _fee) external onlyOwner {
        require(_fee <= 1000, "Max 10%"); // Max 10%
        marketplaceFeePercent = _fee;
        emit MarketplaceFeeUpdated(_fee);
    }
    
    function withdrawFees() external onlyOwner {
        uint256 amount = accumulatedFees;
        require(amount > 0, "No fees");
        accumulatedFees = 0;

        (bool success, ) = payable(owner()).call{value: amount}("");
        require(success, "Withdraw failed");

        emit FeesWithdrawn(amount);
    }
    
    /**
     * @notice Update bot stats (called by oracle/reward distributor)
     */
    function updateBotStats(
        bytes32 _botId,
        uint256 _matchesPlayed,
        uint256 _totalEarnings
    ) external onlyOwner {
        Bot storage bot = bots[_botId];
        bot.matchesPlayed = _matchesPlayed;
        bot.totalEarnings = _totalEarnings;
    }
    
    // ============ View Functions ============
    
    function getBotByName(string calldata _name) external view returns (Bot memory) {
        bytes32 botId = nameToBot[_name];
        require(botId != bytes32(0), "Bot not found");
        return bots[botId];
    }
    
    function getBotById(bytes32 _botId) external view returns (Bot memory) {
        return bots[_botId];
    }
    
    function getOwnerBots(address _owner) external view returns (bytes32[] memory) {
        return ownerBots[_owner];
    }
    
    function getBotsForSale(uint256 _offset, uint256 _limit) 
        external 
        view 
        returns (Bot[] memory) 
    {
        uint256 count = 0;
        
        // Count listed bots
        for (uint i = 0; i < allBots.length; i++) {
            if (bots[allBots[i]].salePrice > 0) count++;
        }
        
        uint256 resultSize = _limit > count ? count : _limit;
        Bot[] memory result = new Bot[](resultSize);
        
        uint256 index = 0;
        uint256 added = 0;
        for (uint i = 0; i < allBots.length && added < resultSize; i++) {
            if (bots[allBots[i]].salePrice > 0) {
                if (index >= _offset) {
                    result[added] = bots[allBots[i]];
                    added++;
                }
                index++;
            }
        }
        
        return result;
    }
    
    function isNameAvailable(string calldata _name) external view returns (bool) {
        return nameToBot[_name] == bytes32(0);
    }
    
    function getRegistrationFee() external view returns (uint256) {
        return registrationFee;
    }

    // ============ Pausable ============

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
