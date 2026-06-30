import os

filepath = "src/core/resolution/solver/report.zig"
with open(filepath, "r") as f:
    content = f.read()

old_root = """        .root => {
            try writer.print("the root project depends on {s} ({})", .{ inc.terms[0].name, inc.terms[0].range });
        },"""
new_root = """        .root => {
            try writer.print("the root project depends on {s} (", .{ inc.terms[0].name });
            try inc.terms[0].range.print(writer);
            try writer.print(")", .{});
        },"""
content = content.replace(old_root, new_root)

old_dep = """        .dependency => {
            const dep_range = try inc.terms[1].range.complement(allocator);
            defer dep_range.deinit(allocator);
            try writer.print("{s} ({}) depends on {s} ({})", .{ inc.terms[0].name, inc.terms[0].range, inc.terms[1].name, dep_range });
        },"""
new_dep = """        .dependency => {
            const dep_range = try inc.terms[1].range.complement(allocator);
            defer dep_range.deinit(allocator);
            try writer.print("{s} (", .{ inc.terms[0].name });
            try inc.terms[0].range.print(writer);
            try writer.print(") depends on {s} (", .{ inc.terms[1].name });
            try dep_range.print(writer);
            try writer.print(")", .{});
        },"""
content = content.replace(old_dep, new_dep)

old_no_versions = """        .no_versions => {
            try writer.print("no versions of {s} match ({})", .{ inc.terms[0].name, inc.terms[0].range });
        },"""
new_no_versions = """        .no_versions => {
            try writer.print("no versions of {s} match (", .{ inc.terms[0].name });
            try inc.terms[0].range.print(writer);
            try writer.print(")", .{});
        },"""
content = content.replace(old_no_versions, new_no_versions)

with open(filepath, "w") as f:
    f.write(content)
