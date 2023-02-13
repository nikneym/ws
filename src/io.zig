const std = @import("std");
const mem = std.mem;
const common = @import("common.zig");
const Header = common.Header;
const Opcode = common.Opcode;
const Message = common.Message;

const MASK_BUFFER_SIZE: usize = 1024;

pub const Strategy = enum {
    server,
    client,
};

pub fn SenderImpl(
    comptime Writer: type,
    comptime strategy: Strategy,
) type {
    return struct {
        const Self = @This();

        writer: Writer,
        mask: [4]u8,

        // Server sends messages masked but Client sends unmasked
        // these mixins here creates proper functions for both situations
        pub usingnamespace switch (strategy) {
            // Server strategy implementation
            .server => struct {
                /// Sends the header without mask.
                pub fn sendHeader(self: Self, header: Header) !void {
                    // we don't let server to send masked messages so buffer here can have max 10 bytes
                    var buf: [10]u8 = undefined;
                    buf[0] = @as(u8, @enumToInt(header.opcode));
                    if (header.fin) buf[0] |= 0x80;

                    buf[1] = 0;
                    if (header.len < 126) {
                        buf[1] |= @truncate(u8, header.len);

                        // send buf[0..2]
                        return self.writer.writeAll(buf[0..2]);
                    } else if (header.len < 65536) {
                        buf[1] |= 126;
                        mem.writeIntBig(u16, buf[2..4], @truncate(u16, header.len));

                        // send buf[0..4]
                        return self.writer.writeAll(buf[0..4]);
                    } else {
                        buf[1] |= 127;
                        mem.writeIntBig(u64, buf[2..10], header.len);

                        // send it all
                        return self.writer.writeAll(&buf);
                    }

                    unreachable;
                }

                /// Sends unmasked message.
                pub fn sendMessage(self: Self, opcode: Opcode, payload: []const u8) !void {
                    try self.sendHeader(.{
                        .len = payload.len,
                        .opcode = opcode,
                        .fin = true,
                    });

                    return self.writer.writeAll(payload);
                }
            },

            // Client strategy implementation
            .client => struct {
                pub fn sendHeader(self: Self, header: Header) !void {
                    // max client header size is 14 (mask included)
                    var buf: [14]u8 = undefined;

                    buf[0] = @as(u8, @enumToInt(header.opcode));
                    if (header.fin) buf[0] |= 0x80;

                    buf[1] = 0x80;
                    if (header.len < 126) {
                        buf[1] |= @truncate(u8, header.len);
                        mem.copy(u8, buf[2..], &self.mask);

                        // 2 + 4
                        return self.writer.writeAll(buf[0..6]);
                    } else if (header.len < 65536) {
                        buf[1] |= 126;
                        mem.writeIntBig(u16, buf[2..4], @truncate(u16, header.len));
                        mem.copy(u8, buf[4..], &self.mask);

                        // 2 + 2 + 4
                        return self.writer.writeAll(buf[0..8]);
                    } else {
                        buf[1] |= 127;
                        mem.writeIntBig(u64, buf[2..10], @intCast(u64, header.len));
                        mem.copy(u8, buf[10..], &self.mask);

                        // 2 + 8 + 4
                        return self.writer.writeAll(&buf);
                    }

                    unreachable;
                }

                pub fn sendMessage(self: Self, opcode: Opcode, payload: []const u8) !void {
                    try self.sendHeader(.{
                        .len = payload.len,
                        .opcode = opcode,
                        .fin = true,
                    });

                    var buf: [MASK_BUFFER_SIZE]u8 = undefined;

                    // small payload, cool stuff!
                    if (payload.len <= MASK_BUFFER_SIZE) {
                        self.maskBytes(buf[0..payload.len], payload, 0);
                        return self.put(buf[0..payload.len]);
                    }

                    const remainder = payload.len % MASK_BUFFER_SIZE;
                    const num_of_chunks = (payload.len - remainder) / MASK_BUFFER_SIZE;
                    var current_chunk: usize = 0;
                    var pos: usize = 0;

                    while (current_chunk < num_of_chunks) : (current_chunk += 1) {
                        pos = current_chunk * MASK_BUFFER_SIZE;
                        const chunk = payload[pos..pos + MASK_BUFFER_SIZE];

                        self.maskBytes(buf[0..], chunk, pos);
                        try self.writer.writeAll(buf[0..]);
                    }

                    if (remainder == 0)
                        return;

                    // got remainder
                    pos += MASK_BUFFER_SIZE;
                    const chunk = payload[pos..pos + remainder];

                    self.maskBytes(&buf, chunk, pos);
                    return self.writer.writeAll(buf[0..remainder]);
                }

                fn maskBytes(self: Self, buf: []u8, source: []const u8, pos: usize) void {
                    for (source) |c, i|
                        buf[i] = c ^ self.mask[(i + pos) % 4];
                }

                fn sendRequest(
                    self: Self,
                    path: []const u8,
                    request_headers: ?[]const [2][]const u8,
                    sec_websocket_key: []const u8,
                ) !void {
                    try self.writer.writeAll("GET ");
                    try self.writer.writeAll(path);
                    try self.writer.writeAll(" HTTP/1.1\r\n");

                    // push default headers
                    const default_headers =
                        "Pragma: no-cache\r\n" ++
                        "Cache-Control: no-cache\r\n" ++
                        "Connection: Upgrade\r\n" ++
                        "Upgrade: websocket\r\n" ++
                        "Sec-WebSocket-Version: 13\r\n";
                    try self.writer.writeAll(default_headers);

                    // push websocket key
                    try self.writer.writeAll("Sec-WebSocket-Key: ");
                    try self.writer.writeAll(sec_websocket_key);
                    try self.writer.writeAll("\r\n");

                    if (request_headers) |headers| {
                        for (headers) |header| {
                            try self.writer.writeAll(header[0]);
                            try self.writer.writeAll(": ");
                            try self.writer.writeAll(header[1]);
                            try self.writer.writeAll("\r\n");
                        }
                    }

                    return self.writer.writeAll("\r\n");
                }
            },
        };

        /// Send a WebSocket message.
        pub fn send(self: Self, opcode: Opcode, payload: []const u8) !void {
            return switch(opcode) {
                .text, .binary => self.sendMessage(opcode, payload),
                .ping, .pong => {
                    if (payload.len > common.MAX_CTL_FRAME_LENGTH)
                        return error.PayloadTooBig;

                    return self.sendMessage(opcode, payload);
                },
                //TODO: implement close with reason and close code
                .close => return error.UseCloseInstead,
                // definite error situations
                // TODO: implement continuation frames
                .continuation, .end => return error.UseStreamInstead,
                else => error.UnknownOpcode,
            };
        }

        // TODO: implement close code & reason
        pub fn close(self: Self) !void {
            return self.sendHeader(.{
                .len = 0,
                .opcode = .close,
                .fin = true,
            });
        }
    };
}

