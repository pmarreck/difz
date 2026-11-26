# Shared pure selection/configuration layer. Sourced by the build entry point.
# CANONICAL_IMPL is always data; it is never sourced or evaluated.
difz_build_fail() { printf 'build: %s\n' "$*" >&2; return 1; }
difz_build_member() {
	local needle=$1 item; shift
	for item in "$@"; do [ "$item" != "$needle" ] || return 0; done
	return 1
}
difz_build_load() {
	DIFZ_BUILD_ROOT=$1
	DIFZ_BUILD_ROWS=(); DIFZ_BUILD_IDS=(); DIFZ_BUILD_KEYS=()
	DIFZ_BUILD_PFS=(linux-amd64 linux-arm64 macos-arm64 mswin-amd64 mswin-arm64)
	local backend frontend pf variant mode profile output extra key line=0 found row row_pf row_mode
	while IFS=$'\t' read -r backend frontend pf variant mode profile output extra || [ -n "${backend:-}" ]; do
		line=$((line + 1))
		case "$backend" in ''|\#*) continue;; esac
		[ -z "$extra" ] && [ -n "$output" ] || { difz_build_fail "invalid registry field count at line $line"; return 1; }
		case "$backend/$frontend/$mode/$profile" in
			zig/c/release/ReleaseFast|zig/c/debug/Debug|rust/rust/release/release|rust/rust/debug/debug) :;;
			*) difz_build_fail "invalid registry backend/frontend/profile at line $line"; return 1;;
		esac
		difz_build_member "$pf" "${DIFZ_BUILD_PFS[@]}" || { difz_build_fail "invalid registry platform at line $line"; return 1; }
		case "$pf/$variant" in linux-*/musl|macos-arm64/-|mswin-amd64/gnu|mswin-arm64/gnu) :;;
			*) difz_build_fail "invalid registry variant at line $line"; return 1;;
		esac
		if [ "$output" != - ] && [[ ! "$output" =~ ^(packages|checks)\.[a-zA-Z0-9_.-]+$ ]]; then
			difz_build_fail "invalid registry output at line $line"; return 1
		fi
		key="$backend/$pf/$mode/$variant"
		if difz_build_member "$key" "${DIFZ_BUILD_KEYS[@]-}"; then difz_build_fail 'duplicate registry target'; return 1; fi
		DIFZ_BUILD_KEYS+=("$key")
		DIFZ_BUILD_ROWS+=("$backend"$'\t'"$frontend"$'\t'"$pf"$'\t'"$variant"$'\t'"$mode"$'\t'"$profile"$'\t'"$output")
		if ! difz_build_member "$backend" "${DIFZ_BUILD_IDS[@]-}"; then DIFZ_BUILD_IDS+=("$backend"); fi
	done < "$DIFZ_BUILD_ROOT/nix/build-targets.tsv" || return 1
	for backend in zig rust; do
		for pf in "${DIFZ_BUILD_PFS[@]}"; do for mode in release debug; do
			found=0
			for row in "${DIFZ_BUILD_ROWS[@]}"; do
				IFS=$'\t' read -r _ _ row_pf _ row_mode _ _ <<< "$row"
				if [[ "$row" = "$backend"$'\t'* ]] && [ "$row_pf/$row_mode" = "$pf/$mode" ]; then found=1; break; fi
			done
			[ "$found" -eq 1 ] || { difz_build_fail 'registry must cover every backend/platform/profile; unavailable builders use -'; return 1; }
		done; done
	done
}
difz_build_read_canonical() {
	local file="$DIFZ_BUILD_ROOT/CANONICAL_IMPL" value= bytes
	[ -f "$file" ] && [ ! -L "$file" ] || { difz_build_fail 'CANONICAL_IMPL must be an ordinary file'; return 1; }
	bytes=$(wc -c < "$file") || return 1
	[ "$bytes" -le 65 ] || { difz_build_fail 'invalid CANONICAL_IMPL contents'; return 1; }
	IFS= read -r value < "$file" || :
	difz_build_member "$value" "${DIFZ_BUILD_IDS[@]}" || { difz_build_fail 'CANONICAL_IMPL must name a registered backend'; return 1; }
	if ! printf '%s' "$value" | cmp -s -- "$file" -; then
		printf '%s\n' "$value" | cmp -s -- "$file" - || { difz_build_fail 'CANONICAL_IMPL permits only one optional LF'; return 1; }
	fi
	DIFZ_BUILD_CANONICAL=$value
}
difz_build_canonize() {
	local value=$1 current= file="$DIFZ_BUILD_ROOT/CANONICAL_IMPL" temporary
	difz_build_member "$value" "${DIFZ_BUILD_IDS[@]}" || { difz_build_fail 'unknown implementation identifier'; return 1; }
	if difz_build_read_canonical 2>/dev/null; then current=$DIFZ_BUILD_CANONICAL; fi
	if [ "$current" != "$value" ]; then
		temporary=$(mktemp "$DIFZ_BUILD_ROOT/.canonical-impl.XXXXXXXX") || return 1
		if ! printf '%s\n' "$value" > "$temporary" || ! mv -f -- "$temporary" "$file"; then
			rm -f -- "$temporary"; return 1
		fi
	fi
	printf '%s implementation canonized. Rerun ./build to rebuild.\n' "$value"
}
difz_build_normalize_host() {
	local os arch
	case "$1" in Linux) os=linux;; Darwin) os=macos;; Windows_NT|MINGW*|MSYS*|CYGWIN*) os=mswin;;
		*) difz_build_fail 'unsupported host operating system'; return 1;; esac
	case "$2" in x86_64|amd64|AMD64) arch=amd64;; aarch64|arm64|ARM64) arch=arm64;;
		*) difz_build_fail 'unsupported host architecture'; return 1;; esac
	difz_build_member "$os-$arch" "${DIFZ_BUILD_PFS[@]}" || { difz_build_fail 'unsupported host platform'; return 1; }
	printf '%s-%s\n' "$os" "$arch"
}
difz_build_parse() {
	DIFZ_BUILD_ACTION=build; DIFZ_BUILD_ALL_IMPLS=0; DIFZ_BUILD_ALL_PLATS=0
	DIFZ_BUILD_MODE=release; DIFZ_BUILD_REQUESTED_PF=; DIFZ_BUILD_PRINT_PATH=0; DIFZ_BUILD_FOR_RELEASE=0; DIFZ_BUILD_NIX_FLAGS=()
	if [ "${1:-}" = canonize ]; then
		[ "$#" -eq 2 ] || { difz_build_fail 'usage: ./build canonize IMPLEMENTATION'; return 1; }
		DIFZ_BUILD_ACTION=canonize; DIFZ_BUILD_REQUESTED_IMPL=$2; return 0
	fi
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--help|-h) DIFZ_BUILD_ACTION=help;;
			debug|--debug) DIFZ_BUILD_MODE=debug;;
			--all-impls|--all-implementations) DIFZ_BUILD_ALL_IMPLS=1;;
			--all-plats|--all-platforms) DIFZ_BUILD_ALL_PLATS=1;;
			--all) DIFZ_BUILD_ALL_IMPLS=1; DIFZ_BUILD_ALL_PLATS=1;;
			--pf) shift; [ "$#" -gt 0 ] || { difz_build_fail '--pf requires a platform'; return 1; }; DIFZ_BUILD_REQUESTED_PF=$1;;
			--print-path) DIFZ_BUILD_PRINT_PATH=1;;
			--for-release) DIFZ_BUILD_FOR_RELEASE=1;;
			--offline|--refresh) DIFZ_BUILD_NIX_FLAGS+=("$1");;
			*) difz_build_fail 'unknown build option'; return 1;;
		esac
		shift
	done
	if [ -n "$DIFZ_BUILD_REQUESTED_PF" ]; then
		[ "$DIFZ_BUILD_ALL_PLATS" -eq 0 ] || { difz_build_fail '--pf and --all-platforms cannot be combined'; return 1; }
		difz_build_member "$DIFZ_BUILD_REQUESTED_PF" "${DIFZ_BUILD_PFS[@]}" || { difz_build_fail 'unsupported requested platform'; return 1; }
	fi
}
difz_build_plan() {
	local selected_pf=${DIFZ_BUILD_REQUESTED_PF:-$1} row backend frontend pf variant mode profile output index errors=0
	DIFZ_BUILD_PLAN=()
	for ((index=0; index<${#DIFZ_BUILD_ROWS[@]}; index++)); do
		row=${DIFZ_BUILD_ROWS[index]}
		IFS=$'\t' read -r backend frontend pf variant mode profile output <<< "$row"
		[ "$mode" = "$DIFZ_BUILD_MODE" ] || continue
		[ "$DIFZ_BUILD_ALL_IMPLS" -eq 1 ] || [ "$backend" = "$DIFZ_BUILD_CANONICAL" ] || continue
		[ "$DIFZ_BUILD_ALL_PLATS" -eq 1 ] || [ "$pf" = "$selected_pf" ] || continue
		DIFZ_BUILD_PLAN+=("$index")
		if [ "$output" = - ]; then difz_build_fail "no Nix artifact builder registered for $backend/$pf/$profile"; errors=$((errors + 1)); fi
	done
	[ "${#DIFZ_BUILD_PLAN[@]}" -gt 0 ] || { difz_build_fail 'empty build scope'; return 1; }
	[ "$errors" -eq 0 ]
}
