// ************************************************************************** //
//                                                                            //
//                                                        :::      ::::::::   //
//   Runtime.zig                                        :+:      :+:    :+:   //
//                                                    +:+ +:+         +:+     //
//   By: pollivie <pollivie.student.42.fr>          +#+  +:+       +#+        //
//                                                +#+#+#+#+#+   +#+           //
//   Created: 2025/02/04 10:31:35 by pollivie          #+#    #+#             //
//   Updated: 2025/02/04 10:31:35 by pollivie         ###   ########.fr       //
//                                                                            //
// ************************************************************************** //

const std = @import("std");
const log = std.log;
const mem = std.mem;
const heap = std.heap;
const httpz = @import("httpz");
const ws = httpz.websocket;
const pg = @import("pg");
const GamePool = @import("GamePool.zig");
const Client = @import("Client.zig");
const Runtime = @This();

allocator: mem.Allocator,
db_pool: *pg.Pool,
gm_pool: *GamePool,

pub const WebsocketContext = struct {
    player: Client,
    conn: *ws.Conn,
};

pub const WebsocketHandler = struct {
    connection: *ws.Conn,
    context: WebsocketContext,

    pub fn init(conn: *ws.Conn, ctx: WebsocketContext) !WebsocketHandler {
        return .{
            .connection = conn,
            .context = .{
                .player = ctx.player,
                .conn = conn,
            },
        };
    }

    pub fn clientMessage(self: *WebsocketHandler, data: []const u8) !void {
        log.info("{} sent {s}", .{ self, data });
    }

    pub fn close(self: *WebsocketHandler) void {
        self.context.player.game.quit(self.context.player) catch |err| {
            log.err("while closing client : {!}", .{err});
        };
    }
};

// Initializes the runtime (handler for httpz.Server)
pub fn init(allocator: mem.Allocator, db_pool: ?*pg.Pool, gm_pool: *GamePool) !Runtime {
    return .{
        .allocator = allocator,
        .db_pool = db_pool orelse undefined,
        .gm_pool = gm_pool,
    };
}

pub fn deinit(self: *Runtime) void {
    _ = self;
}

// WebSocket upgrade route
pub fn handleWebSocketUpgrade(rt: *Runtime, req: *httpz.Request, res: *httpz.Response) !void {
    const game_id = req.param("game_id") orelse {
        res.status = 400;
        res.body = "Invalid WebSocket handshake";
        return;
    };

    const default_options = GamePool.Game.Options{
        .vt_game_kind = .local_ai,
        .vt_game_max_score = 10,
        .vt_game_board_width = 800,
        .vt_game_board_height = 600,
        .vt_game_paddle_width = 20,
        .vt_game_paddle_height = 100,
        .vt_game_paddle_speed = 5,
        .vt_game_ball_radius = 10,
        .vt_game_ball_speed = 4,
    };

    // Get or create a game
    var game = rt.gm_pool.getGame(game_id) orelse blk: {
        log.info("Creating new game: {s}", .{game_id});
        break :blk rt.gm_pool.createGame(game_id, default_options) catch |err| {
            std.log.err("in handleWebScoketUpgrade got : {!}", .{err});
            res.status = 500;
            res.body = "Internal Server Error";
            return;
        };
    };

    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(res.arena, "{}", .{game.states});

    const client = Client.init("1", game);
    game.join(client) catch |err| switch (err) {
        error.GameIsFull => {
            std.log.err("in handleWebScoketUpgrade got : {!}", .{err});
            res.status = 400;
            res.body = "Invalid WebSocket handshake";
            return;
        },
        error.GameIsDone => {
            std.log.err("in handleWebScoketUpgrade got : {!}", .{err});
            res.status = 400;
            res.body = "Invalid WebSocket handshake";
            return;
        },
        error.InvalidAction => {
            std.log.err("in handleWebScoketUpgrade got : {!}", .{err});
            res.status = 400;
            res.body = "Invalid WebSocket handshake";
            return;
        },
    };

    const ctx: WebsocketContext = .{
        .player = client,
        .conn = undefined,
    };

    const upgrade = httpz.upgradeWebsocket(WebsocketHandler, req, res, ctx) catch |err| {
        std.log.err("in handleWebScoketUpgrade got : {!}", .{err});
        res.status = 400;
        res.body = "Invalid WebSocket handshake";
        return;
    };
    _ = upgrade;
}

