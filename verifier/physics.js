'use strict';

// Port of snake-agents/lib/physics-engine.js — self-contained.
//
// Removed runtime-only dependencies so the verifier can re-run physics
// offline with no blockchain/state/logger wiring:
//   - `C` (config)     → pulled from ./constants.js
//   - `S` (global state) + `BC` (blockchain): lockBetting TX block dropped
//   - `C.log`          → removed; verifier is silent by default
//   - `BM.isOpposite`  → inlined below
//   - `room.startGameOver(...)` call         → replaced with a terminal flag
//
// Everything else MUST match lib/physics-engine.js byte-for-byte so the
// verifier reproduces the server's recorded frames exactly.

const C = require('./constants');

function isOpposite(dir1, dir2) {
    return dir1.x === -dir2.x && dir1.y === -dir2.y;
}

function processTick(room) {
    // --- Competitive: Obstacle System ---
    if (room.type === 'competitive' && room.gameState === 'PLAYING') {
        room.obstacleTick++;

        for (const obs of room.obstacles) {
            if (!obs.solid && obs.blinkTimer > 0) {
                obs.blinkTimer--;
                if (obs.blinkTimer <= 0) {
                    obs.solid = true;
                }
            }
        }

        if (room.obstacleTick % 80 === 0) {
            spawnObstacle(room);
        }
    }

    // Auto-move for bots without ws connection (flood-fill AI).
    // In the verifier this branch is never taken: we replay the recorded
    // inputLog, which sets nextDirection before tick() runs.
    Object.values(room.players).forEach((p) => {
        if (!p.ws && p.alive) {
            floodFillMove(room, p);
        }
    });

    const foodCap = room.type === 'competitive'
        ? Math.max(0, Math.ceil(room.matchTimeLeft / 30) - 1)
        : C.MAX_FOOD;

    while (room.food.length > foodCap) {
        room.food.pop();
    }

    while (room.food.length < foodCap) {
        let tries = 0;
        let fx, fy;
        do {
            fx = Math.floor(room.rng() * C.CONFIG.gridSize);
            fy = Math.floor(room.rng() * C.CONFIG.gridSize);
            tries++;
            if (tries > 200) break;
        } while (room.isCellOccupied(fx, fy) || room.food.some(f => f.x === fx && f.y === fy) || (room.obstacles && room.obstacles.some(o => o.x === fx && o.y === fy)));

        if (tries <= 200) {
            room.food.push({ x: fx, y: fy });
        } else {
            break;
        }
    }

    // --- Movement & wall/food collision ---
    Object.values(room.players).forEach((p) => {
        if (!p.alive) return;

        p.hp -= 1;
        if (p.hp <= 0) {
            killPlayer(room, p, 'starvation');
            return;
        }

        p.direction = p.nextDirection;
        const head = p.body[0];
        const newHead = { x: head.x + p.direction.x, y: head.y + p.direction.y };

        if (
            newHead.x < 0 ||
            newHead.x >= C.CONFIG.gridSize ||
            newHead.y < 0 ||
            newHead.y >= C.CONFIG.gridSize
        ) {
            killPlayer(room, p, 'wall');
            return;
        }

        const foodIndex = room.food.findIndex((f) => f.x === newHead.x && f.y === newHead.y);
        if (foodIndex !== -1) {
            room.food.splice(foodIndex, 1);
            p.score++;
            p.hp = 100;
        } else {
            p.body.pop();
        }

        p.body.unshift(newHead);
    });

    // --- Self-collision, corpse collision, obstacle collision ---
    Object.values(room.players).forEach((p) => {
        if (!p.alive) return;
        const head = p.body[0];

        for (let i = 1; i < p.body.length; i++) {
            if (p.body[i].x === head.x && p.body[i].y === head.y) {
                killPlayer(room, p, 'self');
                return;
            }
        }

        Object.values(room.players).forEach((other) => {
            if (other.id === p.id || other.alive) return;
            if (other.deathType === 'eaten') return;

            for (const seg of other.body) {
                if (seg.x === head.x && seg.y === head.y) {
                    killPlayer(room, p, 'corpse');
                    return;
                }
            }
        });

        if (room.type === 'competitive' && p.alive) {
            for (const obs of room.obstacles) {
                if (obs.solid && obs.x === head.x && obs.y === head.y) {
                    killPlayer(room, p, 'obstacle');
                    break;
                }
            }
        }
    });

    // --- Head-to-head and body-eat collisions ---
    const alivePlayers = Object.values(room.players).filter((p) => p.alive);
    const processed = new Set();

    for (const p of alivePlayers) {
        if (!p.alive || processed.has(p.id)) continue;
        const pHead = p.body[0];

        for (const other of alivePlayers) {
            if (other.id === p.id || !other.alive || processed.has(other.id)) continue;
            const oHead = other.body[0];

            if (pHead.x === oHead.x && pHead.y === oHead.y) {
                if (p.body.length > other.body.length) {
                    killPlayer(room, other, 'eaten');
                    processed.add(other.id);
                } else if (other.body.length > p.body.length) {
                    killPlayer(room, p, 'eaten');
                    processed.add(p.id);
                } else {
                    killPlayer(room, p, 'headon');
                    killPlayer(room, other, 'headon');
                    processed.add(p.id);
                    processed.add(other.id);
                }
                continue;
            }

            for (let i = 1; i < other.body.length; i++) {
                if (other.body[i].x === pHead.x && other.body[i].y === pHead.y) {
                    if (p.body.length > other.body.length) {
                        const eaten = other.body.length - i;
                        other.body = other.body.slice(0, i);
                        const tail = p.body[p.body.length - 1];
                        for (let j = 0; j < eaten; j++) {
                            p.body.push({ ...tail });
                        }
                        p.score += eaten;
                        if (other.body.length < 1) {
                            killPlayer(room, other, 'eaten');
                            processed.add(other.id);
                        }
                    } else {
                        killPlayer(room, p, 'collision');
                        processed.add(p.id);
                    }
                    break;
                }
            }

            if (!p.alive || processed.has(p.id)) continue;
            for (let i = 1; i < p.body.length; i++) {
                if (p.body[i].x === oHead.x && p.body[i].y === oHead.y) {
                    if (other.body.length > p.body.length) {
                        const eaten = p.body.length - i;
                        p.body = p.body.slice(0, i);
                        const tail = other.body[other.body.length - 1];
                        for (let j = 0; j < eaten; j++) {
                            other.body.push({ ...tail });
                        }
                        other.score += eaten;
                        if (p.body.length < 1) {
                            killPlayer(room, p, 'eaten');
                            processed.add(p.id);
                        }
                    } else {
                        killPlayer(room, other, 'collision');
                        processed.add(other.id);
                    }
                    break;
                }
            }
        }
    }

    // --- Death blink timers ---
    Object.values(room.players).forEach((p) => {
        if (!p.alive && p.deathTimer !== undefined) {
            if (p.deathTimer > 0) p.deathTimer--;
            if (p.deathTimer <= 0) p.deathTimer = C.DEATH_BLINK_TURNS;
        }
    });

    // --- Victory / wipeout detection ---
    let aliveCount = 0;
    let lastSurvivor = null;
    Object.values(room.players).forEach((p) => {
        if (p.alive) {
            aliveCount++;
            lastSurvivor = p;
        }
    });

    // server-only: betting-lock TX omitted in verifier.

    const totalPlayers = Object.keys(room.players).length;
    if (totalPlayers > 1 && aliveCount === 1) {
        room.victoryPauseTimer = 24;
        room.lastSurvivorForVictory = lastSurvivor;
    } else if (totalPlayers > 1 && aliveCount === 0) {
        // server calls room.startGameOver(null, 'wipeout'); verifier just flags.
        room._terminal = 'wipeout';
    }
}

