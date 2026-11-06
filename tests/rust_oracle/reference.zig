// Both modules share one import root and the original metadata type identity.
pub const metadata = @import("metadata.zig");
pub const directory = @import("directory.zig");
pub const tree_patch = @import("directory_patch.zig");
