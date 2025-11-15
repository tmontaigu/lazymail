const std = @import("std");
const net = std.net;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const lazymail = @import("lazymail_lib");
const ImapClient = lazymail.ImapClient;

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer {
        switch (debug_allocator.deinit()) {
            .ok => {},
            .leak => {
                @panic("There are some memory leaks");
            }
        }
    }
    
    const allocator = debug_allocator.allocator();
    
    // 0.16
    // var threaded_io = std.Io.Threaded.init(allocator);
    // defer threaded_io.deinit();

    var socket_read_buffer: [2048]u8 = undefined;
    var socket_writer_buffer: [2048]u8 = undefined;

    const hostname_bytes = "test.rebex.net";
    // const hostname = try net.HostName.init(hostname_bytes); // 0.16
    const port = ImapClient.IMAP_PORT;
    var client = try ImapClient.init(allocator, hostname_bytes, port, &socket_read_buffer, &socket_writer_buffer);
    defer client.logout();

    std.debug.print("CAPABILITY...\n", .{});
    var responseBuffer: [2048]u8 = undefined;
    var n = try client.rawRunCommand("CAPABILITY", &responseBuffer);
    std.debug.print("Response:\n```\n{s}\n```\n", .{responseBuffer[0..n-2]});

    std.debug.print("LOGIN...\n", .{});
    n = try client.rawRunCommand("LOGIN demo password", &responseBuffer);
    std.debug.print("Response:\n```\n{s}\n```\n", .{responseBuffer[0..n-2]});

    std.debug.print("SELECT INBOX...\n", .{});
    n = try client.rawRunCommand("SELECT INBOX", &responseBuffer);
    std.debug.print("Response:\n```\n{s}\n```\n", .{responseBuffer[0..n-2]});

    std.debug.print("FETCH...\n", .{});
    n = try client.rawRunCommand("FETCH 1:10 (FLAGS ENVELOPE)", &responseBuffer);
    std.debug.print("Response:\n```\n{s}\n```\n", .{responseBuffer[0..n-2]});

    std.debug.print("FETCH 1 BODY[HEADER]...\n", .{});
    n = try client.rawRunCommand("FETCH 1 (BODY[HEADER])", &responseBuffer);
    std.debug.print("Response:\n```\n{s}\n```\n", .{responseBuffer[0..n-2]});

    var headers = ArrayList([]u8).empty;
    try client.fetchHeaderBytesAlloc(1, null, allocator, &headers);
    for (headers.items) |header| {
        std.debug.print("Header:\n```\n{s}\n```\n", .{header[0..header.len-2]});
        allocator.free(header);
    }
    headers.clearAndFree(allocator);

    var stdin = std.fs.File.stdin();
    var line_buf: [512]u8 = undefined;
    var stdin_reader = stdin.reader(&line_buf);
    defer stdin.close();
    while (true) {
        // We should use stdout here, but lazyness as the api seems more anoying
        std.debug.print("> ", .{});
        const line = stdin_reader.interface.takeDelimiterInclusive('\n') catch |err| {
            std.debug.print("Error: {}\n", .{err});
            // break to have clean logout
            break;
        };

        if (std.mem.eql(u8, line, "q\n")) {
            break;
        }

        // The line includes an extra `\n` which must not be part of the 
        // request
        n = client.rawRunCommand(line[0..line.len-1], &responseBuffer) catch |err| {
            std.debug.print("Error: {}\n", .{err});
            // break to have clean logout
            break;
        };
        std.debug.print("Response:\n```\n{s}\n```\n", .{responseBuffer[0..n-2]});
    }
}

