// Both modules share one import root and the original metadata type identity.
pub const metadata = @import("metadata.zig");
pub const directory = @import("directory.zig");
pub const tree_patch = @import("directory_patch.zig");
pub const path_filter = @import("path_filter.zig");
pub const symlink_transport = @import("symlink_transport.zig");
pub const linux_acl = @import("native_acl.zig");
