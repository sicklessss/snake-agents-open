// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IBotRegistry {
    struct Bot {
        bytes32 botId;
        string botName;
        address owner;
        bool registered;
        uint256 registeredAt;
        uint256 matchesPlayed;
        uint256 totalEarnings;
        uint256 salePrice;
    }
    function getBotById(bytes32 _botId) external view returns (Bot memory);
}

interface ISnakeBotNFT {
    function botToTokenId(bytes32 _botId) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
}

/**
 * @title SnakeAgentsPariMutuel
 * @notice Pari-mutuel betting pool for Snake Agents (USDC version)
 * @dev 5% platform rake + 5% runner rewards, 90% to bettors.
 *      Uses USDC (6 decimals) on Base Sepolia.
 *      Single-bettor matches are auto-cancelled (full refund, no rake).
 *      Betting is only open before the scheduled match start.
 *      Oracle locks betting when the match enters PLAYING as an additional safety check.
 *      Timeout safety valve for stuck matches.
 */
contract SnakeAgentsPariMutuel is Ownable, ReentrancyGuard, Pausable {

    // ============ Constants ============
    uint256 public constant PERCENTAGE_BASE = 10000; // 100% = 10000 basis points

    // Prize distribution for TOP 3 bettors (50%, 30%, 20% of 90% = 45%, 27%, 18%)
    uint256 public constant FIRST_PLACE_SHARE = 5000;  // 50%
    uint256 public constant SECOND_PLACE_SHARE = 3000; // 30%
    uint256 public constant THIRD_PLACE_SHARE = 2000;  // 20%

    // Platform rake: 5% (platform only)
    uint256 public constant PLATFORM_RAKE = 500;      // 5%
    // Runner rewards pool: 5% (distributed to top 3 bots per match)
    uint256 public constant RUNNER_RAKE = 500;         // 5%
    // Total rake: 10%
    uint256 public constant TOTAL_RAKE = 1000;         // 10%

    // Runner reward distribution: 60% / 30% / 10% to 1st/2nd/3rd place bots
    uint256 public constant RUNNER_FIRST_SHARE = 6000;  // 60%
    uint256 public constant RUNNER_SECOND_SHARE = 3000; // 30%
    uint256 public constant RUNNER_THIRD_SHARE = 1000;  // 10%

    // Minimum bet: 1 USDC (6 decimals) — prevents dust-bet DoS on claim/refund
    uint256 public constant MIN_BET = 1_000_000;

    // Betting closes at match start. Place bets strictly before startTime.
    uint256 public constant BETTING_WINDOW = 0 seconds;

    // Timeout: if Oracle doesn't settle/cancel within 1 hour, anyone can trigger refund
    uint256 public constant MATCH_TIMEOUT = 1 hours;

    // ============ State Variables ============

    IERC20 public usdc;
    IBotRegistry public botRegistry;
    address public predictionRouter;
    // CRIT-1 fix: authoritative source of bot ownership is the NFT.
    // Runner reward claims and all owner checks derive the owner from
    // snakeBotNFT.ownerOf(tokenId), so trading via ANY ERC-721 marketplace
    // (BotMarketplace escrow, OpenSea, Blur, transferFrom, etc.) is supported.
    ISnakeBotNFT public snakeBotNFT;

    // Runner rewards tracking
    uint256 public totalRunnerRewardsAccumulated; // lifetime total (only increases, includes claimed)
    mapping(bytes32 => uint256) public pendingRunnerRewards; // per-bot unclaimed rewards

    // ============ Structs ============

    struct Bet {
        address bettor;
        bytes32 botId;
        uint256 amount;
        bool claimed;
    }

    struct Match {
        uint256 matchId;
        uint256 startTime;
        uint256 endTime;
        uint256 totalPool;
        uint256 uniqueBettors;
        bool settled;
        bool cancelled;
        bool bettingLocked;
        bytes32[] winners;  // 1st, 2nd, 3rd place bot IDs
        uint256[] winnerPools;
    }

    // ============ Mappings ============

    mapping(uint256 => Match) public matches;
    mapping(uint256 => Bet[]) public matchBets;
    mapping(uint256 => mapping(bytes32 => uint256)) public botTotalBets;
    mapping(uint256 => mapping(address => mapping(bytes32 => uint256[]))) public bettorBotBets;
    mapping(uint256 => mapping(address => uint256)) public bettorTotalBet;

    // Track whether an address has bet on a match (for uniqueBettors counting)
    mapping(uint256 => mapping(address => bool)) public hasBetOnMatch;

    // Redistributed bonus pool per match per winning bot (from unclaimed winner positions)
    mapping(uint256 => mapping(bytes32 => uint256)) public matchRedistributed;

    mapping(address => bool) public authorizedOracles;

    // Track platform fees separately to avoid withdrawing bettor funds
    uint256 public accumulatedPlatformFees;

    // ============ Events ============

    event BetPlaced(
        uint256 indexed matchId,
        address indexed bettor,
        bytes32 indexed botId,
        uint256 amount,
        uint256 betIndex
    );

    event MatchCreated(uint256 indexed matchId, uint256 startTime);

    event MatchSettled(
        uint256 indexed matchId,
        bytes32[] winners,
        uint256 totalPool,
        uint256 platformRake,
        uint256 botRewards
    );

    event MatchCancelled(uint256 indexed matchId, string reason);
    event BettingLocked(uint256 indexed matchId);
    event WinningsClaimed(uint256 indexed matchId, address indexed bettor, uint256 amount);
    event RefundClaimed(uint256 indexed matchId, address indexed bettor, uint256 amount);
    event OracleAuthorized(address oracle);
    event OracleRevoked(address oracle);
    event PlatformFeesWithdrawn(uint256 amount);
    event RunnerRewardsClaimed(bytes32 indexed botId, address indexed owner, uint256 amount);
    event PredictionRouterUpdated(address indexed router);
    event SnakeBotNFTUpdated(address indexed nft);

    // ============ Modifiers ============

    modifier onlyOracle() {
        require(authorizedOracles[msg.sender], "Not authorized oracle");
        _;
    }

    modifier matchExists(uint256 _matchId) {
        require(matches[_matchId].matchId != 0, "Match does not exist");
        _;
    }

    modifier matchNotSettled(uint256 _matchId) {
        require(!matches[_matchId].settled, "Match already settled");
        require(!matches[_matchId].cancelled, "Match cancelled");
        _;
    }

    modifier onlyPredictionRouter() {
        require(msg.sender == predictionRouter, "Not prediction router");
        _;
    }

    // ============ Constructor ============

    constructor(address _usdc, address _botRegistry) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
        botRegistry = IBotRegistry(_botRegistry);
    }

    // ============ Core Functions ============

    /**
     * @notice Place a bet using USDC. Caller must approve this contract first.
     * @param _matchId The match to bet on
     * @param _botId The bot to bet on (bytes32)
     * @param _amount Amount of USDC (6 decimals) to bet
     */
    function placeBet(uint256 _matchId, bytes32 _botId, uint256 _amount)
        external
        nonReentrant
        whenNotPaused
        matchExists(_matchId)
        matchNotSettled(_matchId)
    {
        require(_amount >= MIN_BET, "Bet amount must be >= 1 USDC");
        require(_botId != bytes32(0), "Invalid bot ID");
        // PHASE 3b: bettingLocked check removed — timestamp check below already
        // enforces "no bets after match starts" (BETTING_WINDOW=0). The lockBetting
        // tx is now redundant and no longer sent by backend, saving 1 tx per match.
        require(block.timestamp < matches[_matchId].startTime + BETTING_WINDOW, "Betting closed");

        // Transfer USDC from bettor to this contract
        require(usdc.transferFrom(msg.sender, address(this), _amount), "USDC transfer failed");

        _recordBet(msg.sender, _matchId, _botId, _amount);
    }

    /**
     * @notice Router-assisted intent execution. Tokens must already be transferred to this contract.
     * @param _bettor Final bettor to be recorded on-chain
     * @param _matchId The match to bet on
     * @param _botId The bot to bet on
     * @param _amount Amount of USDC already transferred into this contract
     */
    function placeBetFor(address _bettor, uint256 _matchId, bytes32 _botId, uint256 _amount)
        external
        nonReentrant
        whenNotPaused
        onlyPredictionRouter
        matchExists(_matchId)
        matchNotSettled(_matchId)
    {
        require(_bettor != address(0), "Invalid bettor");
        require(_amount >= MIN_BET, "Bet amount must be >= 1 USDC");
        require(_botId != bytes32(0), "Invalid bot ID");
        // PHASE 3b: bettingLocked removed (see placeBet for rationale).
        require(block.timestamp < matches[_matchId].startTime + BETTING_WINDOW, "Betting closed");

        _recordBet(_bettor, _matchId, _botId, _amount);
    }

    function _recordBet(address _bettor, uint256 _matchId, bytes32 _botId, uint256 _amount) internal {
        Bet memory newBet = Bet({
            bettor: _bettor,
            botId: _botId,
            amount: _amount,
            claimed: false
        });

        uint256 betIndex = matchBets[_matchId].length;
        matchBets[_matchId].push(newBet);

        botTotalBets[_matchId][_botId] += _amount;
        bettorTotalBet[_matchId][_bettor] += _amount;
        bettorBotBets[_matchId][_bettor][_botId].push(betIndex);
        matches[_matchId].totalPool += _amount;

        // Track unique bettors
        if (!hasBetOnMatch[_matchId][_bettor]) {
            hasBetOnMatch[_matchId][_bettor] = true;
            matches[_matchId].uniqueBettors++;
        }

        emit BetPlaced(_matchId, _bettor, _botId, _amount, betIndex);
    }

    /**
     * @notice Oracle locks betting (e.g. when ≤5 snakes alive)
     */
    function lockBetting(uint256 _matchId)
        external
        onlyOracle
        matchExists(_matchId)
        matchNotSettled(_matchId)
    {
        matches[_matchId].bettingLocked = true;
        emit BettingLocked(_matchId);
    }

    function createMatch(uint256 _matchId, uint256 _startTime)
        external
        onlyOracle
    {
        _createMatchInternal(_matchId, _startTime);
    }

    /**
     * @notice PHASE 3a: batch-create up to 50 matches in one tx.
     *         Saves ~70% gas vs sequential calls (base 21k overhead amortized).
     */
    function batchCreateMatch(uint256[] calldata _matchIds, uint256[] calldata _startTimes)
        external
        onlyOracle
    {
        uint256 n = _matchIds.length;
        require(n == _startTimes.length, "Length mismatch");
        require(n > 0 && n <= 50, "Batch size 1-50");
        for (uint256 i = 0; i < n; i++) {
            _createMatchInternal(_matchIds[i], _startTimes[i]);
        }
    }

    function _createMatchInternal(uint256 _matchId, uint256 _startTime) internal {
        require(matches[_matchId].matchId == 0, "Match already exists");
        require(_startTime > block.timestamp, "Start time must be in future");

        matches[_matchId] = Match({
            matchId: _matchId,
            startTime: _startTime,
            endTime: 0,
            totalPool: 0,
            uniqueBettors: 0,
            settled: false,
            cancelled: false,
            bettingLocked: false,
            winners: new bytes32[](0),
            winnerPools: new uint256[](0)
        });

        emit MatchCreated(_matchId, _startTime);
    }

    /**
     * @notice Settle a match. If only 1 unique bettor, auto-cancels for full refund.
     *         Splits 10% rake into 5% platform + 5% runner rewards.
     */
    function settleMatch(
        uint256 _matchId,
        bytes32[] calldata _winners
    )
        external
        nonReentrant
        onlyOracle
        matchExists(_matchId)
        matchNotSettled(_matchId)
    {
        _settleMatchInternal(_matchId, _winners);
    }

    /**
     * @notice PHASE 3c: batch-settle up to 20 matches in one tx.
     *         All-or-nothing: backend pre-validates each input. If any fails,
     *         entire batch reverts (saves accidental partial settles).
     */
    function batchSettleMatch(
        uint256[] calldata _matchIds,
        bytes32[][] calldata _winnersList
    )
        external
        nonReentrant
        onlyOracle
    {
        uint256 n = _matchIds.length;
        require(n == _winnersList.length, "Length mismatch");
        require(n > 0 && n <= 20, "Batch size 1-20");
        for (uint256 i = 0; i < n; i++) {
            require(matches[_matchIds[i]].matchId != 0, "Match does not exist");
            require(!matches[_matchIds[i]].settled, "Already settled");
            require(!matches[_matchIds[i]].cancelled, "Already cancelled");
            // NOTE: single-bettor matches auto-cancel inside _settleMatchInternal
            // without reverting (matchData.cancelled = true, return). A batch can
            // therefore contain a mix of true settles and silent auto-cancels —
            // backend must check matchData.cancelled per-match after the batch
            // confirms, not assume all entries are settled.
            _settleMatchInternal(_matchIds[i], _winnersList[i]);
        }
    }

    function _settleMatchInternal(uint256 _matchId, bytes32[] calldata _winners) internal {
        require(_winners.length > 0 && _winners.length <= 3, "Need 1-3 winners");
        require(block.timestamp >= matches[_matchId].startTime, "Match not started");
        // Validate winners: no zeros, no duplicates
        for (uint i = 0; i < _winners.length; i++) {
            require(_winners[i] != bytes32(0), "Zero winner");
            for (uint j = i + 1; j < _winners.length; j++) {
                require(_winners[i] != _winners[j], "Duplicate winner");
            }
        }

        Match storage matchData = matches[_matchId];

        // Single-bettor match: auto-cancel, full refund (no rake)
        if (matchData.uniqueBettors <= 1) {
            matchData.cancelled = true;
            matchData.endTime = block.timestamp;
            emit MatchCancelled(_matchId, "Single bettor - auto refund");
            return;
        }

        matchData.settled = true;
        matchData.endTime = block.timestamp;
        matchData.winners = _winners;

        uint256 totalPool = matchData.totalPool;
        uint256 platformRake = 0;
        uint256 runnerPool = 0;

        if (totalPool > 0) {
            // Platform rake: 5%
            platformRake = (totalPool * PLATFORM_RAKE) / PERCENTAGE_BASE;
            accumulatedPlatformFees += platformRake;

            // Runner rewards pool: 5%
            runnerPool = (totalPool * RUNNER_RAKE) / PERCENTAGE_BASE;
            totalRunnerRewardsAccumulated += runnerPool;

            // Distribute runner pool to top bots (same proportional logic as bettor payouts)
            uint256 totalAllocatedRunnerShare = 0;
            for (uint i = 0; i < _winners.length; i++) {
                uint256 s;
                if (i == 0) s = RUNNER_FIRST_SHARE;
                else if (i == 1) s = RUNNER_SECOND_SHARE;
                else s = RUNNER_THIRD_SHARE;
                totalAllocatedRunnerShare += s;
            }
            for (uint i = 0; i < _winners.length; i++) {
                uint256 s;
                if (i == 0) s = RUNNER_FIRST_SHARE;
                else if (i == 1) s = RUNNER_SECOND_SHARE;
                else s = RUNNER_THIRD_SHARE;
                uint256 reward = (runnerPool * s) / totalAllocatedRunnerShare;
                pendingRunnerRewards[_winners[i]] += reward;
            }

            // Store winner pool amounts for bettor payout calculation
            uint256[] memory winnerPools = new uint256[](_winners.length);
            for (uint i = 0; i < _winners.length; i++) {
                winnerPools[i] = botTotalBets[_matchId][_winners[i]];
            }
            matchData.winnerPools = winnerPools;

            // Redirect unclaimed winner pools to platform fees
            _redirectUnclaimedPools(_matchId, _winners, totalPool);
        }

        emit MatchSettled(_matchId, _winners, totalPool, platformRake, runnerPool);
    }

    /**
     * @notice Redistribute unclaimed winner pools to claimed winners proportionally.
     *         If no one bet on 1st place but someone bet on 2nd/3rd, 1st place's share
     *         is redistributed to 2nd/3rd proportionally instead of going to platform.
     *         Only goes to platform fees if NO winner has any bets at all.
     */
    function _redirectUnclaimedPools(
        uint256 _matchId,
        bytes32[] calldata _winners,
        uint256 _totalPool
    ) internal {
        uint256 payoutPool = (_totalPool * (PERCENTAGE_BASE - TOTAL_RAKE)) / PERCENTAGE_BASE;
        uint256 totalAllocatedPrizeShare = 0;
        for (uint i = 0; i < _winners.length; i++) {
            uint256 s;
            if (i == 0) s = FIRST_PLACE_SHARE;
            else if (i == 1) s = SECOND_PLACE_SHARE;
            else s = THIRD_PLACE_SHARE;
            totalAllocatedPrizeShare += s;
        }

        // Calculate unclaimed and claimed shares
        uint256 unclaimedShare = 0;
        uint256 claimedShare = 0;
        for (uint i = 0; i < _winners.length; i++) {
            uint256 s;
            if (i == 0) s = FIRST_PLACE_SHARE;
            else if (i == 1) s = SECOND_PLACE_SHARE;
            else s = THIRD_PLACE_SHARE;
            if (botTotalBets[_matchId][_winners[i]] == 0) {
                unclaimedShare += s;
            } else {
                claimedShare += s;
            }
        }

        if (unclaimedShare == 0) return;

        uint256 totalUnclaimed = (payoutPool * unclaimedShare) / totalAllocatedPrizeShare;

        if (claimedShare == 0) {
            // No winner has any bets — 50/50 split between platform and runners
            uint256 half = totalUnclaimed / 2;
            accumulatedPlatformFees += half;
            // Runner half: distribute to winning bots (60/30/10)
            uint256 runnerHalf = totalUnclaimed - half;
            uint256 totalAllocatedRunnerShare = 0;
            for (uint i = 0; i < _winners.length; i++) {
                uint256 s;
                if (i == 0) s = RUNNER_FIRST_SHARE;
                else if (i == 1) s = RUNNER_SECOND_SHARE;
                else s = RUNNER_THIRD_SHARE;
                totalAllocatedRunnerShare += s;
            }
            for (uint i = 0; i < _winners.length; i++) {
                uint256 s;
                if (i == 0) s = RUNNER_FIRST_SHARE;
                else if (i == 1) s = RUNNER_SECOND_SHARE;
                else s = RUNNER_THIRD_SHARE;
                pendingRunnerRewards[_winners[i]] += (runnerHalf * s) / totalAllocatedRunnerShare;
            }
            totalRunnerRewardsAccumulated += runnerHalf;
            return;
        }

        // Redistribute to winners that have bets, proportional to their shares
        for (uint i = 0; i < _winners.length; i++) {
            if (botTotalBets[_matchId][_winners[i]] > 0) {
                uint256 s;
                if (i == 0) s = FIRST_PLACE_SHARE;
                else if (i == 1) s = SECOND_PLACE_SHARE;
                else s = THIRD_PLACE_SHARE;
                matchRedistributed[_matchId][_winners[i]] += (totalUnclaimed * s) / claimedShare;
            }
        }
    }

    function cancelMatch(uint256 _matchId, string calldata _reason)
        external
        onlyOracle
        matchExists(_matchId)
        matchNotSettled(_matchId)
    {
        matches[_matchId].cancelled = true;
        emit MatchCancelled(_matchId, _reason);
    }

    /**
     * @notice PHASE 3c: batch-cancel up to 50 matches in one tx (e.g. matches with no bets).
     */
    function batchCancelMatch(uint256[] calldata _matchIds, string calldata _reason)
        external
        onlyOracle
    {
        uint256 n = _matchIds.length;
        require(n > 0 && n <= 50, "Batch size 1-50");
        for (uint256 i = 0; i < n; i++) {
            require(matches[_matchIds[i]].matchId != 0, "Match does not exist");
            require(!matches[_matchIds[i]].settled, "Already settled");
            require(!matches[_matchIds[i]].cancelled, "Already cancelled");
            matches[_matchIds[i]].cancelled = true;
            emit MatchCancelled(_matchIds[i], _reason);
        }
    }

    /**
     * @notice Anyone can trigger refund if Oracle fails to settle/cancel within MATCH_TIMEOUT.
     */
    function emergencyRefundMatch(uint256 _matchId)
        external
        nonReentrant
        matchExists(_matchId)
    {
        Match storage matchData = matches[_matchId];
        require(!matchData.settled && !matchData.cancelled, "Already finalized");
        require(block.timestamp > matchData.startTime + MATCH_TIMEOUT, "Not timed out yet");

        matchData.cancelled = true;
        emit MatchCancelled(_matchId, "Timeout - auto cancelled");
    }

    function claimWinnings(uint256 _matchId)
        external
        nonReentrant
        matchExists(_matchId)
    {
        Match storage matchData = matches[_matchId];
        require(matchData.settled, "Match not settled");

        uint256 totalWinnings = 0;
        Bet[] storage bets = matchBets[_matchId];

        for (uint i = 0; i < bets.length; i++) {
            if (bets[i].bettor == msg.sender && !bets[i].claimed) {
                uint256 winnings = calculateBetWinnings(_matchId, i);
                if (winnings > 0) {
                    totalWinnings += winnings;
                    bets[i].claimed = true;
                }
            }
        }

        require(totalWinnings > 0, "No winnings to claim");

        require(usdc.transfer(msg.sender, totalWinnings), "USDC transfer failed");

        emit WinningsClaimed(_matchId, msg.sender, totalWinnings);
    }

    function claimRefund(uint256 _matchId)
        external
        nonReentrant
        matchExists(_matchId)
    {
        require(matches[_matchId].cancelled, "Match not cancelled");

        uint256 refundAmount = 0;
        Bet[] storage bets = matchBets[_matchId];

        for (uint i = 0; i < bets.length; i++) {
            if (bets[i].bettor == msg.sender && !bets[i].claimed) {
                refundAmount += bets[i].amount;
                bets[i].claimed = true;
            }
        }

        require(refundAmount > 0, "No refund available");

        require(usdc.transfer(msg.sender, refundAmount), "Refund failed");

        emit RefundClaimed(_matchId, msg.sender, refundAmount);
    }

    // ============ Runner Rewards ============

    /**
     * @notice Resolve the authoritative owner of a bot — the ERC-721 NFT holder.
     * @dev    CRIT-1 fix: rewards follow NFT ownership, so any ERC-721
     *         marketplace (BotMarketplace escrow, OpenSea, Blur, direct
     *         transferFrom) transparently moves reward entitlement.
     */
    function _resolveBotOwner(bytes32 _botId) internal view returns (address) {
        require(address(snakeBotNFT) != address(0), "NFT contract not set");
        uint256 tokenId = snakeBotNFT.botToTokenId(_botId);
        require(tokenId > 0, "Bot has no NFT");
        return snakeBotNFT.ownerOf(tokenId);
    }

    /**
     * @notice Bot Owner claims accumulated runner rewards for a specific bot.
     * @dev Owner is verified via the SnakeBotNFT contract, not BotRegistry.
     *      This makes rewards follow NFT ownership across any marketplace.
     */
    function claimRunnerRewards(bytes32 _botId) external nonReentrant {
        uint256 amount = pendingRunnerRewards[_botId];
        require(amount > 0, "No runner rewards");

        address botOwner = _resolveBotOwner(_botId);
        require(botOwner == msg.sender, "Not bot owner");

        pendingRunnerRewards[_botId] = 0;
        require(usdc.transfer(msg.sender, amount), "USDC transfer failed");

        emit RunnerRewardsClaimed(_botId, msg.sender, amount);
    }

    /**
     * @notice Batch claim runner rewards for multiple bots owned by caller.
     * @dev Same NFT-based ownership check as claimRunnerRewards.
     */
    function claimRunnerRewardsBatch(bytes32[] calldata _botIds) external nonReentrant {
        require(address(snakeBotNFT) != address(0), "NFT contract not set");
        uint256 totalAmount = 0;

        for (uint i = 0; i < _botIds.length; i++) {
            uint256 amount = pendingRunnerRewards[_botIds[i]];
            if (amount == 0) continue;

            // Inlined owner check to avoid repeated `address(0)` checks.
            uint256 tokenId = snakeBotNFT.botToTokenId(_botIds[i]);
            require(tokenId > 0, "Bot has no NFT");
            address botOwner = snakeBotNFT.ownerOf(tokenId);
            require(botOwner == msg.sender, "Not bot owner");

            pendingRunnerRewards[_botIds[i]] = 0;
            totalAmount += amount;

            emit RunnerRewardsClaimed(_botIds[i], msg.sender, amount);
        }

        require(totalAmount > 0, "No runner rewards");
        require(usdc.transfer(msg.sender, totalAmount), "USDC transfer failed");
    }

    // ============ View Functions ============

    function getRunnerRewardStats() external view returns (uint256) {
        return totalRunnerRewardsAccumulated;
    }

    function calculateBetWinnings(uint256 _matchId, uint256 _betIndex)
        public
        view
        returns (uint256)
    {
        Bet storage bet = matchBets[_matchId][_betIndex];
        Match storage matchData = matches[_matchId];

        if (!matchData.settled || bet.claimed) {
            return 0;
        }

        uint256 place = 0;
        for (uint i = 0; i < matchData.winners.length; i++) {
            if (matchData.winners[i] == bet.botId) {
                place = i + 1;
                break;
            }
        }

        if (place == 0) {
            return 0;
        }

        uint256 totalPool = matchData.totalPool;
        // 90% to bettors (100% - 10% total rake)
        uint256 payoutPool = (totalPool * (PERCENTAGE_BASE - TOTAL_RAKE)) / PERCENTAGE_BASE;

        // Calculate this place's share and total allocated shares
        // When fewer than 3 winners, redistribute proportionally so no funds are stuck
        uint256 prizeShare;
        uint256 totalAllocatedShare = 0;
        for (uint j = 0; j < matchData.winners.length; j++) {
            uint256 s;
            if (j == 0) s = FIRST_PLACE_SHARE;
            else if (j == 1) s = SECOND_PLACE_SHARE;
            else s = THIRD_PLACE_SHARE;
            totalAllocatedShare += s;
            if (j + 1 == place) prizeShare = s;
        }

        if (prizeShare == 0 || totalAllocatedShare == 0) {
            return 0;
        }

        // Scale: botPrizePool = payoutPool * (prizeShare / totalAllocatedShare)
        uint256 botPrizePool = (payoutPool * prizeShare) / totalAllocatedShare;

        // Add redistributed bonus from unclaimed winner positions
        botPrizePool += matchRedistributed[_matchId][bet.botId];

        uint256 totalBetOnBot = botTotalBets[_matchId][bet.botId];

        if (totalBetOnBot == 0) {
            return 0;
        }

        uint256 winnings = (bet.amount * botPrizePool) / totalBetOnBot;
        return winnings;
    }

    function getUserPotentialWinnings(uint256 _matchId, address _bettor)
        external
        view
        returns (uint256)
    {
        uint256 total = 0;
        Bet[] storage bets = matchBets[_matchId];

        for (uint i = 0; i < bets.length; i++) {
            if (bets[i].bettor == _bettor) {
                total += calculateBetWinnings(_matchId, i);
            }
        }

        return total;
    }

    function getMatchBets(uint256 _matchId)
        external
        view
        returns (Bet[] memory)
    {
        return matchBets[_matchId];
    }

    function getCurrentOdds(uint256 _matchId, bytes32 _botId)
        external
        view
        returns (uint256)
    {
        uint256 totalPool = matches[_matchId].totalPool;
        uint256 botBets = botTotalBets[_matchId][_botId];

        if (botBets == 0 || totalPool == 0) {
            return 0;
        }

        // 90% payout to bettors
        uint256 payoutPool = (totalPool * (PERCENTAGE_BASE - TOTAL_RAKE)) / PERCENTAGE_BASE;
        return (payoutPool * PERCENTAGE_BASE) / botBets;
    }

    // ============ Admin Functions ============

    function authorizeOracle(address _oracle) external onlyOwner {
        authorizedOracles[_oracle] = true;
        emit OracleAuthorized(_oracle);
    }

    function revokeOracle(address _oracle) external onlyOwner {
        authorizedOracles[_oracle] = false;
        emit OracleRevoked(_oracle);
    }

    function withdrawPlatformFees() external onlyOwner {
        uint256 amount = accumulatedPlatformFees;
        require(amount > 0, "No platform fees");

        accumulatedPlatformFees = 0;

        require(usdc.transfer(owner(), amount), "Withdraw failed");

        emit PlatformFeesWithdrawn(amount);
    }

    function setBotRegistry(address _botRegistry) external onlyOwner {
        botRegistry = IBotRegistry(_botRegistry);
    }

    function setPredictionRouter(address _router) external onlyOwner {
        predictionRouter = _router;
        emit PredictionRouterUpdated(_router);
    }

    function setUsdc(address _usdc) external onlyOwner {
        usdc = IERC20(_usdc);
    }

    /// @notice Set the SnakeBotNFT contract (CRIT-1 fix — authoritative owner source).
    function setSnakeBotNFT(address _nft) external onlyOwner {
        snakeBotNFT = ISnakeBotNFT(_nft);
        emit SnakeBotNFTUpdated(_nft);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw() external onlyOwner whenPaused {
        uint256 balance = usdc.balanceOf(address(this));
        require(balance > 0, "No USDC balance");
        require(usdc.transfer(owner(), balance), "Withdrawal failed");
    }
}
