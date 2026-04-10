// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./BotRegistry.sol";

/**
 * @title RewardDistributor
 * @notice Accumulate and distribute rewards to bot owners (24h settlement)
 */
contract RewardDistributor is Ownable, ReentrancyGuard, Pausable {

    BotRegistry public botRegistry;

    // Operator address (backend wallet) — can accumulate rewards but not withdraw
    address public operator;

    modifier onlyOperator() {
        require(msg.sender == operator || msg.sender == owner(), "Not operator or owner");
        _;
    }
    
    // Minimum claim threshold: 0.001 ETH
    uint256 public constant MIN_CLAIM_THRESHOLD = 0.001 ether;
    
    // Accumulated rewards: botId => pending amount
    mapping(bytes32 => uint256) public pendingRewards;
    
    // Total pending rewards
    uint256 public totalPendingRewards;
    
    // Reward history: botId => (timestamp => amount)
    mapping(bytes32 => mapping(uint256 => uint256)) public rewardHistory;
    
    // ============ Events ============
    
    event RewardAccumulated(
        bytes32 indexed botId, 
        uint256 amount, 
        uint256 matchId,
        uint8 placement // 1st, 2nd, 3rd
    );
    
    event RewardsDistributed(
        bytes32 indexed botId,
        address indexed owner,
        uint256 amount
    );
    
    event BatchDistributed(
        uint256 botCount,
        uint256 totalAmount
    );
    
    event FundsDeposited(address from, uint256 amount);
    
    // ============ Constructor ============
    
    constructor(address _botRegistry) Ownable(msg.sender) {
        botRegistry = BotRegistry(_botRegistry);
    }
    
    // ============ Core Functions ============
    
    /**
     * @notice Record a reward for a bot (called by PariMutuel contract or oracle)
     * @param _botId Bot that earned reward
     * @param _amount Reward amount
     * @param _matchId Match ID
     * @param _placement 1st, 2nd, or 3rd
     */
    function accumulateReward(
        bytes32 _botId,
        uint256 _amount,
        uint256 _matchId,
        uint8 _placement
    ) external onlyOperator whenNotPaused {
        require(_placement >= 1 && _placement <= 3, "Invalid placement");
        require(_amount > 0, "Zero amount");

        pendingRewards[_botId] += _amount;
        totalPendingRewards += _amount;

        rewardHistory[_botId][block.timestamp] = _amount;

        emit RewardAccumulated(_botId, _amount, _matchId, _placement);
    }

    /**
     * @notice Batch accumulate rewards (gas efficient)
     */
    function batchAccumulateRewards(
        bytes32[] calldata _botIds,
        uint256[] calldata _amounts,
        uint256[] calldata _matchIds,
        uint8[] calldata _placements
    ) external onlyOperator whenNotPaused {
        require(
            _botIds.length == _amounts.length &&
            _amounts.length == _matchIds.length &&
            _matchIds.length == _placements.length,
            "Length mismatch"
        );
        
        for (uint i = 0; i < _botIds.length; i++) {
            require(_placements[i] >= 1 && _placements[i] <= 3, "Invalid placement");
            require(_amounts[i] > 0, "Zero amount");
            
            pendingRewards[_botIds[i]] += _amounts[i];
            totalPendingRewards += _amounts[i];
            
            emit RewardAccumulated(_botIds[i], _amounts[i], _matchIds[i], _placements[i]);
        }
    }
    
    /**
     * @notice Bot owner claims their own rewards (primary method)
     */
    function claimRewards(bytes32 _botId) external nonReentrant whenNotPaused {
        uint256 reward = pendingRewards[_botId];
        require(reward >= MIN_CLAIM_THRESHOLD, "Reward below threshold (0.001 ETH)");
        
        BotRegistry.Bot memory bot = botRegistry.getBotById(_botId);
        require(bot.owner == msg.sender, "Not owner");
        require(bot.registered, "Bot not registered");
        
        pendingRewards[_botId] = 0;
        totalPendingRewards -= reward;
        
        (bool success, ) = payable(msg.sender).call{value: reward}("");
        require(success, "Transfer failed");
        
        emit RewardsDistributed(_botId, msg.sender, reward);
    }
    
    /**
     * @notice Claim rewards for multiple bots at once (gas efficient)
     */
    function claimRewardsBatch(bytes32[] calldata _botIds) external nonReentrant whenNotPaused {
        uint256 totalReward = 0;
        
        for (uint i = 0; i < _botIds.length; i++) {
            bytes32 botId = _botIds[i];
            uint256 reward = pendingRewards[botId];
            
            if (reward == 0) continue;
            
            BotRegistry.Bot memory bot = botRegistry.getBotById(botId);
            require(bot.owner == msg.sender, "Not owner of all bots");
            
            pendingRewards[botId] = 0;
            totalReward += reward;
            
            emit RewardsDistributed(botId, msg.sender, reward);
        }
        
        require(totalReward >= MIN_CLAIM_THRESHOLD, "Total reward below threshold (0.001 ETH)");
        totalPendingRewards -= totalReward;
        
        (bool success, ) = payable(msg.sender).call{value: totalReward}("");
        require(success, "Transfer failed");
    }
    
    // ============ Admin Functions ============

    /**
     * @notice Set operator address (backend wallet)
     */
    function setOperator(address _operator) external onlyOwner {
        operator = _operator;
    }

    /**
     * @notice Deposit funds for rewards
     */
    function depositFunds() external payable {
        emit FundsDeposited(msg.sender, msg.value);
    }

    /**
     * @notice Emergency withdrawal (only if paused)
     */
    function emergencyWithdraw() external onlyOwner whenPaused {
        uint256 balance = address(this).balance;
        require(balance > totalPendingRewards, "Cannot withdraw pending rewards");
        
        uint256 withdrawable = balance - totalPendingRewards;
        require(withdrawable > 0, "Nothing to withdraw");
        
        (bool success, ) = payable(owner()).call{value: withdrawable}("");
        require(success, "Withdraw failed");
    }
    
    // ============ View Functions ============
    
    function getPendingReward(bytes32 _botId) external view returns (uint256) {
        return pendingRewards[_botId];
    }
    
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
    
    function getAvailableBalance() external view returns (uint256) {
        uint256 balance = address(this).balance;
        if (balance <= totalPendingRewards) return 0;
        return balance - totalPendingRewards;
    }
    
    // ============ Pausable ============

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    receive() external payable {
        emit FundsDeposited(msg.sender, msg.value);
    }
}
