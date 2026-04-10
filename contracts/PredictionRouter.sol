// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPariMutuelIntent {
    function placeBetFor(address _bettor, uint256 _matchId, bytes32 _botId, uint256 _amount) external;
}

/**
 * @title PredictionRouter
 * @notice Executes signed future-match betting intents once displayMatchId has been bound to a real matchId.
 * @dev Users keep funds in their own wallets. Router only pulls USDC at execution time.
 */
contract PredictionRouter is Ownable, Pausable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    bytes32 public constant INTENT_BET_TYPEHASH = keccak256(
        "IntentBet(address bettor,bytes32 displayMatchKey,bytes32 arenaKey,bytes32 botId,uint256 amount,uint256 deadline,uint256 nonce)"
    );

    struct IntentBet {
        address bettor;
        bytes32 displayMatchKey;
        bytes32 arenaKey;
        bytes32 botId;
        uint256 amount;
        uint256 deadline;
        uint256 nonce;
    }

    IERC20 public immutable usdc;
    IPariMutuelIntent public pariMutuel;
    address public matchBinder;

    mapping(bytes32 => uint256) public boundMatches;
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    event MatchBinderUpdated(address indexed binder);
    event PariMutuelUpdated(address indexed pariMutuel);
    event DisplayMatchBound(bytes32 indexed displayMatchKey, uint256 indexed matchId);
    event IntentExecuted(
        bytes32 indexed intentHash,
        address indexed bettor,
        bytes32 indexed displayMatchKey,
        uint256 matchId,
        bytes32 botId,
        uint256 amount
    );

    modifier onlyMatchBinder() {
        require(msg.sender == matchBinder, "Not match binder");
        _;
    }

    constructor(address _usdc, address _pariMutuel, address _matchBinder)
        Ownable(msg.sender)
        EIP712("SnakeAgents Prediction Router", "1")
    {
        require(_usdc != address(0), "Invalid USDC");
        require(_pariMutuel != address(0), "Invalid pariMutuel");
        require(_matchBinder != address(0), "Invalid matchBinder");
        usdc = IERC20(_usdc);
        pariMutuel = IPariMutuelIntent(_pariMutuel);
        matchBinder = _matchBinder;
    }

    function hashIntent(IntentBet calldata intent) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(
            INTENT_BET_TYPEHASH,
            intent.bettor,
            intent.displayMatchKey,
            intent.arenaKey,
            intent.botId,
            intent.amount,
            intent.deadline,
            intent.nonce
        )));
    }

    function bindDisplayMatch(bytes32 displayMatchKey, uint256 matchId) external onlyMatchBinder {
        require(displayMatchKey != bytes32(0), "Invalid display key");
        require(matchId != 0, "Invalid matchId");
        uint256 existing = boundMatches[displayMatchKey];
        require(existing == 0 || existing == matchId, "Display match already bound");
        boundMatches[displayMatchKey] = matchId;
        emit DisplayMatchBound(displayMatchKey, matchId);
    }

    function executeIntentBet(IntentBet calldata intent, bytes calldata signature)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 matchId, bytes32 intentHash)
    {
        require(intent.bettor != address(0), "Invalid bettor");
        require(intent.botId != bytes32(0), "Invalid botId");
        require(intent.amount > 0, "Invalid amount");
        require(block.timestamp <= intent.deadline, "Intent expired");
        require(!usedNonces[intent.bettor][intent.nonce], "Nonce already used");

        intentHash = hashIntent(intent);
        address signer = ECDSA.recover(intentHash, signature);
        require(signer == intent.bettor, "Invalid signature");

        matchId = boundMatches[intent.displayMatchKey];
        require(matchId != 0, "Display match not bound");

        usedNonces[intent.bettor][intent.nonce] = true;

        usdc.safeTransferFrom(intent.bettor, address(pariMutuel), intent.amount);
        pariMutuel.placeBetFor(intent.bettor, matchId, intent.botId, intent.amount);

        emit IntentExecuted(intentHash, intent.bettor, intent.displayMatchKey, matchId, intent.botId, intent.amount);
    }

    function setMatchBinder(address _matchBinder) external onlyOwner {
        require(_matchBinder != address(0), "Invalid matchBinder");
        matchBinder = _matchBinder;
        emit MatchBinderUpdated(_matchBinder);
    }

    function setPariMutuel(address _pariMutuel) external onlyOwner {
        require(_pariMutuel != address(0), "Invalid pariMutuel");
        pariMutuel = IPariMutuelIntent(_pariMutuel);
        emit PariMutuelUpdated(_pariMutuel);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
