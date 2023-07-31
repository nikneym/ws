const std = @import("std");
const mem = std.mem;
const io = std.io;
const common = @import("common.zig");
const Opcode = common.Opcode;
const Header = common.Header;

const MAX_CTL_FRAME_LENGTH = common.MAX_CTL_FRAME_LENGTH;
const MASK_BUFFER_SIZE: usize = 1024;
const DEFAULT_CLOSE_CODE: u16 = 1000;

fn getUriFullPath(uri: std.Uri) ![]const u8 {
    var buf: [MASK_BUFFER_SIZE]u8 = undefined;
    return try std.fmt.bufPrint(&buf, "{}", .{uri});
}

pub fn Sender(comptime Writer: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        writer: Writer,
        mask: [4]u8,
        // for buffered writes
        buffer: [capacity]u8 = undefined,
        end: usize = 0,

        pub fn sendRequest(
            self: *Self,
            uri: std.Uri,
            request_headers: ?[]const [2][]const u8,
            sec_websocket_key: []const u8,
        ) !void {
            // push http request line
            try self.put("GET ");
            try self.put(try getUriFullPath(uri));
            try self.put(" HTTP/1.1\r\n");

            // push default headers
            const default_headers =
                "Pragma: no-cache\r\n" ++
                "Cache-Control: no-cache\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Sec-WebSocket-Version: 13\r\n";
            try self.put(default_headers);

            // push websocket key
            try self.put("Sec-WebSocket-Key: ");
            try self.put(sec_websocket_key);
            try self.put("\r\n");

            // push user defined headers
            if (request_headers) |headers| {
                for (headers) |header| {
                    try self.put(header[0]);
                    try self.put(": ");
                    try self.put(header[1]);
                    try self.put("\r\n");
                }
            }

            // send 'em all 
            try self.put("\r\n");
            return self.flush();
        }

        /// Write bytes that're buffered in Sender and reset the terminator.
        fn flush(self: *Self) Writer.Error!void {
            try self.writer.writeAll(self.buffer[0..self.end]);
            self.end = 0;
        }

        /// Does buffered writes, pretty similar to io.BufferedWriter.
        fn put(self: *Self, bytes: []const u8) Writer.Error!void {
            if (self.end + bytes.len > self.buffer.len) {
                try self.flush();
                if (bytes.len > self.buffer.len)
                    return self.writer.writeAll(bytes);
            }

            mem.copy(u8, self.buffer[self.end..], bytes);
            self.end += bytes.len;
        }

        fn putHeader(self: *Self, header: Header) Writer.Error!void {
            var buf: [14]u8 = undefined;

            buf[0] = @as(u8, @intFromEnum(header.opcode));
            if (header.fin) buf[0] |= 0x80;

            buf[1] = 0x80;
            if (header.len < 126) {
                buf[1] |= @truncate(header.len);
                mem.copy(u8, buf[2..], &self.mask);

                // 2 + 4
                return self.put(buf[0..6]);
            } else if (header.len < 65536) {
                buf[1] |= 126;
                mem.writeIntBig(u16, buf[2..4], @as(u16, @truncate(header.len)));
                mem.copy(u8, buf[4..], &self.mask);

                // 2 + 2 + 4
                return self.put(buf[0..8]);
            } else {
                buf[1] |= 127;
                mem.writeIntBig(u64, buf[2..10], header.len);
                mem.copy(u8, buf[10..], &self.mask);

                // 2 + 8 + 4
                return self.put(&buf);
            }

            unreachable;
        }

        fn maskBytes(self: Self, buf: []u8, source: []const u8, pos: usize) void {
            for (source, 0..) |c, i|
                buf[i] = c ^ self.mask[(i + pos) % 4];
        }

        fn putMasked(self: *Self, data: []const u8) Writer.Error!void {
            var buf: [MASK_BUFFER_SIZE]u8 = undefined;

            // small payload, cool stuff!
            if (data.len <= MASK_BUFFER_SIZE) {
                self.maskBytes(buf[0..data.len], data, 0);
                return self.put(buf[0..data.len]);
            }

            const remainder = data.len % MASK_BUFFER_SIZE;
            const num_of_chunks = (data.len - remainder) / MASK_BUFFER_SIZE;
            var current_chunk: usize = 0;
            var pos: usize = 0;

            while (current_chunk < num_of_chunks) : (current_chunk += 1) {
                pos = current_chunk * MASK_BUFFER_SIZE;
                const chunk = data[pos..pos + MASK_BUFFER_SIZE];

                self.maskBytes(buf[0..], chunk, pos);
                try self.put(buf[0..]);
            }

            if (remainder == 0)
                return;

            // got remainder
            pos += MASK_BUFFER_SIZE;
            const chunk = data[pos..pos + remainder];

            self.maskBytes(&buf, chunk, pos);
            return self.put(buf[0..remainder]);
        }

        // ----------------------------------
        // Send API
        // ----------------------------------

        /// Send a WebSocket message.
        pub fn send(self: *Self, opcode: Opcode, data: []const u8) !void {
            return switch (opcode) {
                .text, .binary => self.regular(opcode, data),
                .ping, .pong => self.pingPong(opcode, data),
                .close => self.close(),

                .continuation, .end => error.UseStreamInstead,
                else => error.UnknownOpcode,
            };
        }

        // text + binary messages
        fn regular(self: *Self, opcode: Opcode, data: []const u8) !void {
            try self.putHeader(.{
                .len = data.len,
                .opcode = opcode,
                .fin = true,
            });
            try self.putMasked(data);

            return self.flush();
        }

        // the name implies
        fn pingPong(self: *Self, opcode: Opcode, data: []const u8) !void {
            if (data.len > MAX_CTL_FRAME_LENGTH)
                return error.PayloadTooBig;

            try self.putHeader(.{
                .len = data.len,
                .opcode = opcode,
                .fin = true,
            });
            try self.putMasked(data);

            return self.flush();
        }

        // TODO: implement close code & reason.
        pub fn close(self: *Self) !void {
            try self.putHeader(.{
                .len = 0,
                .opcode = .close,
                .fin = true,
            });

            return self.flush();
        }

        // ----------------------------------
        // Stream API
        // ----------------------------------

        /// writes data piece by piece, good for streaming big or unknown amounts of data as chunks.
        pub fn stream(self: *Self, opcode: Opcode, payload: ?[]const u8) !void {
            if (payload) |data| {
                return switch (opcode) {
                    .text, .binary => self.fragmented(opcode, data, false),
                    .continuation => self.fragmented(opcode, data, false),
                    .end => self.fragmented(.continuation, data, true),

                    else => error.UnknownOpcode,
                };
            }

            try self.putHeader(.{
                .len = 0,
                .opcode = switch (opcode) {
                    .text, .binary,
                    .continuation => opcode,
                    .end => .continuation,

                    else => return error.UnknownOpcode,
                },
                .fin = switch (opcode) {
                    .text, .binary,
                    .continuation => false,
                    .end => true,

                    else => return error.UnknownOpcode,
                },
            });

            return self.flush();
        }

        fn fragmented(self: *Self, opcode: Opcode, data: []const u8, fin: bool) !void {
            try self.putHeader(.{
                .len = data.len,
                .opcode = opcode,
                .fin = fin,
            });
            try self.putMasked(data);

            return self.flush();
        }
    };
}

