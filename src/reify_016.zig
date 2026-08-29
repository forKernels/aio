// reify_016.zig — reflective type construction for Zig 0.16+.
// Copyright The Fantastic Planet - By David Clabaugh
//
// The 0.15.x twin is reify_pre016.zig; build.zig picks ONE by compiler version.
// See that file for why this is a file split rather than a comptime branch.
//
// 0.16 removed @Type. Reflective construction moved to dedicated builtins --
// @Union, @Enum, @Struct -- which take parallel name/type slices instead of a
// field-struct array, and the enum-literal type is now spelled with @TypeOf.

const std = @import("std");

/// The type of an enum literal.
pub const EnumLiteral = @TypeOf(.enum_literal_probe);

/// Build a tagged union from its fields. Takes the same UnionField slice as the
/// 0.15.x twin -- std.builtin.Type.UnionField still exists -- and unpacks it
/// into the parallel slices @Union wants, so callers do not have to care which
/// compiler they are on.
pub fn Union(
    comptime Enum: type,
    comptime fields: []const std.builtin.Type.UnionField,
) type {
    comptime var names: []const [:0]const u8 = &.{};
    comptime var types: []const type = &.{};
    inline for (fields) |f| {
        names = names ++ &[_][:0]const u8{f.name};
        types = types ++ &[_]type{f.type};
    }
    // Alignment travels in the attributes slice now; default is natural.
    return @Union(.auto, Enum, names, types, &@splat(.{}));
}
