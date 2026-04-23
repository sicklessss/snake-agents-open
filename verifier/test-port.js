#!/usr/bin/env node
'use strict';

// Smoke test: run this port of physics alongside the reference physics-engine
// and confirm they produce byte-identical output for N ticks.
//
// Defaults to the reference engine at ../lib/physics-engine.js (the copy in
// this repo). Override with SERVER_ROOT=/path/to/another-checkout to compare
// against a different copy (e.g., the private snake-agents repo).
//
// Usage:
//   node test-port.js
//   SERVER_ROOT=/path/to/snake-agents node test-port.js

const path = require('path');
const { mulberry32 } = require('./rng');
const C_VERIF = require('./constants');
const Physics_VERIF = require('./physics');

const SERVER_ROOT = process.env.SERVER_ROOT || path.resolve(__dirname, '..');

// Stub C.log and S for the server physics so it doesn't need a real runtime.
// We need to intercept the `require` cache.
const Module = require('module');
const origResolve = Module._resolve_filename || Module._resolveFilename;
const origLoad = Module._load;

Module._load = function (request, parent, ...rest) {
    // Handle relative requires from the server's physics-engine
    if (parent && parent.filename && parent.filename.includes(path.join(SERVER_ROOT, 'lib'))) {
        if (request === './config') {
            return {
                CONFIG: C_VERIF.CONFIG,
                MAX_FOOD: C_VERIF.MAX_FOOD,
                DEATH_BLINK_TURNS: C_VERIF.DEATH_BLINK_TURNS,
                SPAWN_POINTS: C_VERIF.SPAWN_POINTS,
                TICK_MS: C_VERIF.TICK_MS,
                MATCH_DURATION: C_VERIF.MATCH_DURATION,
                log: { info: () => {}, warn: () => {}, error: () => {}, important: () => {} },
            };
        }
        if (request === './state') {
            return { pariMutuelContract: null };
        }
        if (request === './blockchain') {
            return { enqueueLifecycleTx: () => {} };
        }
        if (request === './bot-manager') {
            return {
                isOpposite(dir1, dir2) { return dir1.x === -dir2.x && dir1.y === -dir2.y; },
            };
        }
    }
    return origLoad.apply(this, [request, parent, ...rest]);
};

const Physics_SERVER = require(path.join(SERVER_ROOT, 'lib', 'physics-engine.js'));

function buildRoom(seed) {
    const players = {
        p1: {
            id: 'p1', name: 'A', color: '#f00',
            body: [{ x: 5, y: 5 }, { x: 4, y: 5 }, { x: 3, y: 5 }],
            direction: { x: 1, y: 0 }, nextDirection: { x: 1, y: 0 },
            alive: true, score: 0, hp: 100, ws: { _stub: true }, botType: 'agent',
        },
        p2: {
            id: 'p2', name: 'B', color: '#0f0',
            body: [{ x: 25, y: 5 }, { x: 26, y: 5 }, { x: 27, y: 5 }],
            direction: { x: -1, y: 0 }, nextDirection: { x: -1, y: 0 },
            alive: true, score: 0, hp: 100, ws: { _stub: true }, botType: 'agent',
        },
        p3: {
            id: 'p3', name: 'C', color: '#00f',
            body: [{ x: 5, y: 25 }, { x: 4, y: 25 }, { x: 3, y: 25 }],
            direction: { x: 1, y: 0 }, nextDirection: { x: 1, y: 0 },
            alive: true, score: 0, hp: 100, ws: null, botType: 'normal',
        },
    };
    return {
        id: 'test', type: 'performance', gameState: 'PLAYING', turn: 0,
        matchTimeLeft: 180,
        rng: mulberry32(seed),
        players, food: [], obstacles: [],
        deathSeq: 0, obstacleTick: 0,
        victoryPauseTimer: 0, lastSurvivorForVictory: null,
        isCellOccupied(x, y) {
            for (const p of Object.values(this.players)) {
                if (!p.alive || !p.body) continue;
                for (const seg of p.body) {
                    if (seg.x === x && seg.y === y) return true;
                }
            }
            return false;
        },
    };
}

function snap(room) {
    return JSON.stringify({
        food: [...room.food].sort((a, b) => a.x - b.x || a.y - b.y),
        players: Object.values(room.players).map(p => ({
            id: p.id,
            body: p.body,
            alive: p.alive,
            hp: p.hp,
            score: p.score,
        })),
    });
}

const SEED = 42;
const TICKS = 200;

const roomA = buildRoom(SEED);
const roomB = buildRoom(SEED);

for (let i = 1; i <= TICKS; i++) {
    roomA.turn = i;
    roomB.turn = i;
    Physics_VERIF.processTick(roomA);
    Physics_SERVER.processTick(roomB);
    const a = snap(roomA);
    const b = snap(roomB);
    if (a !== b) {
        console.error(`DIVERGE at tick ${i}`);
        console.error('  verifier:', a);
        console.error('  server:  ', b);
        process.exit(1);
    }
}

console.log(`OK: ${TICKS} ticks, verifier and server produced identical output`);
