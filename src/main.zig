const std = @import("std");
const net = std.net;
const http = std.http;
const crypto = std.crypto;
const Allocator = std.mem.Allocator;

const tls = @import("tls");

const IMAP_PORT: u16 = 143;
const IMAP_TLS_PORT: u16 = 993;

const CRLF: *const[2]u8 = "\r\n";


/// Reads the next line received into the `response_buffer`
///
/// Returns a slice pointing to the line read in `response_buffer`
///
/// Returns .StreamTooLong if the `response_buffer` cannot store the complete line
fn readerReadNextLine(reader: *std.Io.Reader, response_buffer: []u8) std.Io.Reader.DelimiterError![]u8 {
    var end: usize = 0;
    while (true) {
        // We look for `\n` (LF) only, in reality the server should send a CRLF
        const result = reader.takeDelimiterInclusive('\n');

        if (result) |line| {
            // The internal buffer of the reader had a line delimitor
            if (line.len > response_buffer.len) {
                return std.Io.Reader.DelimiterError.StreamTooLong;
            }
            @memcpy(response_buffer[end..end + line.len], line);
            end += line.len;
            break;
        } else |err| switch (err) {
            std.Io.Reader.DelimiterError.StreamTooLong => {
                // The internal buffer of the reader did not have a LF delimitor
                // so we consume what is has, and retry until we get a complete line
                // 
                // This is ok as an IMAP communication must always end with CRLF
                const data = reader.buffered();
                if (end + data.len > response_buffer.len) {
                    return std.Io.Reader.DelimiterError.StreamTooLong;
                }

                @memcpy(response_buffer[end..end + data.len], data);
                reader.tossBuffered();
                end += data.len;
            },
            else => |other_error| return other_error,
        }
    }

    return response_buffer[0..end];
}


// From the spec:
// | Ok, No, Bad can be tagged or untagged
// | PreAuth and Byt are always untagged
const ResponseStatus = enum {
    Ok,
    No,
    Bad,
    PreAuth,
    Bye,


    const ParseResult = struct {
        value: ResponseStatus,
        bytes_consumed: usize,
    };


    /// Parses the response status code string.
    pub fn parseAdvance(input: []const u8) ?ParseResult {
        if (std.mem.startsWith(u8, input, "OK")) {
            return ParseResult{.value = .Ok, .bytes_consumed = 2};
        } else if (std.mem.startsWith(u8, input, "No")) {
            return ParseResult{.value = .No, .bytes_consumed = 2};
        } else if (std.mem.startsWith(u8, input, "Bad")) {
            return ParseResult{.value = .Bad, .bytes_consumed = 3};
        } else if (std.mem.startsWith(u8, input, "PreAuth")) {
            return ParseResult{.value = .PreAuth, .bytes_consumed = 7};
        } else if (std.mem.startsWith(u8, input, "Bye")) {
            return ParseResult{.value = .Bye, .bytes_consumed = 3};
        } else {
            return null; // failed to parse
        }
    }
};

const ParsedHeader = struct {
    delivered_to: []const u8,
    received: []const u8,
    from: []const u8,
    to: []const u8,
    subject: []const u8,
    date: []const u8,
    content_type: []const u8,
    mime_version: []const u8,
};

const ImapError = error {
    ConnectionError,
};

