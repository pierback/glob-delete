const std = @import("std");

pub fn matches(pattern: []const u8, candidate: []const u8, has_wildcard: bool) bool {
    std.debug.assert(pattern.len > 0);

    if (std.mem.eql(u8, pattern, "*")) return true;
    if (!has_wildcard) {
        return std.mem.eql(u8, pattern, candidate);
    }

    var pattern_index: usize = 0;
    var candidate_index: usize = 0;
    var wildcard_index: ?usize = null;
    var wildcard_candidate_index: usize = 0;

    while (candidate_index < candidate.len) {
        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            wildcard_index = pattern_index;
            pattern_index += 1;
            wildcard_candidate_index = candidate_index;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == candidate[candidate_index]) {
            pattern_index += 1;
            candidate_index += 1;
        } else if (wildcard_index) |index| {
            pattern_index = index + 1;
            wildcard_candidate_index += 1;
            candidate_index = wildcard_candidate_index;
        } else {
            return false;
        }
    }

    while (pattern_index < pattern.len and pattern[pattern_index] == '*') {
        pattern_index += 1;
    }

    return pattern_index == pattern.len;
}

test "matches anchored and wildcard patterns" {
    try std.testing.expect(matches("*", "node_modules", true));
    try std.testing.expect(matches("node_*", "node_modules", true));
    try std.testing.expect(matches("*cache", ".zig-cache", true));
    try std.testing.expect(matches("*foo", "foofoo", true));
    try std.testing.expect(matches("a*b", "abb", true));
    try std.testing.expect(matches("src/*/tmp", "src/one/tmp", true));
    try std.testing.expect(!matches("cache", ".zig-cache", false));
    try std.testing.expect(!matches("src/*/tmp", "src/one/tmp/file", true));
}
