# Validate actual products before publishing. The file reader is independent
# of target names and producer metadata; foreign executables are never run.
difz_verify_header() {
	local pf=$1 description=$2
	case "$pf" in
		linux-*) [[ "$description" = 'ELF 64-bit '* && "$description" = *executable* ]] || return 1;;
		macos-*) [[ "$description" = *Mach-O* && "$description" = *executable* ]] || return 1;;
		mswin-*) [[ "$description" = 'PE32+ executable '* && "$description" != *'(DLL)'* ]] || return 1;;
		*) return 1;;
	esac
	case "$pf" in
		*-amd64) [[ "$description" = *x86-64* || "$description" = *x86_64* ]] || return 1;;
		*-arm64) [[ "$description" = *aarch64* || "$description" = *arm64* || "$description" = *Aarch64* || "$description" = *ARM64* ]] || return 1;;
		*) return 1;;
	esac
}
difz_verify_product() {
	local prefix=$1 backend=$2 pf=$3 variant=$4 profile=$5 host=$6 executable archive header description scratch status target revision dirty
	case "$pf" in mswin-*) executable="$prefix/bin/difz.exe";; *) executable="$prefix/bin/difz";; esac
	case "$backend" in
		zig) archive=libdifz.a; header=difz.h;;
		rust) archive=libdifz_rust.a; header=difz-rust.h;;
		*) difz_build_fail 'unregistered product backend'; return 1;;
	esac
	if [ ! -f "$executable" ] || [ ! -x "$executable" ] || [ ! -f "$prefix/lib/$archive" ] || [ ! -s "$prefix/lib/$archive" ] || [ ! -f "$prefix/include/$header" ] || [ ! -s "$prefix/include/$header" ]; then
		difz_build_fail "incomplete $backend/$pf/$profile product"; return 1
	fi
	description=$(file -Lb -- "$executable") || return 1
	difz_verify_header "$pf" "$description" || { difz_build_fail "executable header disagrees with $pf: $description"; return 1; }
	# Check metadata for foreign products too, without executing their code.
	if ! revision=$(jq -er 'if .schema == "build-provenance/v1" and .available == true and (.revision | type == "string" and test("^r[1-9][0-9]*-[0-9a-f]{6}$")) and (.dirty | type == "boolean") then .revision elif .schema == "build-provenance/v1" and .available == false and (.reason | type == "string") then "unavailable" else error("invalid provenance") end' "$prefix/nix-support/build-provenance.json"); then
		difz_build_fail 'missing or invalid product provenance'; return 1
	fi
	dirty=$(jq -er 'if .available then .dirty | tostring else "unknown" end' "$prefix/nix-support/build-provenance.json") || return 1
	if [ "$backend" = rust ]; then
		[ -f "$prefix/nix-support/rust-profile" ] && [ "$(cat "$prefix/nix-support/rust-profile")" = "$profile" ] || { difz_build_fail 'Rust product profile disagrees with selected profile'; return 1; }
		target=$(cat "$prefix/nix-support/rust-target") || return 1
		case "$pf" in
			linux-amd64) [ "$target" = "x86_64-unknown-linux-$variant" ] || { difz_build_fail 'Rust SDK ABI disagrees with selected variant'; return 1; };;
			linux-arm64) [ "$target" = "aarch64-unknown-linux-$variant" ] || { difz_build_fail 'Rust SDK ABI disagrees with selected variant'; return 1; };;
			mswin-amd64) [ "$target" = "x86_64-pc-windows-$variant" ] || { difz_build_fail 'Rust SDK ABI disagrees with selected variant'; return 1; };;
			mswin-arm64) [ "$target" = "aarch64-pc-windows-$variant" ] || { difz_build_fail 'Rust SDK ABI disagrees with selected variant'; return 1; };;
		esac
		case "$pf/$target" in
			linux-amd64/x86_64-unknown-linux-musl|linux-arm64/aarch64-unknown-linux-musl|macos-arm64/aarch64-apple-darwin) :;;
			mswin-amd64/x86_64-pc-windows-*|mswin-arm64/aarch64-pc-windows-*) :;;
			*) difz_build_fail 'Rust SDK target disagrees with selected platform'; return 1;;
		esac
	fi
	[ "$pf" = "$host" ] || return 0
	scratch=$(mktemp -d "${TMPDIR:-/tmp}/difz-product-verify.XXXXXXXX") || return 1
	env OS=contradictory ARCH=contradictory PF=contradictory PLATFORM=contradictory VARIANT=contradictory \
		DIFZ_BUILD_REVISION=contradictory DIFZ_BUILD_DIRTY=contradictory BUILD=contradictory DIRTY=contradictory \
		DIFZ_LANG=en "$executable" --lang en --about > "$scratch/about" 2> "$scratch/errors"
	status=$?
	if [ "$status" -ne 0 ] || [ "$(wc -l < "$scratch/about")" -ne 1 ] || \
		! grep -Eq '^difz [0-9]+\.[0-9]+' "$scratch/about" || \
		! grep -Eq "(^|[[:space:]])PF=$pf([[:space:]]|$)" "$scratch/about"; then
		status=1
	fi
	if [ "$variant" = - ]; then
		if grep -Fq 'VARIANT=' "$scratch/about"; then status=1; fi
	elif ! grep -Eq "(^|[[:space:]])VARIANT=$variant([[:space:]]|$)" "$scratch/about"; then status=1
	fi
	if ! grep -Eq "(^|[[:space:]])BUILD=$revision DIRTY=$dirty([[:space:]]|$)" "$scratch/about"; then status=1; fi
	if [ "$status" -ne 0 ]; then
		cat "$scratch/about" "$scratch/errors" >&2
		difz_build_fail 'compiled --about identity disagrees with selected product'
	fi
	rm -rf -- "$scratch"
	return "$status"
}
