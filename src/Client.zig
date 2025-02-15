// ************************************************************************** //
//                                                                            //
//                                                        :::      ::::::::   //
//   Client.zig                                         :+:      :+:    :+:   //
//                                                    +:+ +:+         +:+     //
//   By: pollivie <pollivie.student.42.fr>          +#+  +:+       +#+        //
//                                                +#+#+#+#+#+   +#+           //
//   Created: 2025/02/08 14:02:31 by pollivie          #+#    #+#             //
//   Updated: 2025/02/08 14:02:32 by pollivie         ###   ########.fr       //
//                                                                            //
// ************************************************************************** //

const std = @import("std");
const pg = @import("pg");
const httpz = @import("httpz");
const websocket = httpz.websocket;
const log = std.log;
const mem = std.mem;
const heap = std.heap;
const process = std.process;
const Game = @import("Game.zig").Game;
const PongOptions = @import("Pong.zig").PongOptions;
const PongSnapshot = @import("Pong.zig").PongSnapshot;
const PlayerKind = @import("Pong.zig").PlayerKind;
const Thread = std.Thread;

pub const Context = struct {
    arena: heap.ArenaAllocator,
    conn: *websocket.Conn,
    game: *Game,
    options: PongOptions,
    event: Event,

    pub fn init(allocator: mem.Allocator, options: PongOptions, game: *Game) !Context {
        log.debug("Initializing Context", .{});
        var arena: heap.ArenaAllocator = .init(allocator);
        errdefer {
            log.debug("Error during Context init; deinitializing arena", .{});
            arena.deinit();
        }
        defer log.debug("Context initialized successfully", .{});
        return .{
            .arena = arena,
            .game = game,
            .conn = undefined,
            .options = options,
            .event = Event{},
        };
    }
};

pub const Client = struct {
    conn: *websocket.Conn,
    ctx: Context,

    pub fn init(conn: *websocket.Conn, ctx: Context) !Client {
        defer log.debug("Client initialized successfully", .{});
        return .{
            .conn = conn,
            .ctx = .{
                .arena = ctx.arena,
                .game = ctx.game,
                .conn = conn,
                .options = ctx.options,
                .event = Event{},
            },
        };
    }

    pub fn clientMessage(self: *Client, data: []const u8) !void {
        // Reset arena for temporary allocations.
        _ = self.ctx.arena.reset(.retain_capacity);
        const kind = self.ctx.options.game_kind;
        const client_event = std.json.parseFromSliceLeaky(ClientEvent, self.ctx.arena.allocator(), data, .{ .ignore_unknown_fields = true }) catch {
            return;
        };

        // Update event and capture state under a mutex.
        var state: PongSnapshot = undefined;
        self.ctx.game.mutex.lock();
        {
            switch (kind) {
                .local_ai => {
                    if (std.mem.eql(u8, client_event.player, "p1")) {
                        self.ctx.event.player1 = .p1;
                        if (std.mem.eql(u8, client_event.direction, "up")) {
                            self.ctx.event.move1 = .up;
                        } else if (std.mem.eql(u8, client_event.direction, "down")) {
                            self.ctx.event.move1 = .down;
                        } else {
                            self.ctx.event.move1 = .none;
                        }
                    }
                },
                .local_mp, .remote_mp => {
                    if (std.mem.eql(u8, client_event.player, "p1")) {
                        self.ctx.event.player1 = .p1;
                        if (std.mem.eql(u8, client_event.direction, "up")) {
                            self.ctx.event.move1 = .up;
                        } else if (std.mem.eql(u8, client_event.direction, "down")) {
                            self.ctx.event.move1 = .down;
                        } else {
                            self.ctx.event.move1 = .none;
                        }
                    } else if (std.mem.eql(u8, client_event.player, "p2")) {
                        self.ctx.event.player2 = .p2;
                        if (std.mem.eql(u8, client_event.direction, "up")) {
                            self.ctx.event.move2 = .up;
                        } else if (std.mem.eql(u8, client_event.direction, "down")) {
                            self.ctx.event.move2 = .down;
                        } else {
                            self.ctx.event.move2 = .none;
                        }
                    }
                },
            }
            state = self.ctx.game.state;
        }
        self.ctx.game.mutex.unlock();

        const state_str = std.json.stringifyAlloc(self.ctx.arena.allocator(), state, .{}) catch "";
        try self.conn.writeText(state_str);
    }

    pub fn afterInit(self: *Client) !void {
        const game: *Game = self.ctx.game;
        if (!game.join(&self.ctx)) {
            try self.conn.close(.{ .reason = "GameIsFull" });
        } else {
            const options_str = std.json.stringifyAlloc(self.ctx.arena.allocator(), self.ctx.options, .{}) catch "";
            try self.conn.writeText(options_str);
        }
    }

    pub fn close(self: *Client) void {
        _ = self.ctx.game.quit(&self.ctx);
    }
};

pub const Event = struct {
    player1: PlayerKind = .p1,
    move1: Move = .none,
    player2: PlayerKind = .p2,
    move2: Move = .none,
};

pub const Move = enum {
    up,
    down,
    none,
};

pub const ClientEvent = struct {
    player: []const u8,
    direction: []const u8,
};
