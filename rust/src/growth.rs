//! Declared portable codec workloads. Exhaustive probe consumers must handle
//! every declaration; measurement configuration must cover every operation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Axis {
	ValueBytes,
	Attributes,
	Entries,
	FileBytes,
}
impl Axis {
	pub const fn name(self) -> &'static str {
		match self {
			Self::ValueBytes => "value-bytes",
			Self::Attributes => "attributes",
			Self::Entries => "entries",
			Self::FileBytes => "file-bytes",
		}
	}
}
macro_rules! operations {
	($( $variant:ident => ($name:literal, $model:literal, $axis:ident, $first:expr) ),+ $(,)?) => {
		#[derive(Clone, Copy, Debug, Eq, PartialEq)]
		pub enum Operation { $( $variant ),+ }
		impl Operation {
			pub const ALL: &'static [Self] = &[$( Self::$variant ),+];
			pub const fn name(self) -> &'static str { match self { $(Self::$variant => $name),+ } }
			pub const fn model(self) -> &'static str { match self { $(Self::$variant => $model),+ } }
			pub const fn axis(self) -> Axis { match self { $(Self::$variant => Axis::$axis),+ } }
			pub const fn sizes(self) -> [usize; 4] {
				let n = match self { $(Self::$variant => $first),+ };
				[n, n*2, n*4, n*8]
			}
		}
	};
}
// Canonicalization includes materializing descriptors from borrowed records;
// keys have fixed length. Byte sweeps hold the descriptor count at eight.
operations! {
	MetadataEncode => ("metadata-encode", "linear", ValueBytes, 8192),
	MetadataDecode => ("metadata-decode", "linear", Attributes, 256),
	MetadataHash => ("metadata-hash", "linear", ValueBytes, 8192),
	MetadataNormalize => ("metadata-normalize", "n-log-n", Attributes, 256),
	DirectoryCanonical => ("directory-canonical", "linear", Entries, 256),
	DirectoryHash => ("directory-hash", "linear", FileBytes, 8192),
	TreeCreate => ("tree-create", "n-log-n", Entries, 32),
	TreeApply => ("tree-apply", "n-log-n", Entries, 32),
}
