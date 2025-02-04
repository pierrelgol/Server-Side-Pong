// ************************************************************************** //
//                                                                            //
//                                                        :::      ::::::::   //
//   main.zig                                           :+:      :+:    :+:   //
//                                                    +:+ +:+         +:+     //
//   By: pollivie <pollivie.student.42.fr>          +#+  +:+       +#+        //
//                                                +#+#+#+#+#+   +#+           //
//   Created: 2025/01/30 10:09:28 by pollivie          #+#    #+#             //
//   Updated: 2025/01/30 10:09:29 by pollivie         ###   ########.fr       //
//                                                                            //
// ************************************************************************** //

const std = @import("std");
const log = std.log;
const heap = std.heap;
const process = std.process;
const httpz = @import("httpz");
const pg = @import("pg");
const Client = @import("Client.zig");
const Runtime = @import("Runtime.zig");
const GamePool = @import("GamePool.zig");

const SUCCESS: u8 = 0;
const FAILURE: u8 = 1;

pub fn main() !u8 {
    const gpa_options: heap.GeneralPurposeAllocatorConfig = .{
        .safety = true,
        .thread_safe = true,
        .never_unmap = true,
        .retain_metadata = true,
    };

    var gpa: heap.GeneralPurposeAllocator(gpa_options) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var envp = process.getEnvMap(allocator) catch |err| {
        log.err("fatal error {!}. shutting down.", .{err});
        return FAILURE;
    };
    defer envp.deinit();

    // const db_pool_options: pg.Pool.Opts = .{
    //     .size = 2,
    //     .auth = .{
    //         .username = "postgress",
    //         .password = "pass",
    //         .database = "foo",
    //     },
    //     .connect = .{
    //         .host = "xxx.xxx.xxx",
    //         .port = 1234,
    //     },
    // };

    // var db_pool = pg.Pool.init(allocator, db_pool_options) catch |err| {
    //     log.err("fatal error {!}. shutting down.", .{err});
    //     return FAILURE;
    // };
    // defer db_pool.deinit();

    var game_pool = GamePool.init(allocator, null);
    defer game_pool.deinit();

    var runtime = Runtime.init(allocator, null, &game_pool) catch |err| {
        log.err("fatal error {!}. shutting down.", .{err});
        return FAILURE;
    };
    defer runtime.deinit();

    const server_options: httpz.Config = .{
        .port = 8080,
        .address = "127.0.0.1",
    };

    var server = httpz.Server(*Runtime).init(allocator, server_options, &runtime) catch |err| {
        log.err("fatal error {!}. shutting down.", .{err});
        return FAILURE;
    };
    defer {
        server.stop();
        server.deinit();
    }

    std.debug.print("listening", .{});
    server.listen() catch |err| {
        log.err("fatal error {!}. shutting down.", .{err});
        return FAILURE;
    };

    var router = server.router(.{});
    router.get("/play/:game_id", Runtime.handleWebSocketUpgrade, .{ .handler = &runtime });

    return SUCCESS;
}

test "request" {
    const allocator = std.heap.page_allocator;

    // Initialize runtime (handler)
    var game_pool = GamePool.init(allocator, null);
    defer game_pool.deinit();

    var runtime = Runtime.init(allocator, null, &game_pool) catch |err| {
        std.debug.print("Fatal error {!}. Shutting down.\n", .{err});
        return;
    };
    defer runtime.deinit();

    var web_test = httpz.testing.init(.{});
    defer web_test.deinit();

    // Simulate request to /play/game123
    web_test.param("game_id", "game123");
    web_test.query("player_id", "p1");

    // Call handler
    try Runtime.handleWebSocketUpgrade(&runtime, web_test.req, web_test.res);

    // Print response
    std.debug.print("Response status: {}\n", .{web_test.res.status});
    std.debug.print("Response body: {s}\n", .{web_test.res.body});
}
