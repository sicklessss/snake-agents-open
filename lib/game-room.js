'use strict';

const C = require('./config');
const S = require('./state');
const { ethers } = require('ethers');
const Physics = require('./physics-engine');
const Replay = require('./replay-recorder');

class GameRoom {
    constructor({ id, type, letter }) {
        const P = require('./persistence');

        this.id = id;
        this.type = type; // performance | competitive
        this.letter = letter || null; // 'A'-'F' for performance, null for competitive
        this.maxPlayers = C.ROOM_MAX_PLAYERS[type] || 10;
        this.clients = new Set();

        // per-room state
        this.players = {};
        this.food = [];
        this.turn = 0;
        this.deathSeq = 0; // deterministic death ordering counter
        this.matchTimeLeft = C.MATCH_DURATION;
        this.waitingRoom = {};
        this.spawnIndex = 0;
        this.gameState = 'COUNTDOWN';
        this.winner = null;
        this.timerSeconds = 30;
        this.phaseEndsAt = Date.now() + (this.timerSeconds * 1000);
        this.matchEndsAt = null;
        this._countdownSpawnTriggered = false;
        this.currentMatchId = P.nextMatchId();
        this.displayMatchId = P.getNextDisplayId(type, letter);
        P.registerDisplayId(this.displayMatchId, this.currentMatchId);
        this.nextMatch = null; // { matchId, displayMatchId }
        this.futureMatches = []; // pre-created matches beyond nextMatch
        this.victoryPauseTimer = 0;
        this.lastSurvivorForVictory = null;
        this.replayFrames = []; // Record frames for replay

        // Competitive arena fields
        this.obstacles = [];          // { x, y, solid: bool, blinkTimer: int }
        this.obstacleTick = 0;        // Counts ticks for obstacle spawn timing
        this.matchNumber = 0;         // Total match count for this room
        this.paidEntries = (type === 'competitive' && S.savedPaidEntries) ? { ...S.savedPaidEntries } : {};

        this._colorIndex = 0;
        this._intervals = [];
        this._tickTimeout = null;
        this._secondInterval = null;
        this._lastNonPlayBroadcast = 0; // throttle non-PLAYING broadcasts

        this._ensurePredictionSlots();
        this.startLoops();
    }

    startLoops() {
        let nextTickAt = Date.now() + C.TICK_MS;
        const tickLoop = () => {
            // Emergency maintenance mode — freeze everything
            if (!S.maintenanceMode) {
                if (this.type === 'performance' && typeof S.performancePaused !== 'undefined' && S.performancePaused) {
                    // no-op
                } else if (this.gameState === 'PLAYING') {
                    let ticksRun = 0;
                    const maxCatchUpTicks = 4;
                    while (ticksRun < maxCatchUpTicks && Date.now() >= nextTickAt - C.TICK_MS) {
                        this.tick();
                        ticksRun++;
                        nextTickAt += C.TICK_MS;
                        if (Date.now() < nextTickAt) break;
                    }
                } else {
                    // Throttle non-PLAYING broadcasts to 2 FPS (500ms) to save bandwidth
                    const now = Date.now();
                    if (now - this._lastNonPlayBroadcast >= 500) {
                        this.broadcastState();
                        this._lastNonPlayBroadcast = now;
                    }
                    nextTickAt = Date.now() + C.TICK_MS;
                }
            }
            const delay = Math.max(0, nextTickAt - Date.now());
            this._tickTimeout = setTimeout(tickLoop, delay);
        };
        this._tickTimeout = setTimeout(tickLoop, C.TICK_MS);

        this._secondInterval = setInterval(() => {
            // Emergency maintenance mode — freeze timers too
            if (S.maintenanceMode) return;

            if (this.gameState === 'PLAYING') {
                if (this.matchEndsAt) {
                    this.matchTimeLeft = Math.max(0, Math.ceil((this.matchEndsAt - Date.now()) / 1000));
                }
                if (this.matchTimeLeft <= 0) {
                    this.endMatchByTime();
                }
            } else if (this.gameState !== 'PLAYING') {
                // Throttle _ensurePredictionSlots to once per 15s (not every 1s)
                const now = Date.now();
                if (!this._lastSlotCheck || now - this._lastSlotCheck > 15_000) {
                    this._lastSlotCheck = now;
                    this._ensurePredictionSlots();
                }
                if (this.phaseEndsAt) {
                    this.timerSeconds = Math.max(0, Math.ceil((this.phaseEndsAt - Date.now()) / 1000));
                }
                if (this.gameState === 'COUNTDOWN' && !this._countdownSpawnTriggered && this.timerSeconds <= 5) {
                    const RM = require('./room-manager');
                    RM.spawnPerformanceWorkers(this);
                    this._countdownSpawnTriggered = true;
                }
                if (this.timerSeconds > 0) {
                    return;
                }
                if (this.gameState === 'GAMEOVER') {
                    this.startCountdown();
                } else if (this.gameState === 'COUNTDOWN') {
                    this.startGame();
                } else {
                    this.timerSeconds = 0;
                }
            }
        }, 1000);
    }

    destroy() {
        this._intervals.forEach(id => clearInterval(id));
        this._intervals = [];
        if (this._tickTimeout) clearTimeout(this._tickTimeout);
        if (this._secondInterval) clearInterval(this._secondInterval);
        this._tickTimeout = null;
        this._secondInterval = null;
    }

