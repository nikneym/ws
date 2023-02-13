const std = @import("std");
const net = std.net;
const mem = std.mem;
const io = @import("io.zig");

// FIXME: add an option to change request buffer size?
// FIXME: use StringHashMapUnmanaged([]const u8) instead
pub const IncomingConnection = struct {
    underlying_stream: net.Stream,
    address: net.Address,
    //ws_client: WsClient,
    // this will hold url and request headers
    req_buffer: [4096]u8 = undefined,
    headers: std.StringHashMap([]const u8),
    //buffered_reader: BufferedReader,
    sender: Sender,
    receiver: Receiver,

    //const WsClient = Client(Reader, Writer, READ_BUFFER_SIZE, WRITE_BUFFER_SIZE);
    //const BufferedReader = std.io.BufferedReader(4096, net.Stream.Reader);
    //const Reader = BufferedReader.Reader;

    const Sender = io.SenderImpl(net.Stream.Writer, .server);
    const Receiver = io.ReceiverImpl(net.Stream.Reader, .server);

    pub fn deinit(self: *IncomingConnection, allocator: mem.Allocator) void {
        self.receiver.deinit(allocator);
        self.underlying_stream.close();
        self.headers.deinit();
    }
};
