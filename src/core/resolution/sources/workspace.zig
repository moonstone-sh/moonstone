//! Workspace-member resolution: a dependency whose package name names a
//! declared orbit member of the current workspace resolves to that member's
//! directory, without consulting any registry or link store.
//!
//! THE SPLIT THIS ENCODES:
//!
//!   Orbit membership decides LOCATION.
//!   The declared constraint decides COMPATIBILITY.
//!
//! A version requirement is therefore never needed to *locate* a member -- it
//! is an assertion over the member's own manifest version. If the member does
//! not satisfy it, that is a resolution ERROR. It emphatically does not fall
//! through to the registry: a workspace whose members disagree with their own
//! declared constraints is internally inconsistent, and silently substituting
//! a published copy would make one machine's checkout mean something different
//! from another's. Cargo's `{ path, version }` has the same semantics, and for
//! the same reason.
//!
//! WHY THIS EXISTS AT ALL. `project/orbits.zig` has always known every
//! member's package name and directory, but only `orbit run/list/exec` ever
//! called it -- the map was computed and thrown away before anything resolved
//! a dependency. So a member could not depend on a sibling member without
//! `moon link` writing an absolute path into a global mutable store and
//! `registry = "link"` into a committed manifest. That made checkouts
//! machine-dependent, and it is the reason this module exists.
//!
//! WHAT IT DELIBERATELY DOES NOT DO: it ignores the member's `[interpreter]`
//! block. That block says how a member is built and tested as a project; it is
//! not a statement about what an importer must run. Those are separate
//! concerns -- keeping orbits able to mix interpreters is part of why orbits
//! exist -- and coupling them here would be a latent bug that only surfaces
//! the first time a workspace contains two.

const std = @import("std");
const manifest = @import("../../domain/manifest.zig");
const semver = @import("../../domain/semver.zig");
const candidate_mod = @import("../candidate.zig");

/// One declared member, with the identity a dependency resolves against.
pub const Member = struct {
    /// The member's `[package] name`, e.g. "hydronium/cli".
    package_name: []const u8,
    /// Workspace-relative directory, e.g. "cli". NEVER absolute: an absolute
    /// path in resolved state is what makes a checkout mean different things
    /// on different machines.
    rel_path: []const u8,
    /// Absolute path on this machine. Used ONLY at runtime, to read the
    /// member's files during materialization. It is never serialized: the
    /// lock and every exported descriptor carry `rel_path` instead, so a
    /// checkout means the same thing on every machine.
    abs_path: []const u8,
    /// The member's own manifest version, which a declared constraint is
    /// checked against.
    version: []const u8,
    kind: manifest.Kind,

    pub fn deinit(self: *Member, allocator: std.mem.Allocator) void {
        allocator.free(self.package_name);
        allocator.free(self.rel_path);
        allocator.free(self.abs_path);
        allocator.free(self.version);
    }
};

pub const Members = struct {
    items: []Member,

    pub fn deinit(self: *Members, allocator: std.mem.Allocator) void {
        for (self.items) |*m| m.deinit(allocator);
        allocator.free(self.items);
        self.items = &.{};
    }

    /// The member declaring `pkg_name`, or null.
    ///
    /// Exact match on the fully qualified package name, so namespacing does
    /// the disambiguating: a workspace may contain a member named
    /// `hydronium/meteorite` while also depending on the unrelated registry
    /// package `moonstone/meteorite`, and only the first resolves locally.
    pub fn find(self: Members, pkg_name: []const u8) ?Member {
        for (self.items) |m| {
            if (std.mem.eql(u8, m.package_name, pkg_name)) return m;
        }
        return null;
    }
};

pub const Error = error{
    /// The member exists but its manifest version does not satisfy the
    /// declared constraint. Deliberately fatal -- see this file's header.
    WorkspaceMemberVersionMismatch,
};

/// Reads every declared orbit member's manifest and returns the resolution
/// map. Members whose directory has no manifest are skipped rather than
/// failing the whole load: `moon orbit list` reports those separately, and a
/// half-created member should not make every unrelated dependency unresolvable.
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    root_manifest: *const manifest.MoonstoneToml,
) !Members {
    var out = std.ArrayList(Member).empty;
    errdefer {
        for (out.items) |*m| m.deinit(allocator);
        out.deinit(allocator);
    }

    for (root_manifest.orbits.items) |orbit_cfg| {
        const abs_dir = try std.fs.path.join(allocator, &.{ project_root, orbit_cfg.path });
        errdefer allocator.free(abs_dir);
        const manifest_path = try std.fs.path.join(allocator, &.{ abs_dir, "moonstone.toml" });
        defer allocator.free(manifest_path);
        var keep_abs = false;
        defer if (!keep_abs) allocator.free(abs_dir);

        // Same read-then-parse orbits.zig uses. A member whose directory has
        // no readable manifest is SKIPPED rather than failing the load: a
        // half-created member must not make every unrelated dependency in the
        // workspace unresolvable, and `moon orbit list` reports those already.
        const content = std.Io.Dir.cwd().readFileAlloc(
            io,
            manifest_path,
            allocator,
            std.Io.Limit.limited(1024 * 1024),
        ) catch continue;
        defer allocator.free(content);

        var member_manifest = manifest.MoonstoneToml.parse(allocator, content) catch continue;
        defer member_manifest.deinit(allocator);

        if (member_manifest.package.name.len == 0) continue;

        keep_abs = true;
        try out.append(allocator, .{
            .package_name = try allocator.dupe(u8, member_manifest.package.name),
            .rel_path = try allocator.dupe(u8, orbit_cfg.path),
            .abs_path = abs_dir,
            .version = try allocator.dupe(u8, member_manifest.package.version),
            // Enum, not a string: no allocation, and nothing to free.
            .kind = member_manifest.package.kind,
        });
    }

    return .{ .items = try out.toOwnedSlice(allocator) };
}

