#!/usr/bin/env bash
# Called only inside the admitted, qualified Linux host test boundary.
set -eu
bad=${1:?dynamic control required}; shift
[ "$#" -eq 4 ] || { printf 'FAIL expected both backends and profiles\n' >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:?}/difz-standalone.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
# Every run has just the executable, kernel interfaces and this scratch tree.
# No shell, loader, Nix store, libraries, profiles or devShell environment exist.
alone() {
	local binary=$1; shift
	bwrap --unshare-all --die-with-parent --new-session --cap-drop ALL \
		--ro-bind "$binary" /difz --dev /dev --proc /proc --dir /tmp \
		--bind "$work" /work --chdir /work --clearenv \
		--setenv PATH /unusable --setenv HOME /tmp -- /difz "$@"
}
"$bad" > "$work/control-outside"
if alone "$bad" > "$work/control-output" 2> "$work/control-error"; then
	printf 'FAIL dynamic control ran without its loader\n' >&2; exit 1
fi
index=0
for binary in "$@"; do
	index=$((index + 1))
	case_dir="$work/case-$index"
	mkdir -p "$case_dir/source/nested" "$case_dir/target/nested"
	printf 'old\000\377shared data' > "$case_dir/source/data"
	printf 'new\000\200shared data' > "$case_dir/target/data"
	printf 'added\000binary data' > "$case_dir/target/nested/new"
	ln -s ../data "$case_dir/target/nested/link"
	inside="/work/case-$index"
	alone "$binary" --about > "$case_dir/about"
	grep -F 'VARIANT=musl' "$case_dir/about" > /dev/null
	alone "$binary" --no-progress "$inside/source/data" "$inside/target/data" -o "$inside/file.patch"
	alone "$binary" --inspect "$inside/file.patch" > "$case_dir/inspect"
	grep -F 'difz inspect: zstd level 9 patch-from,' "$case_dir/inspect" > /dev/null
	alone "$binary" --patch --no-progress "$inside/source/data" "$inside/file.patch" -o "$inside/file-output"
	cmp "$case_dir/target/data" "$case_dir/file-output"
	alone "$binary" --no-progress --omit-metadata xattr,acl,timestamps,finder,sparse,hardlink "$inside/source" "$inside/target" -o "$inside/tree.patch"
	alone "$binary" --patch --no-progress "$inside/source" "$inside/tree.patch" -o "$inside/tree-output"
	diff -r "$case_dir/target" "$case_dir/tree-output"
	[ -L "$case_dir/tree-output/nested/link" ]
	[ "$(readlink "$case_dir/tree-output/nested/link")" = ../data ]
done
printf 'PASS four standalone Linux products: about, inspection, binary file/tree create/apply and missing-loader control\n'
