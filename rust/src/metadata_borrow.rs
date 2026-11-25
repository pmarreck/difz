use super::{Ace, CanonicalMetadata, Error, Family, Metadata, NativeAcl, Omit, Times, Xattr};
use alloc::{borrow::Cow, vec::Vec};

impl CanonicalMetadata<'_> {
	/// Detach from transport storage in linear retained-byte work. Existing
	/// owned byte buffers and extent storage move without copying. Descriptor
	/// vectors are rebuilt because their byte-field lifetimes change.
	pub fn into_owned(self) -> Result<CanonicalMetadata<'static>, Error> {
		let Metadata {
			xattrs,
			aces,
			native_acl,
			times,
			finder_flags,
			finder_info,
			holes,
			hardlink_to,
		} = self.into_metadata();
		let mut attributes = Vec::new();
		reserve(&mut attributes, xattrs.len())?;
		for Xattr { class, name, value } in xattrs {
			attributes.push(Xattr {
				class,
				name: owned(name)?,
				value: owned(value)?,
			});
		}
		let mut entries = Vec::new();
		reserve(&mut entries, aces.len())?;
		for Ace {
			tag,
			permissions,
			name,
		} in aces
		{
			entries.push(Ace {
				tag,
				permissions,
				name: owned(name)?,
			});
		}
		let native_acl = match native_acl {
			Some(NativeAcl { origin, bytes }) => Some(NativeAcl {
				origin,
				bytes: owned(bytes)?,
			}),
			None => None,
		};
		let hardlink_to = hardlink_to.map(owned).transpose()?;
		CanonicalMetadata::new(Metadata {
			xattrs: attributes,
			aces: entries,
			native_acl,
			times,
			finder_flags,
			finder_info,
			holes,
			hardlink_to,
		})
	}

	/// Copy retained descriptors while borrowing their byte buffers. Omission
	/// precedes allocation; canonical ordering is preserved without sorting.
	pub fn borrowing_omitting(&self, omit: Omit) -> Result<CanonicalMetadata<'_>, Error> {
		let Metadata {
			xattrs,
			aces,
			native_acl,
			times,
			finder_flags,
			finder_info,
			holes,
			hardlink_to,
		} = self.metadata();
		let mut value = Metadata::default();
		for &family in Family::ALL {
			if omit.contains(family) {
				continue;
			}
			match family {
				Family::Xattr => {
					reserve(&mut value.xattrs, xattrs.len())?;
					for Xattr {
						class,
						name,
						value: bytes,
					} in xattrs
					{
						value.xattrs.push(Xattr {
							class: *class,
							name: Cow::Borrowed(name),
							value: Cow::Borrowed(bytes),
						});
					}
				}
				Family::Acl => {
					reserve(&mut value.aces, aces.len())?;
					for Ace {
						tag,
						permissions,
						name,
					} in aces
					{
						value.aces.push(Ace {
							tag: *tag,
							permissions: *permissions,
							name: Cow::Borrowed(name),
						});
					}
					value.native_acl =
						native_acl
							.as_ref()
							.map(|NativeAcl { origin, bytes }| NativeAcl {
								origin: *origin,
								bytes: Cow::Borrowed(bytes),
							});
				}
				Family::Timestamps => {
					let Times {
						mtime,
						atime,
						btime,
					} = times;
					value.times = Times {
						mtime: *mtime,
						atime: *atime,
						btime: *btime,
					};
				}
				Family::Finder => {
					value.finder_flags = *finder_flags;
					value.finder_info = *finder_info;
				}
				Family::Sparse => {
					reserve(&mut value.holes, holes.len())?;
					value.holes.extend_from_slice(holes);
				}
				Family::Hardlink => {
					value.hardlink_to = hardlink_to
						.as_ref()
						.map(|path| Cow::Borrowed(path.as_ref()));
				}
			}
		}
		CanonicalMetadata::new(value)
	}
}
fn owned(bytes: Cow<'_, [u8]>) -> Result<Cow<'static, [u8]>, Error> {
	match bytes {
		Cow::Owned(bytes) => Ok(Cow::Owned(bytes)),
		Cow::Borrowed(bytes) => {
			let mut output = Vec::new();
			reserve(&mut output, bytes.len())?;
			output.extend_from_slice(bytes);
			Ok(Cow::Owned(output))
		}
	}
}
fn reserve<T>(values: &mut Vec<T>, length: usize) -> Result<(), Error> {
	values
		.try_reserve_exact(length)
		.map_err(|_| Error::OutOfMemory)
}
