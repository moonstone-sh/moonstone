const std = @import("std");

const MutexAllocator = struct {
    parent: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    pub fn allocator(self: *MutexAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *MutexAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.parent.rawAlloc(len, ptr_align, ret_addr);
    }
    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *MutexAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.parent.rawResize(buf, buf_align, new_len, ret_addr);
    }
    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        const self: *MutexAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.parent.rawFree(buf, buf_align, ret_addr);
    }
};

pub fn main() void {
    var ma = MutexAllocator{ .parent = std.heap.page_allocator };
    _ = ma.allocator();
}