const ImapClient = struct {
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,

    tag_counter: u32 = 0,

    pub fn init(allocator: Allocator, hostname: []const u8, port: u16, socket_read_buffer: []u8, socket_write_buffer: []u8) !ImapClient {
        if (port == IMAP_PORT) {
            // const options = net.IpAddress.ConnectOptions{
            //     .mode = .stream,
            //     .protocol = .tcp,
            // };
            // var stream = try hostname.connect(io, port, options); // 0.16
            var stream = try std.net.tcpConnectToHost(allocator, hostname, port);
            var reader = stream.reader(socket_read_buffer);

            // We use the writer buffer to read the initial response
            const line = try readerReadNextLine(reader.interface(), socket_write_buffer);
            std.debug.print("Server Init response: {s}", .{line});
            // Parse the '*' tag
            if (line.len < 2 or line[0] != '*') {
                return ImapError.ConnectionError;
            }

            // Get the status, start at 2 to skip the space after the '*'
            const parseResult = ResponseStatus.parseAdvance(line[2..]) orelse {
                return ImapError.ConnectionError;
            };

            if (parseResult.value != ResponseStatus.Ok) {
                return ImapError.ConnectionError;
            }

            // We don't need to clean the buffer,
            // the next response will overwrite, and CRLF will be the end sentinel
            const writer = stream.writer(socket_write_buffer);

            return ImapClient{
                .stream = stream,
                .reader = reader,
                .writer = writer,
            };
        } else if (port == IMAP_TLS_PORT) {
            @panic("TODO: handle TLS");
        } else {
            @panic("TODO: handle non default port");
        }
    }

    /// Reads the next line received into the `response_buffer`
    ///
    /// Returns a slice pointing to the line read in `response_buffer`
    ///
    /// Returns .StreamTooLong if the `response_buffer` cannot store the complete line
    fn readNextLine(client: *ImapClient, response_buffer: []u8) std.Io.Reader.DelimiterError![]u8 {
        return readerReadNextLine(client.reader.interface(), response_buffer);
    }

    fn rawRunCommand(client: *ImapClient, command: []const u8, response_buffer: []u8) !usize {
        client.tag_counter += 1;
        var tag_buf: [8]u8 = undefined;
        const tag = try std.fmt.bufPrint(&tag_buf, "A{:03}", .{client.tag_counter});

        // TODO something like format would be cleaner, but I cant figure out the usage yet
        // try std.fmt.format(client.writer.interface, "{s} {s}\r\n", .{ tag, command });
        _ = try client.writer.interface.write(tag);
        _ = try client.writer.interface.write(" ");
        _ = try client.writer.interface.write(command);
        _ = try client.writer.interface.write(CRLF);
        try client.writer.interface.flush();

        var end: usize = 0;
        while (true) {
            const line = try client.readNextLine(response_buffer[end..]);
            end += line.len;

            if (std.mem.startsWith(u8, line, tag)) {
                // We found the line that starts with the query tag
                // this means the server has completed the request
                //
                // TODO check for OK/BAD/?
                break;
            }
        }
        return end;
    }

    // log outs and closes the connection
    fn logout(client: *ImapClient) void {
        std.debug.print("LOGOUT\n", .{});
        var response_buffer: [124]u8 = undefined;
        const n = client.rawRunCommand("LOGOUT", &response_buffer) catch {
            // We choose to ignore errors as we are closing the connection
            // so we con't really care if somehow the logout failed ?
            // TODO maybe at least check if the error is relative to sending the 
            // logout command
            return;
        };
        std.debug.print("Response:\n```\n{s}\n```\n", .{response_buffer[0..n-2]});
        client.stream.close();
    }
};

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

    var socket_read_buffer: [10]u8 = undefined;
    var socket_writer_buffer: [2048]u8 = undefined;

    const hostname_bytes = "test.rebex.net";
    // const hostname = try net.HostName.init(hostname_bytes); // 0.16
    const port = IMAP_PORT;
    var client = try ImapClient.init(allocator, hostname_bytes, port, &socket_read_buffer, &socket_writer_buffer);
    defer client.logout();

    std.debug.print("CAPABILITY...\n", .{});
    var responseBuffer: [1024]u8 = undefined;
    var n = try client.rawRunCommand("CAPABILITY", &responseBuffer);
    std.debug.print("Response:\n```\n{s}\n```\n", .{responseBuffer[0..n-2]});

    std.debug.print("LOGIN...\n", .{});
    n = try client.rawRunCommand("LOGIN demo password", &responseBuffer);
    std.debug.print("Response:\n```\n{s}\n```\n", .{responseBuffer[0..n-2]});

    std.debug.print("SELECT INBOX...\n", .{});
    n = try client.rawRunCommand("SELECT INBOX", &responseBuffer);
    std.debug.print("Response:\n```\n{s}\n```\n", .{responseBuffer[0..n-2]});

    std.debug.print("FETCH...\n", .{});
    n = try client.rawRunCommand("FETCH 1:* (FLAGS ENVELOPE)", &responseBuffer);
    std.debug.print("Response:\n```\n{s}\n```\n", .{responseBuffer[0..n-2]});

    std.debug.print("FETCH 1 BODY[HEADER]...\n", .{});
    n = try client.rawRunCommand("FETCH 1 BODY[HEADER]", &responseBuffer);
    std.debug.print("Response:\n```\n{s}\n```\n", .{responseBuffer[0..n-2]});


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


    // std.debug.print("LOGOUT\n", .{});
    // n = try client.rawRunCommand("LOGOUT", &responseBuffer);
    // std.debug.print("Response:\n```\n{s}\n```\n", .{responseBuffer[0..n-2]});
}

