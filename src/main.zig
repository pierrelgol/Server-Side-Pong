// ************************************************************************** //
//                                                                            //
//                                                        :::      ::::::::   //
//   main.zig                                           :+:      :+:    :+:   //
//                                                    +:+ +:+         +:+     //
//   By: pollivie <pollivie.student.42.fr>          +#+  +:+       +#+        //
//                                                +#+#+#+#+#+   +#+           //
//   Created: 2025/02/08 13:42:16 by pollivie          #+#    #+#             //
//   Updated: 2025/02/08 13:42:17 by pollivie         ###   ########.fr       //
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
const GamePool = @import("GamePool.zig").GamePool;
const Runtime = @import("Runtime.zig").Runtime;
const Thread = std.Thread;

const SUCCESS = 0;
const FAILURE = 1;

pub const std_options = std.Options{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .websocket, .level = .err },
    },
    .http_enable_ssl_key_log_file = true,
};

const gpa_config: heap.GeneralPurposeAllocatorConfig = .{
    .safety = true,
    .thread_safe = true,
    .retain_metadata = true,
};

pub fn main() !u8 {
    var gpa: heap.GeneralPurposeAllocator(gpa_config) = .init;
    defer _ = gpa.deinit();
    std.log.info("initializing memory allocator.", .{});
    log.debug("General Purpose Allocator initialized.", .{});

    var envp = process.getEnvMap(gpa.allocator()) catch |err| {
        log.err("Encountered Fatal Error : {!}", .{err});
        return FAILURE;
    };
    log.debug("Environment variables loaded.", .{});
    defer envp.deinit();

    const db_url = envp.get("DATABASE_URL") orelse {
        log.err("Encountered Fatal Error missing 'DATABASE_URL'", .{});
        return FAILURE;
    };
    log.debug("DATABASE_URL found: {s}", .{db_url});

    const db_uri = std.Uri.parse(db_url) catch |err| {
        log.err("Encountered Fatal Error : {!}", .{err});
        return FAILURE;
    };
    log.debug("DATABASE_URL parsed into URI successfully.", .{});

    var db_pool = pg.Pool.initUri(gpa.allocator(), db_uri, 2, 10_000) catch |err| {
        log.err("Encountered Fatal Error : {!}", .{err});
        return FAILURE;
    };
    log.debug("Database pool initialized.", .{});
    defer db_pool.deinit();

    var gm_pool = GamePool.init(gpa.allocator());
    log.debug("GamePool initialized.", .{});
    defer gm_pool.deinit();

    var runtime = Runtime.init(gpa.allocator(), db_pool, &gm_pool) catch |err| {
        log.err("Encountered Fatal Error : {!}", .{err});
        return FAILURE;
    };
    log.debug("Runtime initialized.", .{});

    const server_opts: httpz.Config = .{
        .port = 8081,
        .address = "0.0.0.0",
        .thread_pool = .{
            .count = 2,
            .backlog = 500,
        },
        .workers = .{
            .count = 2,
        },
    };

    var server = httpz.Server(*Runtime).init(gpa.allocator(), server_opts, &runtime) catch |err| {
        log.err("Encountered Fatal Error : {!}", .{err});
        return FAILURE;
    };
    log.debug("Server instance created.", .{});
    defer server.stop();
    defer server.deinit();

    var router = server.router(.{});
    log.debug("Router configured.", .{});

    router.tryGet("/game/:game_id", Runtime.handleWebsocketUpgrade, .{ .handler = &runtime }) catch |err| {
        log.err("Encountered Fatal Error : {!}", .{err});
        return FAILURE;
    };
    log.debug("Route '/game/:game_id' for websocket upgrade configured.", .{});

    server.listen() catch |err| {
        log.err("Encountered Fatal Error : {!}", .{err});
        return FAILURE;
    };
    log.debug("Server is now listening for connections.", .{});
    const thread = server.listenInNewThread() catch |err| {
        log.err("Encountered Fatal Error : {!}", .{err});
        return FAILURE;
    };
    log.debug("Server is now listening for connections.", .{});

    thread.join();

    return SUCCESS;
}
