# shellcheck shell=bash
# A target-specific SDK supplies the archive and generated bindings together.
if [ -n "${DIFZ_ZSTDZ_ROOT:-}" ] && [ "$DIFZ_ZSTDZ_ROOT" != '@sdk@' ]; then
	printf 'Conflicting difz zstdz SDK roots\n' >&2
	return 1
fi
export DIFZ_ZSTDZ_ROOT='@sdk@'
