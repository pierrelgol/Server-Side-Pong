// ************************************************************************** //
//                                                                            //
//                                                        :::      ::::::::   //
//   GamePool.zig                                       :+:      :+:    :+:   //
//                                                    +:+ +:+         +:+     //
//   By: pollivie <pollivie.student.42.fr>          +#+  +:+       +#+        //
//                                                +#+#+#+#+#+   +#+           //
//   Created: 2025/02/04 12:33:02 by pollivie          #+#    #+#             //
//   Updated: 2025/02/04 12:33:03 by pollivie         ###   ########.fr       //
//                                                                            //
// ************************************************************************** //

const std = @import("std");
const log = std.log;
const mem = std.mem;
const heap = std.heap;
const httpz = @import("httpz");
const pg = @import("pg");
const GamePool = @This();
const Client = @import("Client.zig");

allocator: mem.Allocator,
db_pool: *pg.Pool,
active_games: std.StringHashMap(*Game),

pub fn init(allocator: mem.Allocator, db_pool: ?*pg.Pool) GamePool {
    return .{
        .allocator = allocator,
        .db_pool = db_pool orelse undefined,
        .active_games = std.StringHashMap(*Game).init(allocator),
    };
}

pub fn getGame(self: *GamePool, game_id: []const u8) ?*Game {
    return self.active_games.get(game_id);
}

pub fn createGame(self: *GamePool, game_id: []const u8, options: Game.Options) !*Game {
    const game: *Game = try Game.create(self.allocator, options);
    errdefer game.destroy(self.allocator);
    try self.active_games.put(game_id, game);
    return game;
}

pub fn deinit(self: *GamePool) void {
    self.active_games.deinit();
    self.* = undefined;
}

pub const Game = struct {
    options: Options,
    status: Status,
    states: States,
    player1: ?Client,
    player2: ?Client,

    pub const Error = error{
        GameIsFull,
        GameIsDone,
        InvalidAction,
    };

    pub const Kind = enum {
        local_ai,
        local_mp,
        remote_mp,
    };

    pub const Status = enum {
        lobby,
        ongoing,
        finished,
    };

    pub const States = struct {
        vt_player1_score: u8,
        vt_player2_score: u8,
        vt_player1_x: u16,
        vt_player1_y: u16,
        vt_player2_x: u16,
        vt_player2_y: u16,
        vt_ball_x: u16,
        vt_ball_y: u16,

        pub fn init(options: Game.Options) States {
            _ = options;
            return .{
                .vt_player1_score = 0,
                .vt_player2_score = 0,
                .vt_player1_x = 0,
                .vt_player1_y = 0,
                .vt_player2_x = 0,
                .vt_player2_y = 0,
                .vt_ball_x = 0,
                .vt_ball_y = 0,
            };
        }

        pub fn format(
            self: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            try std.json.stringify(self, .{ .whitespace = .indent_2 }, writer);
        }
    };

    pub const Options = struct {
        vt_game_kind: Kind,
        vt_game_max_score: u8,
        vt_game_board_width: u16,
        vt_game_board_height: u16,
        vt_game_paddle_width: u16,
        vt_game_paddle_height: u16,
        vt_game_paddle_speed: u16,
        vt_game_ball_radius: u16,
        vt_game_ball_speed: u16,

        pub fn format(
            self: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            try std.json.stringify(self, .{ .whitespace = .indent_2 }, writer);
        }
    };

    pub fn create(allocator: mem.Allocator, options: Game.Options) !*Game {
        const self: *Game = try allocator.create(Game);
        self.* = .{
            .options = options,
            .status = .lobby,
            .states = States.init(options),
            .player1 = null,
            .player2 = null,
        };
        return self;
    }

    pub fn destroy(game: *Game, allocator: mem.Allocator) void {
        allocator.destroy(game);
    }

    pub fn join(game: *Game, client: Client) !void {
        switch (game.options.vt_game_kind) {
            .local_ai => try game.joinLocalAi(client),
            .local_mp => try game.joinLocalAi(client),
            .remote_mp => try game.joinLocalAi(client),
        }
    }

    fn joinLocalAi(game: *Game, client: Client) !void {
        if (game.status == .lobby and game.player1 == null) {
            game.player1 = client;
            game.status = .ongoing;
        } else {
            return Error.GameIsFull;
        }
    }

    fn joinLocalMp(game: *Game, client: Client) !void {
        if (game.status == .lobby and game.player1 == null) {
            game.player1 = client;
            game.status = .ongoing;
        } else {
            return Error.GameIsFull;
        }
    }

    fn joinRemoteMp(game: *Game, client: Client) !void {
        switch (game.status) {
            .lobby => {
                if (game.has1PlayerWaiting()) {
                    try game.addPlayer(client);
                    game.status = .ongoing;
                } else {
                    game.player1 = client;
                    game.status = .lobby;
                }
            },
            else => return Error.GameIsFull,
        }
    }

    pub fn quit(game: *Game, client: Client) !void {
        switch (game.options.vt_game_kind) {
            .local_ai => try game.quitLocalAi(client),
            .local_mp => try game.quitLocalMp(client),
            .remote_mp => try game.quitLocalMp(client),
        }
    }

    fn quitLocalAi(game: *Game, client: Client) !void {
        if (!game.isPlayer1(client)) {
            return Error.InvalidAction;
        }
        game.status = .finished;
    }

    fn quitLocalMp(game: *Game, client: Client) !void {
        if (!game.isPlayer1(client)) {
            return Error.InvalidAction;
        }
        game.status = .finished;
    }

    fn quitRemoteMp(game: *Game, client: Client) !void {
        if (!game.isPlayer1(client) or !game.isPlayer2(client)) {
            return Error.InvalidAction;
        }
        game.status = .finished;
    }

    fn isPlayer1(game: *Game, client: Client) bool {
        const p1 = game.player1 orelse return false;
        return std.mem.eql(u8, p1.player_id, client.player_id);
    }

    fn isPlayer2(game: *Game, client: Client) bool {
        const p2 = game.player2 orelse return false;
        return std.mem.eql(u8, p2.player_id, client.player_id);
    }

    fn has1PlayerWaiting(game: *Game) bool {
        if (game.status != .lobby) return false;
        return if (game.player1 == null and game.player2 == null) false else true;
    }

    fn addPlayer(game: *Game, client: Client) !void {
        if (game.player1 != null and game.player2 != null) {
            return Error.GameIsFull;
        } else if (game.player1 == null) {
            game.player1 = client;
        } else if (game.player2 == null) {
            game.player2 = client;
        }
    }
};
