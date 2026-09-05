//! LZMA2-only z7z surface for difz. Avoids z7z's C FFI export module.
pub const lzma2_encoder = @import("lzma2_encoder");