    _ensureMatchCreated(entry, startTime, reason = 'scheduled') {
        if (!entry || entry.chainCreated || entry.chainCreateQueued || !S.pariMutuelContract) return;
        const targetMatchId = entry.matchId;
        const displayMatchId = entry.displayMatchId;
        const BC = require('./blockchain');
        // Dedup: skip if this matchId is already in the TX queue
        if (BC.isCreateMatchQueued(targetMatchId)) return;
        entry.chainCreateQueued = true;
        BC.enqueueTxPriority(`createMatch ${targetMatchId} (${reason})`, async (overrides) => {
            try {
                const existing = await S.pariMutuelContract.matches(targetMatchId);
                const existingId = Number(existing.matchId || existing[0] || 0);
                if (existingId !== 0) {
                    entry.chainCreated = true;
                    entry.chainCreateQueued = false;
                    C.log.info(`[Blockchain] createMatch #${targetMatchId} (${reason}) already exists, skipping`);
                    // Auto-bind displayMatch so prediction executor doesn't need to
                    this._autoBindDisplayMatch(displayMatchId, targetMatchId);
                    return;
                }
            } catch (_) {}
            try {
                const tx = await S.pariMutuelContract.createMatch(targetMatchId, startTime, overrides);
                // Don't await tx.wait() — let the queue move on immediately.
                // Confirmation is detected by the executor's on-chain check or event polling.
                C.log.important(`[Blockchain] createMatch #${targetMatchId} (${reason}, startTime=${startTime}) sent tx=${tx.hash.slice(0,14)}`);
                // Wait for confirmation in background, then set chainCreated + auto-bind
                tx.wait(1, 60000).then(() => {
                    entry.chainCreated = true;
                    entry.chainCreateQueued = false;
                    C.log.important(`[Blockchain] createMatch #${targetMatchId} (${reason}) confirmed`);
                    this._autoBindDisplayMatch(displayMatchId, targetMatchId);
                }).catch((e) => {
                    entry.chainCreateQueued = false;
                    C.log.warn(`[Blockchain] createMatch #${targetMatchId} (${reason}) wait failed: ${e.message}`);
                });
            } catch (e) {
                entry.chainCreateQueued = false;
                throw e; // re-throw for queue retry logic
            }
        });
    }

    _autoBindDisplayMatch(displayMatchId, matchId) {
        // Disabled: auto-bind was causing nonce collisions with the executor's
        // bind+execute TX on the same settlementWallet. The executor already
        // handles binding as part of its serial queue, so auto-bind is redundant.
        // Keeping the method stub so callers don't need to be updated.
    }

    _estimateFutureSlotStartTime(slotIndex) {
        const now = Math.floor(Date.now() / 1000);
        const cycleSeconds = C.MATCH_DURATION + 60; // GAMEOVER 30s + COUNTDOWN 30s
        let untilNextStart;

        if (this.gameState === 'COUNTDOWN') {
            untilNextStart = Math.max(0, this.timerSeconds) + cycleSeconds;
        } else if (this.gameState === 'PLAYING') {
            untilNextStart = Math.max(0, this.matchTimeLeft) + 60;
        } else if (this.gameState === 'GAMEOVER') {
            untilNextStart = Math.max(0, this.timerSeconds) + 30 + C.MATCH_DURATION + 60;
        } else {
            untilNextStart = cycleSeconds;
        }

        return now + untilNextStart + Math.max(0, slotIndex - 1) * cycleSeconds;
    }

    _ensurePredictionSlots() {
        const P = require('./persistence');

        const TARGET_VISIBLE_FUTURE = 3; // nextMatch + 2 futureMatches = 4 visible slots including current
        const existing = (this.nextMatch ? 1 : 0) + this.futureMatches.length;
        const toAdd = Math.max(0, TARGET_VISIBLE_FUTURE - existing);

        for (let i = 0; i < toAdd; i++) {
            const mid = P.nextMatchId();
            const dispId = P.getNextDisplayId(this.type, this.letter);
            P.registerDisplayId(dispId, mid);
            const entry = { matchId: mid, displayMatchId: dispId, chainCreated: false };
            if (!this.nextMatch) this.nextMatch = entry;
            else this.futureMatches.push(entry);
            C.log.important(`[Room ${this.id}] Reserved prediction slot #${mid} (${dispId})`);
        }

        if (!S.pariMutuelContract) return;

        const queueLen = S._txQueue.length;
        if (queueLen > 20) {
            C.log.warn(`[PredictionSlots] TX queue backlog: ${queueLen} items`);
        }
        // Always pre-create at least 1 slot so prediction intents can execute;
        // only throttle the 2nd slot when queue is heavily backed up.
        const onChainSlots = queueLen > 50 ? 1 : 2;
        const entries = [this.nextMatch, ...this.futureMatches].filter(Boolean);

        entries.forEach((entry, idx) => {
            if (idx >= onChainSlots || entry.chainCreated) return;
            const startTime = this._estimateFutureSlotStartTime(idx + 1);
            this._ensureMatchCreated(entry, startTime, `prediction-slot-${idx + 1}`);
        });
    }

    sendEvent(type, payload = {}) {
        const msg = JSON.stringify({ type, ...payload });
        this.clients.forEach((c) => {
            if (c.readyState === 1) c.send(msg);
        });
    }

    getSpawnPosition() {
        // Collect occupied spawn positions
        const occupied = new Set();
        Object.values(this.players).forEach(p => {
            if (p.body && p.body[0]) {
                // Check if any spawn point is too close to this player's head
                C.SPAWN_POINTS.forEach((sp, idx) => {
                    const dist = Math.abs(sp.x - p.body[0].x) + Math.abs(sp.y - p.body[0].y);
                    if (dist < 5) occupied.add(idx);
                });
            }
        });

        // Get available spawn points
        const available = C.SPAWN_POINTS.map((sp, idx) => idx).filter(idx => !occupied.has(idx));

        // Random selection from available, or fallback to any random
        let spawnIdx;
        if (available.length > 0) {
            spawnIdx = available[Math.floor(Math.random() * available.length)];
        } else {
            spawnIdx = Math.floor(Math.random() * C.SPAWN_POINTS.length);
        }

        const spawn = C.SPAWN_POINTS[spawnIdx];
        const body = [
            { x: spawn.x, y: spawn.y },
            { x: spawn.x - spawn.dir.x, y: spawn.y - spawn.dir.y },
            { x: spawn.x - spawn.dir.x * 2, y: spawn.y - spawn.dir.y * 2 },
        ];
        return { body, direction: spawn.dir };
    }

