//! Small UTF-8 PCRE2 wrapper extracted from dirtree's path matcher.

const std = @import("std");

const c = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});

pub const Error = error{
    CompileFailed,
    MatchFailed,
    OutOfMemory,
    WorkspaceOverflow,
};

pub const Regex = struct {
    code: *c.pcre2_code_8,
    match_data: *c.pcre2_match_data_8,
    workspace: []c_int,
    allocator: std.mem.Allocator,

    const default_workspace_size: usize = 256;

    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) Error!Regex {
        var error_code: c_int = 0;
        var error_offset: c.PCRE2_SIZE = 0;
        const code = c.pcre2_compile_8(
            pattern.ptr,
            pattern.len,
            c.PCRE2_UTF | c.PCRE2_UCP,
            &error_code,
            &error_offset,
            null,
        ) orelse return error.CompileFailed;

        const match_data = c.pcre2_match_data_create_from_pattern_8(code, null) orelse {
            c.pcre2_code_free_8(code);
            return error.OutOfMemory;
        };
        const workspace = allocator.alloc(c_int, default_workspace_size) catch {
            c.pcre2_match_data_free_8(match_data);
            c.pcre2_code_free_8(code);
            return error.OutOfMemory;
        };
        return .{
            .code = code,
            .match_data = match_data,
            .workspace = workspace,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Regex) void {
        self.allocator.free(self.workspace);
        c.pcre2_match_data_free_8(self.match_data);
        c.pcre2_code_free_8(self.code);
    }

    pub fn matches(self: *Regex, subject: []const u8) Error!bool {
        while (true) {
            const result = c.pcre2_dfa_match_8(
                self.code,
                subject.ptr,
                subject.len,
                0,
                c.PCRE2_ANCHORED | c.PCRE2_ENDANCHORED,
                self.match_data,
                null,
                self.workspace.ptr,
                self.workspace.len,
            );
            if (result == c.PCRE2_ERROR_DFA_WSSIZE) {
                try self.growWorkspace();
                continue;
            }
            if (result == c.PCRE2_ERROR_NOMATCH) return false;
            if (result < 0) return error.MatchFailed;
            return true;
        }
    }

    fn growWorkspace(self: *Regex) Error!void {
        const new_size = self.workspace.len * 2;
        if (new_size < self.workspace.len) return error.WorkspaceOverflow;
        self.workspace = self.allocator.realloc(self.workspace, new_size) catch return error.OutOfMemory;
    }
};
