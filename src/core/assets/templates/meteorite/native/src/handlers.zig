pub fn root(ctx: anytype) !void {
    try ctx.text(200, "hello from {{name}}");
}

pub fn health(ctx: anytype) !void {
    try ctx.json(200, "{\"ok\":true}");
}