    isCellOccupied(x, y) {
        for (const p of Object.values(this.players)) {
            for (const seg of p.body || []) {
                if (seg.x === x && seg.y === y) return true;
            }
        }
        return false;
    }

    tick() {
        if (this.victoryPauseTimer > 0) {
            this.victoryPauseTimer--;
            this.broadcastState();
            if (this.victoryPauseTimer <= 0) {
                this.startGameOver(this.lastSurvivorForVictory);
            }
            return;
        }

        this.turn++;
        Physics.processTick(this);
        this.broadcastState();
    }

    endMatchByTime() {
        let longest = null;
        let maxLen = 0;

        Object.values(this.players).forEach((p) => {
            if (p.alive && p.body.length > maxLen) {
                maxLen = p.body.length;
                longest = p;
            }
        });

        this.startGameOver(longest, 'timeout');
    }

    killPlayer(p, deathType = 'default') {
        Physics.killPlayer(this, p, deathType);
    }

    _isRegisteredBot(botId) {
        return !!(botId && S.botRegistry[botId] && S.botRegistry[botId].unlimited && !S.botRegistry[botId].regCode);
    }

    _buildPlacementEntry(player, place, aliveAtEnd = false) {
        return {
            place,
            playerId: player.id,
            botId: this._isRegisteredBot(player.botId) ? player.botId : null,
            name: player.name,
            aliveAtEnd,
        };
    }

    _computePlacements({ survivor = null, reason = 'last_survivor' } = {}) {
        const allPlayers = Object.values(this.players);
        if (reason === 'wipeout') return [];

        const placements = [];
        const seen = new Set();
        const pushPlayer = (player, aliveAtEnd = false) => {
            if (!player || seen.has(player.id)) return;
            seen.add(player.id);
            placements.push(this._buildPlacementEntry(player, placements.length + 1, aliveAtEnd));
        };

        if (reason === 'timeout') {
            const alive = allPlayers
                .filter(p => p.alive)
                .sort((a, b) => {
                    const lenDiff = (b.body?.length || 0) - (a.body?.length || 0);
                    if (lenDiff !== 0) return lenDiff;
                    const scoreDiff = (b.score || 0) - (a.score || 0);
                    if (scoreDiff !== 0) return scoreDiff;
                    const hpDiff = (b.hp || 0) - (a.hp || 0);
                    if (hpDiff !== 0) return hpDiff;
                    return String(a.id).localeCompare(String(b.id));
                });
            const dead = allPlayers
                .filter(p => !p.alive && p.deathSeq)
                .sort((a, b) => b.deathSeq - a.deathSeq);
            alive.forEach(p => pushPlayer(p, true));
            dead.forEach(p => pushPlayer(p, false));
            return placements;
        }

        if (survivor && survivor.alive) pushPlayer(survivor, true);
        allPlayers
            .filter(p => !p.alive && p.deathSeq)
            .sort((a, b) => b.deathSeq - a.deathSeq)
            .forEach(p => pushPlayer(p, false));
        return placements;
    }

