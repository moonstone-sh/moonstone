const std = @import("std");

pub const root = @import("coordinator.zig");
pub const coordinator = @import("coordinator.zig");
pub const request = @import("request.zig");
pub const options = @import("options.zig");
pub const candidate = @import("candidate.zig");
pub const selection = @import("selection.zig");
pub const plan = @import("plan.zig");

pub const sources = struct {
    pub const source = @import("sources/source.zig");
    pub const moonstone_registry = @import("sources/moonstone_registry.zig");
    pub const luarocks = @import("sources/luarocks.zig");
    pub const path = @import("sources/path.zig");
    pub const link = @import("sources/link.zig");
    pub const artifact_hash = @import("sources/artifact_hash.zig");
};

pub const provider = struct {
    pub const package_provider = @import("provider/package_provider.zig");
    pub const graph_provider = @import("provider/graph_provider.zig");
};

pub const solver = struct {
    pub const pubgrub = @import("solver/pubgrub.zig");
    pub const term = @import("solver/term.zig");
    pub const incompatibility = @import("solver/incompatibility.zig");
    pub const assignment = @import("solver/assignment.zig");
    pub const partial_solution = @import("solver/partial_solution.zig");
    pub const report = @import("solver/report.zig");
};

pub const CoordinatorKind = coordinator.CoordinatorKind;
pub const ResolverKind = coordinator.CoordinatorKind;

pub const Candidate = candidate.Candidate;
pub const ResolutionPlan = plan.ResolutionPlan;
pub const ResolvedPackage = plan.ResolvedPackage;

pub const ResolvedArtifact = candidate.ResolvedArtifact;

pub const ResolveResult = candidate.ResolvedArtifact;
pub const ResolveOptions = options.ResolveOptions;
pub const ResolveCallback = options.ResolveCallback;
pub const ResolveEvent = options.ResolveEvent;
pub const ResolveRequest = request.ResolveRequest;

