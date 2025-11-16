const std = @import("std");
const net = std.net;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;


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


const ParseByteCountError = error {
    InvalidString,
    InvalidCharacter,
    Overflow,
};

/// Given a response line that ends with 
/// `{x}\r\n`
///
/// This function parse the value x
fn extractRawBytesCount(line: []const u8) ParseByteCountError!usize {
    if (line.len < 5) {
        // `*`` + `{` + `}` + `\r` + `\n` = 5
        return ParseByteCountError.InvalidString;
    }
    if (line[line.len - 3] != '}') {
        return ParseByteCountError.InvalidString;
    }
    const count_end = line.len - 3;

    var count_start = count_end - 1;
    var found = false;
    while (count_start >= 0) {
        count_start -= 1;
        if (line[count_start] == '{') {
            found = true;
            count_start += 1;
            break;
        }
    }

    if (!found) {
        return ParseByteCountError.InvalidString;
    }

   return std.fmt.parseInt(usize, line[count_start..count_end], 10);
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

// Use std.mem.findScalar in 0.16
fn findScalar(comptime T: type, buffer: []const T, scalar: T) ?usize {
    for (0.., buffer) |i, s| {
        if (s == scalar) {
            return i;
        }
    }

    return null;
}

fn findColon(buffer: []const u8) ?usize {
    return findScalar(u8, buffer, ':');
}

fn findCrlf(buffer: []const u8) ?usize {
    const cr_pos = findScalar(u8, buffer, '\r') orelse return null;
    if (cr_pos == buffer.len - 1) {
        return null;
    }
    if (buffer[cr_pos + 1] != '\n') {
        return null;
    }
    return cr_pos;
}



pub const ParsedHeader = struct {
    // delivered_to: []const u8,
    // received: []const u8,
    from: []const u8,
    // to: []const u8,
    subject: []const u8,
    date: []const u8,
    // content_type: []const u8,
    // mime_version: []const u8,

    pub const Empty: ParsedHeader = ParsedHeader{
        // .delivered_to= "",
        // .received= "",
        .from= "",
        // .to= "",
        .subject= "",
        .date= "",
        // .content_type= "",
        // .mime_version= "",
    };


    pub fn parse(data: []const u8) ParsedHeader {
        const eqlIgnoreCase = std.ascii.eqlIgnoreCase;

        var parsed = ParsedHeader.Empty;

        std.debug.print("data: \n```{s}```\n", .{data});

        // TODO we skip the first line as its some meta data of the response
        // and not strictly email header
        //
        var buffer = data[0..];
        if (buffer.len > 0 and buffer[0] == '*') {
            const eofl = findCrlf(buffer) orelse {
                @panic("todo");
            };
            buffer = buffer[eofl + CRLF.len..];
        }
        while (buffer.len != 0) {
            std.debug.print("buffer: \n```{s}```\n", .{buffer});
            // Skip empty lines
            // TODO this is not robust to data not 100% conforming (i.e what if there are whitespaces)
            if (buffer.len >= 2 and buffer[0] == CRLF[0] and buffer[1] == CRLF[1]) {
                buffer = buffer[CRLF.len..];
                continue;
            }
            if (buffer[0] == ')') {
                // End of header
                break;
            }
            const colon_pos = findColon(buffer) orelse {
                @panic("todo");
            };
            const field_name = buffer[0..colon_pos];

            var cr_pos = findCrlf(buffer[colon_pos..]) orelse {
                @panic("todo");
            };
            cr_pos += colon_pos;


            if (cr_pos + CRLF.len >= buffer.len - 1) {
                @panic("todo");
            }

            while (cr_pos+CRLF.len < buffer.len and std.ascii.isWhitespace(buffer[cr_pos+CRLF.len])) {
                // The field body is 'folded'
                if (findCrlf(buffer[cr_pos+CRLF.len..])) |pos| {
                    cr_pos += pos + CRLF.len;
                } else {
                    @panic("todo");
                }
            }

            const field_body = buffer[colon_pos + 1..cr_pos + CRLF.len];
            std.debug.print("colon_pos: {}, cr_pos: {}, buffer len {}\n", .{colon_pos, cr_pos, buffer.len});
            std.debug.print("field_name: {s}, field_body {s}\n", .{field_name, field_body});
            if (eqlIgnoreCase(field_name, "from")) {
                parsed.from = field_body;
            } else if (eqlIgnoreCase(field_name, "to")) {
                // parsed.to = field_body;
            } else if (eqlIgnoreCase(field_name, "delivered-to")) {
                // parsed.delivered_to = field_body;
            } else if (eqlIgnoreCase(field_name, "subject")) {
                parsed.subject = field_body;
            } else if (eqlIgnoreCase(field_name, "received")) {
                // parsed.received = field_body;
            } else if (eqlIgnoreCase(field_name, "date")) {
                parsed.date = field_body;
            } else if (eqlIgnoreCase(field_name, "content-type")) {
                // parsed.content_type = field_body;
            }

            std.debug.print("Setting buffer to {s}", .{buffer[cr_pos + CRLF.len..]});

            buffer = buffer[cr_pos+CRLF.len..];
        }

        return parsed;
    }

};


pub const ImapError = error {
    ConnectionError,
};

pub const ImapClient = struct {
    pub const IMAP_PORT: u16 = 143;
    pub const IMAP_TLS_PORT: u16 = 993;

    /// Imap is a (mostly) line based protocol
    /// and the spec suggests 999 as a comoon limit for line length
    pub const MIN_READER_BUF_LEN = 1024;

    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,

    tag_counter: u32 = 0,
    tag_buf: [8]u8 = undefined,

    pub fn init(allocator: Allocator, hostname: []const u8, port: u16, socket_read_buffer: []u8, socket_write_buffer: []u8) !ImapClient {
        if (port == IMAP_PORT) {
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

    fn sendCommand(client: *ImapClient, command: []const u8) ![]u8 {
        client.tag_counter += 1;
        const tag = try std.fmt.bufPrint(&client.tag_buf, "A{:03}", .{client.tag_counter});

        // TODO something like format would be cleaner, but I cant figure out the usage yet
        // try std.fmt.format(client.writer.interface, "{s} {s}\r\n", .{ tag, command });
        _ = try client.writer.interface.write(tag);
        _ = try client.writer.interface.write(" ");
        _ = try client.writer.interface.write(command);
        _ = try client.writer.interface.write(CRLF);
        try client.writer.interface.flush();

        return tag;
    }

    fn sendFormattedCommand(client: *ImapClient, comptime fmt: []const u8, args: anytype) ![]const u8 {
        client.tag_counter += 1;
        const tag = try std.fmt.bufPrint(&client.tag_buf, "A{:03}", .{client.tag_counter});
        
        _ = try client.writer.interface.write(tag);
        _ = try client.writer.interface.write(" ");
        try client.writer.interface.print(fmt, args);
        _ = try client.writer.interface.write(CRLF);
        try client.writer.interface.flush();

        return tag;
    }


    pub fn fetchHeaderBytesAlloc(client: *ImapClient, start: u32, stop: ?u32, allocator: Allocator, out_list: *ArrayList([]u8)) !void {
        var tag: []const u8 = undefined;
        if (stop) |end| {
            if (end < start) {
                @panic("stop cannot be less then start");
            }
            tag = try client.sendFormattedCommand("FETCH {}:{} (BODY[HEADER])", .{start, end});
            const n = end - start;
            try out_list.ensureUnusedCapacity(allocator, n);
        } else {
           tag = try client.sendFormattedCommand("FETCH {}:* (BODY[HEADER])", .{start});
        }

        while (true) {
            // TODO try to handle StreamTooLong (=line too long) ?
            var line = try client.reader.interface().takeDelimiterInclusive('\n');

            if (std.mem.startsWith(u8, line, "*")) {
                // This line is should look like this:
                // `* 1 FETCH (BODY[HEADER] {n}`
                // where `n` is the number of literal bytes of the header
                const raw_bytes_count = try extractRawBytesCount(line);

                const HEADER_SIZE_LIMIT = 256 * 1024; // 256 KB
                if (raw_bytes_count > HEADER_SIZE_LIMIT) {
                    @panic("todo: return an error like Suspicious size");
                }

                const bytes = try allocator.alloc(u8, raw_bytes_count);

                try client.reader.interface().readSliceAll(bytes);

                try out_list.append(allocator, bytes);

                while (true) {
                    line = try client.reader.interface().takeDelimiterInclusive('\n');
                    if (line.len >= 1 and line[0] == ')') {
                        break;
                    }
                }
            } else if (std.mem.startsWith(u8, line, tag)) {
                // We found the line that starts with the query tag
                // this means the server has completed the request
                //
                // TODO check for OK/BAD/
                break;
            }
        }
    }

    pub fn readBodyBytesAlloc(client: *ImapClient, id: u32, allocator: Allocator, out_bytes: *ArrayList(u8)) !void {
        const tag = try client.sendFormattedCommand("FETCH {} (BODY[TEXT])", .{id});
        while (true) {
            // TODO try to handle StreamTooLong (=line too long) ?
            var line = try client.reader.interface().takeDelimiterInclusive('\n');

            if (std.mem.startsWith(u8, line, "*")) {
                // This line is should look like this:
                // `* 1 FETCH (BODY[TEXT] {n}`
                // where `n` is the number of literal bytes of the header
                const raw_bytes_count = try extractRawBytesCount(line);

                const BODY_SIZE_LIMIT = 64 * 1024 * 1000; // 64 MB
                if (raw_bytes_count > BODY_SIZE_LIMIT) {
                    @panic("todo: return an error like Suspicious size");
                }

                var writer = std.Io.Writer.Allocating.fromArrayList(allocator, out_bytes);
                try writer.ensureTotalCapacity(raw_bytes_count);
                try client.reader.interface().streamExact(&writer.writer, raw_bytes_count);
                out_bytes.* = writer.toArrayList();

                while (true) {
                    line = try client.reader.interface().takeDelimiterInclusive('\n');
                    if (line.len >= 1 and line[0] == ')') {
                        break;
                    }
                }
            } else if (std.mem.startsWith(u8, line, tag)) {
                // We found the line that starts with the query tag
                // this means the server has completed the request
                //
                // TODO check for OK/BAD/
                break;
            }
        }
    }

    pub fn rawRunCommand(client: *ImapClient, command: []const u8, response_buffer: []u8) !usize {
        const tag = try client.sendCommand(command);

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
    pub fn logout(client: *ImapClient) void {
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

    /// Reads the next line received into the `response_buffer`
    ///
    /// Returns a slice pointing to the line read in `response_buffer`
    ///
    /// Returns .StreamTooLong if the `response_buffer` cannot store the complete line
    fn readNextLine(client: *ImapClient, response_buffer: []u8) std.Io.Reader.DelimiterError![]u8 {
        return readerReadNextLine(client.reader.interface(), response_buffer);
    }
};


test "Header Parsing" {
    // const testing = std.testing;

    const data = "* 1 FETCH (BODY[HEADER] {398}\r\nDelivered-To: bob@example.com\r\nReceived: by 10.217.121.71 with SMTP id dc49csp20728web;\r\n Fri, 1 Nov 2013 05:34:54 -0700 (PDT)\r\nFrom: Alice <alice@example.com>\r\nTo: Bob <bob@example.com>\r\nSubject: Shocking document attached\r\nDate: Fri, 1 Nov 2013 12:34:52 +0000\r\nContent-Type: multipart/mixed;\r\n boundary=\"_002_30EAEBC95FDA154393D406239659F0C20A5B6BFETRITONhqrebexcz_\"\r\nMIME-Version: 1.0\r\n\r\n)\r\nA005 OK FETCH completed.\r\n";
    const header = ParsedHeader.parse(data[0..]);

    _ = .{header};

    // try testing.expectEqualStrings(" bob@example.com\r\n", header.delivered_to);
    // try testing.expectEqualStrings(" by 10.217.121.71 with SMTP id dc49csp20728web;\r\n Fri, 1 Nov 2013 05:34:54 -0700 (PDT)\r\n", header.received);
}