test "std.Uri processing results in expected paths" {
    const uris = [_]std.Uri {
        try std.Uri.parse("ws://localhost"),
        try std.Uri.parse("ws://localhost/"),
        try std.Uri.parse("ws://localhost?query=example"),
        try std.Uri.parse("ws://localhost/?query=example"),
        try std.Uri.parse("ws://localhost/?query1=&&something&query2=somethingelse"),
        try std.Uri.parse("ws://localhost/?query1=something with spaces&query2=somethingelse"),
        try std.Uri.parse("ws://localhost:8080"),
        try std.Uri.parse("ws://localhost:8080/"),
        try std.Uri.parse("ws://localhost:8080?query=example"),
        try std.Uri.parse("ws://localhost:8080/?query=example"),
        try std.Uri.parse("ws://localhost:8080/?query1=&&something&query2=somethingelse"),
        try std.Uri.parse("ws://localhost:8080/?query1=something with spaces&query2=somethingelse"),
    };

    const paths = [_][]const u8{
        "/",
        "/",
        "/?query=example",
        "/?query=example",
        "/?query1=&&something&query2=somethingelse",
        "/?query1=something%20with%20spaces&query2=somethingelse",
        "/",
        "/",
        "/?query=example",
        "/?query=example",
        "/?query1=&&something&query2=somethingelse",
        "/?query1=something%20with%20spaces&query2=somethingelse",
    };
    
    for (uris, paths) |uri, path| {
        try std.testing.expectEqualSlices(u8, path, try getUriFullPath(uri));
    }
}