    startGameOver(survivor, reason = 'last_survivor') {
        const P = require('./persistence');
        const BC = require('./blockchain');
        const BM = require('./bot-manager');

        this.gameState = 'GAMEOVER';
        this.winner = survivor ? survivor.name : 'No Winner';
        this.timerSeconds = 30;
        this.phaseEndsAt = Date.now() + 30_000;
        this.matchEndsAt = null;
        this._countdownSpawnTriggered = false;
        const participants = Object.values(this.players)
            .filter(p => p.botId && !p.id.startsWith('normal_'))
            .map(p => p.name);
        P.saveHistory(this.id, this.winner, survivor ? survivor.score : 0, null, participants);

        // Save replay
        Replay.saveReplay(this, survivor);

        const placementDetails = this._computePlacements({ survivor, reason });
        const topThreePlacements = placementDetails.slice(0, 3);
        const settlementWinnerBotIds = topThreePlacements
            .filter(p => p.botId)
            .map(p => p.botId);
        // Debug: log placements to diagnose no_registered_winners
        C.log.important(`[Settlement] ${this.type} match #${this.currentMatchId} top3: ${topThreePlacements.map(p => `${p.name}(botId=${p.botId},id=${p.playerId})`).join(', ')} → winners: [${settlementWinnerBotIds.join(',')||'none'}]`);
        const scorePlacementEntries = topThreePlacements.filter((p) =>
            p.botId && p.place >= 1 && p.place <= C.MATCH_PLACE_REWARDS.length
        );

        this.sendEvent('match_end', {
            matchId: this.currentMatchId,
            winnerBotId: survivor && this._isRegisteredBot(survivor.botId) ? survivor.botId : null,
            winnerName: this.winner,
            arenaId: this.id,
            arenaType: this.type,
            placements: settlementWinnerBotIds,
            placementDetails,
        });

        // Create the NEXT on-chain match only after the current match is finished.
        // This keeps on-chain startTime close to the real next start and avoids long
        // settlement defers caused by over-eager future pre-creation.
        if (this.nextMatch && !this.nextMatch.chainCreated && S.pariMutuelContract) {
            const startTime = Math.floor(Date.now() / 1000) + 60; // 30s GAMEOVER + 30s COUNTDOWN
            this._ensureMatchCreated(this.nextMatch, startTime, 'next-after-gameover');
        }

        // Settle or cancel match on-chain (PariMutuel USDC contract) — fire-and-forget
        if (S.pariMutuelContract) {
            const onChainMatchId = this.currentMatchId;

            if (settlementWinnerBotIds.length > 0) {
                // --- Settle with winners ---
                const winnerBytes32Array = settlementWinnerBotIds.map(botId => ethers.encodeBytes32String(botId));

                // Persist to disk BEFORE attempting settle (survives server restart)
                S.pendingSettlements.push({
                    matchId: onChainMatchId,
                    winnerBotIds: settlementWinnerBotIds,
                    winnerNames: topThreePlacements.map(p => p.name),
                    createdAt: Date.now()
                });
                P.savePendingSettlements();

                // Wait for match to exist on-chain (created by main queue),
                // then enqueue the actual settle TX. Checks are done OUTSIDE
                // the queue to avoid wasting nonce/gas RPC calls on deferred reads.
                let settleDefers = 0;
                const _waitAndSettle = async () => {
                    try {
                        const matchData = await S.pariMutuelSettleContract.matches(onChainMatchId);
                        const matchId = Number(matchData.matchId || matchData[0] || 0);
                        if (matchId === 0) {
                            settleDefers++;
                            // Wait up to 30 min (main queue may be heavily backed up)
                            if (settleDefers > 360) {
                                C.log.warn(`[Blockchain] settleMatch #${onChainMatchId}: match never appeared on-chain after 30 min, giving up`);
                                S.pendingSettlements = S.pendingSettlements.filter(s => s.matchId !== onChainMatchId);
                                P.savePendingSettlements();
                                return;
                            }
                            // Increasing interval: 5s for first 12, then 10s, then 30s
                            const delay = settleDefers <= 12 ? 5000 : settleDefers <= 36 ? 10000 : 30000;
                            if (settleDefers % 12 === 0) C.log.info(`[Blockchain] settleMatch #${onChainMatchId}: not on-chain yet, waiting... (${settleDefers} checks, queue=${S._txQueue.length})`);
                            setTimeout(_waitAndSettle, delay);
                            return;
                        }
                        const startTime = Number(matchData.startTime || matchData[1] || 0);
                        const now = Math.floor(Date.now() / 1000);
                        if (startTime > now) {
                            const waitSec = startTime - now + 2;
                            C.log.info(`[Blockchain] settleMatch #${onChainMatchId}: deferring ${waitSec}s for startTime`);
                            setTimeout(_waitAndSettle, waitSec * 1000);
                            return;
                        }
                    } catch (e) {
                        C.log.warn(`[Blockchain] settleMatch #${onChainMatchId}: match query failed (${e.message}), attempting settle anyway`);
                    }
                    // Match is on-chain and startTime has passed — enqueue actual TX
                    BC.enqueueSettleTx(`settleMatch ${onChainMatchId}`, async (overrides) => {
                        const tx = await S.pariMutuelSettleContract.settleMatch(onChainMatchId, winnerBytes32Array, overrides);
                        // Don't await tx.wait() inside the queue — let queue move to next TX immediately.
                        // Confirmation is verified in background.
                        tx.wait(1, 120000).then(async (receipt) => {
                            if (receipt.status !== 1) {
                                C.log.error(`[Blockchain] settleMatch #${onChainMatchId} TX reverted (status=${receipt.status})`);
                                return;
                            }
                            // Double-check on-chain
                            try {
                                const matchCheck = await S.pariMutuelSettleContract.matches(onChainMatchId);
                                const settled = matchCheck.settled || matchCheck[5] || false;
                                if (!settled) {
                                    C.log.error(`[Blockchain] settleMatch #${onChainMatchId} receipt OK but not settled on-chain — will retry`);
                                    // Re-enqueue
                                    _waitAndSettle();
                                    return;
                                }
                            } catch (_) {}
                            C.log.important(`[Blockchain] settleMatch #${onChainMatchId} settled with ${settlementWinnerBotIds.length} winner(s): ${settlementWinnerBotIds.join(', ')}`);
                            S.pendingSettlements = S.pendingSettlements.filter(s => s.matchId !== onChainMatchId);
                            P.savePendingSettlements();
                            S.settledOnChainMatchIds.push(onChainMatchId);
                            if (S.settledOnChainMatchIds.length > 500) S.settledOnChainMatchIds.shift();
                            P.saveSettledIds();
                        }).catch(e => {
                            C.log.error(`[Blockchain] settleMatch #${onChainMatchId} TX wait failed: ${e.message} — will retry`);
                            _waitAndSettle();
                        });
                    });
                };
                _waitAndSettle();
            } else {
                // --- No registered bot winners — cancel only if there are bets to refund ---
                BC.enqueueSettleTx(`cancelMatch ${onChainMatchId}`, async (overrides) => {
                    try {
                        const matchData = await S.pariMutuelSettleContract.matches(onChainMatchId);
                        const matchId = Number(matchData.matchId || matchData[0] || 0);
                        if (matchId === 0) {
                            C.log.debug(`[Blockchain] cancelMatch #${onChainMatchId}: not on-chain, skipping`);
                            return;
                        }
                        const settled = matchData.settled || matchData[5] || false;
                        const cancelled = matchData.cancelled || matchData[6] || false;
                        if (settled || cancelled) {
                            C.log.debug(`[Blockchain] cancelMatch #${onChainMatchId}: already settled/cancelled, skipping`);
                            return;
                        }
                        // Skip cancel if no bets — saves gas and avoids nonce congestion
                        const totalPool = BigInt(matchData.totalPool || matchData[3] || 0);
                        if (totalPool === 0n) {
                            C.log.debug(`[Blockchain] cancelMatch #${onChainMatchId}: no bets, skipping cancel`);
                            return;
                        }
                    } catch (e) {
                        C.log.warn(`[Blockchain] cancelMatch #${onChainMatchId}: match query failed (${e.message}), attempting cancel anyway`);
                    }
                    const tx = await S.pariMutuelSettleContract.cancelMatch(onChainMatchId, 'no_registered_winners', overrides);
                    await tx.wait(1, 60000);
                    C.log.important(`[Blockchain] cancelMatch #${onChainMatchId} cancelled (no registered bot winners)`);
                    S.settledOnChainMatchIds.push(onChainMatchId);
                    if (S.settledOnChainMatchIds.length > 500) S.settledOnChainMatchIds.shift();
                    P.saveSettledIds();
                });
            }
        }

        // --- Score: match participation & placements ---
        const matchId = this.currentMatchId;
        const arenaType = this.type;
        const allPlayers = Object.values(this.players);
        const allBotsInMatch = allPlayers.filter(p => p.botId);
        const ownersAwarded = new Set();
        for (const p of allBotsInMatch) {
            const ownerAddr = S.botRegistry[p.botId]?.owner;
            if (!ownerAddr || ownerAddr === 'unknown' || ownersAwarded.has(ownerAddr)) continue;
            ownersAwarded.add(ownerAddr);
            P.awardScore(ownerAddr, 'match_participate', C.MATCH_PARTICIPATE_POINTS, { matchId, botId: p.botId });
        }

        // Placement rewards (only performance/competitive)
        if (arenaType === 'performance' || arenaType === 'competitive') {
            for (const entry of scorePlacementEntries) {
                const botId = entry.botId;
                const ownerAddr = S.botRegistry[botId]?.owner;
                if (!ownerAddr || ownerAddr === 'unknown') continue;
                P.awardScore(ownerAddr, 'match_place', C.MATCH_PLACE_REWARDS[entry.place - 1], {
                    matchId,
                    botId,
                    place: entry.place,
                });
            }
        }

        // Release performance workers during inter-match interval
        if (this.type === 'performance') {
            for (const p of Object.values(this.players)) {
                if (p.botType === 'agent' && p.botId && S.activeWorkers.has(p.botId)) {
                    BM.stopBotWorker(p.botId, false); // false = keep running flag
                }
            }
        }
    }

