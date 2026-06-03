//! Scrollable column layout state for the Niri-style layout.

const std = @import("std");

const WindowId = @import("window.zig").WindowId;
const Frame = @import("window.zig").Window.Frame;

pub const Direction = enum {
    left,
    right,
    up,
    down,
};

pub const LayoutEntry = struct {
    wid: WindowId,
    frame: Frame,
    visible: bool,
};

/// A Niri column. Named Node to keep layout terminology local to this module
/// without reusing the BSP tree node type from layout.zig.
pub const Node = struct {
    windows: std.ArrayList(WindowId) = .empty,

    pub fn initSingle(allocator: std.mem.Allocator, wid: WindowId) !Node {
        var node: Node = .{};
        try node.windows.append(allocator, wid);
        return node;
    }

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        self.windows.deinit(allocator);
        self.* = .{};
    }

    pub fn activeWid(self: *const Node, row: usize) WindowId {
        std.debug.assert(self.windows.items.len > 0);
        return self.windows.items[@min(row, self.windows.items.len - 1)];
    }

    pub fn contains(self: *const Node, wid: WindowId) bool {
        return self.indexOf(wid) != null;
    }

    pub fn indexOf(self: *const Node, wid: WindowId) ?usize {
        for (self.windows.items, 0..) |existing, index| {
            if (existing == wid) return index;
        }
        return null;
    }

    pub fn removeAt(self: *Node, index: usize) WindowId {
        std.debug.assert(index < self.windows.items.len);
        return self.windows.orderedRemove(index);
    }
};

