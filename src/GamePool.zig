// ************************************************************************** //
//                                                                            //
//                                                        :::      ::::::::   //
//   GamePool.zig                                       :+:      :+:    :+:   //
//                                                    +:+ +:+         +:+     //
//   By: pollivie <pollivie.student.42.fr>          +#+  +:+       +#+        //
//                                                +#+#+#+#+#+   +#+           //
//   Created: 2025/02/08 13:49:23 by pollivie          #+#    #+#             //
//   Updated: 2025/02/08 13:49:23 by pollivie         ###   ########.fr       //
//                                                                            //
// ************************************************************************** //

const std = @import("std");
const pg = @import("pg");
const httpz = @import("httpz");
const log = std.log;
const mem = std.mem;
const heap = std.heap;
const process = std.process;
const Game = @import("Game.zig").Game;
const PongOptions = @import("Pong.zig").PongOptions;
const Thread = std.Thread;
const Runtime = @import("Runtime.zig");

pub const GamePool = struct {
    allocator: mem.Allocator,
    pool: std.StringHashMap(*Game),
    tids: std.StringHashMap(Thread),

    pub fn init(allocator: mem.Allocator) GamePool {
        log.debug("Initializing GamePool", .{});
        return .{
            .allocator = allocator,
            .pool = std.StringHashMap(*Game).init(allocator),
            .tids = std.StringHashMap(Thread).init(allocator),
        };
    }

    pub fn get(self: *GamePool, game_id: []const u8) ?*Game {
        log.debug("Fetching game with id: {s}", .{game_id});
        const game = self.pool.get(game_id);
        if (game) |_| {
            log.debug("Game found for id: {s}", .{game_id});
        } else {
            log.debug("No game found for id: {s}", .{game_id});
        }
        return game;
    }

    pub fn create(self: *GamePool, game_id: []const u8, options: PongOptions) !*Game {
        log.debug("Creating game with id: {s}", .{game_id});
        const game = try Game.create(self.allocator, options, game_id);
        errdefer {
            log.debug("Error occurred after creating game; destroying game with id: {s}", .{game_id});
            game.destroy(self.allocator);
        }
        try self.pool.put(game_id, game);
        errdefer _ = self.pool.remove(game_id);

        try self.tids.put(game_id, try game.startGame());
        log.debug("Game inserted into pool with id: {s}", .{game_id});
        return game;
    }

    pub fn del(self: *GamePool, game_id: []const u8) void {
        log.debug("Deleting game with id: {s}", .{game_id});
        const maybe_game = self.pool.fetchRemove(game_id);
        if (maybe_game) |game| {
            log.debug("Game found; deinitializing game with id: {s}", .{game_id});
            game.value.destroy(self.allocator);
        } else {
            log.debug("No game found to delete for id: {s}", .{game_id});
        }
        const maybe_thread = self.tids.fetchRemove(game_id);
        if (maybe_thread) |thread| {
            log.debug("Game found; deinitializing game with id: {s}", .{game_id});
            thread.value.join();
        } else {
            log.debug("No game found to delete for id: {s}", .{game_id});
        }
    }

    pub fn deinit(self: *GamePool) void {
        var ith = self.tids.iterator();
        while (ith.next()) |threads| {
            threads.value_ptr.join();
        }

        var itp = self.pool.iterator();
        while (itp.next()) |game| {
            log.debug("Destroying game with id: {s}", .{game.key_ptr});
            game.value_ptr.*.destroy(self.allocator);
        }

        self.pool.deinit();
        self.tids.deinit();
        log.debug("GamePool deinitialized", .{});
    }

    pub fn setServer(self: *GamePool, server: *httpz.Server(*Runtime)) void {
        self.server = server;
    }
};