    startCountdown() {
        const P = require('./persistence');
        const BC = require('./blockchain');
        const RM = require('./room-manager');

        this.gameState = 'COUNTDOWN';
        this.timerSeconds = 30;
        this.phaseEndsAt = Date.now() + 30_000;
        this.matchEndsAt = null;
        this._countdownSpawnTriggered = false;
        this.food = [];
        this.spawnIndex = 0;
        this._colorIndex = 0; // Reset colors each match for max contrast
        this.deathSeq = 0; // Reset death sequence counter

        // Clear obstacles for competitive
        if (this.type === 'competitive') {
            this.obstacles = [];
            this.obstacleTick = 0;
            this.matchNumber++;
            S.competitiveLaunchFailed.clear();
        }

        // Preserve queued bots and re-queue current players for next match
        const preserved = this.waitingRoom || {};
        Object.values(this.players).forEach((p) => {
            if (p.kicked) return;
            preserved[p.id] = {
                id: p.id,
                name: p.name,
                color: p.color,
                ws: p.ws,
                botType: p.botType,
                botId: p.botId || null,
                botPrice: 0,
                entryPrice: p.entryPrice || 0,
            };
        });
        this.waitingRoom = preserved;

        // Performance agents: worker was stopped at game-over, restart them for next match
        if (this.type === 'performance') {
            const BM = require('./bot-manager');
            for (const [id, w] of Object.entries(this.waitingRoom)) {
                if (w.botType === 'agent' && w.botId) {
                    delete this.waitingRoom[id]; // remove stale entry, worker will re-join via WS
                    if (!S.activeWorkers.has(w.botId)) {
                        BM.startBotWorker(w.botId, this.id);
                    }
                }
            }
        }

        // For competitive rooms: remove ws:null agent entries so autoFill can retry with real workers
        if (this.type === 'competitive') {
            for (const [id, w] of Object.entries(this.waitingRoom)) {
                if (w.botType === 'agent' && !w.ws) {
                    delete this.waitingRoom[id];
                }
            }
        }

        // Remove exhausted trial bots (credits already deducted in handleJoin)
        if (this.type === 'performance') {
            for (const [id, w] of Object.entries(this.waitingRoom)) {
                if (w.botType === 'agent' && w.botId) {
                    const meta = S.botRegistry[w.botId];
                    if (meta && !meta.unlimited && meta.credits <= 0) {
                        meta.credits = 0;
                        meta.running = false;
                        delete this.waitingRoom[id];
                        C.log.important(`[Credits] ${w.name} (${w.botId}) trial exhausted, stopped & removed from ${this.id}`);
                        if (w.ws && w.ws.readyState === 1) {
                            w.ws.send(JSON.stringify({ type: 'credits', remaining: 0, exhausted: true }));
                        }
                    }
                }
            }
            P.saveBotRegistry();
            // Backfill after removing exhausted bots
            RM.backfillRoom(this);
        }

        // Enforce maxPlayers cap on next match.
        const cap = this.maxPlayers;
        const allIds = Object.keys(this.waitingRoom);
        if (allIds.length > cap) {
            let overflow = allIds.length - cap;
            const normals = allIds.filter(id => this.waitingRoom[id].botType === 'normal');
            while (overflow > 0 && normals.length > 0) {
                const victimId = normals.pop();
                delete this.waitingRoom[victimId];
                overflow--;
            }
            const remaining = Object.keys(this.waitingRoom);
            while (overflow > 0 && remaining.length > 0) {
                const victimId = remaining.pop();
                delete this.waitingRoom[victimId];
                overflow--;
            }
        }

        this.players = {};
        // Consume pre-created nextMatch if available
        if (this.nextMatch) {
            this.currentMatchId = this.nextMatch.matchId;
            this.displayMatchId = this.nextMatch.displayMatchId;
            const wasChainCreated = this.nextMatch.chainCreated;
            C.log.important(`[Room ${this.id}] Using pre-created match #${this.currentMatchId} (${this.displayMatchId}), chainCreated=${wasChainCreated}`);
            // If chain creation failed earlier, retry now before match starts
            if (!wasChainCreated && S.pariMutuelContract) {
                const startTime = Math.floor(Date.now() / 1000) + 5;
                this._ensureMatchCreated(this.nextMatch, startTime, 'retry');
            }
        } else {
            // Fallback: create immediately
            this.currentMatchId = P.nextMatchId();
            this.displayMatchId = P.getNextDisplayId(this.type, this.letter);
            P.registerDisplayId(this.displayMatchId, this.currentMatchId);
            // Create match on-chain
            if (S.pariMutuelContract) {
                const startTime = Math.floor(Date.now() / 1000) + 5;
                this._ensureMatchCreated({ matchId: this.currentMatchId, displayMatchId: this.displayMatchId, chainCreated: false }, startTime, 'fallback');
            }
        }
        // Promote: shift futureMatches[0] → nextMatch
        if (this.futureMatches.length > 0) {
            this.nextMatch = this.futureMatches.shift();
            C.log.important(`[Room ${this.id}] Promoted futureMatch → nextMatch #${this.nextMatch.matchId} (${this.nextMatch.displayMatchId}), ${this.futureMatches.length} remaining in queue`);
        } else {
            this.nextMatch = null;
        }
        this._ensurePredictionSlots();
        this.lastSurvivorForVictory = null;
        this.matchTimeLeft = C.MATCH_DURATION;
        this._colorIndex = 0;

        // Competitive: re-seed with normal bots if room is empty/low
        if (this.type === 'competitive') {
            const currentCount = Object.keys(this.waitingRoom).length;
            if (currentCount < this.maxPlayers) {
                const needed = this.maxPlayers - currentCount;
                for (let i = 0; i < needed; i++) {
                    const id = 'normal_' + C.randomId();
                    this.waitingRoom[id] = {
                        id,
                        name: C.getDefaultNormalBotName(id),
                        color: C.getNextColor(this),
                        ws: null,
                        botType: 'normal',
                        botId: null,
                        botPrice: 0,
                    };
                }
            }
            // Reassign colors every round so stale preserved filler colors do not
            // collapse into a wall of red across competitive matches.
            this._colorIndex = 0;
            const priority = { hero: 0, agent: 1, normal: 2 };
            const waitingEntries = Object.entries(this.waitingRoom).sort(([, a], [, b]) => {
                const pa = priority[a.botType] ?? 9;
                const pb = priority[b.botType] ?? 9;
                if (pa !== pb) return pa - pb;
                return String(a.name || a.id).localeCompare(String(b.name || b.id));
            });
            for (const [, waiting] of waitingEntries) {
                waiting.color = C.getNextColor(this);
            }
        }
    }

