<p align="center">
  <img src="https://github.com/nikneym/ws/blob/main/misc/logo.png" alt="ws" width="60%" height="30%" />
</p>

ws
===========
a lightweight WebSocket library for Zig ⚡

Features
===========
* Only allocates for WebSocket handshake, message parsing and building does not allocate
* Ease of use, can be used directly with `net.Stream`
* Does buffered reads and writes (can be used with any other reader/writer too)
* Supports streaming output thanks to WebSocket fragmentation

Example
===========
By default, ws uses the `Stream` interface of `net` namespace.
You can use your choice of stream through `ws.Client` interface.
```zig
test "Simple connection to :8080" {
    const allocator = std.testing.allocator;

    var cli = try connect(allocator, try std.Uri.parse("ws://localhost:8080"), &.{
        .{"Host",   "localhost"},
        .{"Origin", "http://localhost/"},
    });
    defer cli.deinit(allocator);

    while (true) {
        const msg = try cli.receive();
        switch (msg.type) {
            .text => {
                std.debug.print("received: {s}\n", .{msg.data});
                try cli.send(.text, msg.data);
            },

            .ping => {
                std.debug.print("got ping! sending pong...\n", .{});
                try cli.pong();
            },

            .close => {
                std.debug.print("close", .{});
                break;
            },

            else => {
                std.debug.print("got {s}: {s}\n", .{@tagName(msg.type), msg.data});
            },
        }
    }

    try cli.close();
}
```

Planned
===========
- [ ] WebSocket server support
- [ ] TLS support out of the box (tracks `std.crypto.tls.Client`)
- [x] Request & response headers
- [ ] WebSocket Compression support

Acknowledgements
===========
This library wouldn't be possible without these cool projects & posts:
* [truemedian/wz](https://github.com/truemedian/wz)
* [frmdstryr/zhp](https://github.com/frmdstryr/zhp/blob/master/src/websocket.zig)
* [treeform/ws](https://github.com/treeform/ws)
* [openmymind.net/WebSocket-Framing-Masking-Fragmentation-and-More](https://www.openmymind.net/WebSocket-Framing-Masking-Fragmentation-and-More/)
* [Writing WebSocket servers](https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API/Writing_WebSocket_servers)

License
===========
MIT License, [check out](https://github.com/nikneym/ws/blob/main/LICENSE).
