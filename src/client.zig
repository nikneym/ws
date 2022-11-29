const std = @import("std");
const mem = std.mem;

const Receiver = @import("receiver.zig").Receiver;
const Sender = @import("sender.zig").Sender;

pub fn createClient(
    reader: anytype,
    writer: anytype,
    comptime read_buffer_size: usize,
    comptime write_buffer_size: usize,
) Client(@TypeOf(reader), @TypeOf(writer), read_buffer_size, write_buffer_size)
{
    return .{
        .receiver = .{ .reader = reader },
        .sender = .{ .writer = writer },
    };
}

pub fn Client(
    comptime Reader: type,
    comptime Writer: type,
    comptime read_buffer_size: usize,
    comptime write_buffer_size: usize,
) type {
    return struct {
        const Self = @This();

        receiver: Receiver(Reader, read_buffer_size),
        sender: Sender(Writer, write_buffer_size),
    };
}
