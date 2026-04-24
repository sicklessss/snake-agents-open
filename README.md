# Snake Agents — Open Source Engine, Contracts & Replay Verifier

Open-source verifiable core for [promdict.ai](https://promdict.ai) — an on-chain AI snake bot battle arena on Base.

This repo contains everything you need to **independently verify** that any match on promdict.ai was produced by the rules published here:

1. **Smart contracts** — settle predictions and distribute rewards on-chain
2. **Game engine** — the deterministic physics and match state machine
3. **Replay verifier** — a runnable script that re-plays any match from the public replay file and confirms it byte-for-byte against the published engine

---

## Verifier — the part most people will actually run

Every match on promdict.ai records:

- `rngSeed` — the `uint32` seed used for match-level randomness (food spawn, obstacle layout, AI tie-breaking)
- `inputLog` — every direction change each ws-connected bot sent, tagged with tick + player
- `eventLog` — out-of-band events (disconnects) that affect physics
- `initialState` — post-spawn, pre-tick-1 snapshot of every snake
- Full keyframes every 80 ticks

The verifier replays the recorded inputs through a self-contained port of the production physics engine (`verifier/physics.js`) and confirms every keyframe matches. A server running different rules would diverge within ~80 ticks (~4 seconds of play).

```bash
git clone https://github.com/sicklessss/snake-agents-open.git
cd snake-agents-open/verifier

# Verify a live replay from promdict.ai
node verify.js https://promdict.ai/api/replay/A15539

# Or a local replay file (supports .json or .json.gz)
node verify.js path/to/match-118349.json.gz
```

Exit codes: `0` = consistent, `1` = mismatch (replay invalid OR server ran different physics), `2` = bad input.

What a successful verify proves:

- ✅ The recorded `rngSeed + inputLog + eventLog`, applied to the published physics, reproduces every keyframe byte-for-byte
- ✅ The server cannot silently swap in different physics rules without verifications failing

What it does NOT prove:

- ❌ That a specific bot's decision logic is "correct" — `inputLog` is taken as ground truth for ws-connected bots
- ❌ Pool settlements / on-chain payouts — those are enforced by the contracts under `contracts/`

Requirements: Node.js ≥ 18 (uses built-in `fetch`, `zlib`, `fs`). No `npm install` needed.

See [`verifier/README.md`](verifier/README.md) for full details on the trust model and how each piece works.

---

## What's in the repo

### Smart Contracts (`contracts/`)

Solidity 0.8.20, MIT licensed. Live on Base Sepolia (testnet); mainnet-ready.

| Contract | Purpose |
|----------|---------|
| `SnakeAgentsPariMutuel.sol` | Parimutuel prediction pool with USDC, refund mechanics, 1-hour emergency-cancel timeout |
| `BotRegistry.sol` | Bot registration and ownership |
| `SnakeBotNFT.sol` | ERC-721 NFT for registered bots |
| `PredictionRouter.sol` | EIP-712 signed prediction intents |
| `RewardDistributor.sol` | Runner reward accumulation |
| `ReferralRewards.sol` | Referral tracking and payouts |
| `BotMarketplace.sol` | NFT bot secondary market |
| `MatchRecordStore.sol` | On-chain hash anchor for batch match summaries (v2 with `authorizedRecorders` allowlist) |

Settlement rules: 10% rake (5% platform + 5% runner rewards), 90% to predictors. Prize split: 1st 50%, 2nd 30%, 3rd 20%.

### Game Engine (`lib/`)

Reference copies of the engine the server runs. These have `require('./config')` etc. that the public repo doesn't ship — they're here for code review, not direct execution. The verifier under `verifier/` is the runnable, self-contained port.

| File | Purpose |
|------|---------|
| `game-room.js` | Match state machine (COUNTDOWN → PLAYING → GAMEOVER), seeded RNG, input/event logs, idempotency guards, replay metadata snapshot |
| `physics-engine.js` | Tick-based simulation: movement, collision, food spawn, HP drain, obstacle mechanics. Uses `room.rng()` (mulberry32) for all randomness — fully deterministic given seed + inputs |
| `replay-recorder.js` | Frame recording with incremental keyframe + delta encoding; ships `verifiable: true` metadata in every saved replay |

### Verifier (`verifier/`)

Standalone replay verifier — see [verifier/README.md](verifier/README.md).

| File | Purpose |
|------|---------|
| `verify.js` | Entry point: load replay → rebuild room → step physics → compare keyframes |
| `physics.js` | Self-contained port of `lib/physics-engine.js` (no runtime deps) |
| `rng.js` | mulberry32 PRNG, bit-identical to the server's PRNG |
| `constants.js` | Grid 30×30, 50ms tick, 180s match, spawn points |
| `test-port.js` | Parity test: runs verifier physics alongside `lib/physics-engine.js` for 200 ticks and confirms byte-identical output |

### Game Rules (`GAME_RULES.md`)

Complete specification of game mechanics, arena rules, and settlement logic.

---

## Why open source?

Match outcomes determine real predictions (USDC). By open-sourcing the engine, contracts, and verifier, anyone can:

1. **Verify fairness** — same inputs always produce the same output, and the verifier proves it
2. **Audit settlement** — rake, prize splits, and refund logic are fully on-chain and visible
3. **Build better bots** — understanding the engine helps you write smarter AI agents

## What's NOT in this repo

The platform's runtime infrastructure (web server, HTTP/WebSocket routes, blockchain TX queue, persistence layer, sandbox isolate, prediction-intent executor, frontend UI, marketing) lives in the private repo. Only the verifiable core is published here.

## Links

- **Play**: [promdict.ai](https://promdict.ai)
- **Bot guide**: [promdict.ai/guide](https://promdict.ai/guide)
- **Full platform** (private): [github.com/sicklessss/snake-agents](https://github.com/sicklessss/snake-agents)

## License

MIT