    startGame() {
        const P = require('./persistence');
        const BC = require('./blockchain');
        const RM = require('./room-manager');

        this.spawnIndex = 0;
        this._bettingLockSent = false; // Reset betting lock flag for new match

        // Performance rooms should always start with a full 10-player grid.
        // Backfill agents first, then top up the remaining seats with normals.
        if (this.type === 'performance') {
            RM.backfillRoom(this);
            const missing = this.maxPlayers - Object.keys(this.waitingRoom).length;
            if (missing > 0) {
                RM.seedNormalBots(this, missing);
            }
        }

        // Competitive rooms must never start empty. If paid/agent entries did
        // not materialize in time, fall back to normal bots so the arena stays
        // visually alive and the room state remains coherent.
        if (this.type === 'competitive') {
            const missing = this.maxPlayers - Object.keys(this.waitingRoom).length;
            if (missing > 0) {
                RM.seedNormalBots(this, missing);
            }
        }

        C.log.important(`[Room ${this.id}] Starting match with ${Object.keys(this.waitingRoom).length} players`);

        const usedSpawnIndices = new Set();

        Object.keys(this.waitingRoom).forEach((id) => {
            const w = this.waitingRoom[id];

            // Get available spawn points (not close to existing players AND not used in this startGame batch)
            const occupied = new Set();
            Object.values(this.players).forEach(p => {
                if (p.body && p.body[0]) {
                    C.SPAWN_POINTS.forEach((sp, idx) => {
                        const dist = Math.abs(sp.x - p.body[0].x) + Math.abs(sp.y - p.body[0].y);
                        if (dist < 5) occupied.add(idx);
                    });
                }
            });

            let spawnIdx = -1;
            const available = C.SPAWN_POINTS.map((_, i) => i).filter(i => !occupied.has(i) && !usedSpawnIndices.has(i));

            if (available.length > 0) {
                spawnIdx = available[Math.floor(Math.random() * available.length)];
            } else {
                // Fallback to any not used in this batch
                const notUsedInBatch = C.SPAWN_POINTS.map((_, i) => i).filter(i => !usedSpawnIndices.has(i));
                spawnIdx = notUsedInBatch.length > 0 ? notUsedInBatch[0] : Math.floor(Math.random() * C.SPAWN_POINTS.length);
            }

            usedSpawnIndices.add(spawnIdx);
            const spawn = C.SPAWN_POINTS[spawnIdx];
            const body = [
                { x: spawn.x, y: spawn.y },
                { x: spawn.x - spawn.dir.x, y: spawn.y - spawn.dir.y },
                { x: spawn.x - spawn.dir.x * 2, y: spawn.y - spawn.dir.y * 2 },
            ];

            C.log.info(`[Spawn] Player "${w.name}" (${id}) at (${spawn.x}, ${spawn.y})`);

            this.players[id] = {
                id: id,
                name: w.name,
                color: w.color,
                body: body,
                direction: spawn.dir,
                nextDirection: spawn.dir,
                alive: true,
                score: 0,
                hp: 100,
                ws: w.ws,
                botType: w.botType,
                botId: w.botId || id,
                entryPrice: w.entryPrice || 0,
            };
            if (w.ws && w.ws.readyState === 1) {
                w.ws.send(JSON.stringify({ type: 'init', id: id, botId: w.botId || id, gridSize: C.CONFIG.gridSize }));
            }
        });

        this.waitingRoom = {};
        this.gameState = 'PLAYING';
        this.turn = 0;
        this.timerSeconds = 0;
        this.matchTimeLeft = C.MATCH_DURATION;
        this.phaseEndsAt = null;
        this.matchEndsAt = Date.now() + (C.MATCH_DURATION * 1000);
        this._countdownSpawnTriggered = false;
        if (!this._bettingLockSent && S.pariMutuelContract) {
            this._bettingLockSent = true;
            const matchId = this.currentMatchId;
            // Delay lockBetting by 5s to give prediction executor time to
            // complete bind + execute TXs before betting is locked on-chain.
            // The first 5s of a 180s match have no meaningful results yet.
            setTimeout(() => {
                BC.enqueueLifecycleTx(`lockBetting ${matchId}`, async (overrides) => {
                    const tx = await S.pariMutuelContract.lockBetting(matchId, overrides);
                    await tx.wait(1, 60000);
                    C.log.info(`[PariMutuel] lockBetting #${matchId} confirmed`);
                });
            }, 5000);
        }
        this.sendEvent('match_start', { matchId: this.currentMatchId, arenaId: this.id, arenaType: this.type });
    }

