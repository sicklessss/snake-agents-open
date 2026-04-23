'use strict';

const C = require('./config');
const zlib = require('zlib');
const fs = require('fs');
const path = require('path');

// --- Incremental Encoding Constants ---
const KEYFRAME_INTERVAL = 80; // Full snapshot every 80 ticks (~10 seconds)
const MAX_FRAMES = 2000;

/**
 * Build a full snapshot of current state (used for keyframes).
 */
function _buildSnapshot(room, displayPlayers) {
    return {
        players: displayPlayers.map(p => ({
            id: p.id,
            name: p.name,
            color: p.color,
            body: p.body.map(s => ({ x: s.x, y: s.y })),
            score: p.score,
            hp: p.hp,
            alive: p.alive,
            botType: p.botType,
        })),
        food: room.food.map(f => ({ x: f.x, y: f.y })),
        obstacles: room.type === 'competitive'
            ? room.obstacles.filter(o => o.solid || o.blinkTimer > 0).map(o => ({ x: o.x, y: o.y, solid: o.solid }))
            : [],
    };
}

/**
 * Build a delta frame by comparing current state to previous snapshot.
 * Only records what changed since last frame.
 */
function _buildDelta(room, displayPlayers, prevSnapshot) {
    const events = [];

    // Detect player changes
    const prevPlayerMap = new Map(prevSnapshot.players.map(p => [p.id, p]));
    for (const p of displayPlayers) {
        const prev = prevPlayerMap.get(p.id);
        if (!prev) {
            // New player spawned
            events.push({ type: 'spawn', id: p.id, name: p.name, color: p.color, body: p.body.map(s => ({ x: s.x, y: s.y })), botType: p.botType });
        } else {
            // Check direction change (head movement delta)
            if (p.body.length > 0 && prev.body.length > 0) {
                const head = p.body[0];
                const prevHead = prev.body[0];
                const dx = head.x - prevHead.x;
                const dy = head.y - prevHead.y;
                if (dx !== 0 || dy !== 0) {
                    events.push({ type: 'move', id: p.id, dx, dy });
                }
            }
            // Check length change (ate food)
            if (p.body.length > prev.body.length) {
                events.push({ type: 'grow', id: p.id, len: p.body.length });
            }
            // Check death
            if (!p.alive && prev.alive) {
                events.push({ type: 'death', id: p.id });
            }
            // Score change
            if (p.score !== prev.score) {
                events.push({ type: 'score', id: p.id, s: p.score });
            }
            // HP change
            if (p.hp !== prev.hp) {
                events.push({ type: 'hp', id: p.id, hp: p.hp });
            }
        }
    }
    // Detect removed players
    for (const prev of prevSnapshot.players) {
        if (!displayPlayers.find(p => p.id === prev.id)) {
            events.push({ type: 'remove', id: prev.id });
        }
    }

    // Food changes (simple diff)
    const prevFoodSet = new Set(prevSnapshot.food.map(f => `${f.x},${f.y}`));
    const currFoodSet = new Set(room.food.map(f => `${f.x},${f.y}`));
    for (const f of room.food) {
        if (!prevFoodSet.has(`${f.x},${f.y}`)) {
            events.push({ type: 'food+', x: f.x, y: f.y });
        }
    }
    for (const f of prevSnapshot.food) {
        if (!currFoodSet.has(`${f.x},${f.y}`)) {
            events.push({ type: 'food-', x: f.x, y: f.y });
        }
    }

    // Obstacle changes (competitive only)
    if (room.type === 'competitive') {
        const currObs = room.obstacles.filter(o => o.solid || o.blinkTimer > 0);
        const prevObsSet = new Set(prevSnapshot.obstacles.map(o => `${o.x},${o.y},${o.solid}`));
        for (const o of currObs) {
            if (!prevObsSet.has(`${o.x},${o.y},${o.solid}`)) {
                events.push({ type: 'obs+', x: o.x, y: o.y, solid: o.solid });
            }
        }
    }

    return events;
}

/**
 * Record a single frame of game state for replay.
 * Uses incremental encoding: keyframes every KEYFRAME_INTERVAL ticks,
 * delta frames in between to reduce memory/GC pressure.
 *
 * @param {import('./game-room')} room
 * @param {Array} displayPlayers - Pre-built display player array from broadcastState
 */