// // WebSocket upgrade route
// pub fn handleWebSocketUpgrade(rt: *Runtime, req: *httpz.Request, res: *httpz.Response) !void {
//     // from the route http://<pong_server_name:port>/play/<game_id>  <---- this value.
//     const game_id = req.param("game_id") orelse {
//         res.status = 400;
//         res.body = "Invalid WebSocket handshake: missing game_id";
//         return;
//     };

//     // var db = rt.db_pool;

// // I then take the game_id and uses it to querry the db to fetch the game config
// const QUERRY =
//     \\ SELECT game_kind, max_score, board_width, board_height,
//     \\ paddle_width, paddle_height, paddle_speed,
//     \\ ball_radius, ball_speed
//     \\ FROM game_object
//     \\ WHERE game_id = $1
// ;

// // Query the database for the game configuration
// var result = try db.query(QUERRY, .{game_id});
// defer result.deinit();

// var game_options: ?GamePool.Game.Options = null;
// if (try result.next()) |row| {
//     // Extract values from the row and construct the Game Options struct
//     game_options = .{
//         .vt_game_kind = switch (row.get(i32, 0)) {
//             0 => .local_ai,
//             1 => .local_mp,
//             2 => .remote_mp,
//             else => {
//                 res.status = 400;
//                 res.body = "Invalid game kind";
//                 return;
//             },
//         },
//         .vt_game_max_score = row.get(u8, 1),
//         .vt_game_board_width = row.get(u16, 2),
//         .vt_game_board_height = row.get(u16, 3),
//         .vt_game_paddle_width = row.get(u16, 4),
//         .vt_game_paddle_height = row.get(u16, 5),
//         .vt_game_paddle_speed = row.get(u16, 6),
//         .vt_game_ball_radius = row.get(u16, 7),
//         .vt_game_ball_speed = row.get(u16, 8),
//     };
// } else {
//     res.status = 404;
//     res.body = "Game not found";
//     return;
// }

// // Ensure we retrieved valid game options
// if (game_options == null) {
//     res.status = 500;
//     res.body = "Failed to fetch game configuration";
//     return;
// }

// Get or create the game using the fetched options
//     var game = rt.gm_pool.getGame(game_id) orelse blk: {
//         log.info("Creating new game from DB: {s}", .{game_id});
//         break :blk rt.gm_pool.createGame(game_id, game_options) catch |err| {
//             std.log.err("Error creating game: {!}", .{err});
//             res.status = 500;
//             res.body = "Internal Server Error";
//             return;
//         };
//     };

//     // Create a new WebSocket client
//     const client = Client.init("1", game);

//     // Attempt to join the game
//     game.join(client) catch |err| switch (err) {
//         error.GameIsFull, error.GameIsDone, error.InvalidAction => {
//             std.log.err("Failed to join game: {!}", .{err});
//             res.status = 400;
//             res.body = "Invalid WebSocket handshake";
//             return;
//         },
//     };

//     // Create WebSocket context
//     const ctx: WebsocketContext = .{
//         .player = client,
//         .conn = undefined,
//     };

//     // Upgrade the connection to WebSocket
//     const upgrade = httpz.upgradeWebsocket(WebsocketHandler, req, res, ctx) catch |err| {
//         std.log.err("WebSocket upgrade error: {!}", .{err});
//         res.status = 400;
//         res.body = "Invalid WebSocket handshake";
//         return;
//     };
//     _ = upgrade;
// }
//

// WebSocket upgrade route
