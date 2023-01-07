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
You can use your choice of stream by providing `Receiver` and `Sender` to it.
```zig
const std = @import("std");
const ws = @import("ws");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try ws.connect(allocator, "ws://localhost:8080", &.{
        .{"Host",   "localhost"},
        .{"Origin", "http://localhost/"},
    });
    defer client.deinit(allocator);

    while (true) {
        var msg = try client.receive();
        switch (msg.type) {
            .text => {
                std.debug.print("received: {s}\n", .{msg.data});
                try client.send(.text, msg.data);
            },

            .ping => {
                std.debug.print("got ping! sending pong...\n", .{});
                try client.pong();
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

    try client.close();
}
```

Planned
===========
- [ ] WebSocket server support
- [ ] TLS support out of the box
- [ ] Custom headers
- [ ] WebSocket Compression support
- [ ] Maybe support for streaming input?

Thanks
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