function floodFillMove(room, p) {
    const head = p.body[0];
    const G = C.CONFIG.gridSize;
    const dirs = [
        { x: 1, y: 0 }, { x: -1, y: 0 },
        { x: 0, y: 1 }, { x: 0, y: -1 }
    ];

    const grid = [];
    for (let y = 0; y < G; y++) {
        grid[y] = new Uint8Array(G);
    }
    Object.values(room.players).forEach(other => {
        if (!other.body) return;
        other.body.forEach((seg, idx) => {
            if (seg.x >= 0 && seg.x < G && seg.y >= 0 && seg.y < G) {
                if (other.alive && idx === other.body.length - 1) return;
                grid[seg.y][seg.x] = 1;
            }
        });
    });
    if (room.obstacles) {
        room.obstacles.forEach(obs => {
            if (obs.solid && obs.x >= 0 && obs.x < G && obs.y >= 0 && obs.y < G)
                grid[obs.y][obs.x] = 1;
        });
    }

    const enemyHeadDanger = new Set();
    Object.values(room.players).forEach(other => {
        if (other.id === p.id || !other.alive || !other.body || !other.body[0]) return;
        const oh = other.body[0];
        for (const d of dirs) {
            const ex = oh.x + d.x, ey = oh.y + d.y;
            if (ex >= 0 && ex < G && ey >= 0 && ey < G) {
                if (other.body.length >= p.body.length) {
                    enemyHeadDanger.add(ex + ',' + ey);
                }
            }
        }
    });

    const floodFill = (sx, sy) => {
        if (sx < 0 || sx >= G || sy < 0 || sy >= G || grid[sy][sx] === 1) return 0;
        const visited = [];
        for (let y = 0; y < G; y++) visited[y] = new Uint8Array(G);
        const queue = [{ x: sx, y: sy }];
        visited[sy][sx] = 1;
        let count = 0;
        while (queue.length > 0) {
            const cur = queue.shift();
            count++;
            for (const d of dirs) {
                const nx = cur.x + d.x, ny = cur.y + d.y;
                if (nx >= 0 && nx < G && ny >= 0 && ny < G && !visited[ny][nx] && grid[ny][nx] !== 1) {
                    visited[ny][nx] = 1;
                    queue.push({ x: nx, y: ny });
                }
            }
        }
        return count;
    };

    const candidates = dirs
        .filter(d => !isOpposite(d, p.direction))
        .map(d => {
            const nx = head.x + d.x;
            const ny = head.y + d.y;
            if (nx < 0 || nx >= G || ny < 0 || ny >= G) return null;
            if (grid[ny][nx] === 1) return null;

            let score = 0;

            const space = floodFill(nx, ny);
            if (space < p.body.length) score -= 10000;
            else if (space < p.body.length * 2) score -= 2000;
            score += space * 2;

            if (enemyHeadDanger.has(nx + ',' + ny)) score -= 5000;

            const foodWeight = p.body.length < 8 ? 8 : 3;
            let bestFoodDist = G * 2;
            for (const f of (room.food || [])) {
                const fd = Math.abs(nx - f.x) + Math.abs(ny - f.y);
                if (fd < bestFoodDist) bestFoodDist = fd;
            }
            score += (G * 2 - bestFoodDist) * foodWeight;

            const centerDist = Math.abs(nx - G / 2) + Math.abs(ny - G / 2);
            score -= centerDist * 0.3;

            if (nx === 0 || nx === G - 1) score -= 30;
            if (ny === 0 || ny === G - 1) score -= 30;

            return { d, score };
        })
        .filter(Boolean);

    if (candidates.length > 0) {
        candidates.sort((a, b) => b.score - a.score);
        p.nextDirection = candidates[0].d;
    } else {
        const any = dirs.filter(d => !isOpposite(d, p.direction));
        p.nextDirection = any.length > 0 ? any[Math.floor(room.rng() * any.length)] : p.direction;
    }
}

