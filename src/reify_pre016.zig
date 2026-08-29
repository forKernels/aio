// reify_pre016.zig — reflective type construction for Zig 0.15.x.
// Copyright The Fantastic Planet - By David Clabaugh
//
// The 0.16 twin is reify_016.zig; build.zig picks ONE by compiler version.
//
// WHY A FILE SPLIT AND NOT A COMPTIME BRANCH
// ------------------------------------------
// Everywhere else in this port, `if (comptime zig16) A else B` is enough: an
// unknown NAMESPACE MEMBER in the untaken branch is never analysed, so 0.15.2
// never sees std.Io.Dir and 0.16 never sees std.fs.cwd.
//
// Builtins are different. "invalid builtin function" is raised by AstGen, which
// processes the whole file's AST before any comptime branch is evaluated. So a
// dead branch does NOT hide @Type from 0.16, nor @Union from 0.15.2 -- both fail
// in the same file no matter how the condition is written. The only way to keep
// both compilers is for the wrong file never to be reached at all, which means
// selecting it in build.zig.

const std = @import("std");

/// The type of an enum literal.
pub const EnumLiteral = @Type(.enum_literal);

/// Build a tagged union from its fields.
pub fn Union(
    comptime Enum: type,
    comptime fields: []const std.builtin.Type.UnionField,
) type {
    return @Type(.{ .@"union" = .{
        .layout = .auto,
        .fields = fields,
        .decls = &.{},
        .tag_type = Enum,
    } });
}
