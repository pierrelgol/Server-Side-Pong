// ************************************************************************** //
//                                                                            //
//                                                        :::      ::::::::   //
//   Results.zig                                        :+:      :+:    :+:   //
//                                                    +:+ +:+         +:+     //
//   By: pollivie <pollivie.student.42.fr>          +#+  +:+       +#+        //
//                                                +#+#+#+#+#+   +#+           //
//   Created: 2025/02/11 16:07:31 by pollivie          #+#    #+#             //
//   Updated: 2025/02/11 16:07:32 by pollivie         ###   ########.fr       //
//                                                                            //
// ************************************************************************** //

const std = @import("std");
const mem = std.mem;
const net = std.net;
const heap = std.heap;
const http = std.http;
const json = std.json;
const Snapshot = @import("Pong.zig").PongSnapshot;

pub const Results = struct {
    arena: heap.ArenaAllocator,
    value: ResultValues,

    pub fn init(allocator: mem.Allocator, snapshot: Snapshot, game_id: i32) Results {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .value = ResultValues.init(snapshot, game_id),
        };
    }

    pub fn deinit(self: *Results) void {
        self.arena.deinit();
    }

    pub fn postResults(self: *Results, url: []const u8) !void {
        var client: std.http.Client = .{
            .allocator = self.arena.allocator(),
        };
        defer client.deinit();

        const options: http.Client.FetchOptions = .{
            .headers = .{
                .content_type = .{
                    .override = "application/json",
                },
            },
            .method = .POST,
            .keep_alive = false,
            .location = .{ .url = url },
            .payload = try self.value.toJson(self.arena.allocator()),
        };

        _ = try client.fetch(options);
    }

    pub const ResultValues = struct {
        key: []const u8 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        game_id: i32 = 1,
        score1: i32 = 0,
        score2: i32 = 0,
        winner: []const u8 = "player1",
        duration: i64 = 0,

        pub fn init(snapshot: Snapshot, game_id: i32) ResultValues {
            var self: ResultValues = .{};
            self.game_id = game_id;
            self.score1 = snapshot.player_1_score;
            self.score2 = snapshot.player_2_score;
            self.winner = if (self.score1 > self.score2) "player1" else "player2";
            self.duration = std.time.milliTimestamp();
            return self;
        }

        pub fn toJson(self: ResultValues, allocator: mem.Allocator) ![]const u8 {
            return try json.stringifyAlloc(allocator, self, .{});
        }

        pub fn format(
            self: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = options;
            _ = fmt;
            try json.stringify(self, .{}, writer);
        }
    };
};