    broadcastState() {
        const displayPlayers = Object.values(this.players).map((p) => ({
            id: p.id,
            name: p.name,
            color: p.color,
            body: p.body,
            head: p.body && p.body.length > 0 ? p.body[0] : null,
            direction: p.direction,
            score: p.score,
            hp: p.hp,
            alive: p.alive,
            blinking: !p.alive && p.deathTimer > 0,
            deathTimer: p.deathTimer,
            deathType: p.deathType,
            length: p.body.length,
            botType: p.botType,
            botId: p.botId || p.id,
        }));

        const waitingPlayers = Object.values(this.waitingRoom).map((w) => ({
            id: w.id,
            name: w.name,
            color: w.color,
            body: null,
            head: null,
            score: 0,
            alive: true,
            waiting: true,
            botType: w.botType,
            botId: w.botId || w.id,
        }));

        // Betting is open only before the match starts.
        const bettingOpen = !S.bettingDisabled && this.gameState === 'COUNTDOWN';

        const phaseTimeLeft = this.gameState === 'PLAYING'
            ? this.matchTimeLeft
            : this.timerSeconds;

        const state = {
            matchId: this.currentMatchId,
            arenaId: this.id,
            arenaType: this.type,
            gridSize: C.CONFIG.gridSize,
            turn: this.turn,
            gameState: this.gameState,
            winner: this.winner,
            timeLeft: phaseTimeLeft,
            matchTimeLeft: this.matchTimeLeft,
            players: displayPlayers,
            waitingPlayers: waitingPlayers,
            food: this.food,
            obstacles: this.type === 'competitive' ? this.obstacles : [],
            matchNumber: this.matchNumber || 1,
            displayMatchId: this.displayMatchId,
            nextMatch: this.nextMatch ? {
                matchId: this.nextMatch.matchId,
                displayMatchId: this.nextMatch.displayMatchId,
                chainCreated: this.nextMatch.chainCreated || false,
            } : null,
            futureMatches: this.futureMatches.map(m => ({
                matchId: m.matchId,
                displayMatchId: m.displayMatchId,
                chainCreated: m.chainCreated || false,
            })),
            epoch: C.getCurrentEpoch(),
            victoryPause: this.victoryPauseTimer > 0,
            victoryPauseTime: Math.ceil(this.victoryPauseTimer / 8),
            bettingOpen,
            serverNow: Date.now(),
            phaseEndsAt: this.phaseEndsAt,
            matchEndsAt: this.matchEndsAt,
        };

        // Record frame for replay (only during PLAYING)
        Replay.recordFrame(this, displayPlayers);

        const msg = JSON.stringify({ type: 'update', state });
        this.clients.forEach((c) => {
            if (c.readyState === 1) c.send(msg);
        });
    }

    hasSpace() {
        return Object.keys(this.waitingRoom).length < this.maxPlayers;
    }

    capacityRemaining() {
        const playing = Object.keys(this.players).length;
        const waiting = Object.keys(this.waitingRoom).length;
        return this.maxPlayers - playing - waiting;
    }

