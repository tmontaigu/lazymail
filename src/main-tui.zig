const std = @import("std");
const fmt = std.fmt;
const heap = std.heap;
const mem = std.mem;
const meta = std.meta;
const ArrayList = std.ArrayList;

const vaxis = @import("vaxis");
const lazymail = @import("lazymail_lib");
const ImapClient = lazymail.ImapClient;

const log = std.log.scoped(.main);

const ActiveSection = enum {
    top,
    mid,
    btm,
};

// fn spawnExample() !void {
    // const progname: []const u8 = "nvim";
    // const argv: [1][]const u8 = .{progname};
    // //try std.process.execv(alloc, &argv);
    // var child = std.process.Child.init(&argv, alloc);
    // const term = try child.spawnAndWait();
    // std.debug.print("Exited with {}\n", .{term});
// }

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.detectLeaks()) log.err("Memory leak detected!", .{});
    const alloc = gpa.allocator();

    // // Users set up below the main function
    // const users_buf = try alloc.dupe(User, users[0..]);
    // defer alloc.free(users_buf);

    var socket_read_buffer: [2048]u8 = undefined;
    var socket_writer_buffer: [2048]u8 = undefined;
    const hostname_bytes = "test.rebex.net";
    const port = ImapClient.IMAP_PORT;
    var client = try ImapClient.init(alloc, hostname_bytes, port, &socket_read_buffer, &socket_writer_buffer);
    defer client.logout();

    var responseBuffer: [2048]u8 = undefined;
    std.debug.print("LOGIN...\n", .{});
    _ = try client.rawRunCommand("LOGIN demo password", &responseBuffer);

    std.debug.print("SELECT INBOX...\n", .{});
    _ = try client.rawRunCommand("SELECT INBOX", &responseBuffer);

    // var mail_headers: [1]lazymail.ParsedHeader = undefined;
    // mail_headers[0] = lazymail.ParsedHeader.parse(responseBuffer[0..n]);

    var headers_bytes = ArrayList([]u8).empty;
    try client.fetchHeaderBytesAlloc(1, null, alloc, &headers_bytes);
    defer {
        for (headers_bytes.items) |header| {
            alloc.free(header);
        }
        headers_bytes.clearAndFree(alloc);
    }

    var header_page: [10]lazymail.ParsedHeader = undefined;
    const num_valid = @min(headers_bytes.items.len, header_page.len);
    for (0..num_valid) |i| {
        header_page[i] = lazymail.ParsedHeader.parse(headers_bytes.items[i]);
    }

    var buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(&buffer);
    defer tty.deinit();
    const tty_writer = tty.writer();
    var vx = try vaxis.init(alloc, .{
        .kitty_keyboard_flags = .{ .report_events = true },
    });
    defer vx.deinit(alloc, tty.writer());

    var loop: vaxis.Loop(union(enum) {
        key_press: vaxis.Key,
        winsize: vaxis.Winsize,
        table_upd,
    }) = .{ .tty = &tty, .vaxis = &vx };
    try loop.init();
    try loop.start();
    defer loop.stop();
    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), 250 * std.time.ns_per_ms);

    const logo =
        \\░█░█░█▀█░█░█░▀█▀░█▀▀░░░▀█▀░█▀█░█▀▄░█░░░█▀▀░
        \\░▀▄▀░█▀█░▄▀▄░░█░░▀▀█░░░░█░░█▀█░█▀▄░█░░░█▀▀░
        \\░░▀░░▀░▀░▀░▀░▀▀▀░▀▀▀░░░░▀░░▀░▀░▀▀░░▀▀▀░▀▀▀░
    ;
    const title_logo = vaxis.Cell.Segment{
        .text = logo,
        .style = .{},
    };
    const title_info = vaxis.Cell.Segment{
        .text = "===A Demo of the the Vaxis Table Widget!===",
        .style = .{},
    };
    const title_disclaimer = vaxis.Cell.Segment{
        .text = "(All data is non-sensical & LLM generated.)",
        .style = .{},
    };
    var title_segs = [_]vaxis.Cell.Segment{ title_logo, title_info, title_disclaimer };

    var cmd_input = vaxis.widgets.TextInput.init(alloc);
    defer cmd_input.deinit();

    // Colors
    const active_bg: vaxis.Cell.Color = .{ .rgb = .{ 64, 128, 255 } };
    const selected_bg: vaxis.Cell.Color = .{ .rgb = .{ 32, 64, 255 } };
    const other_bg: vaxis.Cell.Color = .{ .rgb = .{ 32, 32, 48 } };

    // Table Context
    var demo_tbl: vaxis.widgets.Table.TableContext = .{
        .active_bg = active_bg,
        .active_fg = .{ .rgb = .{ 0, 0, 0 } },
        .row_bg_1 = .{ .rgb = .{ 8, 8, 8 } },
        .selected_bg = selected_bg,
        // .header_names = .{ .custom = &.{ "First", "Last", "Username", "Phone#", "Email" } },
        //.header_align = .left,
        // .col_indexes = .{ .by_idx = &.{ 0, 1, 2, 3 } },
        //.col_align = .{ .by_idx = &.{ .left, .left, .center, .center, .left } },
        .col_align = .{ .all = .left },
        .header_borders = true,
        .col_borders = true,
        // .col_width = .{ .static_all = 15 },
        // .col_width = .{ .dynamic_header_len = 3 },
        //.col_width = .{ .static_individual = &.{ 10, 20, 15, 25, 15 } },
        // .col_width = .{ .dynamic_header_len = 2 },
        //.y_off = 10,
    };
    defer if (demo_tbl.sel_rows) |rows| alloc.free(rows);

    // TUI State
    var active: ActiveSection = .mid;
    var moving = false;
    var see_content = false;

    // Create an Arena Allocator for easy allocations on each Event.
    var event_arena = heap.ArenaAllocator.init(alloc);
    defer event_arena.deinit();
    while (true) {
        defer _ = event_arena.reset(.retain_capacity);
        defer tty_writer.flush() catch {};
        const event_alloc = event_arena.allocator();
        const event = loop.nextEvent();

        switch (event) {
            .key_press => |key| keyEvt: {
                // Close the Program
                if (key.matches('c', .{ .ctrl = true })) {
                    break;
                }
                if (key.matches('q', .{})) {
                    break;
                }
                // Refresh the Screen
                if (key.matches('l', .{ .ctrl = true })) {
                    vx.queueRefresh();
                    break :keyEvt;
                }
                // Enter Moving State
                if (key.matches('w', .{ .ctrl = true })) {
                    moving = !moving;
                    break :keyEvt;
                }
                // Command State
                if (active != .btm and
                    key.matchesAny(&.{ ':', '/', 'g', 'G' }, .{}))
                {
                    active = .btm;
                    cmd_input.clearAndFree();
                    try cmd_input.update(.{ .key_press = key });
                    break :keyEvt;
                }

                switch (active) {
                    .top => {
                        if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{}) and moving) active = .mid;
                    },
                    .mid => midEvt: {
                        if (moving) {
                            if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) active = .top;
                            if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) active = .btm;
                            break :midEvt;
                        }
                        // Change Row
                        if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) demo_tbl.row -|= 1;
                        if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) demo_tbl.row +|= 1;
                        // Change Column
                        if (key.matchesAny(&.{ vaxis.Key.left, 'h' }, .{})) demo_tbl.col -|= 1;
                        if (key.matchesAny(&.{ vaxis.Key.right, 'l' }, .{})) demo_tbl.col +|= 1;
                        // Select/Unselect Row
                        if (key.matches(vaxis.Key.space, .{})) {
                            const rows = demo_tbl.sel_rows orelse createRows: {
                                demo_tbl.sel_rows = try alloc.alloc(u16, 1);
                                break :createRows demo_tbl.sel_rows.?;
                            };
                            var rows_list = std.ArrayList(u16).fromOwnedSlice(rows);
                            for (rows_list.items, 0..) |row, idx| {
                                if (row != demo_tbl.row) continue;
                                _ = rows_list.orderedRemove(idx);
                                break;
                            } else try rows_list.append(alloc, demo_tbl.row);
                            demo_tbl.sel_rows = try rows_list.toOwnedSlice(alloc);
                        }
                        // See Row Content
                        if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true })) see_content = !see_content;
                    },
                    .btm => {
                        if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{}) and moving) active = .mid
                            // Run Command and Clear Command Bar
                        else if (key.matchExact(vaxis.Key.enter, .{}) or key.matchExact('j', .{ .ctrl = true })) {
                            const cmd = try cmd_input.toOwnedSlice();
                            defer alloc.free(cmd);
                            if (mem.eql(u8, ":q", cmd) or
                                mem.eql(u8, ":quit", cmd) or
                                mem.eql(u8, ":exit", cmd)) return;
                            if (mem.eql(u8, "G", cmd)) {
                                demo_tbl.row = @intCast(num_valid);
                                active = .mid;
                            }
                            if (cmd.len >= 2 and mem.eql(u8, "gg", cmd[0..2])) {
                                const goto_row = fmt.parseInt(u16, cmd[2..], 0) catch 0;
                                demo_tbl.row = goto_row;
                                active = .mid;
                            }
                        } else try cmd_input.update(.{ .key_press = key });
                    },
                }
                moving = false;
            },
            .winsize => |ws| try vx.resize(alloc, tty.writer(), ws),
            else => {},
        }

        // Content
        seeRow: {
            if (!see_content) {
                demo_tbl.active_content_fn = null;
                demo_tbl.active_ctx = &{};
                break :seeRow;
            }
            const RowContext = struct {
                row: []const u8,
                bg: vaxis.Color,
            };
            const row_ctx = RowContext{
                .row = try fmt.allocPrint(event_alloc, "Row #: {d}", .{demo_tbl.row}),
                .bg = demo_tbl.active_bg,
            };
            demo_tbl.active_ctx = &row_ctx;
            demo_tbl.active_content_fn = struct {
                fn see(win: *vaxis.Window, ctx_raw: *const anyopaque) !u16 {
                    const ctx: *const RowContext = @ptrCast(@alignCast(ctx_raw));
                    win.height = 5;
                    const see_win = win.child(.{
                        .x_off = 0,
                        .y_off = 1,
                        .width = win.width,
                        .height = 4,
                    });
                    see_win.fill(.{ .style = .{ .bg = ctx.bg } });
                    const content_logo =
                        \\
                        \\░█▀▄░█▀█░█░█░░░█▀▀░█▀█░█▀█░▀█▀░█▀▀░█▀█░▀█▀
                        \\░█▀▄░█░█░█▄█░░░█░░░█░█░█░█░░█░░█▀▀░█░█░░█░
                        \\░▀░▀░▀▀▀░▀░▀░░░▀▀▀░▀▀▀░▀░▀░░▀░░▀▀▀░▀░▀░░▀░
                    ;
                    const content_segs: []const vaxis.Cell.Segment = &.{
                        .{
                            .text = ctx.row,
                            .style = .{ .bg = ctx.bg },
                        },
                        .{
                            .text = content_logo,
                            .style = .{ .bg = ctx.bg },
                        },
                    };
                    _ = see_win.print(content_segs, .{});
                    return see_win.height;
                }
            }.see;
            loop.postEvent(.table_upd);
        }

        // Sections
        // - Window
        const win = vx.window();
        win.clear();

        // - Top
        const top_div = 6;
        const top_bar = win.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = win.width,
            .height = win.height / top_div,
        });
        for (title_segs[0..]) |*title_seg|
            title_seg.style.bg = if (active == .top) selected_bg else other_bg;
        top_bar.fill(.{ .style = .{
            .bg = if (active == .top) selected_bg else other_bg,
        } });
        const logo_bar = vaxis.widgets.alignment.center(
            top_bar,
            44,
            top_bar.height - (top_bar.height / 3),
        );
        _ = logo_bar.print(title_segs[0..], .{ .wrap = .word });

        // - Middle
        const middle_bar = win.child(.{
            .x_off = 0,
            .y_off = win.height / top_div,
            .width = win.width,
            .height = win.height - (top_bar.height + 1),
        });
        const slc: []const lazymail.ParsedHeader = header_page[0..num_valid];
        if (num_valid > 0) {
            demo_tbl.active = active == .mid;
            try vaxis.widgets.Table.drawTable(
                null,
                middle_bar,
                slc,
                &demo_tbl,
            );
        }

        // - Bottom
        const bottom_bar = win.child(.{
            .x_off = 0,
            .y_off = win.height - 1,
            .width = win.width,
            .height = 1,
        });
        if (active == .btm) bottom_bar.fill(.{ .style = .{ .bg = active_bg } });
        cmd_input.draw(bottom_bar);

        // Render the screen
        try vx.render(tty_writer);
    }
}

