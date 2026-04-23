'use strict';

// Mirror of snake-agents/lib/config.js game constants.
// These values are part of the physics spec — the verifier would catch any
// server-side deviation. Bump `physicsVersion` if any of these change.

module.exports = {
    physicsVersion: 1,

    CONFIG: { gridSize: 30 },
    TICK_MS: 50,
    MATCH_DURATION: 180,     // seconds
    MAX_FOOD: 5,             // performance mode
    DEATH_BLINK_TURNS: 24,   // ticks the corpse blinks before cleanup

    // Competitive arena food curve — max food decreases over time.
    // Keep in sync with physics-engine.js foodCap logic if you add curves.

    SPAWN_POINTS: [
        { x: 5, y: 5, dir: { x: 1, y: 0 } },
        { x: 25, y: 5, dir: { x: -1, y: 0 } },
        { x: 5, y: 25, dir: { x: 1, y: 0 } },
        { x: 25, y: 25, dir: { x: -1, y: 0 } },
        { x: 15, y: 3, dir: { x: 0, y: 1 } },
        { x: 15, y: 27, dir: { x: 0, y: -1 } },
        { x: 3, y: 15, dir: { x: 1, y: 0 } },
        { x: 27, y: 15, dir: { x: -1, y: 0 } },
        { x: 10, y: 10, dir: { x: 1, y: 0 } },
        { x: 20, y: 20, dir: { x: -1, y: 0 } },
    ],
};
