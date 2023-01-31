const std = @import("std");
const net = std.net;

const Client = @import("client.zig").Client;
const client = @import("client.zig").client;

const common = @import("common.zig");
const Opcode = common.Opcode;
const Message = common.Message;

const READ_BUFFER_SIZE: usize = 1024 * 8;
const WRITE_BUFFER_SIZE: usize = 1024 * 4;

// FIXME: add an option to change request buffer size?
// FIXME: use StringHashMapUnmanaged([]const u8) instead
pub const IncomingConnection = struct {
    underlying_stream: net.Stream,
    address: net.Address,
    ws_client: WsClient,
    // this will hold url and request headers
    req_buffer: [4096]u8 = undefined,
    headers: std.StringHashMap([]const u8),
    buffered_reader: BufferedReader,

    const WsClient = Client(Reader, Writer, READ_BUFFER_SIZE, WRITE_BUFFER_SIZE);
    const BufferedReader = std.io.BufferedReader(4096, net.Stream.Reader);
    const Reader = BufferedReader.Reader;
    const Writer = net.Stream.Writer;

    pub fn deinit(self: *IncomingConnection) void {
        self.underlying_stream.close();
        self.headers.deinit();
    }
};
