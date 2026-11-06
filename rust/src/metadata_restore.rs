use super::{CanonicalMetadata, Error, Family, Metadata, Os, Times, XattrClass, raw_accepted};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RestoreError {
	PlanImpossible,
}

/// Filesystem capabilities. Defaults describe each OS conservatively; a
/// filesystem probe may override individual capabilities before planning.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Capabilities {
	pub os: Os,
	pub set_btime: bool,
	pub punch_holes: bool,
	pub hardlink: bool,
	pub portable_acl: bool,
	pub native_acl: bool,
	pub bsd_flags: bool,
	pub finder_info: bool,
	pub logical_xattr: bool,
}
impl Capabilities {
	pub const fn for_os(os: Os) -> Self {
		match os {
			Os::Linux => Self {
				os,
				set_btime: false,
				punch_holes: true,
				hardlink: true,
				portable_acl: true,
				native_acl: true,
				bsd_flags: false,
				finder_info: false,
				logical_xattr: true,
			},
			Os::Macos => Self {
				os,
				set_btime: true,
				punch_holes: true,
				hardlink: true,
				portable_acl: true,
				native_acl: true,
				bsd_flags: true,
				finder_info: true,
				logical_xattr: true,
			},
			Os::Mswin => Self {
				os,
				set_btime: true,
				punch_holes: false,
				hardlink: true,
				portable_acl: false,
				native_acl: true,
				bsd_flags: false,
				finder_info: false,
				logical_xattr: true,
			},
		}
	}
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct RestoreActions {
	pub logical_xattr: bool,
	pub raw_xattr: bool,
	pub raw_xattr_sidecar: bool,
	pub portable_acl: bool,
	pub portable_acl_sidecar: bool,
	pub native_acl: bool,
	pub native_acl_sidecar: bool,
	pub mtime_atime: bool,
	pub btime: bool,
	pub btime_sidecar: bool,
	pub bsd_flags: bool,
	pub bsd_flags_sidecar: bool,
	pub finder_info: bool,
	pub finder_info_sidecar: bool,
	pub punch_holes: bool,
	pub sparse_sidecar: bool,
	pub hardlink: bool,
	pub hardlink_copy: bool,
}

wire_enum! { CompromiseCode {
	NativeAclPreserved = 1, PortableAclPreserved = 2, FinderFlagsPreserved = 3,
	FinderInfoPreserved = 4, BirthTimePreserved = 5, SparsePreserved = 6,
	HardlinkCopied = 7, RawXattrPreserved = 8, SymlinkMetadataPreserved = 9,
	ModificationTimePreserved = 10,
} }

/// Associated data exists only for the native ACL warning that uses it.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Compromise {
	NativeAclPreserved {
		origin: Os,
		portable_acl_applied: bool,
	},
	PortableAclPreserved,
	FinderFlagsPreserved,
	FinderInfoPreserved,
	BirthTimePreserved,
	SparsePreserved,
	HardlinkCopied,
	RawXattrPreserved,
}
impl Compromise {
	pub const fn code(self) -> CompromiseCode {
		match self {
			Self::NativeAclPreserved { .. } => CompromiseCode::NativeAclPreserved,
			Self::PortableAclPreserved => CompromiseCode::PortableAclPreserved,
			Self::FinderFlagsPreserved => CompromiseCode::FinderFlagsPreserved,
			Self::FinderInfoPreserved => CompromiseCode::FinderInfoPreserved,
			Self::BirthTimePreserved => CompromiseCode::BirthTimePreserved,
			Self::SparsePreserved => CompromiseCode::SparsePreserved,
			Self::HardlinkCopied => CompromiseCode::HardlinkCopied,
			Self::RawXattrPreserved => CompromiseCode::RawXattrPreserved,
		}
	}
	pub const fn family(self) -> Family {
		match self {
			Self::NativeAclPreserved { .. } | Self::PortableAclPreserved => Family::Acl,
			Self::FinderFlagsPreserved | Self::FinderInfoPreserved => Family::Finder,
			Self::BirthTimePreserved => Family::Timestamps,
			Self::SparsePreserved => Family::Sparse,
			Self::HardlinkCopied => Family::Hardlink,
			Self::RawXattrPreserved => Family::Xattr,
		}
	}
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct RestoreReport(u32);
const _: () = {
	let mut index = 0;
	while index < CompromiseCode::ALL.len() {
		let tag = CompromiseCode::ALL[index] as u8;
		assert!(tag > 0 && tag <= 32);
		index += 1;
	}
};
impl RestoreReport {
	pub fn add(&mut self, code: CompromiseCode) {
		self.0 |= 1 << (code as u8 - 1);
	}
	pub const fn bits(self) -> u32 {
		self.0
	}
}

/// A pure plan. Filesystem effects and warnings occur only when applying it.
#[derive(Debug, Eq, PartialEq)]
pub struct RestorePlan {
	actions: RestoreActions,
	compromises: [Compromise; CompromiseCode::ALL.len()],
	length: usize,
}
impl RestorePlan {
	/// Linear in attribute descriptors/names; other families need presence only.
	pub fn new(metadata: &CanonicalMetadata<'_>, caps: Capabilities) -> Result<Self, RestoreError> {
		let Metadata {
			xattrs,
			aces,
			native_acl,
			times,
			finder_flags,
			finder_info,
			holes,
			hardlink_to,
		} = metadata.metadata();
		let Capabilities {
			os,
			set_btime,
			punch_holes,
			hardlink,
			portable_acl,
			native_acl: has_native_acl,
			bsd_flags,
			finder_info: has_finder_info,
			logical_xattr,
		} = caps;
		let mut plan = Self {
			actions: RestoreActions::default(),
			compromises: [Compromise::PortableAclPreserved; CompromiseCode::ALL.len()],
			length: 0,
		};
		let require_transport = || {
			if logical_xattr {
				Ok(())
			} else {
				Err(RestoreError::PlanImpossible)
			}
		};
		for attr in xattrs {
			match attr.class {
				XattrClass::Logical => plan.actions.logical_xattr = true,
				XattrClass::Raw => {
					if raw_accepted(os, &attr.name) {
						plan.actions.raw_xattr = true;
					} else {
						plan.actions.raw_xattr_sidecar = true;
					}
				}
			}
		}
		if plan.actions.logical_xattr || plan.actions.raw_xattr_sidecar {
			require_transport()?;
		}
		if plan.actions.raw_xattr_sidecar {
			plan.push(Compromise::RawXattrPreserved)?;
		}
		if let Some(acl) = native_acl {
			if has_native_acl && acl.origin == os {
				plan.actions.native_acl = true;
			} else {
				require_transport()?;
				plan.actions.native_acl_sidecar = true;
				let applied = !aces.is_empty() && portable_acl;
				plan.actions.portable_acl = applied;
				plan.actions.portable_acl_sidecar = !aces.is_empty() && !portable_acl;
				plan.push(Compromise::NativeAclPreserved {
					origin: acl.origin,
					portable_acl_applied: applied,
				})?;
				if plan.actions.portable_acl_sidecar {
					plan.push(Compromise::PortableAclPreserved)?;
				}
			}
		} else if !aces.is_empty() {
			if portable_acl {
				plan.actions.portable_acl = true;
			} else {
				require_transport()?;
				plan.actions.portable_acl_sidecar = true;
				plan.push(Compromise::PortableAclPreserved)?;
			}
		}
		let Times {
			mtime,
			atime,
			btime,
		} = times;
		plan.actions.mtime_atime = mtime.is_some() || atime.is_some();
		if btime.is_some() {
			if set_btime {
				plan.actions.btime = true;
			} else {
				require_transport()?;
				plan.actions.btime_sidecar = true;
				plan.push(Compromise::BirthTimePreserved)?;
			}
		}
		if *finder_flags != 0 {
			if bsd_flags {
				plan.actions.bsd_flags = true;
			} else {
				require_transport()?;
				plan.actions.bsd_flags_sidecar = true;
				plan.push(Compromise::FinderFlagsPreserved)?;
			}
		}
		if finder_info.is_some() {
			if has_finder_info {
				plan.actions.finder_info = true;
			} else {
				require_transport()?;
				plan.actions.finder_info_sidecar = true;
				plan.push(Compromise::FinderInfoPreserved)?;
			}
		}
		if !holes.is_empty() {
			if punch_holes {
				plan.actions.punch_holes = true;
			} else {
				require_transport()?;
				plan.actions.sparse_sidecar = true;
				plan.push(Compromise::SparsePreserved)?;
			}
		}
		if hardlink_to.is_some() {
			if hardlink {
				plan.actions.hardlink = true;
			} else {
				require_transport()?;
				plan.actions.hardlink_copy = true;
				plan.push(Compromise::HardlinkCopied)?;
			}
		}
		Ok(plan)
	}
	fn push(&mut self, compromise: Compromise) -> Result<(), RestoreError> {
		*self
			.compromises
			.get_mut(self.length)
			.ok_or(RestoreError::PlanImpossible)? = compromise;
		self.length += 1;
		Ok(())
	}
	pub fn actions(&self) -> &RestoreActions {
		&self.actions
	}
	pub fn compromises(&self) -> &[Compromise] {
		&self.compromises[..self.length]
	}
}
