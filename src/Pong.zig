// ************************************************************************** //
//                                                                            //
//                                                        :::      ::::::::   //
//   Pong.zig                                           :+:      :+:    :+:   //
//                                                    +:+ +:+         +:+     //
//   By: pollivie <pollivie.student.42.fr>          +#+  +:+       +#+        //
//                                                +#+#+#+#+#+   +#+           //
//   Created: 2025/02/08 13:49:58 by pollivie          #+#    #+#             //
//   Updated: 2025/02/08 13:49:58 by pollivie         ###   ########.fr       //
//                                                                            //
// ************************************************************************** //

const std = @import("std");
const pg = @import("pg");
const httpz = @import("httpz");
const log = std.log;
const mem = std.mem;
const heap = std.heap;
const process = std.process;

var randomizer = std.Random.DefaultPrng.init(0);

///---------------------------------------------------------------------
/// Helper functions
///---------------------------------------------------------------------
fn clamp(value: i32, min: i32, max: i32) i32 {
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

/// Returns true if the circle at (cx,cy) with radius “radius” overlaps the rectangle
/// with top–left (rx,ry) and dimensions (rwidth, rheight).
fn circleRectCollision(cx: i32, cy: i32, radius: i32, rx: i32, ry: i32, rwidth: i32, rheight: i32) bool {
    const closestX = clamp(cx, rx, rx + rwidth);
    const closestY = clamp(cy, ry, ry + rheight);
    const dx = cx - closestX;
    const dy = cy - closestY;
    return (dx * dx + dy * dy) <= (radius * radius);
}

///---------------------------------------------------------------------
/// Collision enum used by the ball update
///---------------------------------------------------------------------
pub const BallCollision = enum {
    none,
    paddle,
    wall,
    score_left, // Ball went off the right side → left player scores.
    score_right, // Ball went off the left side → right player scores.
};

///---------------------------------------------------------------------
/// Pong game types
///---------------------------------------------------------------------
pub const Pong = struct {
    config: PongOptions = .{},
    p1: Player = .{},
    p2: Player = .{},
    ball: Ball = .{},
    board: Board = .{},

    /// Initialize a Pong game given options.
    pub fn init(config: PongOptions) Pong {
        return switch (config.game_kind) {
            .local_ai => .{
                .config = config,
                .p1 = Player.init(.p1, config),
                .p2 = Player.init(.ai, config),
                .ball = Ball.init(config),
                .board = Board.init(config),
            },
            .local_mp, .remote_mp => .{
                .config = config,
                .p1 = Player.init(.p1, config),
                .p2 = Player.init(.p2, config),
                .ball = Ball.init(config),
                .board = Board.init(config),
            },
        };
    }

    /// Update the game state.
    /// p1_input and p2_input are “direction” values (-1 for up, 0 for none, 1 for down).
    pub fn update(self: *Pong, delta_time_ms: i16, p1_input: i32, p2_input: i32) PongSnapshot {
        self.p1.update(delta_time_ms, self.board.height, p1_input, &self.ball);
        self.p2.update(delta_time_ms, self.board.height, p2_input, &self.ball);
        const collision = self.ball.update(delta_time_ms, self.board, &self.p1, &self.p2);
        switch (collision) {
            BallCollision.score_left => {
                // Right player scores when the ball goes off the right.
                self.p2.score += 1;
                self.ball.reset(self.board);
            },
            BallCollision.score_right => {
                // Left player scores when the ball goes off the left.
                self.p1.score += 1;
                self.ball.reset(self.board);
            },
            else => {},
        }
        return .{
            .game_is_playing = if (self.p1.alive and self.p2.alive) true else false,
            .game_is_waiting = if (!self.p1.alive and self.p2.alive) true else if ((self.p1.alive and !self.p2.alive)) true else false,
            .game_is_timeout = false,

            .player_1_score = self.p1.score,
            .player_2_score = self.p2.score,

            .player_1_alive = self.p1.alive,
            .player_2_alive = self.p2.alive,

            .player1_x = self.p1.position.x,
            .player1_y = self.p1.position.y,

            .player2_x = self.p2.position.x,
            .player2_y = self.p2.position.y,

            .ball_x = self.ball.position.x,
            .ball_y = self.ball.position.y,
        };
    }

    pub fn tick(self: *Pong, delta_time_ms: i16) PongSnapshot {
        const collision = self.ball.update(delta_time_ms, self.board, &self.p1, &self.p2);
        if (self.p2.kind == .ai) {
            self.p2.update(delta_time_ms, self.board.height, 0, &self.ball);
        }

        switch (collision) {
            BallCollision.score_left => {
                // Right player scores when the ball goes off the right.
                self.p2.score += 1;
                self.ball.reset(self.board);
            },
            BallCollision.score_right => {
                // Left player scores when the ball goes off the left.
                self.p1.score += 1;
                self.ball.reset(self.board);
            },
            else => {},
        }
        return .{
            .game_is_playing = if (self.p1.alive and self.p2.alive) true else false,
            .game_is_waiting = if (!self.p1.alive and self.p2.alive) true else if ((self.p1.alive and !self.p2.alive)) true else false,
            .game_is_timeout = false,

            .player_1_score = self.p1.score,
            .player_2_score = self.p2.score,

            .player_1_alive = self.p1.alive,
            .player_2_alive = self.p2.alive,

            .player1_x = self.p1.position.x,
            .player1_y = self.p1.position.y,

            .player2_x = self.p2.position.x,
            .player2_y = self.p2.position.y,

            .ball_x = self.ball.position.x,
            .ball_y = self.ball.position.y,
        };
    }
};

pub const PongKind = enum(i32) {
    local_ai = 0,
    local_mp = 1,
    remote_mp = 2,
};

pub const PongOptions = struct {
    game_kind: PongKind = .local_ai,
    max_score: i32 = 999,
    board_width: i32 = 1024,
    board_height: i32 = 512,
    paddle_width: i32 = 16,
    paddle_height: i32 = 64,
    paddle_speed: i32 = 256, // in pixels per second
    ball_radius: i32 = 8, // in pixels
    ball_speed: i32 = 256, // in pixels per second
    player_1_score: i32 = 0,
    player_2_score: i32 = 0,
    player_1_alive: bool = false,
    player_2_alive: bool = false,
    player1_x: i32 = 8,
    player1_y: i32 = 256 - 32,
    player2_x: i32 = 1024 - 16 - 8,
    player2_y: i32 = 256 - 32,
    ball_x: i32 = 512,
    ball_y: i32 = 256,

    pub fn queryFromDb(db: *pg.Pool, comptime query: []const u8, value: anytype) !PongOptions {
        var self: PongOptions = .{};
        var result = try db.rowOpts(query, value, .{ .column_names = true }) orelse {
            log.info("no config found for the game using defaults {}.", .{self});
            return self;
        };
        defer result.deinit() catch {};

        self.game_kind = @enumFromInt(result.getCol(i32, "game_kind"));
        self.max_score = result.getCol(i32, "max_score");
        self.board_width = result.getCol(i32, "board_width");
        self.board_height = result.getCol(i32, "board_height");
        self.paddle_width = result.getCol(i32, "paddle_width");
        self.paddle_height = result.getCol(i32, "paddle_height");
        self.paddle_speed = result.getCol(i32, "paddle_speed");
        self.ball_radius = result.getCol(i32, "ball_radius");
        self.ball_speed = result.getCol(i32, "ball_speed");

        const offset_x = @divTrunc(self.board_width, 100);
        const half_board = @divTrunc(self.board_height, 2);
        const half_paddle = @divTrunc(self.paddle_height, 2);

        self.player1_x = offset_x;
        self.player1_y = half_board - half_paddle;
        self.player2_x = self.board_width - (offset_x + self.paddle_width);
        self.player2_y = half_board - half_paddle;
        self.ball_x = @divTrunc(self.board_width, 2);
        self.ball_y = @divTrunc(self.board_height, 2);

        return self;
    }

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try std.json.stringify(self, .{}, writer);
    }
};

