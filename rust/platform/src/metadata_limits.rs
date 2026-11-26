//! Shared bounds for canonical metadata and its native capture buffers.
#[derive(Clone, Copy, Debug)]
pub struct Limits {
	pub attributes: usize,
	pub metadata_bytes: usize,
	pub extents: usize,
}
impl Default for Limits {
	fn default() -> Self {
		Self {
			attributes: 65_536,
			metadata_bytes: 64 << 20,
			extents: 1_000_000,
		}
	}
}
