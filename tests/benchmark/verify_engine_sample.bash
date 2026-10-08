#!/usr/bin/env bash
# Hyperfine calls this after each timed sample; failure invalidates the run.
set -u
phase="${1:?phase required}"
case "$phase" in
	prepare-create|prepare-apply)
		# Owned scratch outputs must be absent so skipped work cannot reuse them.
		rm -f -- "${ENGINE_REBUILT:?}" || exit 1
		[ "$phase" != prepare-create ] || rm -f -- "${ENGINE_PATCH:?}" || exit 1
		exit 0
		;;
	create|apply) ;;
	*) exit 2 ;;
esac
if [ "$phase" = create ]; then
	"${ENGINE_BINARY:?}" --patch "${ENGINE_SOURCE:?}" "${ENGINE_PATCH:?}" \
		-o "${ENGINE_REBUILT:?}" --no-progress --max-rss-bytes 17179869184 --max-wall-ms 120000 \
		> /dev/null 2> "${ENGINE_REBUILT}.stderr" || exit 1
fi
if ! cmp -s "${ENGINE_TARGET:?}" "${ENGINE_REBUILT:?}"; then
	printf 'reconstruction mismatch\n' >&2
	exit 1
fi
