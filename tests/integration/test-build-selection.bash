#!/usr/bin/env bash
set -u
root=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
work=$(mktemp -d "${TMPDIR:-/tmp}/difz-build-selection.XXXXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
project="$work/project with spaces"
mkdir -p "$project/nix" "$work/tools" || exit 1
cp "$root/nix/build-targets.tsv" "$project/nix/build-targets.tsv" || exit 1
cp "$root/CANONICAL_IMPL" "$project/CANONICAL_IMPL" || exit 1
source "$root/scripts/build-selection.bash"
export DIFZ_SELECTION_EXECUTED="$work/executed"
for tool in nix nix-store zig cargo rustc; do
	printf '#!%s\ntouch "$DIFZ_SELECTION_EXECUTED"\nexit 65\n' "$BASH" > "$work/tools/$tool" || exit 1
	chmod +x "$work/tools/$tool" || exit 1
done
export PATH="$work/tools:$PATH"
difz_build_load "$project" || exit 1
for backend in zig rust; do for ending in none lf; do
	printf '%s' "$backend" > "$project/CANONICAL_IMPL"
	if [ "$ending" = lf ]; then printf '\n' >> "$project/CANONICAL_IMPL"; fi
	difz_build_read_canonical || exit 1
	[ "$DIFZ_BUILD_CANONICAL" = "$backend" ] || exit 1
	touch -t 200001010000 "$project/CANONICAL_IMPL" || exit 1
	before=$(stat -c '%i:%Y:%s' "$project/CANONICAL_IMPL") || exit 1
	difz_build_canonize "$backend" > "$work/out" || exit 1
	printf '%s implementation canonized. Rerun ./build to rebuild.\n' "$backend" > "$work/expected"
	cmp "$work/out" "$work/expected" || exit 1
	[ "$(stat -c '%i:%Y:%s' "$project/CANONICAL_IMPL")" = "$before" ] || exit 1
done; done
for value in '' ' ' ' zig' 'zig ' unknown $'zig\n\n' $'zig\nrust' $'zig\r\n' '$(touch must-not-execute)'; do
	printf '%s' "$value" > "$project/CANONICAL_IMPL"
	if difz_build_read_canonical > "$work/out" 2> "$work/err"; then printf 'FAIL invalid selector accepted\n' >&2; exit 1; fi
done
printf 'zig\0' > "$project/CANONICAL_IMPL"
if difz_build_read_canonical > "$work/out" 2> "$work/err"; then printf 'FAIL NUL selector accepted\n' >&2; exit 1; fi
printf 'published command sentinel' > "$work/published"
rm -- "$project/CANONICAL_IMPL" || exit 1
ln -s "$work/published" "$project/CANONICAL_IMPL" || exit 1
difz_build_canonize zig > "$work/out" || exit 1
[ ! -L "$project/CANONICAL_IMPL" ] && [ "$(cat "$work/published")" = 'published command sentinel' ] || exit 1
for backend in zig rust; do
	difz_build_canonize "$backend" > "$work/out" || exit 1
	difz_build_read_canonical || exit 1
	for flags in default debug short long repeated platforms-short platforms-long platforms-repeated all short-pair reversed mixed-repeated; do
		case "$flags" in
			default) args=(); expected=1; status_expected=0;;
			debug) args=(--debug debug --debug); expected=1; status_expected=0;;
			short) args=(--all-impls); expected=2; status_expected=0;;
			long) args=(--all-implementations); expected=2; status_expected=0;;
			repeated) args=(--all-impls --all-implementations --all-impls); expected=2; status_expected=0;;
			platforms-short) args=(--all-plats); expected=5; status_expected=1;;
			platforms-long) args=(--all-platforms); expected=5; status_expected=1;;
			platforms-repeated) args=(--all-plats --all-platforms --all-plats); expected=5; status_expected=1;;
			all) args=(--all --all); expected=10; status_expected=1;;
			short-pair) args=(--all-impls --all-plats); expected=10; status_expected=1;;
			reversed) args=(--all-platforms --all-implementations); expected=10; status_expected=1;;
			mixed-repeated) args=(--all-impls --all-platforms --all-plats --all-implementations); expected=10; status_expected=1;;
		esac
		if [ "$backend" = zig ] && [ "$expected" -eq 5 ]; then status_expected=0; fi
		difz_build_parse "${args[@]}" || exit 1
		difz_build_plan linux-amd64 > "$work/out" 2> "$work/err"; actual=$?
		[ "$actual" -eq "$status_expected" ] && [ "${#DIFZ_BUILD_PLAN[@]}" -eq "$expected" ] || { printf 'FAIL scope %s/%s\n' "$backend" "$flags" >&2; exit 1; }
		: > "$work/keys"
		for index in "${DIFZ_BUILD_PLAN[@]}"; do
			IFS=$'\t' read -r selected _ selected_pf _ selected_mode _ _ <<< "${DIFZ_BUILD_ROWS[index]}"
			printf '%s/%s/%s\n' "$selected" "$selected_pf" "$selected_mode" >> "$work/keys"
		done
		sort "$work/keys" > "$work/sorted"
		case "$expected" in
			1) printf '%s/linux-amd64/%s\n' "$backend" "$DIFZ_BUILD_MODE" > "$work/expected";;
			2) printf 'rust/linux-amd64/release\nzig/linux-amd64/release\n' > "$work/expected";;
			5) for selected_pf in linux-amd64 linux-arm64 macos-arm64 mswin-amd64 mswin-arm64; do printf '%s/%s/release\n' "$backend" "$selected_pf"; done > "$work/expected";;
			10) for selected in rust zig; do for selected_pf in linux-amd64 linux-arm64 macos-arm64 mswin-amd64 mswin-arm64; do printf '%s/%s/release\n' "$selected" "$selected_pf"; done; done > "$work/expected";;
		esac
		cmp "$work/sorted" "$work/expected" || exit 1
	done
