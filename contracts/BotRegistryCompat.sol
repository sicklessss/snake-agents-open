// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title BotRegistryCompat
 * @notice Compatibility adapter for historical runner rewards keyed by display name.
 *         It preserves the BotRegistry.getBotById(bytes32) interface expected by
 *         SnakeAgentsPariMutuel, but falls back to getBotByName(string) when the
 *         incoming bytes32 key is a historical display-name key instead of a botId.
 */
interface IBotRegistryCompatSource {
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
    function getBotByName(string calldata _name) external view returns (Bot memory);
}

contract BotRegistryCompat {
    IBotRegistryCompatSource public immutable source;

    constructor(address _source) {
        source = IBotRegistryCompatSource(_source);
    }

    function getBotById(bytes32 _key) external view returns (
        bytes32 botId,
        string memory botName,
        address owner,
        bool registered,
        uint256 registeredAt,
        uint256 matchesPlayed,
        uint256 totalEarnings,
        uint256 salePrice
    ) {
        IBotRegistryCompatSource.Bot memory bot = source.getBotById(_key);
        if (bot.botId != bytes32(0)) {
            return (
                bot.botId,
                bot.botName,
                bot.owner,
                bot.registered,
                bot.registeredAt,
                bot.matchesPlayed,
                bot.totalEarnings,
                bot.salePrice
            );
        }

        string memory nameKey = _bytes32ToString(_key);
        if (bytes(nameKey).length == 0) {
            return _emptyBot();
        }

        try source.getBotByName(nameKey) returns (IBotRegistryCompatSource.Bot memory byName) {
            return (
                byName.botId,
                byName.botName,
                byName.owner,
                byName.registered,
                byName.registeredAt,
                byName.matchesPlayed,
                byName.totalEarnings,
                byName.salePrice
            );
        } catch {
            return _emptyBot();
        }
    }

    function _emptyBot() private pure returns (
        bytes32 botId,
        string memory botName,
        address owner,
        bool registered,
        uint256 registeredAt,
        uint256 matchesPlayed,
        uint256 totalEarnings,
        uint256 salePrice
    ) {
        return (bytes32(0), "", address(0), false, 0, 0, 0, 0);
    }

    function _bytes32ToString(bytes32 value) private pure returns (string memory) {
        uint256 length = 0;
        while (length < 32 && value[length] != 0) {
            length++;
        }

        bytes memory result = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            result[i] = value[i];
        }
        return string(result);
    }
}