    findKickableNormal() {
        const ids = Object.keys(this.waitingRoom).filter((id) => this.waitingRoom[id].botType === 'normal');
        if (ids.length === 0) return null;
        const victimId = ids[Math.floor(Math.random() * ids.length)];
        return victimId || null;
    }

    findKickableOldAgent() {
        const ids = Object.keys(this.waitingRoom);
        // Prefer kicking low-price/old agents (<=0.01)
        const victimId = ids.find((id) => this.waitingRoom[id].botType === 'agent' && (this.waitingRoom[id].botPrice || 0) <= 0.01);
        return victimId || null;
    }

    handleJoin(data, ws) {
        const P = require('./persistence');
        const RM = require('./room-manager');

        let name = C.clampNameBytes((data.name || 'Bot').toString().replace(/[<>&"']/g, ''));
        const isHero = name && name.includes('HERO');
        if (data.botId && String(data.botId).length > C.MAX_BOT_ID_LEN) {
            return { ok: false, reason: 'invalid_bot_id' };
        }
        let botType = data.botType || (isHero ? 'hero' : 'normal');
        const botMeta = data.botId && S.botRegistry[data.botId] ? S.botRegistry[data.botId] : null;
        if (botMeta) {
            name = botMeta.name || name;
            botType = botMeta.botType || botType;
        }

        if (this.type === 'performance' && botType === 'agent' && botMeta && !botMeta.unlimited) {
            botMeta.credits -= 1;
            if (botMeta.credits < 0) { botMeta.credits += 1; botMeta.running = false; P.saveBotRegistry(); return { ok: false, reason: 'trial_exhausted', message: 'Trial plays used up. Register your bot (mint NFT) for unlimited plays.' }; }
            P.saveBotRegistry();
            if (ws && ws.readyState === 1) {
                ws.send(JSON.stringify({ type: 'credits', remaining: botMeta.credits }));
            }
        }

        // If an agent worker is connecting and a ws:null placeholder exists, replace it
        if (data.botId && ws) {
            for (const [existingId, w] of Object.entries(this.waitingRoom)) {
                if (w.botId === data.botId && !w.ws) {
                    w.ws = ws;
                    w.name = name;
                    ws.send(JSON.stringify({ type: 'queued', id: existingId, botId: data.botId, entryPrice: w.entryPrice || 0 }));
                    return { ok: true, id: existingId };
                }
            }
        }

        // Prevent same botId from occupying multiple slots in the same room
        if (data.botId) {
            const alreadyInRoom = Object.values(this.waitingRoom).some(w => w.botId === data.botId)
                || Object.values(this.players).some(p => p.botId === data.botId);
            if (alreadyInRoom) {
                return { ok: false, reason: 'already_in_room' };
            }
        }

        const gameInProgress = this.gameState !== 'COUNTDOWN';

        // Check capacity - but allow agent/hero to queue during match (overflow handled at startCountdown)
        if (this.capacityRemaining() <= 0) {
            if (gameInProgress && (botType === 'agent' || isHero)) {
                // Allow agent/hero to queue even if over capacity during match
                // startCountdown() will trim normals before next match
                console.log(`[Join] Allowing ${botType} "${name}" to queue during match (will trim normals later)`);
            } else if ((this.type === 'performance' || this.type === 'competitive') && botType === 'agent') {
                const victim = this.findKickableNormal();
                if (victim) delete this.waitingRoom[victim];
                if (this.capacityRemaining() <= 0) return { ok: false, reason: 'full' };
            } else if (isHero) {
                const victim = Object.keys(this.waitingRoom).find((id) => this.waitingRoom[id].botType !== 'hero');
                if (victim) delete this.waitingRoom[victim];
                if (this.capacityRemaining() <= 0) return { ok: false, reason: 'full' };
            } else {
                return { ok: false, reason: 'full' };
            }
        }

        // Record entry price for agent/hero
        const entryPrice = (this.type === 'competitive' && (botType === 'agent' || botType === 'hero')) ? S.currentEntryFee : 0;

        const id = C.randomId();
        this.waitingRoom[id] = {
            id: id,
            name: name,
            color: C.getNextColor(this),
            ws: ws,
            botType,
            botId: data.botId || null,
            botPrice: data.botPrice || 0,
            entryPrice: entryPrice,
        };
        ws.send(JSON.stringify({ type: 'queued', id: id, botId: data.botId || null, entryPrice }));

        // Check if we should increase entry fee
        RM.checkAndIncreaseFee();

        return { ok: true, id };
    }

    handleMove(playerId, data) {
        if (playerId && this.players[playerId] && this.players[playerId].alive) {
            const BM = require('./bot-manager');
            const p = this.players[playerId];
            const newDir = data.direction;
            // Validate direction is one of the 4 cardinal directions
            if (!newDir || typeof newDir.x !== 'number' || typeof newDir.y !== 'number') return;
            const valid = (newDir.x === 0 && (newDir.y === 1 || newDir.y === -1)) ||
                          (newDir.y === 0 && (newDir.x === 1 || newDir.x === -1));
            if (!valid) return;
            if (!BM.isOpposite(newDir, p.direction)) {
                p.nextDirection = newDir;
            }
        }
    }

    handleDisconnect(playerId) {
        if (playerId) {
            const RM = require('./room-manager');
            const wasAgent = (this.players[playerId]?.botType === 'agent' || this.players[playerId]?.botType === 'hero') ||
                             (this.waitingRoom[playerId]?.botType === 'agent' || this.waitingRoom[playerId]?.botType === 'hero');
            if (this.players[playerId]) this.killPlayer(this.players[playerId], 'disconnect');
            if (this.waitingRoom[playerId]) delete this.waitingRoom[playerId];
            if (wasAgent) RM.backfillRoom(this);
        }
    }
}

module.exports = GameRoom;
