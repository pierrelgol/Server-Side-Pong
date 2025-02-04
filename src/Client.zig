// ************************************************************************** //
//                                                                            //
//                                                        :::      ::::::::   //
//   Client.zig                                         :+:      :+:    :+:   //
//                                                    +:+ +:+         +:+     //
//   By: pollivie <pollivie.student.42.fr>          +#+  +:+       +#+        //
//                                                +#+#+#+#+#+   +#+           //
//   Created: 2025/02/04 12:47:07 by pollivie          #+#    #+#             //
//   Updated: 2025/02/04 12:47:07 by pollivie         ###   ########.fr       //
//                                                                            //
// ************************************************************************** //

const std = @import("std");
const log = std.log;
const mem = std.mem;
const heap = std.heap;
const httpz = @import("httpz");
const pg = @import("pg");
const GamePool = @import("GamePool.zig");
const Client = @This();

player_id: []const u8,
game: *GamePool.Game,

pub fn init(player_id: []const u8, game: *GamePool.Game) Client {
    log.info("new client {s}.", .{player_id});
    return .{
        .player_id = player_id,
        .game = game,
    };
}
