const std = @import("std");

pub fn main() void {
    var mutex = std.Thread.Mutex{};
    mutex.lock();
    mutex.unlock();
}
