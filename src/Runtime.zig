// ************************************************************************** //
//                                                                            //
//                                                        :::      ::::::::   //
//   Runtime.zig                                        :+:      :+:    :+:   //
//                                                    +:+ +:+         +:+     //
//   By: pollivie <pollivie.student.42.fr>          +#+  +:+       +#+        //
//                                                +#+#+#+#+#+   +#+           //
//   Created: 2025/02/08 13:48:51 by pollivie          #+#    #+#             //
//   Updated: 2025/02/08 13:48:52 by pollivie         ###   ########.fr       //
//                                                                            //
// ************************************************************************** //

const std = @import("std");
const pg = @import("pg");
const httpz = @import("httpz");
const log = std.log;
const mem = std.mem;
const heap = std.heap;
const process = std.process;
const Client = @import("Client.zig").Client;
const Context = @import("Client.zig").Context;
const Game = @import("Game.zig").Game;
const GamePool = @import("GamePool.zig").GamePool;
const Pong = @import("Pong.zig");
const Thread = std.Thread;

pub const Runtime = struct {
    allocator: mem.Allocator,
    db_pool: *pg.Pool,
    gm_pool: *GamePool,

    pub fn init(allocator: mem.Allocator, db_pool: *pg.Pool, gm_pool: *GamePool) !Runtime {
        log.debug("Initializing Runtime", .{});
        defer log.debug("Runtime initialized successfully", .{});
        return .{
            .allocator = allocator,
            .db_pool = db_pool,
            .gm_pool = gm_pool,
        };
    }

    pub const WebsocketContext = Context;
    pub const WebsocketHandler = Client;

    pub fn handleWebsocketUpgrade(rt: *Runtime, req: *httpz.Request, res: *httpz.Response) !void {
        log.debug("Handling websocket upgrade request", .{});
        const game_id = req.params.get("game_id") orelse {
            log.debug("Missing 'game_id' in request parameters", .{});
            res.status = 400;
            res.body = "Missing 'game_id'";
            return;
        };
        log.debug("Received websocket upgrade request for game_id: {s}", .{game_id});

        const options = Pong.PongOptions.queryFromDb(rt.db_pool, "select * from \"Game\" where id = $1", .{game_id}) catch |err| {
            log.err("Failed to query game options from DB for game_id {s}: {!}", .{ game_id, err });
            res.status = 500;
            res.body = "Internal Server Error : Missing Game.";
            return;
        };
        log.debug("Retrieved game options for game_id: {s}", .{game_id});

        log.debug("Attempting to retrieve game from pool for game_id: {s}", .{game_id});
        const game: *Game = rt.gm_pool.get(game_id) orelse blk: {
            log.debug("Game not found in pool for game_id: {s}. Creating new game.", .{game_id});
            const new_game = rt.gm_pool.create(game_id, options) catch |err| {
                log.err("Failed to create game for game_id {s}: {!}", .{ game_id, err });
                res.status = 500;
                res.body = "Internal Server Error : Missing Game.";
                return;
            };
            log.debug("Created new game for game_id: {s}", .{game_id});
            break :blk new_game;
        };

        log.debug("Initializing websocket context for game_id: {s}", .{game_id});
        const context = Context.init(rt.allocator, options, game) catch |err| {
            log.err("Failed to initialize context for game_id {s}: {!}", .{ game_id, err });
            res.status = 500;
            res.body = "Internal Server Error : Missing Game.";
            return;
        };
        log.debug("Websocket context initialized for game_id: {s}", .{game_id});

        log.debug("Attempting websocket upgrade for game_id: {s}", .{game_id});
        const did_upgrade = httpz.upgradeWebsocket(Client, req, res, context) catch |err| {
            log.err("Websocket upgrade encountered an error for game_id {s}: {!}", .{ game_id, err });
            res.status = 500;
            res.body = "Internal Server Error : Missing Game.";
            return;
        };

        if (!did_upgrade) {
            rt.gm_pool.del(game_id);
            log.err("Failed to upgrade to websocket for game_id: {s}", .{game_id});
        } else {
            log.debug("Successfully upgraded to websocket for game_id: {s}", .{game_id});
        }
    }
};