pub const PlayerKind = enum {
    p1,
    p2,
    ai,
};

///---------------------------------------------------------------------
/// Player
///---------------------------------------------------------------------
pub const Player = struct {
    kind: PlayerKind = .p1,
    position: Vector2 = .{ .x = 0, .y = 0 },
    velocity: Vector2 = .{ .x = 0, .y = 0 },
    width: i32 = 0,
    height: i32 = 0,
    speed: i32 = 0,
    score: i32 = 0,
    alive: bool = false,

    /// Initialize a player given the kind and game options.
    pub fn init(kind: PlayerKind, options: PongOptions) Player {
        const offset_x = @divTrunc(options.board_width, 100); // a small offset from the edge
        const offset_y = @divTrunc(options.board_height, 2) - @divTrunc(options.paddle_height, 2);
        return switch (kind) {
            .p1 => .{
                .kind = kind,
                .position = Vector2.init(offset_x, offset_y),
                .velocity = Vector2.init(0, 0),
                .width = options.paddle_width,
                .height = options.paddle_height,
                .speed = options.paddle_speed,
                .score = 0,
                .alive = true,
            },
            .p2, .ai => .{
                .kind = kind,
                .position = Vector2.init(options.board_width - offset_x - options.paddle_width, offset_y),
                .velocity = Vector2.init(0, 0),
                .width = options.paddle_width,
                .height = options.paddle_height,
                .speed = options.paddle_speed,
                .score = 0,
                .alive = true,
            },
        };
    }

    /// Update the paddle’s vertical position.
    /// For AI players the input_direction is ignored and the ball’s position is used.
    pub fn update(self: *Player, delta_time_ms: i16, board_height: i32, input_direction: i32, ball: *Ball) void {
        var direction: i32 = input_direction;
        if (self.kind == .ai and @mod(std.time.milliTimestamp(), 2) == 0) {
            const paddle_center = self.position.y + @divTrunc(self.height, 2);
            if (ball.position.y < paddle_center)
                direction = -1
            else if (ball.position.y > paddle_center)
                direction = 1
            else
                direction = 0;
        }
        // Compute movement: (speed * delta_time_ms)/1000 (pixels per ms)
        const move_delta = @divTrunc((self.speed * @as(i32, delta_time_ms)), 1_000);
        self.position.y += move_delta * direction;
        // Clamp paddle within the board.
        if (self.position.y < 0) {
            self.position.y = 0;
        } else if (self.position.y > board_height - self.height) {
            self.position.y = board_height - self.height;
        }
    }
};

