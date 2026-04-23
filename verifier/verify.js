#!/usr/bin/env node
'use strict';

// Promdict replay verifier.
//
// Re-runs the recorded inputLog through this package's port of the production
// physics engine and confirms every keyframe in the replay matches the output
// byte-for-byte. If a single cell, score, or HP differs, verification fails.
//
// Usage:
//   node verify.js <replay.json.gz>
//   node verify.js <replay.json>
//   node verify.js https://promdict.ai/api/replay/<displayMatchId>
//
// Exit codes:
//   0  = replay is consistent with the published physics
//   1  = mismatch (replay is invalid OR the server ran a different physics)
//   2  = bad input / unsupported format

const fs = require('fs');
const zlib = require('zlib');
const { mulberry32 } = require('./rng');
const C = require('./constants');
const Physics = require('./physics');

const SUPPORTED_PHYSICS_VERSION = C.physicsVersion;
const SUPPORTED_RNG = 'mulberry32';
const SUPPORTED_ENCODING = 'incremental';

function die(code, msg) {
    process.stderr.write(msg + '\n');
    process.exit(code);
}

async function loadReplay(src) {
    let buf;
    if (/^https?:\/\//.test(src)) {
        const res = await fetch(src);
        if (!res.ok) die(2, `HTTP ${res.status} fetching ${src}`);
        buf = Buffer.from(await res.arrayBuffer());
    } else {
        if (!fs.existsSync(src)) die(2, `file not found: ${src}`);
        buf = fs.readFileSync(src);
    }
    // gzip magic 1f 8b
    if (buf[0] === 0x1f && buf[1] === 0x8b) {
        buf = zlib.gunzipSync(buf);
    }
    let json;
    try {
        json = JSON.parse(buf.toString('utf8'));
    } catch (e) {
        die(2, `not valid JSON: ${e.message}`);
    }
    return json;
}

function checkMetadata(replay) {
    const errors = [];
    if (!replay.verifiable) errors.push('replay.verifiable !== true');
    if (replay.rngAlgo !== SUPPORTED_RNG) errors.push(`unsupported rngAlgo: ${replay.rngAlgo}`);
    if (replay.physicsVersion !== SUPPORTED_PHYSICS_VERSION) {
        errors.push(`physicsVersion mismatch: replay=${replay.physicsVersion} verifier=${SUPPORTED_PHYSICS_VERSION}`);
    }
    if (replay.encoding !== SUPPORTED_ENCODING) errors.push(`unsupported encoding: ${replay.encoding}`);
    if (typeof replay.rngSeed !== 'number') errors.push('replay.rngSeed missing');
    if (!Array.isArray(replay.inputLog)) errors.push('replay.inputLog missing');
    if (!Array.isArray(replay.frames) || replay.frames.length === 0) errors.push('replay.frames missing');
    if (!replay.initialState || !Array.isArray(replay.initialState.players)) {
        errors.push('replay.initialState.players missing');
    }
    return errors;
}

function buildRoom(replay) {
    const players = {};
    for (const p of replay.initialState.players) {
        players[p.id] = {
            id: p.id,
            name: p.name,
            color: p.color,
            body: p.body.map(s => ({ x: s.x, y: s.y })),
            direction: { x: p.direction.x, y: p.direction.y },
            nextDirection: { x: p.direction.x, y: p.direction.y },
            alive: true,
            score: 0,
            hp: 100,
            // Stub ws-truthy for controller-driven bots so physics-engine skips
            // its floodFillMove fallback (their inputs come from inputLog).
            // Leave ws=null for bots that ran floodFillMove on the server, so
            // the verifier reproduces those moves by re-running the same code.
            ws: p.hasController ? { _stub: true } : null,
            botType: p.botType,
        };
    }

    return {
        id: replay.arenaId,
        type: replay.arenaType,
        gameState: 'PLAYING',
        turn: 0,
        matchTimeLeft: replay.matchDuration || C.MATCH_DURATION,
        rng: mulberry32(replay.rngSeed),
        players,
        food: [],
        obstacles: (replay.initialState.obstacles || []).map(o => ({ ...o })),
        deathSeq: 0,
        obstacleTick: 0,
        victoryPauseTimer: 0,
        lastSurvivorForVictory: null,
        _terminal: null,
        // Used by physics food spawn loop. Mirrors game-room.isCellOccupied
        // exactly — checks ALL players' body segments (alive AND dead). Dead
        // snake corpses still block food spawn until they're cleaned up.
        isCellOccupied(x, y) {
            for (const p of Object.values(this.players)) {
                for (const seg of (p.body || [])) {
                    if (seg.x === x && seg.y === y) return true;
                }
            }
            return false;
        },
    };
}