// pub fn main() !void {
//     const allocator = std.heap.page_allocator;
//     var threaded_io = std.Io.Threaded.init(allocator);
//     const io = threaded_io.io();
//
//     // const hostname_bytes = "imap.laposte.net";
//     // const hostname_bytes = "test.rebex.net";
//     const hostname_bytes = "imap.gmail.com";
//     // const hostname_bytes = "example.org";
//
//     // --- Server configuration ---
//     const hostname = try net.HostName.init(hostname_bytes);
//
//     const port = 993; // IMAPS + TLS
//     // const port = 143; // IMAPS
//     // const port = 443;
//
//     const options = net.IpAddress.ConnectOptions{
//         .mode = .stream,
//         .protocol = net.Protocol.tcp
//     };
//
//     std.debug.print("connecting...", .{});
//     var stream = try hostname.connect(io, port, options);
//     std.debug.print("ok\n", .{});
//
//     var tls_read_buffer: [crypto.tls.Client.min_buffer_len]u8 = undefined;
//     var tls_write_buffer: [crypto.tls.Client.min_buffer_len]u8 = undefined;
//     var socket_write_buffer: [crypto.tls.Client.min_buffer_len]u8 = undefined;
//     var socket_read_buffer: [crypto.tls.Client.min_buffer_len]u8 = undefined;
//
//     var reader = stream.reader(io, &socket_read_buffer);
//     var writer = stream.writer(io, &tls_write_buffer);
//
//     var random_buffer: [176]u8 = undefined;
//     std.crypto.random.bytes(&random_buffer);
//     const now = try std.Io.Clock.real.now(io);
//
//     const tls_options = crypto.tls.Client.Options {
//         .host = .no_verification,
//         .ca = .no_verification,
//         .write_buffer = &socket_write_buffer,
//         .read_buffer = &tls_read_buffer,
//         .entropy = &random_buffer,
//         .realtime_now_seconds = now.toSeconds(),
//     };
//     std.debug.print("hello\n", .{});
//     var tls_client = try crypto.tls.Client.init(
//         &reader.interface,
//         &writer.interface,
//         tls_options
//     );
//     std.debug.print("world\n", .{});
//     std.debug.print("TLS with {}\n", .{tls_client.tls_version});
//
//     // std.debug.print("writing...", .{});
//     // try tls_client.writer.writeAll("GET / HTTP/1.0\r\nHost: gmail.com\r\n\r\n");
//     // try tls_client.writer.flush();
//     // try writer.interface.flush();
//     // std.debug.print("done\n", .{});
//
//     std.debug.print("reading... \n", .{});
//     var responseBuffer: [crypto.tls.Client.min_buffer_len]u8 = undefined;
//     // const n = try reader.interface.readSliceShort(&responseBuffer);
//     const n = try tls_client.reader.readSliceShort(&responseBuffer);
//     std.debug.print("n: {} data: '{s}'\n", .{n, responseBuffer[0..n]});
//
//     //defer stream.close(io);
//     //
//     // // --- Wrap in TLS ---
//     // // var tls = try std.crypto.tls.Client.init(allocator, stream, .{
//     // //     .server_name = server,
//     // // });
//     // // defer tls.deinit();
//     // //
//     // // const reader = &tls.reader();
//     // // const writer = &tls.writer();
//     // const reader = stream.reader();
//     //
//     // // --- Read server greeting ---
//     // var buf: [1024]u8 = undefined;
//     // const n = try reader.read(&buf);
//     // std.debug.print("Server greeting:\n{s}\n", .{buf[0..n]});
//
//     // // --- Send LOGIN command (IMAP) ---
//     // const login_cmd = "a001 LOGIN " ++ username ++ " " ++ password ++ "\r\n";
//     // try writer.writeAll(login_cmd);
//     //
//     // // --- Read login response ---
//     // const n2 = try reader.read(&buf);
//     // std.debug.print("Login response:\n{s}\n", .{buf[0..n2]});
// }
