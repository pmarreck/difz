//! Computation-only blar surface: BLIP core + compression, no C FFI exports.
pub const core = @import("blip");
pub const compression_mod = @import("compression");
