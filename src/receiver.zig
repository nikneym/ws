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

        // TODO
        pub fn receiveResponse(self: Self) !void {
            var buf: [4096]u8 = undefined;
            while (true) {
                const header = try self.reader.readUntilDelimiter(buf[0..], '\n');
                if (header.len == 1) break;
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
            const var_length = @truncate(u7, buf[1] & 0x7F);
            const length = try self.getLength(var_length);

            const b = buf[0];
            const fin = b & 0x80 != 0;
            const rsv1 = b & 0x40 != 0;
            const rsv2 = b & 0x20 != 0;
            const rsv3 = b & 0x10 != 0;

            const op = b & 0x0F;
            const opcode = @intToEnum(Opcode, @truncate(u4, op));

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

                // FIXME: inline?
                else => var_length,
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
