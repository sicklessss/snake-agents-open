// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title SnakeBotNFT v2
 * @notice NFT for registered Snake Agents bots. Uses ERC721Enumerable so
 *         wallets can enumerate their bots on-chain without a backend.
 */
contract SnakeBotNFT is ERC721Enumerable, Ownable {
    using Strings for uint256;

    uint256 private _tokenIds;
    address public botRegistry;

    mapping(bytes32 => uint256) public botToTokenId;
    mapping(uint256 => bytes32) public tokenIdToBot;

    event BotNFTMinted(uint256 indexed tokenId, bytes32 indexed botId, address indexed owner);

    constructor() ERC721("SnakeBot", "SNAKE") Ownable(msg.sender) {}

    modifier onlyBotRegistry() {
        require(msg.sender == botRegistry, "Only BotRegistry");
        _;
    }

    function setBotRegistry(address _registry) external onlyOwner {
        botRegistry = _registry;
    }

    /**
     * @notice Mint a bot NFT. Called by BotRegistry on registerBot().
     * @param _to      Recipient (the registering wallet)
     * @param _botId   bytes32 bot ID (e.g. encodeBytes32String("bot_zu3up5"))
     * @param _botName Bot display name (stored in event / metadata)
     */
    function mintBotNFT(address _to, bytes32 _botId, string calldata _botName) external onlyBotRegistry returns (uint256) {
        require(botToTokenId[_botId] == 0, "Bot already has NFT");

        _tokenIds++;
        uint256 newTokenId = _tokenIds;

        _safeMint(_to, newTokenId);

        botToTokenId[_botId] = newTokenId;
        tokenIdToBot[newTokenId] = _botId;

        emit BotNFTMinted(newTokenId, _botId, _to);

        return newTokenId;
    }

    /**
     * @notice Return all botIds owned by a wallet. Frontend calls this on connect.
     */
    function getBotsByOwner(address _owner) external view returns (bytes32[] memory) {
        uint256 count = balanceOf(_owner);
        bytes32[] memory botIds = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(_owner, i);
            botIds[i] = tokenIdToBot[tokenId];
        }
        return botIds;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);

        bytes32 botId = tokenIdToBot[tokenId];
        string memory botIdStr = bytes32ToHexStr(botId);
        string memory image = string(
            abi.encodePacked(
                "data:image/svg+xml;base64,",
                Base64.encode(bytes(logoSvg()))
            )
        );

        string memory json = string(abi.encodePacked(
            '{"name":"SnakeBot #', tokenId.toString(), '",',
            '"description":"A battle-ready snake bot on Snake Agents",',
            '"image":"', image, '",',
            '"attributes":[',
                '{"trait_type":"Collection","value":"Snake Agents"},',
                '{"trait_type":"Bot ID","value":"', botIdStr, '"}',
            ']}'
        ));

        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }

    // ============ Internal helpers ============

    function bytes32ToHexStr(bytes32 _b) internal pure returns (string memory) {
        bytes memory bytesArray = new bytes(64);
        for (uint8 i = 0; i < 32; i++) {
            uint8 char = uint8(bytes1(_b << (i * 8)));
            uint8 hi = char / 16;
            uint8 lo = char % 16;
            bytesArray[i * 2]     = hi < 10 ? bytes1(hi + 48) : bytes1(hi + 87);
            bytesArray[i * 2 + 1] = lo < 10 ? bytes1(lo + 48) : bytes1(lo + 87);
        }
        return string(bytesArray);
    }

    function logoSvg() internal pure returns (string memory) {
        return string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 512 512'>",
            "<defs><filter id='g1'><feGaussianBlur stdDeviation='4' result='b'/>",
            "<feMerge><feMergeNode in='b'/><feMergeNode in='SourceGraphic'/></feMerge></filter>",
            "<filter id='g2'><feGaussianBlur stdDeviation='8' result='b'/>",
            "<feMerge><feMergeNode in='b'/><feMergeNode in='SourceGraphic'/></feMerge></filter>",
            "<linearGradient id='sg' x1='0%' y1='0%' x2='100%' y2='100%'>",
            "<stop offset='0%' stop-color='#00ff88'/><stop offset='100%' stop-color='#00ccff'/></linearGradient>",
            "<linearGradient id='bg' x1='0%' y1='0%' x2='100%' y2='100%'>",
            "<stop offset='0%' stop-color='#050510'/><stop offset='100%' stop-color='#0a0a2a'/></linearGradient></defs>",
            "<rect width='512' height='512' rx='64' fill='url(#bg)'/>",
            "<g stroke='#0d0d25' stroke-width='1' opacity='0.6'>",
            "<line x1='64' y1='0' x2='64' y2='512'/><line x1='128' y1='0' x2='128' y2='512'/>",
            "<line x1='192' y1='0' x2='192' y2='512'/><line x1='256' y1='0' x2='256' y2='512'/>",
            "<line x1='320' y1='0' x2='320' y2='512'/><line x1='384' y1='0' x2='384' y2='512'/>",
            "<line x1='448' y1='0' x2='448' y2='512'/><line x1='0' y1='64' x2='512' y2='64'/>",
            "<line x1='0' y1='128' x2='512' y2='128'/><line x1='0' y1='192' x2='512' y2='192'/>",
            "<line x1='0' y1='256' x2='512' y2='256'/><line x1='0' y1='320' x2='512' y2='320'/>",
            "<line x1='0' y1='384' x2='512' y2='384'/><line x1='0' y1='448' x2='512' y2='448'/></g>",
            "<g filter='url(#g1)'><path d='M120 130 L200 130 L200 190 L350 190 L350 250 L160 250 L160 310 L370 310 L370 370 L200 370 L200 420' stroke='url(#sg)' stroke-width='18' fill='none' stroke-linecap='round' stroke-linejoin='round'/>",
            "<circle cx='200' cy='130' r='6' fill='#00ff88'/><circle cx='200' cy='190' r='6' fill='#00ff88'/>",
            "<circle cx='350' cy='190' r='6' fill='#00ff88'/><circle cx='350' cy='250' r='6' fill='#00ff88'/>",
            "<circle cx='160' cy='250' r='6' fill='#00ccff'/><circle cx='160' cy='310' r='6' fill='#00ccff'/>",
            "<circle cx='370' cy='310' r='6' fill='#00ccff'/><circle cx='370' cy='370' r='6' fill='#00ccff'/>",
            "<circle cx='200' cy='370' r='6' fill='#00ccff'/></g>",
            "<g filter='url(#g2)'><polygon points='80,130 120,110 120,150' fill='#00ff88'/>",
            "<circle cx='105' cy='125' r='5' fill='#050510'/><circle cx='106' cy='124' r='2' fill='#fff'/></g>",
            "<g filter='url(#g1)' opacity='0.6'><rect x='192' y='420' width='16' height='16' fill='#00ccff' rx='2'/>",
            "<rect x='192' y='440' width='16' height='12' fill='#00ccff' rx='2' opacity='0.4'/></g>",
            "<g stroke='#00ff88' stroke-width='2' opacity='0.3'><line x1='200' y1='190' x2='240' y2='190'/>",
            "<line x1='240' y1='190' x2='240' y2='160'/><circle cx='240' cy='155' r='3' fill='#00ff88'/>",
            "<line x1='160' y1='310' x2='120' y2='310'/><line x1='120' y1='310' x2='120' y2='340'/>",
            "<circle cx='120' cy='345' r='3' fill='#00ff88'/><line x1='370' y1='370' x2='410' y2='370'/>",
            "<line x1='410' y1='370' x2='410' y2='340'/><circle cx='410' cy='335' r='3' fill='#00ccff'/></g>",
            "<g filter='url(#g1)'><rect x='280' y='120' width='14' height='14' fill='#ff0055' rx='3'/>",
            "<rect x='100' y='280' width='14' height='14' fill='#ff0055' rx='3'/>",
            "<rect x='400' y='240' width='14' height='14' fill='#ff0055' rx='3'/></g>",
            "<g transform='translate(410 440)' opacity='0.4'><polygon points='0,-18 15.6,-9 15.6,9 0,18 -15.6,9 -15.6,-9' fill='none' stroke='#00ccff' stroke-width='1.5'/>",
            "<polygon points='0,-10 8.7,-5 8.7,5 0,10 -8.7,5 -8.7,-5' fill='none' stroke='#00ccff' stroke-width='1'/></g></svg>"
        );
    }
}