pub const Options = struct {
    
};

// TODO: Receiver
pub fn ReceiverImpl(
    comptime Reader: type,
    comptime strategy: Strategy,
) type {
    return struct {
        const Self = @This();

        reader: Reader,
        buffer: []u8,
        control_buffer: [common.MAX_CTL_FRAME_LENGTH]u8 = undefined,

        /// Only call this function if you've heap allocated `buffer`.
        pub fn deinit(self: Self, allocator: mem.Allocator) void {
            allocator.free(self.buffer);
        }

        pub usingnamespace switch (strategy) {
            .server => struct {
                // Server always receives masked
                pub fn readHeader(self: Self) !Header {
                    var buf: [8]u8 = undefined;
                    const len = try self.reader.readAll(buf[0..2]);
                    if (len < 2) return error.EndOfStream;

                    const fin = buf[0] & 0x80 != 0;
                    const rsv1 = buf[0] & 0x40 != 0;
                    const rsv2 = buf[0] & 0x20 != 0;
                    const rsv3 = buf[0] & 0x10 != 0;

                    const opcode = @intToEnum(Opcode, @truncate(u4, buf[0] & 0x0F));

                    // TODO: check if message is masked or not here
                    // ...

                    const var_length = @truncate(u7, buf[1] & 0x7F);
                    const length = try self.getLength(var_length, &buf);

                    return Header{
                        .len = length,
                        .opcode = opcode,
                        .fin = fin,
                        .rsv1 = rsv1,
                        .rsv2 = rsv2,
                        .rsv3 = rsv3,
                    };
                }

                // server have to decode masked data.
                pub fn readMessage(self: *Self) !Message {
                    // get header
                    const header = try self.readHeader();

                    // get mask
                    var mask: [4]u8 = undefined;
                    var len = try self.reader.readAll(&mask);
                    if (len < mask.len) return error.EndOfStream;

                    switch (header.opcode) {
                        .text, .binary => {
                            // read the encoded bytes
                            const reserved = self.buffer[0..header.len];
                            len = try self.reader.readAll(reserved);
                            if (len < header.len) return error.EndOfStream;

                            // decode with mask
                            for (reserved) |b, i|
                                reserved[i] = b ^ mask[i % mask.len];

                            return .{ .type = header.opcode, .data = reserved, .code = null };
                        },

                        .ping, .pong => {
                            // control frames can only be 125 bytes long
                            if (header.len > common.MAX_CTL_FRAME_LENGTH)
                                return error.PayloadTooBig;

                            const reserved = self.control_buffer[0..header.len];
                            len = try self.reader.readAll(reserved);
                            if (len < header.len) return error.EndOfStream;

                            for (reserved) |b, i|
                                reserved[i] = b ^ mask[i % mask.len];

                            return .{ .type = header.opcode, .data = reserved, .code = null };
                        },

                        .close => {
                            // control frames can only be 125 bytes long
                            if (header.len > common.MAX_CTL_FRAME_LENGTH)
                                return error.PayloadTooBig;

                            const reserved = self.control_buffer[0..header.len];
                            len = try self.reader.readAll(reserved);
                            if (len < header.len) return error.EndOfStream;

                            switch (@truncate(u7, header.len)) {
                                // only close message
                                0 => return .{ .type = header.opcode, .data = reserved, .code = null },
                                // without reason but code
                                2 => {
                                    for (reserved) |b, i|
                                        reserved[i] = b ^ mask[i % mask.len];

                                    const code = mem.readIntBig(u16, reserved[0..2]);
                                    return .{ .type = header.opcode, .data = reserved, .code = code };
                                },
                                // with reason
                                inline else => {
                                    for (reserved) |b, i|
                                        reserved[i] = b ^ mask[i % mask.len];

                                    const code = mem.readIntBig(u16, reserved[0..2]);
                                    const reason = reserved[2..];
                                    return .{ .type = header.opcode, .data = reason, .code = code };
                                },
                            }

                            unreachable;
                        },

                        // TODO: implement continuation frames
                        .continuation => return error.NotYetImplemented,
                        else => return error.UnknownOpcode,
                    }

                    unreachable;
                }
            },

            .client => struct {

            },
        };

        /// `buf` passed to this function must be 8 bytes long.
        fn getLength(self: Self, var_length: u7, buf: []u8) (Reader.Error || error{EndOfStream})!u64 {
            return switch (var_length) {
                126 => {
                    const len = try self.reader.readAll(buf[0..2]);
                    if (len < 2) return error.EndOfStream;

                    return mem.readIntBig(u16, buf[0..2]);
                },

                127 => {
                    const len = try self.reader.readAll(buf[0..8]);
                    if (len < 8) return error.EndOfStream;

                    return mem.readIntBig(u64, buf[0..8]);
                },

                inline else => var_length,
            };
        }

        pub fn receive(self: *Self) !Message {
            return self.readMessage();
        }
    };
}