pub const State = struct {
    columns: std.ArrayList(Node) = .empty,
    focused_column: usize = 0,
    focused_row: usize = 0,
    viewport_x: f64 = 0,

    pub fn init() State {
        return .{};
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.columns.items) |*column| {
            column.deinit(allocator);
        }
        self.columns.deinit(allocator);
        self.* = .{};
    }

    pub fn windowCount(self: *const State) usize {
        var count: usize = 0;
        for (self.columns.items) |column| {
            count += column.windows.items.len;
        }
        return count;
    }

    pub fn insertWindow(self: *State, allocator: std.mem.Allocator, wid: WindowId) !void {
        if (self.findWindow(wid) != null) return;

        const insert_index = if (self.columns.items.len == 0)
            0
        else
            @min(self.focused_column + 1, self.columns.items.len);

        var column = try Node.initSingle(allocator, wid);
        errdefer column.deinit(allocator);
        try self.columns.insert(allocator, insert_index, column);
        self.focused_column = insert_index;
        self.focused_row = 0;
    }

    pub fn removeWindow(self: *State, allocator: std.mem.Allocator, wid: WindowId) bool {
        const location = self.findWindow(wid) orelse return false;
        var column = &self.columns.items[location.column];
        _ = column.removeAt(location.row);

        if (column.windows.items.len == 0) {
            column.deinit(allocator);
            _ = self.columns.orderedRemove(location.column);
            if (self.columns.items.len == 0) {
                self.focused_column = 0;
                self.focused_row = 0;
                self.viewport_x = 0;
                return true;
            }
            if (self.focused_column == location.column) {
                self.focused_column = @min(location.column, self.columns.items.len - 1);
            } else if (location.column < self.focused_column) {
                self.focused_column -= 1;
            }
            self.focused_row = @min(self.focused_row, self.columns.items[self.focused_column].windows.items.len - 1);
            return true;
        }

        if (self.focused_column == location.column) {
            self.focused_row = @min(self.focused_row, column.windows.items.len - 1);
        } else if (location.column < self.focused_column) {
            self.focused_column -= 1;
        }
        return true;
    }

    pub fn setActive(self: *State, wid: WindowId) bool {
        const location = self.findWindow(wid) orelse return false;
        self.focused_column = location.column;
        self.focused_row = location.row;
        return true;
    }

    pub fn focusedWid(self: *const State) ?WindowId {
        if (self.columns.items.len == 0) return null;
        const column = self.columns.items[self.focused_column];
        if (column.windows.items.len == 0) return null;
        return column.activeWid(self.focused_row);
    }

    pub fn focus(self: *State, direction: Direction) ?WindowId {
        if (self.columns.items.len == 0) return null;
        const column = &self.columns.items[self.focused_column];
        switch (direction) {
            .left => if (self.focused_column > 0) {
                self.focused_column -= 1;
                self.focused_row = @min(self.focused_row, self.columns.items[self.focused_column].windows.items.len - 1);
            },
            .right => if (self.focused_column + 1 < self.columns.items.len) {
                self.focused_column += 1;
                self.focused_row = @min(self.focused_row, self.columns.items[self.focused_column].windows.items.len - 1);
            },
            .up => if (self.focused_row > 0) {
                self.focused_row -= 1;
            },
            .down => if (self.focused_row + 1 < column.windows.items.len) {
                self.focused_row += 1;
            },
        }
        return self.focusedWid();
    }

    pub fn consumeFocused(self: *State, allocator: std.mem.Allocator, side: Direction) !bool {
        std.debug.assert(side == .left or side == .right);
        if (self.columns.items.len < 2) return false;
        const source_column = self.focused_column;
        const target_column = switch (side) {
            .left => if (source_column == 0) return false else source_column - 1,
            .right => if (source_column + 1 >= self.columns.items.len) return false else source_column + 1,
            else => unreachable,
        };

        const wid = self.columns.items[source_column].removeAt(self.focused_row);
        var adjusted_target = target_column;
        if (self.columns.items[source_column].windows.items.len == 0) {
            self.columns.items[source_column].deinit(allocator);
            _ = self.columns.orderedRemove(source_column);
            if (source_column < adjusted_target) adjusted_target -= 1;
        }

        try self.columns.items[adjusted_target].windows.append(allocator, wid);
        self.focused_column = adjusted_target;
        self.focused_row = self.columns.items[adjusted_target].windows.items.len - 1;
        return true;
    }

    pub fn expelFocused(self: *State, allocator: std.mem.Allocator, side: Direction) !bool {
        std.debug.assert(side == .left or side == .right);
        if (self.columns.items.len == 0) return false;
        var column = &self.columns.items[self.focused_column];
        if (column.windows.items.len < 2) return false;

        const source_column = self.focused_column;
        const wid = column.removeAt(self.focused_row);
        const insert_index = switch (side) {
            .left => source_column,
            .right => source_column + 1,
            else => unreachable,
        };
        var new_column = try Node.initSingle(allocator, wid);
        errdefer new_column.deinit(allocator);
        try self.columns.insert(allocator, insert_index, new_column);
        self.focused_column = insert_index;
        self.focused_row = 0;
        return true;
    }

    pub fn applyLayout(
        self: *State,
        frame: Frame,
        inner_gap: f64,
        column_width: f64,
        output: *std.ArrayList(LayoutEntry),
        allocator: std.mem.Allocator,
    ) !void {
        std.debug.assert(inner_gap >= 0);
        std.debug.assert(column_width > 0);
        if (self.columns.items.len == 0) return;

        self.updateViewport(frame.width, inner_gap, column_width);

        const stride = column_width + inner_gap;
        for (self.columns.items, 0..) |column, column_index| {
            const natural_x = @as(f64, @floatFromInt(column_index)) * stride;
            const column_frame: Frame = .{
                .x = frame.x + natural_x - self.viewport_x,
                .y = frame.y,
                .width = column_width,
                .height = frame.height,
            };
            const visible = fullyVisible(column_frame, frame);
            try appendColumnEntries(column, column_frame, inner_gap, visible, output, allocator);
        }
    }

    fn updateViewport(self: *State, viewport_width: f64, inner_gap: f64, column_width: f64) void {
        std.debug.assert(viewport_width >= 0);
        const stride = column_width + inner_gap;
        const left = @as(f64, @floatFromInt(self.focused_column)) * stride;
        const right = left + column_width;

        if (left < self.viewport_x) {
            self.viewport_x = left;
        } else if (right > self.viewport_x + viewport_width) {
            self.viewport_x = right - viewport_width;
        }

        if (self.viewport_x < 0) self.viewport_x = 0;
    }

    const Location = struct {
        column: usize,
        row: usize,
    };

    fn findWindow(self: *const State, wid: WindowId) ?Location {
        for (self.columns.items, 0..) |column, column_index| {
            if (column.indexOf(wid)) |row| {
                return .{ .column = column_index, .row = row };
            }
        }
        return null;
    }
};

fn fullyVisible(column: Frame, viewport: Frame) bool {
    const tol: f64 = 0.5;
    return column.x >= viewport.x - tol and
        column.x + column.width <= viewport.x + viewport.width + tol;
}

