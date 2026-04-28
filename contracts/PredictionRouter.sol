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
    event DisplayMatchUnbound(bytes32 indexed displayMatchKey, uint256 indexed previousMatchId);
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

    /**
     * @notice Owner-only escape hatch: clear an existing display-match binding
     *         so a new matchId can be bound later.
     * @dev    HIGH-3 fix. Without this, a buggy or compromised matchBinder that
     *         writes a wrong/malicious binding would permanently brick all future
     *         intents for that displayMatchKey. The owner (expected to be a
     *         multisig or hardware wallet, NOT the hot matchBinder) can reset
     *         the binding. Intentionally NOT callable by the matchBinder.
     */
    function unbindDisplayMatch(bytes32 displayMatchKey) external onlyOwner {
        uint256 previous = boundMatches[displayMatchKey];
        require(previous != 0, "Not bound");
        delete boundMatches[displayMatchKey];
        emit DisplayMatchUnbound(displayMatchKey, previous);
    }

    function executeIntentBet(IntentBet calldata intent, bytes calldata signature)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 matchId, bytes32 intentHash)
    {
        (matchId, intentHash) = _executeIntentInternal(intent, signature);
    }

    /**
     * @notice PHASE 3c-2: batch-execute up to 20 intents in a single tx.
     *         All-or-nothing: if any intent fails (bad sig, expired, nonce reused,
     *         match not bound, USDC transfer fail), entire batch reverts. Backend
     *         pre-validates intents to keep batches clean.
     *         Saves ~40% gas per intent (amortized base 21k + warm storage reads).
     */
    function batchExecuteIntent(IntentBet[] calldata intents, bytes[] calldata signatures)
        external
        nonReentrant
        whenNotPaused
        returns (uint256[] memory matchIds, bytes32[] memory intentHashes)
    {
        uint256 n = intents.length;
        require(n == signatures.length, "Length mismatch");
        require(n > 0 && n <= 20, "Batch size 1-20");
        matchIds = new uint256[](n);
        intentHashes = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            (matchIds[i], intentHashes[i]) = _executeIntentInternal(intents[i], signatures[i]);
        }
    }

    function _executeIntentInternal(IntentBet calldata intent, bytes calldata signature)
        internal
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
