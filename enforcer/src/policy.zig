//! The only place a prompt rule goes. There is one rule by design: a single
//! substring scan keeps the hook predictable and the binary small.

const std = @import("std");

pub const Verdict = union(enum) {
    allow,
    block: []const u8,
};

const needle = "ghp_";

/// Case-sensitive on purpose: `GHP_` is not a GitHub token.
pub fn evaluate(prompt: []const u8) Verdict {
    if (std.mem.indexOf(u8, prompt, needle) != null) {
        return .{ .block = "prompt contains what looks like a GitHub token (ghp_...)" };
    }
    return .allow;
}

test "blocks the GitHub classic token prefix" {
    const verdict = evaluate("please use ghp_abc123");
    try std.testing.expect(verdict == .block);
    try std.testing.expect(std.mem.indexOf(u8, verdict.block, "GitHub") != null);
}

test "allows clean prompts and the uppercase spelling" {
    try std.testing.expect(evaluate("hello") == .allow);
    try std.testing.expect(evaluate("GHP_ABC") == .allow);
    try std.testing.expect(evaluate("github_pat_abc") == .allow);
}
