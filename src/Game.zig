// ************************************************************************** //
//                                                                            //
//                                                        :::      ::::::::   //
//   Game.zig                                           :+:      :+:    :+:   //
//                                                    +:+ +:+         +:+     //
//   By: pollivie <pollivie.student.42.fr>          +#+  +:+       +#+        //
//                                                +#+#+#+#+#+   +#+           //
//   Created: 2025/02/08 13:49:39 by pollivie          #+#    #+#             //
//   Updated: 2025/02/08 13:49:39 by pollivie         ###   ########.fr       //
//                                                                            //
// ************************************************************************** //

const std = @import("std");
const pg = @import("pg");
const httpz = @import("httpz");
const log = std.log;
const mem = std.mem;
const heap = std.heap;
const process = std.process;
const PongOptions = @import("Pong.zig").PongOptions;
const Pong = @import("Pong.zig").Pong;
const Snapshot = @import("Pong.zig").PongSnapshot;
const Thread = std.Thread;
const PlayerContext = @import("Client.zig").Context;
const Results = @import("Results.zig").Results;

pub const Game = struct {
    arena: std.heap.ArenaAllocator,
    game_id: []const u8,
    options: PongOptions,
    pong: Pong = undefined,
    state: Snapshot = .{},
    mutex: Thread.Mutex = .{},
    p1: ?*PlayerContext,
    p2: ?*PlayerContext,

    pub fn create(allocator: mem.Allocator, options: PongOptions, id: []const u8) !*Game {
        log.debug("Creating Game instance", .{});
        var arena: heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const self = try allocator.create(Game);
        self.* = .{
            .arena = arena,
            .game_id = try arena.allocator().dupe(u8, id),
            .options = options,
            .pong = Pong.init(options),
            .mutex = Thread.Mutex{},
            .state = Snapshot{},
            .p1 = null,
            .p2 = null,
        };
        log.debug("Game instance created successfully; Pong initialized", .{});
        return self;
    }

    pub fn destroy(self: *Game, allocator: mem.Allocator) void {
        log.debug("Destroying Game instance", .{});
        self.arena.deinit();
        allocator.destroy(self);
        log.debug("Game instance destroyed", .{});
    }

    pub fn startGame(self: *Game) !Thread {
        return switch (self.options.game_kind) {
            .local_ai => Thread.spawn(.{}, gameLoopAi, .{self}),
            .local_mp => Thread.spawn(.{}, gameLoopLocalMp, .{self}),
            .remote_mp => Thread.spawn(.{}, gameLoopRemoteMp, .{self}),
        };
    }

    pub fn join(self: *Game, ctx: *PlayerContext) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        switch (self.options.game_kind) {
            .local_ai, .local_mp => {
                // Only one player allowed.
                if (self.p1 != null) return false;
                self.p1 = ctx;
                self.state.game_is_playing = true;
                self.state.game_is_waiting = false;
                self.state.game_is_timeout = false;
                return true;
            },
            .remote_mp => {
                // Allow up to two players.
                if (self.p1 == null) {
                    self.p1 = ctx;
                    return true;
                } else if (self.p2 == null) {
                    self.p2 = ctx;
                    // Both players are now connected; start the game.
                    self.state.game_is_playing = true;
                    self.state.game_is_waiting = false;
                    self.state.game_is_timeout = false;
                    return true;
                } else {
                    return false;
                }
            },
        }
    }

    pub fn quit(self: *Game, ctx: *PlayerContext) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        switch (self.options.game_kind) {
            .local_ai, .local_mp => {
                // Only allow quitting if the current player is the one stored.
                if (self.p1 != ctx) return false;
                self.p1 = null;
                self.state.game_is_playing = false;
                self.state.game_is_waiting = false;
                return true;
            },
            .remote_mp => {
                // Remove the quitting player from the appropriate slot.
                if (self.p1 == ctx) {
                    self.p1 = null;
                } else if (self.p2 == ctx) {
                    self.p2 = null;
                } else {
                    return false;
                }
                // If no players remain, clear game state.
                // Otherwise, if one player remains, set the game to waiting.
                if (self.p1 == null and self.p2 == null) {
                    self.state.game_is_playing = false;
                    self.state.game_is_waiting = false;
                } else {
                    self.state.game_is_playing = false;
                    self.state.game_is_waiting = true;
                }
                return true;
            },
        }
    }

    pub fn gameLoopAi(self: *Game) void {
        var buffer: [8192]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(buffer[0..]);

        const timeout_ms = 15_000;
        var last_play_ms: i64 = std.time.milliTimestamp();
        const tickrate_ms = 16;
        var last_tick_ms = last_play_ms;
        var shouldExit = false;

        while (true) {
            const now_ms = std.time.milliTimestamp();
            if (now_ms - last_tick_ms < tickrate_ms) {
                Thread.sleep(tickrate_ms * 10000);
                continue;
            }
            last_tick_ms = now_ms;

            var current_state: Snapshot = self.state;
            var local_last_play_ms = last_play_ms;
            var client: ?*PlayerContext = null;

            // Critical section: update shared game state.
            {
                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.p1) |conn| {
                    client = conn;
                    switch (conn.event.move1) {
                        .up => {
                            self.state.player_1_alive = true;
                            self.state.player_2_alive = true;
                            self.state = self.pong.update(tickrate_ms, -1, 0);
                            last_play_ms = now_ms;
                            conn.event.move1 = .none;
                        },
                        .down => {
                            self.state.player_1_alive = true;
                            self.state.player_2_alive = true;
                            self.state = self.pong.update(tickrate_ms, 1, 0);
                            last_play_ms = now_ms;
                            conn.event.move1 = .none;
                        },
                        .none => {
                            self.state = self.pong.update(tickrate_ms, 0, 0);
                        },
                    }

                    // Check win conditions.
                    if (self.state.player_1_score >= self.options.max_score) {
                        self.state.player_1_won = true;
                        self.state.game_is_playing = false;
                        self.state.game_is_waiting = false;
                        self.state.game_is_timeout = false;
                        self.state.player_2_won = false;
                        shouldExit = true;
                    } else if (self.state.player_2_score >= self.options.max_score) {
                        self.state.player_2_won = true;
                        self.state.game_is_playing = false;
                        self.state.game_is_waiting = false;
                        self.state.game_is_timeout = false;
                        self.state.player_1_won = false;
                        shouldExit = true;
                    }

                    current_state = self.state;
                    local_last_play_ms = last_play_ms;
                }
            } // mutex is unlocked here

            // If a client is connected, perform network I/O outside the lock.
            if (client) |still_connected| {
                fba.reset();
                const json_str = std.json.stringifyAlloc(fba.allocator(), self.state, .{}) catch "";

                // Write the updated state.
                still_connected.conn.writeText(json_str) catch {
                    // Handle write error if needed.
                    continue;
                };

                // Check for timeout (now_ms exceeds last play timestamp plus timeout_ms).
                if (std.time.milliTimestamp() > local_last_play_ms + timeout_ms) {
                    still_connected.conn.close(.{ .reason = "Idling" }) catch {};
                    break;
                }
            }

            if (shouldExit) break;
        }

        var results = Results.init(self.arena.allocator(), self.state, std.fmt.parseInt(i32, self.game_id, 10) catch 1);
        defer results.deinit();

        results.postResults("https://localhost:8000/api/add_game/") catch {};
    }

    pub fn gameLoopLocalMp(self: *Game) void {
        var buffer: [8192]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(buffer[0..]);

        const timeout_ms = 15_000;
        var last_play_ms: i64 = std.time.milliTimestamp();
        const tickrate_ms = 16;
        var last_tick_ms = last_play_ms;
        var shouldExit = false;

        while (true) {
            const now_ms = std.time.milliTimestamp();
            if (now_ms - last_tick_ms < tickrate_ms) {
                Thread.sleep(tickrate_ms * 10000);
                continue;
            }
            last_tick_ms = now_ms;

            var current_state: Snapshot = self.state;
            var local_last_play_ms = last_play_ms;
            var client: ?*PlayerContext = null;

            self.mutex.lock();
            {
                defer self.mutex.unlock();

                if (self.p1) |conn| {
                    client = conn;

                    // Read both players’ moves from the same connection.
                    var leftMove: i32 = 0;
                    switch (conn.event.move1) {
                        .up => {
                            leftMove = -1;
                            conn.event.move1 = .none;
                            last_play_ms = now_ms;
                        },
                        .down => {
                            leftMove = 1;
                            conn.event.move1 = .none;
                            last_play_ms = now_ms;
                        },
                        .none => leftMove = 0,
                    }

                    var rightMove: i32 = 0;
                    switch (conn.event.move2) {
                        .up => {
                            rightMove = -1;
                            conn.event.move2 = .none;
                            last_play_ms = now_ms;
                        },
                        .down => {
                            rightMove = 1;
                            conn.event.move2 = .none;
                            last_play_ms = now_ms;
                        },
                        .none => rightMove = 0,
                    }

                    // Update the game state once with both inputs.
                    self.state = self.pong.update(tickrate_ms, leftMove, rightMove);

                    // Check win conditions.
                    if (self.state.player_1_score >= self.options.max_score) {
                        self.state.player_1_won = true;
                        self.state.game_is_playing = false;
                        self.state.game_is_waiting = false;
                        self.state.game_is_timeout = false;
                        self.state.player_2_won = false;
                        shouldExit = true;
                    } else if (self.state.player_2_score >= self.options.max_score) {
                        self.state.player_2_won = true;
                        self.state.game_is_playing = false;
                        self.state.game_is_waiting = false;
                        self.state.game_is_timeout = false;
                        self.state.player_1_won = false;
                        shouldExit = true;
                    }

                    current_state = self.state;
                    local_last_play_ms = last_play_ms;
                }
            }

            // Network I/O: write the updated state outside the lock.
            if (client) |still_connected| {
                fba.reset();
                const json_str = std.json.stringifyAlloc(fba.allocator(), self.state, .{}) catch "";
                still_connected.conn.writeText(json_str) catch {
                    continue;
                };

                if (std.time.milliTimestamp() > local_last_play_ms + timeout_ms) {
                    still_connected.conn.close(.{ .reason = "Idling" }) catch {};
                    break;
                }
            }

            if (shouldExit) break;
        }
        var results = Results.init(self.arena.allocator(), self.state, std.fmt.parseInt(i32, self.game_id, 10) catch 1);
        defer results.deinit();

        results.postResults("https://localhost:8000/api/add_game/") catch {};
    }

    pub fn gameLoopRemoteMp(self: *Game) void {
        var buffer: [8192]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(buffer[0..]);

        const timeout_ms = 15_000;
        var last_play_ms: i64 = std.time.milliTimestamp();
        const tickrate_ms = 16;
        var last_tick_ms = last_play_ms;
        var shouldExit = false;

        while (true) {
            const now_ms = std.time.milliTimestamp();
            if (now_ms - last_tick_ms < tickrate_ms) {
                Thread.sleep(tickrate_ms * 10000);
                continue;
            }
            last_tick_ms = now_ms;

            var local_last_play_ms = last_play_ms;
            // Local copies of both player connections.
            var p1_client: ?*PlayerContext = null;
            var p2_client: ?*PlayerContext = null;

            self.mutex.lock();
            {
                defer self.mutex.unlock();

                // If no players remain, exit the loop.
                if (self.p1 == null and self.p2 == null) {
                    break;
                }

                var leftMove: i32 = 0;
                var rightMove: i32 = 0;

                if (self.p1) |p1| {
                    p1_client = p1;
                    switch (p1.event.move1) {
                        .up => {
                            leftMove = -1;
                            p1.event.move1 = .none;
                            last_play_ms = now_ms;
                        },
                        .down => {
                            leftMove = 1;
                            p1.event.move1 = .none;
                            last_play_ms = now_ms;
                        },
                        .none => leftMove = 0,
                    }
                }

                if (self.p2) |p2| {
                    p2_client = p2;
                    switch (p2.event.move2) {
                        .up => {
                            rightMove = -1;
                            p2.event.move2 = .none;
                            last_play_ms = now_ms;
                        },
                        .down => {
                            rightMove = 1;
                            p2.event.move2 = .none;
                            last_play_ms = now_ms;
                        },
                        .none => rightMove = 0,
                    }
                }

                // Update game simulation using both inputs.
                self.state = self.pong.update(tickrate_ms, leftMove, rightMove);

                // Check win conditions.
                if (self.state.player_1_score >= self.options.max_score) {
                    self.state.player_1_won = true;
                    self.state.game_is_playing = false;
                    self.state.game_is_waiting = false;
                    self.state.game_is_timeout = false;
                    self.state.player_2_won = false;
                    shouldExit = true;
                } else if (self.state.player_2_score >= self.options.max_score) {
                    self.state.player_2_won = true;
                    self.state.game_is_playing = false;
                    self.state.game_is_waiting = false;
                    self.state.game_is_timeout = false;
                    self.state.player_1_won = false;
                    shouldExit = true;
                }

                local_last_play_ms = last_play_ms;
            } // Unlock mutex here

            // Outside the critical section, send the updated state to each connected client.
            if (p1_client) |client1| {
                fba.reset();
                const json_str = std.json.stringifyAlloc(fba.allocator(), self.state, .{}) catch "";
                client1.conn.writeText(json_str) catch {
                    // On error, the connection may be closed by the quit function.
                };
                if (std.time.milliTimestamp() > local_last_play_ms + timeout_ms) {
                    client1.conn.close(.{ .reason = "Idling" }) catch {};
                }
            }
            if (p2_client) |client2| {
                fba.reset();
                const json_str = std.json.stringifyAlloc(fba.allocator(), self.state, .{}) catch "";
                client2.conn.writeText(json_str) catch {
                    // On error, handle accordingly.
                };
                if (std.time.milliTimestamp() > local_last_play_ms + timeout_ms) {
                    client2.conn.close(.{ .reason = "Idling" }) catch {};
                }
            }

            if (shouldExit) break;
        }
        var results = Results.init(self.arena.allocator(), self.state, std.fmt.parseInt(i32, self.game_id, 10) catch 1);
        defer results.deinit();

        results.postResults("https://localhost:8000/api/add_game/") catch {};
    }
};