// Apply all inputs that were received between previous tick and the next one.
// Server convention: handleMove(turn=N) means "received before tick N+1 ran".
function applyInputs(room, inputLog, cursor, beforeTurn) {
    while (cursor < inputLog.length && inputLog[cursor].t === beforeTurn - 1) {
        const inp = inputLog[cursor];
        const p = room.players[inp.p];
        if (p && p.alive) {
            const newDir = { x: inp.x, y: inp.y };
            // Reject illegal 180s (the server's handleMove also rejects these).
            const cur = p.direction;
            if (!(newDir.x === -cur.x && newDir.y === -cur.y)) {
                p.nextDirection = newDir;
            }
        }
        cursor++;
    }
    return cursor;
}

// Apply out-of-band events (disconnects, etc.) that happened between the
// previous tick and the next one. Same convention as applyInputs.
function applyEvents(room, eventLog, cursor, beforeTurn) {
    while (cursor < eventLog.length && eventLog[cursor].t === beforeTurn - 1) {
        const ev = eventLog[cursor];
        const p = room.players[ev.p];
        if (ev.type === 'disconnect' && p && p.alive) {
            // Mirror game-room.killPlayer(p, 'disconnect'). In competitive mode
            // the disconnected snake's body turns into obstacles (same as any
            // non-'eaten' death).
            p.alive = false;
            p.deathTimer = C.DEATH_BLINK_TURNS;
            p.deathTime = 0;
            p.deathType = 'disconnect';
            p.deathSeq = ++room.deathSeq;
            if (room.type === 'competitive' && p.body && p.body.length > 0) {
                for (const seg of p.body) {
                    room.obstacles.push({
                        x: seg.x, y: seg.y,
                        solid: true, blinkTimer: 0, fromCorpse: true,
                    });
                }
                room.food = room.food.filter(f => !p.body.some(s => s.x === f.x && s.y === f.y));
            }
        }
        cursor++;
    }
    return cursor;
}

function verifierTick(room, matchDuration) {
    if (room.victoryPauseTimer > 0) {
        room.victoryPauseTimer--;
        if (room.victoryPauseTimer <= 0) {
            room._terminal = 'victory';
        }
        return;
    }
    room.turn++;
    // Server updates matchTimeLeft on a 1Hz wall-clock timer that runs
    // independently of the 20Hz tick loop. Re-derive it from turn count so
    // verification doesn't depend on real time. This can drift by ±1 second
    // around food-cap boundaries in competitive mode.
    room.matchTimeLeft = Math.max(0, matchDuration - Math.floor((room.turn * C.TICK_MS) / 1000));
    Physics.processTick(room);
}

function snapshotPlayer(p) {
    return {
        id: p.id,
        body: p.body.map(s => ({ x: s.x, y: s.y })),
        score: p.score,
        hp: p.hp,
        alive: p.alive,
    };
}

function pointSetEqual(a, b) {
    if (a.length !== b.length) return false;
    const ka = new Set(a.map(p => `${p.x},${p.y}`));
    for (const p of b) if (!ka.has(`${p.x},${p.y}`)) return false;
    return true;
}

function obstacleSetEqual(a, b) {
    if (a.length !== b.length) return false;
    const ka = new Set(a.map(o => `${o.x},${o.y},${o.solid ? 1 : 0}`));
    for (const o of b) if (!ka.has(`${o.x},${o.y},${o.solid ? 1 : 0}`)) return false;
    return true;
}