fn appendColumnEntries(
    column: Node,
    column_frame: Frame,
    inner_gap: f64,
    visible: bool,
    output: *std.ArrayList(LayoutEntry),
    allocator: std.mem.Allocator,
) !void {
    const count = column.windows.items.len;
    if (count == 0) return;

    const gap_total = inner_gap * @as(f64, @floatFromInt(count - 1));
    const row_height = @max(1.0, (column_frame.height - gap_total) / @as(f64, @floatFromInt(count)));

    for (column.windows.items, 0..) |wid, row| {
        try output.append(allocator, .{
            .wid = wid,
            .frame = .{
                .x = column_frame.x,
                .y = column_frame.y + @as(f64, @floatFromInt(row)) * (row_height + inner_gap),
                .width = column_frame.width,
                .height = row_height,
            },
            .visible = visible,
        });
    }
}

const t = std.testing;

test "niri inserts new windows to the right of focused column" {
    var state: State = .init();
    defer state.deinit(t.allocator);

    try state.insertWindow(t.allocator, 1);
    try state.insertWindow(t.allocator, 2);
    try state.insertWindow(t.allocator, 3);

    try t.expectEqual(@as(usize, 3), state.columns.items.len);
    try t.expectEqual(@as(WindowId, 1), state.columns.items[0].windows.items[0]);
    try t.expectEqual(@as(WindowId, 2), state.columns.items[1].windows.items[0]);
    try t.expectEqual(@as(WindowId, 3), state.columns.items[2].windows.items[0]);
    try t.expectEqual(@as(WindowId, 3), state.focusedWid().?);
}

test "niri minimally scrolls focused column into view" {
    var state: State = .init();
    defer state.deinit(t.allocator);
    for (1..5) |wid| {
        try state.insertWindow(t.allocator, @intCast(wid));
    }

    var out: std.ArrayList(LayoutEntry) = .empty;
    defer out.deinit(t.allocator);
    try state.applyLayout(.{ .x = 0, .y = 0, .width = 100, .height = 100 }, 0, 50, &out, t.allocator);

    try t.expectApproxEqAbs(@as(f64, 100), state.viewport_x, 0.001);
    try t.expect(out.items[0].visible == false);
    try t.expect(out.items[2].visible == true);
    try t.expect(out.items[3].visible == true);
}

test "niri consume and expel focused window" {
    var state: State = .init();
    defer state.deinit(t.allocator);
    try state.insertWindow(t.allocator, 1);
    try state.insertWindow(t.allocator, 2);
    try state.insertWindow(t.allocator, 3);

    try t.expect(try state.consumeFocused(t.allocator, .left));
    try t.expectEqual(@as(usize, 2), state.columns.items.len);
    try t.expectEqual(@as(usize, 2), state.columns.items[1].windows.items.len);
    try t.expectEqual(@as(WindowId, 3), state.focusedWid().?);

    try t.expect(try state.expelFocused(t.allocator, .right));
    try t.expectEqual(@as(usize, 3), state.columns.items.len);
    try t.expectEqual(@as(WindowId, 3), state.focusedWid().?);
}

test "niri removing a left column preserves focused column" {
    var state: State = .init();
    defer state.deinit(t.allocator);
    try state.insertWindow(t.allocator, 1);
    try state.insertWindow(t.allocator, 2);
    try state.insertWindow(t.allocator, 3);
    try t.expectEqual(@as(WindowId, 3), state.focusedWid().?);

    try t.expect(state.removeWindow(t.allocator, 1));
    try t.expectEqual(@as(WindowId, 3), state.focusedWid().?);
    try t.expectEqual(@as(usize, 1), state.focused_column);
}

test "niri stacked column gets equal height frames" {
    var state: State = .init();
    defer state.deinit(t.allocator);
    try state.insertWindow(t.allocator, 1);
    try state.insertWindow(t.allocator, 2);
    try t.expect(try state.consumeFocused(t.allocator, .left));

    var out: std.ArrayList(LayoutEntry) = .empty;
    defer out.deinit(t.allocator);
    try state.applyLayout(.{ .x = 0, .y = 0, .width = 100, .height = 102 }, 2, 50, &out, t.allocator);

    try t.expectEqual(@as(usize, 2), out.items.len);
    try t.expectApproxEqAbs(@as(f64, 50), out.items[0].frame.height, 0.001);
    try t.expectApproxEqAbs(@as(f64, 52), out.items[1].frame.y, 0.001);
}