done
for os in Linux Darwin Windows_NT MINGW64_NT-10.0 MSYS_NT-10.0 CYGWIN_NT-10.0; do
	case "$os" in Linux) expected_os=linux;; Darwin) expected_os=macos;; *) expected_os=mswin;; esac
	for pair in x86_64:amd64 amd64:amd64 AMD64:amd64 aarch64:arm64 arm64:arm64 ARM64:arm64; do
		arch=${pair%%:*}; normalized=${pair#*:}
		actual=$(difz_build_normalize_host "$os" "$arch" 2> "$work/err"); status=$?
		if [ "$expected_os/$normalized" = macos/amd64 ]; then [ "$status" -ne 0 ] || exit 1
		else [ "$status" -eq 0 ] && [ "$actual" = "$expected_os-$normalized" ] || exit 1; fi
	done
done
for pair in FreeBSD:x86_64 unknown:aarch64 Linux:i386 Linux:armv7l; do
	if difz_build_normalize_host "${pair%%:*}" "${pair#*:}" > "$work/out" 2> "$work/err"; then exit 1; fi
done
for flags in missing-canonize mixed-canonize missing-pf conflicting-pf unknown; do
	case "$flags" in missing-canonize) args=(canonize);; mixed-canonize) args=(canonize rust --all);; missing-pf) args=(--pf);; conflicting-pf) args=(--pf linux-amd64 --all-plats);; unknown) args=(--unknown);; esac
	if difz_build_parse "${args[@]}" > "$work/out" 2> "$work/err"; then printf 'FAIL invalid build arguments\n' >&2; exit 1; fi
done
cp "$root/nix/build-targets.tsv" "$project/nix/build-targets.tsv" || exit 1
sed 's/\tmusl\t/\tgnu\t/g' "$root/nix/build-targets.tsv" > "$project/nix/build-targets.tsv" || exit 1
if difz_build_load "$project" > "$work/out" 2> "$work/err"; then printf 'FAIL mixed Linux libc registry accepted\n' >&2; exit 1; fi
cp "$root/nix/build-targets.tsv" "$project/nix/build-targets.tsv" || exit 1
truncate -s -1 "$project/nix/build-targets.tsv" || exit 1
difz_build_load "$project" || exit 1
[ "${#DIFZ_BUILD_ROWS[@]}" -eq 20 ] || exit 1
printf '%s\n' "${DIFZ_BUILD_ROWS[@]:1}" > "$project/nix/build-targets.tsv"
if difz_build_load "$project" > "$work/out" 2> "$work/err"; then printf 'FAIL incomplete registry accepted\n' >&2; exit 1; fi
cp "$root/nix/build-targets.tsv" "$project/nix/build-targets.tsv" || exit 1
difz_build_load "$project" || exit 1
[ ! -e "$DIFZ_SELECTION_EXECUTED" ] && [ ! -e "$project/must-not-execute" ] || exit 1
printf 'PASS build selection: strict/idempotent configuration, all scope aliases, complete unavailable matrix, host aliases and rejected arguments without builds or publication\n'