function recordFrame(room, displayPlayers) {
    if (room.gameState !== 'PLAYING' || room.replayFrames.length >= MAX_FRAMES) return;

    const frameIndex = room.replayFrames.length;
    const isKeyframe = (frameIndex % KEYFRAME_INTERVAL === 0);

    if (isKeyframe) {
        const snapshot = _buildSnapshot(room, displayPlayers);
        room.replayFrames.push({
            turn: room.turn,
            matchTimeLeft: room.matchTimeLeft,
            keyframe: true,
            ...snapshot,
        });
        // Store last snapshot for delta comparison
        room._lastReplaySnapshot = snapshot;
    } else if (room._lastReplaySnapshot) {
        const events = _buildDelta(room, displayPlayers, room._lastReplaySnapshot);
        room.replayFrames.push({
            turn: room.turn,
            matchTimeLeft: room.matchTimeLeft,
            events,
        });
        // Update snapshot for next delta
        room._lastReplaySnapshot = _buildSnapshot(room, displayPlayers);
    } else {
        // Fallback: if no previous snapshot, force a keyframe
        const snapshot = _buildSnapshot(room, displayPlayers);
        room.replayFrames.push({
            turn: room.turn,
            matchTimeLeft: room.matchTimeLeft,
            keyframe: true,
            ...snapshot,
        });
        room._lastReplaySnapshot = snapshot;
    }
}

/**
 * Compress replay frames with gzip and save to disk.
 * Also updates the lightweight replay index via persistence.
 *
 * @param {import('./game-room')} room
 * @param {object|null} survivor - The winning player, or null
 */
function saveReplay(room, survivor) {
    const P = require('./persistence');

    if (room.replayFrames.length === 0) {
        // Upstream signal that no bot ever joined this match (workers timed out
        // before handshake, PM2 restart mid-match, etc.). Used to be silent —
        // surfaces now so the TG error aggregator picks it up.
        C.log.warn(`[Replay] Empty frames for match #${room.currentMatchId} (${room.displayMatchId || '-'}) in ${room.id} — no bot joined, skipping save`);
        return;
    }

    const replay = {
        matchId: room.currentMatchId,
        displayMatchId: room.displayMatchId,
        arenaId: room.id,
        arenaType: room.type,
        gridSize: C.CONFIG.gridSize,
        timestamp: new Date().toISOString(),
        winner: room.winner,
        winnerScore: survivor ? survivor.score : 0,
        totalFrames: room.replayFrames.length,
        encoding: 'incremental', // Mark format for client-side decoder
        keyframeInterval: KEYFRAME_INTERVAL,
        frames: room.replayFrames,
        // --- Verifiability metadata (snake-agents-open verifier consumes these) ---
        // Re-running mulberry32(rngSeed) with the same input log on the published
        // physics engine MUST reproduce the recorded frames byte-for-byte.
        verifiable: true,
        verifiableVersion: 1,
        rngSeed: room._rngSeed != null ? room._rngSeed : (room.currentMatchId >>> 0),
        rngAlgo: 'mulberry32',
        physicsVersion: 1,           // bump when physics rules change
        tickMs: C.TICK_MS,
        matchDuration: C.MATCH_DURATION,
        inputLog: room.inputLog || [],
        eventLog: room.eventLog || [],
        initialState: room._initialState || null,
    };

    // Ensure replays directory exists
    const replayDir = C.REPLAY_DIR;
    if (!fs.existsSync(replayDir)) {
        fs.mkdirSync(replayDir, { recursive: true });
    }

    const filename = `match-${room.currentMatchId}.json.gz`;
    const jsonBuf = Buffer.from(JSON.stringify(replay));
    zlib.gzip(jsonBuf, (err, compressed) => {
        if (err) { C.log.error('[Replay] Gzip failed:', err.message); return; }
        fs.writeFile(path.join(replayDir, filename), compressed, (err2) => {
            if (err2) C.log.error('[Replay] Failed to save:', err2.message);
        });
    });
    C.log.info(`[Replay] Saved ${filename} (${room.replayFrames.length} frames, incremental encoding)`);

    // Add to lightweight replay index
    P.addToReplayIndex({
        matchId: room.currentMatchId,
        displayMatchId: room.displayMatchId,
        arenaId: room.id,
        timestamp: replay.timestamp,
        winner: room.winner,
        winnerScore: survivor ? survivor.score : 0,
        totalFrames: room.replayFrames.length,
    });

    // Clear frames for next match
    room.replayFrames = [];
    room._lastReplaySnapshot = null;
}

/**
 * Reset replay frames array for the room.
 *
 * @param {import('./game-room')} room
 */
function clearFrames(room) {
    room.replayFrames = [];
    room._lastReplaySnapshot = null;
}

module.exports = {
    recordFrame,
    saveReplay,
    clearFrames,
    KEYFRAME_INTERVAL,
};
