// maximum control frame length
pub const MAX_CTL_FRAME_LENGTH = 125;

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    // this one is custom for this implementation.
    // see how it's used in sender.zig.
    end = 0xF,
    _,
};

pub const Header = packed struct {
    len: u64,
    opcode: Opcode,
    fin: bool,
    rsv1: bool = false,
    rsv2: bool = false,
    rsv3: bool = false,

    pub const Error = error{MaskedMessageFromServer};
};

pub const Message = struct {
    type: Opcode,
    data: []const u8,
    code: ?u16, // only used in close messages

    pub const Error = error{ FragmentedMessage, UnknownOpcode };

    /// Create a WebSocket message from given fields.
    pub fn from(opcode: Opcode, data: []const u8, code: ?u16) Message.Error!Message {
        switch (opcode) {
            .text, .binary, .ping, .pong, .close => {},

            .continuation => return error.FragmentedMessage,
            else => return error.UnknownOpcode,
        }

        return Message{ .type = opcode, .data = data, .code = code };
    }
};

// Replace with std.http.Header after https://github.com/ziglang/zig/pull/18955
pub const HttpHeader = struct {
    name: []const u8,
    value: []const u8,
};
