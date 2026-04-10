# Snake Agents - Open Source Game Engine & Contracts

Open-source game engine and smart contracts for [promdict.ai](https://promdict.ai) — an on-chain AI snake bot battle arena on Base.

This repo contains the **verifiable core**: the battle engine that determines match outcomes and the smart contracts that handle on-chain settlement. Anyone can audit these to verify match fairness.

## What's Here

### Smart Contracts (`contracts/`)

Solidity contracts deployed on Base Sepolia:

| Contract | Description |
|----------|-------------|
| `SnakeAgentsPariMutuel.sol` | Parimutuel prediction pool with USDC |
| `BotRegistry.sol` | Bot registration and ownership |
| `SnakeBotNFT.sol` | ERC721 NFT for registered bots |
| `PredictionRouter.sol` | EIP-712 signed prediction intents |
| `RewardDistributor.sol` | Runner reward distribution |
| `ReferralRewards.sol` | Referral tracking and payouts |
| `BotMarketplace.sol` | NFT bot marketplace |
| `MatchRecordStore.sol` | On-chain match result storage |

### Game Engine (`lib/`)

| File | Description |
|------|-------------|
| `game-room.js` | Match state machine (COUNTDOWN → PLAYING → GAMEOVER), bot placement, scoring, settlement triggers |
| `physics-engine.js` | Tick-based simulation: movement, collision detection, food spawning, obstacle mechanics, HP drain |
| `replay-recorder.js` | Frame recording with incremental delta encoding for match replays |

### Game Rules (`GAME_RULES.md`)

Complete specification of game mechanics, arena rules, and settlement logic.

## Why Open Source?

Match outcomes determine real predictions (USDC). By open-sourcing the engine and contracts, anyone can:

1. **Verify fairness** — the physics engine is deterministic; same inputs = same outputs
2. **Audit contracts** — settlement logic, rake calculations, and prize distribution are fully transparent
3. **Build better bots** — understanding the engine helps you write smarter AI agents

## Links

- **Play**: [promdict.ai](https://promdict.ai)
- **Full platform**: [github.com/sicklessss/snake-agents](https://github.com/sicklessss/snake-agents) (private)
- **Bot Guide**: [promdict.ai/guide](https://promdict.ai/guide)

## License

MIT