/// Checks a declared constraint against a member's own manifest version.
///
/// An empty or `*` constraint is a workspace-only relationship: perfectly
/// reasonable for a member that is never published, and nothing to check.
///
/// Everything else defers to semver.matches, so a constraint means exactly
/// what the same constraint means anywhere else in Moonstone. Worth knowing
/// that Moonstone's caret is `>=v, <(major+1).0.0` with NO 0.x special case --
/// `^0.1.0` admits 0.2.0 here, where npm and Cargo would refuse it. Whether
/// that is the right rule is a separate question from this module; what
/// matters here is that a workspace constraint is not a second dialect.
pub fn satisfies(member: Member, constraint: []const u8) bool {
    if (constraint.len == 0) return true;
    if (std.mem.eql(u8, constraint, "*")) return true;
    return semver.matches(member.version, constraint);
}

/// Builds the candidate for a locally resolved member.
///
/// The candidate carries no artifact hash: a workspace member is live source,
/// not an immutable artifact. Build/CAS identity is computed when the member
/// is actually built or cached, and is a different question from which
/// dependency was selected. Conflating them would mean every edit to a member
/// invalidates the lockfile of everything that depends on it.
pub fn candidateFor(
    allocator: std.mem.Allocator,
    member: Member,
    constraint: []const u8,
) !candidate_mod.Candidate {
    if (!satisfies(member, constraint)) return Error.WorkspaceMemberVersionMismatch;

    return candidate_mod.Candidate{
        .name = try allocator.dupe(u8, member.package_name),
        .version = try allocator.dupe(u8, member.version),
        .kind = member.kind,
        .artifact_hash = try allocator.dupe(u8, "workspace"),
        .runtime = try allocator.dupe(u8, ""),
        .runtime_artifact_hash = try allocator.dupe(u8, ""),
        .lua_abi = try allocator.dupe(u8, ""),
        .lua_api = try allocator.dupe(u8, ""),
        // Absolute, for reading files during materialization. The lock gets
        // rel_path from `origin` below, never this.
        .local_path = try allocator.dupe(u8, member.abs_path),
        .origin = .{ .workspace = .{
            .member = try allocator.dupe(u8, member.package_name),
            .rel_path = try allocator.dupe(u8, member.rel_path),
        } },
        // local_path, carrying the workspace-relative directory: the member
        // is live source on disk, not an entry in the content-addressed store.
        .location = .{ .local_path = try allocator.dupe(u8, member.rel_path) },
    };
}

test "find matches on the fully qualified name only" {
    const allocator = std.testing.allocator;
    var items = [_]Member{
        .{
            .package_name = try allocator.dupe(u8, "hydronium/meteorite"),
            .rel_path = try allocator.dupe(u8, "meteorite"),
            .abs_path = try allocator.dupe(u8, "/tmp/ws/meteorite"),
            .version = try allocator.dupe(u8, "0.1.0"),
            .kind = .lib,
        },
    };
    const members = Members{ .items = &items };
    // NOT members.deinit(): `items` is a stack array here, and Members.deinit
    // frees the slice itself. Free the members' own allocations only.
    defer for (&items) |*m| m.deinit(allocator);

    try std.testing.expect(members.find("hydronium/meteorite") != null);
    // The unrelated registry package of a similar name must NOT resolve
    // locally. This is a real pair in the hydronium workspace.
    try std.testing.expect(members.find("moonstone/meteorite") == null);
    try std.testing.expect(members.find("meteorite") == null);
}

test "constraint is an assertion over the member version" {
    const allocator = std.testing.allocator;
    var m = Member{
        .package_name = try allocator.dupe(u8, "acme/lib"),
        .rel_path = try allocator.dupe(u8, "lib"),
        .abs_path = try allocator.dupe(u8, "/tmp/ws/lib"),
        .version = try allocator.dupe(u8, "0.2.0"),
        .kind = .lib,
    };
    defer m.deinit(allocator);

    // No constraint: a workspace-only relationship needs none.
    try std.testing.expect(satisfies(m, ""));
    try std.testing.expect(satisfies(m, "*"));
    try std.testing.expect(satisfies(m, "^0.2.0"));
    // Moonstone's caret has no 0.x special case, so this one PASSES here even
    // though npm/Cargo would reject it. Asserted deliberately: it documents
    // which dialect this module speaks.
    try std.testing.expect(satisfies(m, "^0.1.0"));

    // Mismatch must be refused, not quietly satisfied from a registry.
    try std.testing.expect(!satisfies(m, "^1.0.0"));
    try std.testing.expect(!satisfies(m, ">=0.3.0"));

    const err = candidateFor(allocator, m, "^1.0.0");
    try std.testing.expectError(Error.WorkspaceMemberVersionMismatch, err);
}
