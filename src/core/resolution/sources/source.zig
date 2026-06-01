const std = @import("std");
const semver = @import("../../domain/semver.zig");
const candidate_mod = @import("../candidate.zig");

pub const CandidateSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        findCandidates: *const fn (ctx: *anyopaque, pkg_name: []const u8, constraint: []const u8) anyerror![]candidate_mod.ResolvedArtifact,
    };

    pub fn findCandidates(self: CandidateSource, pkg_name: []const u8, constraint: []const u8) ![]candidate_mod.ResolvedArtifact {
        return self.vtable.findCandidates(self.ptr, pkg_name, constraint);
    }
};