function killPlayer(room, p, deathType = 'default') {
    p.alive = false;
    p.deathTimer = C.DEATH_BLINK_TURNS;
    p.deathTime = 0; // server uses Date.now(); verifier uses 0 so it's deterministic
    p.deathType = deathType;
    p.deathSeq = ++room.deathSeq;

    if (deathType === 'eaten') {
        p.body = [p.body[0]];
    }

    if (room.type === 'competitive' && deathType !== 'eaten' && p.body && p.body.length > 0) {
        for (const seg of p.body) {
            room.obstacles.push({
                x: seg.x,
                y: seg.y,
                solid: true,
                blinkTimer: 0,
                fromCorpse: true,
            });
        }
        room.food = room.food.filter(f => !p.body.some(seg => seg.x === f.x && seg.y === f.y));
    }
}

function spawnObstacle(room) {
    const size = Math.floor(room.rng() * 16) + 1;
    const maxSize = Math.min(size, 12);

    let seedX, seedY, tries = 0;
    do {
        seedX = Math.floor(room.rng() * (C.CONFIG.gridSize - 4)) + 2;
        seedY = Math.floor(room.rng() * (C.CONFIG.gridSize - 4)) + 2;
        tries++;
    } while (tries < 50 && isCellBlocked(room, seedX, seedY));

    if (tries >= 50) return;

    const cells = [{ x: seedX, y: seedY }];
    const visited = new Set();
    visited.add(seedX + ',' + seedY);
    const queue = [{ x: seedX, y: seedY }];

    const dirs = [{ x: 1, y: 0 }, { x: -1, y: 0 }, { x: 0, y: 1 }, { x: 0, y: -1 }];

    while (cells.length < maxSize && queue.length > 0) {
        const idx = Math.floor(room.rng() * queue.length);
        const current = queue[idx];
        queue.splice(idx, 1);

        const shuffled = dirs.slice().sort(() => room.rng() - 0.5);

        for (const d of shuffled) {
            if (cells.length >= maxSize) break;
            const nx = current.x + d.x;
            const ny = current.y + d.y;
            const key = nx + ',' + ny;

            if (nx >= 1 && nx < C.CONFIG.gridSize - 1 && ny >= 1 && ny < C.CONFIG.gridSize - 1
                && !visited.has(key) && !isCellBlocked(room, nx, ny)) {
                visited.add(key);
                cells.push({ x: nx, y: ny });
                queue.push({ x: nx, y: ny });
            }
        }
    }

    for (const cell of cells) {
        room.obstacles.push({
            x: cell.x,
            y: cell.y,
            solid: false,
            blinkTimer: 16
        });
        room.food = room.food.filter(f => !(f.x === cell.x && f.y === cell.y));
    }
}

function isCellBlocked(room, x, y) {
    for (const obs of room.obstacles) {
        if (obs.x === x && obs.y === y) return true;
    }
    for (const p of Object.values(room.players)) {
        if (!p.body) continue;
        for (const seg of p.body) {
            if (seg.x === x && seg.y === y) return true;
        }
    }
    for (const f of room.food) {
        if (f.x === x && f.y === y) return true;
    }
    return false;
}

function clearSpawnZone(room) {
    const radius = 3;
    for (const sp of C.SPAWN_POINTS) {
        room.obstacles = room.obstacles.filter(o => {
            const dist = Math.abs(o.x - sp.x) + Math.abs(o.y - sp.y);
            return dist > radius;
        });
        room.food = room.food.filter(f => {
            const dist = Math.abs(f.x - sp.x) + Math.abs(f.y - sp.y);
            return dist > radius;
        });
    }
}

module.exports = {
    processTick,
    floodFillMove,
    killPlayer,
    spawnObstacle,
    clearSpawnZone,
    isCellBlocked,
    isOpposite,
};