function compareKeyframe(room, frame) {
    const issues = [];

    // Build server snapshot from frame
    const recordedById = new Map(frame.players.map(p => [p.id, p]));
    const computedById = new Map(Object.values(room.players).map(p => [p.id, snapshotPlayer(p)]));

    if (recordedById.size !== computedById.size) {
        issues.push(`player count: recorded=${recordedById.size} computed=${computedById.size}`);
    }

    for (const [id, rec] of recordedById) {
        const com = computedById.get(id);
        if (!com) { issues.push(`player ${id} missing in computed`); continue; }
        if (com.alive !== rec.alive) issues.push(`player ${id} alive: recorded=${rec.alive} computed=${com.alive}`);
        if (com.score !== rec.score) issues.push(`player ${id} score: recorded=${rec.score} computed=${com.score}`);
        if (com.hp !== rec.hp) issues.push(`player ${id} hp: recorded=${rec.hp} computed=${com.hp}`);
        if (com.body.length !== rec.body.length) {
            issues.push(`player ${id} body length: recorded=${rec.body.length} computed=${com.body.length}`);
        } else {
            for (let i = 0; i < com.body.length; i++) {
                if (com.body[i].x !== rec.body[i].x || com.body[i].y !== rec.body[i].y) {
                    issues.push(`player ${id} body[${i}]: recorded=(${rec.body[i].x},${rec.body[i].y}) computed=(${com.body[i].x},${com.body[i].y})`);
                    break;
                }
            }
        }
    }

    if (!pointSetEqual(frame.food, room.food)) {
        issues.push(`food mismatch: recorded=${frame.food.length} computed=${room.food.length}`);
    }

    if (room.type === 'competitive') {
        const computedObs = room.obstacles.filter(o => o.solid || o.blinkTimer > 0);
        if (!obstacleSetEqual(frame.obstacles || [], computedObs)) {
            issues.push(`obstacle mismatch: recorded=${(frame.obstacles || []).length} computed=${computedObs.length}`);
        }
    }

    return issues;
}

function verify(replay) {
    const errors = checkMetadata(replay);
    if (errors.length) {
        return { ok: false, stage: 'metadata', errors };
    }

    const room = buildRoom(replay);
    const inputLog = replay.inputLog;
    let inputCursor = 0;

    const matchDuration = replay.matchDuration || C.MATCH_DURATION;
    const eventLog = replay.eventLog || [];
    let eventCursor = 0;
    let keyframeChecks = 0;
    let lastTurn = 0;
    for (const frame of replay.frames) {
        const targetTurn = frame.turn;
        // Drive ticks forward until we reach the frame's turn.
        while (room.turn < targetTurn) {
            inputCursor = applyInputs(room, inputLog, inputCursor, room.turn + 1);
            eventCursor = applyEvents(room, eventLog, eventCursor, room.turn + 1);
            verifierTick(room, matchDuration);
            if (room._terminal && room.turn < targetTurn) {
                // Match ended early but replay still has frames. Allow trailing
                // frames to mirror the post-terminal state (server keeps running
                // ticks after a wipeout/victory pause until startGameOver fires).
            }
        }
        lastTurn = targetTurn;
        if (frame.keyframe) {
            const issues = compareKeyframe(room, frame);
            if (issues.length) {
                return { ok: false, stage: 'keyframe', frameTurn: frame.turn, issues };
            }
            keyframeChecks++;
        }
        // delta frames are not verified individually (the next keyframe covers
        // their cumulative effect). The presence of well-formed deltas is OK.
    }

    return {
        ok: true,
        matchId: replay.matchId,
        displayMatchId: replay.displayMatchId,
        totalFrames: replay.frames.length,
        keyframeChecks,
        lastTurn,
        rngSeed: replay.rngSeed,
        inputs: inputLog.length,
    };
}

async function main() {
    const src = process.argv[2];
    if (!src) {
        die(2, 'usage: node verify.js <replay.json[.gz] | url>');
    }
    const replay = await loadReplay(src);
    const result = verify(replay);
    if (result.ok) {
        process.stdout.write(`OK match=${result.matchId} display=${result.displayMatchId || '-'} ` +
            `frames=${result.totalFrames} keyframes=${result.keyframeChecks} ` +
            `inputs=${result.inputs} seed=${result.rngSeed} lastTurn=${result.lastTurn}\n`);
        process.exit(0);
    } else {
        process.stdout.write(`FAIL stage=${result.stage}\n`);
        if (result.errors) for (const e of result.errors) process.stdout.write(`  - ${e}\n`);
        if (result.issues) {
            process.stdout.write(`  at frameTurn=${result.frameTurn}\n`);
            for (const i of result.issues.slice(0, 10)) process.stdout.write(`  - ${i}\n`);
            if (result.issues.length > 10) process.stdout.write(`  ...${result.issues.length - 10} more\n`);
        }
        process.exit(1);
    }
}

main().catch(e => die(2, `error: ${e.stack || e.message}`));
