#!/usr/bin/env bash
# Run inside the pinned Nix development environment; compilation stays in Nix.
set -u
root=$(cd "$(dirname "$0")/.." && pwd -P) || exit 1
cd "$root" || exit 1
source scripts/build-selection.bash
source scripts/verify-build-output.bash
difz_build_load "$root" && difz_build_parse "$@" && difz_build_read_canonical || exit 1
[ "$DIFZ_BUILD_ACTION" = build ] || { difz_build_fail 'use ./build for configuration actions'; exit 1; }
selected_backend=$DIFZ_BUILD_CANONICAL
host=$(difz_build_normalize_host "$(uname -s)" "$(uname -m)") || exit 1
difz_build_plan "$host" || exit 1
ensure_directory() {
	local relative=$1 path=$root component
	while [ -n "$relative" ]; do
		component=${relative%%/*}
		if [ "$relative" = "$component" ]; then relative=; else relative=${relative#*/}; fi
		case "$component" in ''|.|..) difz_build_fail 'invalid managed directory component'; return 1;; esac
		path="$path/$component"
		[ ! -L "$path" ] || { difz_build_fail 'managed directory must not be a symlink'; return 1; }
		if [ -e "$path" ]; then [ -d "$path" ] || return 1
		else mkdir -- "$path" || return 1; fi
	done
}
product_relative() {
	local backend=$1 pf=$2 variant=$3 profile=$4
	if [ "$variant" = - ]; then printf '%s-out/%s/%s' "$backend" "$pf" "$profile"
	else printf '%s-out/%s/%s/%s' "$backend" "$pf" "$variant" "$profile"; fi
}
command_name() { case "$1" in mswin-*) printf difz.exe;; *) printf difz;; esac; }
managed_command() {
	local candidate=$1 row backend frontend pf variant mode profile output relative name
	for row in "${DIFZ_BUILD_ROWS[@]}"; do
		IFS=$'\t' read -r backend frontend pf variant mode profile output <<< "$row"
		[ "$pf" = "$host" ] || continue
		relative=$(product_relative "$backend" "$pf" "$variant" "$profile")
		name=$(command_name "$pf")
		[ "$candidate" != "../../$relative/bin/$name" ] || return 0
	done
	return 1
}
source_snapshot() {
	local metadata
	metadata=$(nix flake metadata --no-update-lock-file --json "${DIFZ_BUILD_NIX_FLAGS[@]}") || return 1
	jq -er '.path | select(type == "string" and length > 0)' <<< "$metadata"
}
ensure_directory .build-state && ensure_directory .build-work || exit 1
lock="$root/.build-state/publish.lock"
mkdir -- "$lock" 2>/dev/null || { difz_build_fail 'another publisher owns .build-state/publish.lock; inspect it before recovering a stale lock'; exit 1; }
work=$(mktemp -d "$root/.build-work/publish.XXXXXXXX") || { rmdir "$lock"; exit 1; }
prefixes=(); relatives=(); previous=(); changed=()
public="$root/bin/$host/$(command_name "$host")"
old_public=; new_public=; public_changed=0; committed=0; preserve=0; link_directory=
cleanup() {
	local result=$? index failed=0 rollback_link
	trap - EXIT
	if [ "$committed" -ne 1 ]; then
		if [ "$public_changed" -eq 1 ]; then
			if [ -n "$old_public" ]; then
				rollback_link=$(mktemp -d "$root/bin/$host/.difz-rollback.XXXXXXXX") || failed=1
				if [ "$failed" -eq 0 ]; then
					ln -s -- "$old_public" "$rollback_link/entry" && mv -Tf -- "$rollback_link/entry" "$public" || failed=1
					rmdir -- "$rollback_link" || failed=1
				fi
			elif [ -L "$public" ] && [ "$(readlink -- "$public")" = "$new_public" ]; then rm -f -- "$public" || failed=1
			else failed=1; fi
		fi
		for ((index=${#changed[@]}-1; index>=0; index--)); do
			local slot=${changed[index]} target="$root/${relatives[${changed[index]}]}"
			if [ -n "${previous[slot]}" ]; then
				nix build --no-update-lock-file --out-link "$target" "${previous[slot]}" > "$work/rollback-$slot.log" 2>&1 || failed=1
			elif [ -L "$target" ] && [ "$(readlink -- "$target")" = "${prefixes[slot]}" ]; then rm -f -- "$target" || failed=1
			elif [ ! -e "$target" ] && [ ! -L "$target" ]; then :
			else failed=1; fi
		done
	fi
	if [ "$failed" -ne 0 ]; then preserve=1; difz_build_fail "rollback incomplete; retained roots and evidence in $work"; result=1; fi
	if [ -n "$link_directory" ]; then rm -rf -- "$link_directory" || result=1; fi
	if [ "$preserve" -eq 0 ]; then rm -rf -- "$work" || result=1; fi
	rmdir -- "$lock" || result=1
	exit "$result"
}
trap cleanup EXIT
snapshot=$(source_snapshot) || exit 1
installables=()
publish_slot=-1
print_slot=-1
for index in "${DIFZ_BUILD_PLAN[@]}"; do
	IFS=$'\t' read -r backend frontend pf variant mode profile output <<< "${DIFZ_BUILD_ROWS[index]}"
	installables+=(".#$output")
	if [ "$backend/$pf" = "$selected_backend/$host" ]; then publish_slot=$((${#installables[@]} - 1)); fi
	if [ "$backend/$pf" = "$selected_backend/${DIFZ_BUILD_REQUESTED_PF:-$host}" ]; then print_slot=$((${#installables[@]} - 1)); fi
done
if [ "$publish_slot" -ge 0 ]; then
	ensure_directory "bin/$host" || exit 1
	if [ -L "$public" ]; then
		old_public=$(readlink -- "$public") || exit 1
		managed_command "$old_public" || { difz_build_fail 'refusing to replace an unrecognized command link'; exit 1; }
	elif [ -e "$public" ]; then difz_build_fail 'refusing to replace an unrecognized command file'; exit 1; fi
fi
printf 'Building %d declared product(s) through Nix...\n' "${#installables[@]}" >&2
nix build --no-update-lock-file --json --out-link "$work/result" "${DIFZ_BUILD_NIX_FLAGS[@]}" "${installables[@]}" > "$work/build.json" || exit 1
[ "$(jq -er 'length' "$work/build.json")" -eq "${#installables[@]}" ] || { difz_build_fail 'Nix returned an unexpected product count'; exit 1; }
for ((slot=0; slot<${#DIFZ_BUILD_PLAN[@]}; slot++)); do
	index=${DIFZ_BUILD_PLAN[slot]}
	IFS=$'\t' read -r backend frontend pf variant mode profile output <<< "${DIFZ_BUILD_ROWS[index]}"
	prefix=$(jq -er ".[$slot].outputs.out | select(type == \"string\" and startswith(\"/\") and (contains(\"\\n\") | not))" "$work/build.json") || exit 1
	nix-store --check-validity "$prefix" || { difz_build_fail 'Nix reported an invalid store output'; exit 1; }
	difz_verify_product "$prefix" "$backend" "$pf" "$variant" "$profile" "$host" || exit 1
	relative=$(product_relative "$backend" "$pf" "$variant" "$profile")
	ensure_directory "${relative%/*}" || exit 1
	old=
	if [ -L "$root/$relative" ]; then
		old=$(readlink -- "$root/$relative") || exit 1
		case "$old" in /*) :;; *) difz_build_fail 'retained product link must name an absolute store output'; exit 1;; esac
		if [ -e "$old" ]; then
			nix-store --check-validity "$old" || { difz_build_fail 'existing product link does not name a valid store output'; exit 1; }
			nix build --no-update-lock-file --out-link "$work/keep-$slot" "$old" > "$work/keep-$slot.log" || exit 1
		else old=; fi
	elif [ -e "$root/$relative" ]; then difz_build_fail 'retained product path is not a managed link'; exit 1; fi
	prefixes+=("$prefix"); relatives+=("$relative"); previous+=("$old")
done
[ "$(source_snapshot)" = "$snapshot" ] || { difz_build_fail 'source changed during preparation; preserving the previous publication'; exit 1; }
difz_build_read_canonical || exit 1
[ "$DIFZ_BUILD_CANONICAL" = "$selected_backend" ] || { difz_build_fail 'canonical selection changed during preparation'; exit 1; }
if [ "$publish_slot" -ge 0 ]; then
	if [ -n "$old_public" ]; then [ -L "$public" ] && [ "$(readlink -- "$public")" = "$old_public" ] || exit 1
	else [ ! -e "$public" ] && [ ! -L "$public" ] || exit 1; fi
	if [ -n "$old_public" ] && [ -e "$public" ]; then
		ensure_directory ".build-state/previous/$host" || exit 1
		old_root=${old_public#../../}; old_root=${old_root%/bin/*}
		old_prefix=$(readlink -- "$root/$old_root") || exit 1
		nix-store --check-validity "$old_prefix" || exit 1
		nix build --no-update-lock-file --out-link "$root/.build-state/previous/$host/product" "$old_prefix" > "$work/previous.log" || exit 1
		selection_tmp=$(mktemp "$root/.build-state/previous/$host/.selection.XXXXXXXX") || exit 1
		if ! printf '%s\n%s\n' "$old_root" "$old_public" > "$selection_tmp" || ! mv -Tf -- "$selection_tmp" "$root/.build-state/previous/$host/selection"; then rm -f -- "$selection_tmp"; exit 1; fi
	fi
fi
# Register each verified store output at its final root; the temporary roots
# remain live until the whole transaction succeeds or rollback finishes.
for ((slot=0; slot<${#prefixes[@]}; slot++)); do
	changed+=("$slot")
	nix build --no-update-lock-file --out-link "$root/${relatives[slot]}" "${prefixes[slot]}" > "$work/retain-$slot.log" || exit 1
done
if [ "$publish_slot" -ge 0 ]; then
	new_public="../../${relatives[publish_slot]}/bin/$(command_name "$host")"
	link_directory=$(mktemp -d "$root/bin/$host/.difz-link.XXXXXXXX") || exit 1
	ln -s -- "$new_public" "$link_directory/entry" && mv -Tf -- "$link_directory/entry" "$public" || exit 1
	public_changed=1
fi
committed=1
if [ "$DIFZ_BUILD_PRINT_PATH" -eq 1 ]; then
	if [ "$publish_slot" -ge 0 ]; then printf '%s\n' "$public"
	else [ "$print_slot" -ge 0 ] || exit 1; printf '%s/%s/bin/%s\n' "$root" "${relatives[print_slot]}" "$(command_name "${DIFZ_BUILD_REQUESTED_PF:-$host}")"; fi
else printf 'Prepared %d verified product(s).\n' "${#prefixes[@]}" >&2; fi
