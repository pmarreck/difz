# Sourced by the prepared runner and its exhaustive filesystem-state controls.
difz_require_prepared_artifacts() {
	if [ "$#" -eq 0 ]; then
		printf 'FAIL no Nix-prepared host artifacts were declared\n' >&2
		return 1
	fi
	local artifact
	for artifact in "$@"; do
		if [ ! -f "$artifact" ] || [ ! -x "$artifact" ]; then
			printf 'FAIL Nix-prepared host artifact is missing: %s\n' "$artifact" >&2
			return 1
		fi
	done
	return 0
}