///---------------------------------------------------------------------
/// Ball
///---------------------------------------------------------------------
pub const Ball = struct {
    position: Vector2 = .{ .x = 0, .y = 0 },
    velocity: Vector2 = .{ .x = 0, .y = 0 },
    radius: i32 = 0,
    speed: i32 = 0,

    /// Initialize the ball in the board’s center.
    pub fn init(options: PongOptions) Ball {
        const rand = randomizer.random();
        return .{
            .position = Vector2.init(@divTrunc(options.board_width, 2), @divTrunc(options.board_height, 2)),
            .velocity = Vector2.init(rand.intRangeLessThan(i32, -1, 2), rand.intRangeLessThan(i32, -1, 2)), // initially stationary; update() will serve it
            .radius = options.ball_radius,
            .speed = options.ball_speed,
        };
    }

    /// Update the ball’s position, check for wall/paddle collisions, and return a collision enum.
    pub fn update(self: *Ball, delta_time_ms: i16, board: Board, p1: *Player, p2: *Player) BallCollision {
        const rand = randomizer.random();
        // Serve the ball if not already moving.
        if (self.velocity.x == 0 and self.velocity.y == 0) {
            self.velocity = Vector2.init(@intFromFloat(rand.float(f32)), @intFromFloat(rand.float(f32)));
        }
        const move_x = @divTrunc((self.velocity.x * self.speed * @as(i32, delta_time_ms)), 1_000);
        const move_y = @divTrunc((self.velocity.y * self.speed * @as(i32, delta_time_ms)), 1_000);
        self.position.x += move_x;
        self.position.y += move_y;

        // Bounce off the top wall.
        if (self.position.y - self.radius < 0) {
            self.position.y = self.radius;
            self.velocity.y = -self.velocity.y;
            return BallCollision.wall;
        }
        // Bounce off the bottom wall.
        if (self.position.y + self.radius > board.height) {
            self.position.y = board.height - self.radius;
            self.velocity.y = -self.velocity.y;
            return BallCollision.wall;
        }

        // Check collision with player 1 paddle.
        if (circleRectCollision(self.position.x, self.position.y, self.radius, p1.position.x, p1.position.y, p1.width, p1.height)) {
            self.velocity.x = -self.velocity.x;
            return BallCollision.paddle;
        }
        // Check collision with player 2 paddle.
        if (circleRectCollision(self.position.x, self.position.y, self.radius, p2.position.x, p2.position.y, p2.width, p2.height)) {
            self.velocity.x = -self.velocity.x;
            return BallCollision.paddle;
        }

        // Off the left side: score for the right player.
        if (self.position.x + self.radius < 0) {
            return BallCollision.score_right;
        }
        // Off the right side: score for the left player.
        if (self.position.x - self.radius > board.width) {
            return BallCollision.score_left;
        }

        return BallCollision.none;
    }

    /// Reset the ball to the center and make it stationary (it will be re–served on the next update).
    pub fn reset(self: *Ball, board: Board) void {
        const rand = randomizer.random();
        self.position = Vector2.init(@divTrunc(board.width, 2), @divTrunc(board.height, 2));
        self.velocity = Vector2.init(rand.intRangeLessThan(i32, -1, 2), rand.intRangeLessThan(i32, -1, 2));
    }
};

///---------------------------------------------------------------------
/// Board
///---------------------------------------------------------------------
pub const Board = struct {
    position: Vector2 = .{ .x = 0, .y = 0 },
    width: i32 = 0,
    height: i32 = 0,

    pub fn init(options: PongOptions) Board {
        return .{
            .position = Vector2.init(0, 0),
            .width = options.board_width,
            .height = options.board_height,
        };
    }
};

///---------------------------------------------------------------------
/// Vector2 (for positions and velocities)
///---------------------------------------------------------------------
pub const Vector2 = struct {
    x: i32 = 0,
    y: i32 = 0,

    pub fn init(x: i32, y: i32) Vector2 {
        return .{
            .x = x,
            .y = y,
        };
    }
};

///---------------------------------------------------------------------
/// A snapshot of the game state (e.g. for rendering or network updates)
///---------------------------------------------------------------------
pub const PongSnapshot = struct {
    game_is_playing: bool = false,
    game_is_waiting: bool = false,
    game_is_timeout: bool = false,

    player_1_score: i32 = 0,
    player_2_score: i32 = 0,

    player_1_alive: bool = false,
    player_2_alive: bool = false,

    player1_x: i32 = 0,
    player1_y: i32 = 0,

    player2_x: i32 = 0,
    player2_y: i32 = 0,

    ball_x: i32 = 0,
    ball_y: i32 = 0,

    player_1_won: bool = false,
    player_2_won: bool = false,

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try std.json.stringify(self, .{}, writer);
    }
};
