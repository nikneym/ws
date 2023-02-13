const std = @import("std");
const mem = std.mem;
const net = std.net;
const bs64 = std.base64.standard;
const Sha1 = std.crypto.hash.Sha1;
const IncomingConnection = @import("incoming_connection.zig").IncomingConnection;

const GET_ = @bitCast(u32, [4]u8{'G', 'E', 'T', ' '});
const HTTP = @bitCast(u32, [4]u8{'H', 'T', 'T', 'P'});
const V1_1 = @bitCast(u32, [4]u8{'/', '1', '.', '1'});

const MAGIC_STRING = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const CONNECTION = "Upgrade";
const UPGRADE = "websocket";
const SEC_WEBSOCKET_VERSION = "13";
const BARE_RESPONSE = "HTTP/1.1 101 Switching Protocols\r\n" ++
                     "Upgrade: " ++ UPGRADE ++ "\r\n" ++
                     "Connection: " ++ CONNECTION ++ "\r\n" ++
                     "Sec-WebSocket-Accept: "; // this field will be filled in sendHttpResponse

const ENCODED_BUFFER_SIZE = bs64.Encoder.calcSize(Sha1.digest_length);

// WebSocket server implementation over net.StreamServer
pub const Server = struct {
    underlying_server: net.StreamServer,
    route: []const u8,

    const BufferedReader = std.io.BufferedReader(4096, net.Stream.Reader);
    const Reader = net.Stream.Reader;

    pub fn init(address: net.Address, route: []const u8) !Server {
        var server = net.StreamServer.init(.{ .reuse_address = true });
        errdefer server.deinit();
        try server.listen(address);

        return Server{
            .underlying_server = server,
            .route = route,
        };
    }

    pub fn deinit(self: *Server) void {
        self.underlying_server.deinit();
    }

    const RequestState = enum {
        parseMethod,
        parseUrl,
        parseHttpVersion,
        parseHeaderKey,
        parseHeaderValue,
    };

    pub const ParseError = error{
        MalformedRequest,
        RequestTooBig,
        UnknownRoute,
        UnknownHttpVersion,
        EndOfStream,
    } || net.Stream.ReadError || mem.Allocator.Error;

    // TODO: use StringHashMapUnmanaged instead
    // parses incoming HTTP request. this does not check must-have WebSocket headers
    fn parseHttpRequest(
        self: Server,
        reader: Reader,
        buf: []u8,
        headers: *std.StringHashMap([]const u8),
    ) ParseError!void {
        var state: RequestState = .parseMethod;
        var pos: usize = 0;
        var key_start_pos: usize = 0;
        var value_start_pos: usize = 0;

        while (true) {
            switch (state) {
                .parseMethod => {
                    const len = try reader.readAll(buf[0..4]);
                    if (len != 4)
                        return error.EndOfStream;

                    if (@bitCast(u32, buf[0..4].*) != GET_)
                        return error.MalformedRequest;

                    state = .parseUrl;
                },
                .parseUrl => {
                    const b = try reader.readByte();
                    switch (b) {
                        ' ' => { // reached end of URL
                            // TODO: URL must be sanitized and parsed better
                            if (pos < self.route.len)
                                return error.UnknownRoute;
                            if (!mem.eql(u8, buf[0..self.route.len], self.route))
                                return error.UnknownRoute;

                            state = .parseHttpVersion;
                            key_start_pos = pos;
                        },

                        else => {
                            if (pos > buf.len)
                                return error.RequestTooBig;
                            buf[pos] = b;
                            pos += 1;
                        },
                    }
                },
                .parseHttpVersion => {
                    var bytes: [4]u8 = undefined;
                    var len = try reader.readAll(&bytes);
                    if (len != 4)
                        return error.EndOfStream;

                    if (@bitCast(u32, bytes) != HTTP)
                        return error.MalformedRequest;

                    // parse actual (numeric) version
                    len = try reader.readAll(&bytes);
                    if (len != 4)
                        return error.EndOfStream;

                    if (@bitCast(u32, bytes) != V1_1)
                        return error.UnknownHttpVersion;

                    // look for line feed
                    const b = try reader.readByte();
                    switch (b) {
                        '\n' => state = .parseHeaderKey,
                        '\r' => if (try reader.readByte() == '\n') {
                            state = .parseHeaderKey;
                        } else return error.MalformedRequest,

                        else => return error.MalformedRequest,
                    }
                },
                .parseHeaderKey => {
                    const b = try reader.readByte();
                    switch (b) {
                        ':' => {
                            if (try reader.readByte() == ' ') {
                                state = .parseHeaderValue;
                                value_start_pos = pos;
                            }
                        },
                        '\r' => if (try reader.readByte() == '\n') break
                                else return error.MalformedRequest,
                        '\n' => break,

                        else => {
                            if (pos > buf.len)
                                return error.RequestTooBig;
                            buf[pos] = b;
                            pos += 1;
                        },
                    }
                },
                .parseHeaderValue => {
                    const b = try reader.readByte();
                    switch (b) {
                        '\r' => if (try reader.readByte() == '\n') {
                            if (key_start_pos > value_start_pos or value_start_pos > pos)
                                return error.MalformedRequest;

                            const key = buf[key_start_pos..value_start_pos];
                            const value = buf[value_start_pos..pos];
                            try headers.put(key, value);

                            state = .parseHeaderKey;
                            key_start_pos = pos;
                        } else return error.MalformedRequest,
                        '\n' => {
                            if (key_start_pos > value_start_pos or value_start_pos > pos)
                                return error.MalformedRequest;

                            const key = buf[key_start_pos..value_start_pos];
                            const value = buf[value_start_pos..pos];
                            try headers.put(key, value);

                            state = .parseHeaderKey;
                            key_start_pos = pos;
                        },

                        else => {
                            if (pos > buf.len)
                                return error.RequestTooBig;
                            buf[pos] = b;
                            pos += 1;
                        },
                    }
                },
            } // switch state
        } // while
    }

    pub const HeaderError = error{MissingHeader, UnexpectedHeaderValue};

    /// check if request headers contain ws handshake fields and match their values
    fn checkRequestHeaders(headers: std.StringHashMap([]const u8)) HeaderError!void {
        const connection = headers.get("Connection") orelse return error.MissingHeader;
        if (!mem.eql(u8, connection, CONNECTION))
            return error.UnexpectedHeaderValue;

        const upgrade = headers.get("Upgrade") orelse return error.MissingHeader;
        if (!mem.eql(u8, upgrade, UPGRADE))
            return error.UnexpectedHeaderValue;

        const sec_websocket_version = headers.get("Sec-WebSocket-Version") orelse return error.MissingHeader;
        if (!mem.eql(u8, sec_websocket_version, SEC_WEBSOCKET_VERSION))
            return error.UnexpectedHeaderValue;
    }

    pub fn accept(self: *Server, allocator: mem.Allocator) !IncomingConnection {
        var connection = try self.underlying_server.accept();
        //var buffered_reader = BufferedReader{ .unbuffered_reader = connection.stream.reader() };
        const writer = connection.stream.writer();
        const reader = connection.stream.reader();

        // create a WebSocket client out of stream
        var ws_client = IncomingConnection{
            .underlying_stream = connection.stream,
            .address = connection.address,
            //.buffered_reader = buffered_reader,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .sender = .{ .writer = writer, .mask = undefined },
            .receiver = .{ .reader = reader, .buffer = try allocator.alloc(u8, 1024 * 4) },
        };
        errdefer ws_client.deinit(allocator);

        self.parseHttpRequest(reader, &ws_client.req_buffer, &ws_client.headers) catch |e| switch (e) {
            error.MalformedRequest,
            error.RequestTooBig,
            error.UnknownRoute,
            error.UnknownHttpVersion => {
                try sendFailResponse(writer);
                return e;
            },

            // if it got here, we just can't send HTTP response
            else => return e,
        };

        checkRequestHeaders(ws_client.headers) catch |e| {
            try sendFailResponse(writer);
            return e;
        };

        // create Sec-WebSocket-Accept header value
        // TODO: check if a given value is valid base64
        const sec_websocket_key = ws_client.headers.get("Sec-WebSocket-Key") orelse {
            try sendFailResponse(writer);
            return error.MissingHeader;
        };
        //if (sec_websocket_key.len != 24)
        //    return error.UnexpectedHeaderValue;

        // the Sec-WebSocket-Accept overhead
        var h = Sha1.init(.{});
        h.update(sec_websocket_key);
        h.update(MAGIC_STRING);
        var hash_buf: [Sha1.digest_length]u8 = undefined;
        h.final(&hash_buf);
        var encoded_buf: [ENCODED_BUFFER_SIZE]u8 = undefined;
        const sec_websocket_accept = bs64.Encoder.encode(&encoded_buf, &hash_buf);

        // tell the client that we're switching protocols
        try sendSuccessResponse(writer, sec_websocket_accept);

        // handshake succeeded, what a mess!
        return ws_client;
    }

    // TODO: allow custom HTTP responses for both situations

    fn sendFailResponse(writer: net.Stream.Writer) !void {
        try writer.writeAll(
            "HTTP/1.1 400 Bad Request\r\n" ++
            "Connection: close\r\n" ++
            "\r\n"
        );
    }

    fn sendSuccessResponse(writer: net.Stream.Writer, sec_websocket_accept: []const u8) !void {
        // implementation reference from std.http.client.zig#764
        var buf = try std.BoundedArray(u8, 4096).init(0);
        try buf.appendSlice(BARE_RESPONSE);
        try buf.appendSlice(sec_websocket_accept);
        try buf.appendSlice("\r\n");
        // additional headers should come here
        try buf.appendSlice("\r\n");

        try writer.writeAll(buf.slice());
    }
};
