# Promdict Replay Verifier

Cryptographically verify that a promdict.ai match replay was produced by the
physics engine published in this repo, without seeing the server source.

## What this proves

Every match on promdict.ai records:

- `rngSeed` — the `uint32` seed used for match-level randomness
- `inputLog` — every direction change each bot sent, tagged with tick + player
- `initialState` — post-spawn, pre-tick-1 snake positions
- Keyframes every 80 ticks with full board state

Running `verify.js` replays the same inputs through the same deterministic
`mulberry32` PRNG and the same physics code. If every keyframe matches
byte-for-byte, the replay is **provably** the output of this physics engine:
a server running different rules would produce divergent food positions, snake
lengths, or kill order within ~80 ticks (4 seconds of play).

## What this does NOT prove

- That any specific bot's **decision logic** is correct. The verifier accepts
  the recorded `inputLog` as ground-truth for each ws-connected bot. It only
  proves the server applied those inputs to the public physics rules.
- That the server broadcast the replay file to all viewers at the same time.
- Pool settlements / on-chain payouts. Those are enforced by the smart
  contracts under `contracts/`.

## Usage

```bash
# Verify a local replay file
node verify.js path/to/match-12345.json.gz

# Verify a live replay from promdict.ai
node verify.js https://promdict.ai/api/replay/ABC123
```

Exit codes:

- `0` — replay matches published physics
- `1` — mismatch (replay invalid, or server ran different physics)
- `2` — bad input / format

## Requirements

- Node.js ≥ 18 (uses built-in `fetch`, `zlib`, `fs`)
- No `npm install` needed

## How it works

1. Load and decompress the replay JSON.
2. Validate metadata: `verifiable === true`, `rngAlgo === "mulberry32"`,
   `physicsVersion === 1`, `encoding === "incremental"`.
3. Rebuild the pre-tick-1 room state from `initialState.players`
   (bodies, directions, colors) plus the exact `rngSeed`.
4. For each turn 1..N:
   - Apply every `inputLog` entry with `t === turn - 1` by setting the
     matching player's `nextDirection`.
   - Call `physics.processTick(room)`. For bots that had no websocket on
     the server (`hasController === false`), the port's `floodFillMove`
     runs and consumes the seeded PRNG identically to the server.
   - At keyframe turns, compare every player's body/score/hp/alive, plus
     the food and obstacle sets, to the recorded snapshot.
5. Report pass/fail.

## Files

- `rng.js` — mulberry32, bit-identical to `lib/game-room.js` on the server.
- `constants.js` — grid size, tick rate, match duration, spawn points.
- `physics.js` — self-contained port of `lib/physics-engine.js`. The only
  changes from the server copy are: `C` config is inlined from
  `constants.js`, `isOpposite` is inlined, log calls are stripped, and the
  blockchain `lockBetting` TX is removed (the verifier has no wallet).
- `verify.js` — entry point.

## Physics version

This verifier understands `physicsVersion: 1`. When the server bumps that
number, the ported physics in this repo must be updated to match before
replays with the new version can be verified.

## Integrity of the published engine

The SHA256 of `physics.js` + `rng.js` + `constants.js` is what any observer
should compare against a trusted reference (a signed release tag, a
well-known commit, etc.). A malicious fork that serves a different engine
cannot produce replays that `verify.js` will accept.

## License

MIT.
