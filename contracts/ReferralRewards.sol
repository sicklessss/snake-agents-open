// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title ReferralRewards
 * @notice 二层邀请奖励系统 - 链下计算，链上结算
 * @dev 使用 EIP-712 签名验证
 */
contract ReferralRewards is Ownable {
    using ECDSA for bytes32;
    
    // 签名验证地址（后端服务器）
    address public signer;
    
    // 用户 nonce（防重放）
    mapping(address => uint256) public nonces;
    
    // 用户已领取金额
    mapping(address => uint256) public claimed;
    
    // 累计发放金额
    uint256 public totalDistributed;
    
    // EIP-712 域分隔符
    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant CLAIM_TYPEHASH = keccak256(
        "Claim(address user,uint256 amount,uint256 nonce,uint256 chainId)"
    );
    
    event Claimed(address indexed user, uint256 amount, uint256 nonce, uint256 newTotalClaimed);
    event SignerUpdated(address indexed oldSigner, address indexed newSigner);
    event FundsReceived(address indexed from, uint256 amount);
    event FundsWithdrawn(address indexed to, uint256 amount);
    
    constructor(address _signer) Ownable(msg.sender) {
        require(_signer != address(0), "Invalid signer");
        signer = _signer;
        
        // 构建 EIP-712 域分隔符
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("SnakeReferral")),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
    }
    
    /**
     * @notice 用户领取邀请奖励
     * @param amount 领取金额（wei）
     * @param nonce 当前 nonce
     * @param signature 后端签名
     */
    function claim(
        uint256 amount,
        uint256 nonce,
        bytes calldata signature
    ) external {
        require(nonce == nonces[msg.sender], "Invalid nonce");
        require(amount > 0, "Invalid amount");
        require(address(this).balance >= amount, "Insufficient contract balance");
        require(_verifySignature(msg.sender, amount, nonce, signature), "Invalid signature");
        
        nonces[msg.sender]++;
        claimed[msg.sender] += amount;
        totalDistributed += amount;
        
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "ETH transfer failed");
        
        emit Claimed(msg.sender, amount, nonce, claimed[msg.sender]);
    }
    
    /**
     * @notice 批量领取（节省 gas）
     */
    function claimBatch(
        uint256[] calldata amounts,
        uint256[] calldata noncesList,
        bytes[] calldata signatures
    ) external {
        require(amounts.length == signatures.length, "Length mismatch");
        require(amounts.length == noncesList.length, "Length mismatch");
        
        uint256 totalAmount = 0;
        uint256 currentNonce = nonces[msg.sender];
        
        for (uint256 i = 0; i < amounts.length; i++) {
            require(noncesList[i] == currentNonce + i, "Invalid nonce sequence");
            require(_verifySignature(msg.sender, amounts[i], noncesList[i], signatures[i]), "Invalid signature");
            totalAmount += amounts[i];
        }
        
        require(address(this).balance >= totalAmount, "Insufficient balance");
        
        nonces[msg.sender] += amounts.length;
        claimed[msg.sender] += totalAmount;
        totalDistributed += totalAmount;
        
        (bool success, ) = payable(msg.sender).call{value: totalAmount}("");
        require(success, "ETH transfer failed");
        
        emit Claimed(msg.sender, totalAmount, currentNonce, claimed[msg.sender]);
    }
    
    /**
     * @notice 验证签名
     */
    function _verifySignature(
        address user,
        uint256 amount,
        uint256 nonce,
        bytes calldata signature
    ) internal view returns (bool) {
        bytes32 structHash = keccak256(abi.encode(
            CLAIM_TYPEHASH,
            user,
            amount,
            nonce,
            block.chainid
        ));
        
        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        return hash.recover(signature) == signer;
    }
    
    /**
     * @notice 更换签名地址（紧急情况下）
     */
    function setSigner(address _newSigner) external onlyOwner {
        require(_newSigner != address(0), "Invalid signer");
        address oldSigner = signer;
        signer = _newSigner;
        emit SignerUpdated(oldSigner, _newSigner);
    }
    
    /**
     * @notice 提取合约资金（紧急情况）
     */
    function withdraw(address payable to, uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient balance");
        (bool success, ) = to.call{value: amount}("");
        require(success, "Transfer failed");
        emit FundsWithdrawn(to, amount);
    }
    
    /**
     * @notice 查询用户待领取金额（供前端调用）
     * @dev 实际金额需要从后端 API 获取
     */
    function getClaimed(address user) external view returns (uint256) {
        return claimed[user];
    }
    
    /**
     * @notice 查询用户当前 nonce
     */
    function getNonce(address user) external view returns (uint256) {
        return nonces[user];
    }
    
    receive() external payable {
        emit FundsReceived(msg.sender, msg.value);
    }
    
    fallback() external payable {
        emit FundsReceived(msg.sender, msg.value);
    }
}
