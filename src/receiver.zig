const std = @import("std");
const mem = std.mem;
const common = @import("common.zig");
const Opcode = common.Opcode;
const Header = common.Header;
const Message = common.Message;

const MAX_CTL_FRAME_LENGTH = common.MAX_CTL_FRAME_LENGTH;
// max header size can be 10 * u8,
// if masking is allowed, header size can be up to 14 * u8
// server should not be sending masked messages.
const MAX_HEADER_SIZE = 10;

pub fn Receiver(comptime Reader: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        reader: Reader,
        buffer: [capacity]u8 = undefined,
        header_buffer: [MAX_HEADER_SIZE]u8 = undefined,
        // specified for ping, pong and close frames.
        control_buffer: [MAX_CTL_FRAME_LENGTH]u8 = undefined,
        end: usize = 0,
        fragmentation: Fragmentation = .{},

        const Fragmentation = struct {
            on: bool = false,
            opcode: Opcode = .text,
        };

        /// Deallocate HTTP response headers and string hashmap.
        pub fn freeHttpHeaders(
            _: Self,
            allocator: mem.Allocator,
            headers: *std.StringHashMapUnmanaged([]const u8),
        ) void {
            defer headers.deinit(allocator);
            var iter = headers.iterator();
            while (iter.next()) |entry| {
                //std.debug.print("{s}: {s}\n", .{entry.key_ptr.*, entry.value_ptr.*});
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
        }

        /// Receive and allocate for HTTP headers, uses a StringHashMapUnmanaged([]const u8) to store the parsed headers.
        pub fn receiveResponse(
            self: Self,
            allocator: mem.Allocator,
            headers: *std.StringHashMapUnmanaged([]const u8),
        ) !void {
            errdefer self.freeHttpHeaders(allocator, headers);
            var buf: [2048]u8 = undefined;
            var i: usize = 0;
            var state: enum { key, value } = .key;
            var key_ptr: ?[]u8 = null;

            // HTTP/1.1 101 Switching Protocols
            const request_line = try self.reader.readUntilDelimiter(&buf, '\n');
            if (request_line.len < 32) return error.FailedSwitchingProtocols;
            if (!mem.eql(u8, request_line[0..32], "HTTP/1.1 101 Switching Protocols"))
                return error.FailedSwitchingProtocols;

            while (true) {
                const b = try self.reader.readByte();
                switch (state) {
                    .key => switch (b) {
                        ':' => { // delimiter of key
                            // make sure space comes afterwards
                            if (try self.reader.readByte() == ' ') {
                                key_ptr = try allocator.dupe(u8, buf[0..i]);
                                i = 0;
                                state = .value;
                            } else {
                                return error.BadHttpResponse;
                            }
                        },
                        '\r' => {
                            if (try self.reader.readByte() == '\n') break;
                            return error.BadHttpResponse;
                        },
                        '\n' => break,

                        else => {
                            buf[i] = b;
                            if (i < buf.len) {
                                i += 1;
                            } else {
                                return error.HttpHeaderTooLong;
                            }
                        },
                    },

                    .value => switch (b) {
                        '\r' => {
                            // make sure '\n' comes afterwards
                            if (try self.reader.readByte() == '\n') {
                                if (key_ptr) |ptr| {
                                    errdefer allocator.free(ptr);
                                    if (headers.contains(ptr)) {
                                        return error.RepeatingHttpHeader;
                                        // FIXME: alternative
                                        //const entry = headers.getEntry(ptr).?;
                                        //allocator.free(entry.key_ptr.*);
                                        //allocator.free(entry.value_ptr.*);
                                    }

                                    try headers.put(allocator, ptr, try allocator.dupe(u8, buf[0..i]));
                                } else {
                                    return error.BadHttpResponse;
                                }

                                i = 0;
                                state = .key;
                            } else {
                                return error.BadHttpResponse;
                            }
                        },

                        else => {
                            buf[i] = b;
                            if (i < buf.len) {
                                i += 1;
                            } else {
                                return error.HttpHeaderTooLong;
                            }
                        },
                    },
                }
            }
        }

        pub const GetHeaderError = error{EndOfStream} || Header.Error || Reader.Error;

        fn getHeader(self: *Self) GetHeaderError!Header {
            const buf = self.header_buffer[0..2];

            const len = try self.reader.readAll(buf);
            if (len < 2) return error.EndOfStream;

            const is_masked = buf[1] & 0x80 != 0;
            if (is_masked)
                return error.MaskedMessageFromServer; // FIXME: should this be allowed?

            // get length from variable length
            const var_length: u7 = @truncate(buf[1] & 0x7F);
            const length = try self.getLength(var_length);

            const b = buf[0];
            const fin = b & 0x80 != 0;
            const rsv1 = b & 0x40 != 0;
            const rsv2 = b & 0x20 != 0;
            const rsv3 = b & 0x10 != 0;

            const op = b & 0x0F;
            const opcode: Opcode = @enumFromInt(@as(u4, @truncate(op)));

            return Header{
                .len = length,
                .opcode = opcode,
                .fin = fin,
                .rsv1 = rsv1,
                .rsv2 = rsv2,
                .rsv3 = rsv3,
            };
        }

        pub const GetLengthError = error{EndOfStream} || Reader.Error;

        fn getLength(self: *Self, var_length: u7) GetLengthError!u64 {
            return switch (var_length) {
                126 => {
                    const len = try self.reader.readAll(self.header_buffer[2..4]);
                    if (len < 2) return error.EndOfStream;

                    return mem.readIntBig(u16, self.header_buffer[2..4]);
                },

                127 => {
                    const len = try self.reader.readAll(self.header_buffer[2..]);
                    if (len < 8) return error.EndOfStream;

                    return mem.readIntBig(u64, self.header_buffer[2..]);
                },

                inline else => var_length,
            };
        }

        fn pingPong(self: *Self, header: Header) FrameError!Message {
            if (header.len > self.control_buffer.len)
                return error.PayloadTooBig;

            const buf = self.control_buffer[0..header.len];

            const len = try self.reader.readAll(buf);
            if (len < buf.len)
                return error.EndOfStream;

            return Message.from(header.opcode, buf, null);
        }

        fn close(self: *Self, header: Header) FrameError!Message {
            if (header.len > self.control_buffer.len)
                return error.PayloadTooBig;

            const buf = self.control_buffer[0..header.len];

            const len = try self.reader.readAll(buf);
            if (len < buf.len)
                return error.EndOfStream;

            return switch (buf.len) {
                0 => Message.from(.close, buf, null),

                2 => { // without reason but code
                    const code = mem.readIntBig(u16, buf[0..2]);

                    return Message.from(.close, buf, code);
                },

                else => { // with reason
                    const code = mem.readIntBig(u16, buf[0..2]);
                    const reason = buf[2..];

                    return Message.from(.close, reason, code);
                }
            };
        }

        pub const ContinuationError = error{UnknownOpcode} || FrameError || GetHeaderError;

        // this must be called when continuation frame is received
        fn continuation1(self: *Self, header: Header) (error{BadMessageOrder} || ContinuationError)!Message {
            if (!self.fragmentation.on)
                return error.BadMessageOrder;

            var last: Header = header;
            while (true) : (last = try self.getHeader()) {
                switch (last.opcode) {
                    .continuation => {},
                    .text, .binary => return error.BadMessageOrder,
                    .ping, .pong => return self.pingPong(last),
                    .close => return self.close(last),

                    else => return error.UnknownOpcode,
                }

                const boundary = self.end + last.len;
                if (boundary > self.buffer.len)
                    return error.PayloadTooBig;

                const buf = self.buffer[self.end..boundary];

                const len = try self.reader.readAll(buf);
                if (len < buf.len)
                    return error.EndOfStream;

                self.end = boundary;
                if (last.fin) break;
            }

            const buf = self.buffer[0..self.end];
            self.end = 0;

            return Message.from(self.fragmentation.opcode, buf, null);
        }

        // this must be called when text or binary frame without fin is received
        fn continuation(self: *Self, header: Header) ContinuationError!Message {
            // keep track of fragmentation
            self.fragmentation.on = true;
            self.fragmentation.opcode = header.opcode;

            var last: Header = header;
            // any of the control frames might sneak in to this while loop,
            // beware!
            while (true) : (last = try self.getHeader()) {
                switch (last.opcode) {
                    .text, .binary, .continuation => {},
                    // disturbed
                    .ping, .pong => return self.pingPong(last),
                    .close => return self.close(last),

                    else => return error.UnknownOpcode,
                }

                const boundary = self.end + last.len;
                if (boundary > self.buffer.len)
                    return error.PayloadTooBig;

                const buf = self.buffer[self.end..boundary];

                const len = try self.reader.readAll(buf);
                if (len < buf.len)
                    return error.EndOfStream;

                self.end = boundary;
                if (last.fin) break;
            }

            const buf = self.buffer[0..self.end];
            self.end = 0;

            return Message.from(self.fragmentation.opcode, buf, null);
        }

        pub const FrameError = error{
            EndOfStream,
            PayloadTooBig,
        } || Message.Error || Reader.Error;

        fn regular(self: *Self, header: Header) FrameError!Message {
            const boundary = self.end + header.len;

            if (boundary > self.buffer.len)
                return error.PayloadTooBig;

            const buf = self.buffer[self.end..boundary];

            const len = try self.reader.readAll(buf);
            if (len < buf.len)
                return error.EndOfStream;

            return Message.from(header.opcode, buf, null);
        }

        pub const Error = error{BadMessageOrder} || Header.Error || FrameError || ContinuationError;

        /// Receive the next message from the stream.
        pub fn receive(self: *Self) Error!Message {
            const header = try self.getHeader();

            return switch (header.opcode) {
                .continuation => self.continuation1(header),
                .text, .binary => switch (header.fin) {
                    true => self.regular(header),
                    false => self.continuation(header),
                },

                // control frames
                .ping, .pong => self.pingPong(header),
                .close => self.close(header),

                else => error.UnknownOpcode,
            };
        }
    };
}
