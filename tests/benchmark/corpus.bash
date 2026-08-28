#!/usr/bin/env bash

# Deterministic benchmark corpus generators. Callers own the output directory.

corpus_file_size() {
	wc -c < "$1" | tr -d ' '
}

corpus_assert_exact_size() {
	local path="$1"
	local expected="$2"
	local actual

	actual=$(corpus_file_size "$path")
	if [ "$expected" -le 0 ] || [ "$actual" -ne "$expected" ]; then
		printf 'corpus: %s has %s bytes; expected %s nonzero bytes\n' \
			"$path" "$actual" "$expected" >&2
		return 1
	fi
}

# Replace every NUL byte with 0x01. Seeded random input contains changes
# throughout the file, producing thousands of alternating COPY/INSERT ops.
generate_interleaved_pair() {
	local random_bin="$1"
	local output_dir="$2"
	local name="$3"
	local size="$4"
	local seed="$5"
	local file_a="$output_dir/${name}_a"
	local file_b="$output_dir/${name}_b"
	local generator_stderr="$output_dir/${name}_random.stderr"

	if [ "$size" -le 0 ]; then
		printf 'corpus: %s declares a non-positive size: %s\n' "$name" "$size" >&2
		return 1
	fi

	if ! "$random_bin" --seed "$seed" -b -c "$size" > "$file_a" 2> "$generator_stderr"; then
		printf 'corpus: random failed while generating %s\n' "$file_a" >&2
		return 1
	fi
	corpus_assert_exact_size "$file_a" "$size" || return 1

	if ! LC_ALL=C tr '\000' '\001' < "$file_a" > "$file_b"; then
		printf 'corpus: byte transform failed while generating %s\n' "$file_b" >&2
		return 1
	fi
	corpus_assert_exact_size "$file_b" "$size" || return 1

	if cmp -s "$file_a" "$file_b"; then
		printf 'corpus: interleaved fixture contains no edits\n' >&2
		return 1
	fi
}

# Install two independently built, runnable Linux x86_64 executables. Exact
# revisions and hashes make the pair auditable without committing binaries.
install_real_elf_pair() {
	local output_dir="$1"
	local name="$2"
	local source_binary="$3"
	local target_binary="$4"
	local repository="$5"
	local source_revision="$6"
	local target_revision="$7"
	local file_a="$output_dir/${name}_a"
	local file_b="$output_dir/${name}_b"
	local provenance="$output_dir/${name}_provenance"
	local path description about source_size target_size source_hash target_hash revision

	if ! printf '%s\n' "$repository" | grep -qE '^github:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
		printf 'corpus: invalid immutable repository identity: %s\n' "$repository" >&2
		return 1
	fi
	for revision in "$source_revision" "$target_revision"; do
		if ! printf '%s\n' "$revision" | grep -qE '^[0-9a-f]{40}$'; then
			printf 'corpus: invalid 40-character Git revision: %s\n' "$revision" >&2
			return 1
		fi
	done
	if [ "$source_revision" = "$target_revision" ]; then
		printf 'corpus: source and target revisions are identical\n' >&2
		return 1
	fi

	for path in "$source_binary" "$target_binary"; do
		if [ ! -f "$path" ] || [ ! -x "$path" ]; then
			printf 'corpus: real binary is not an executable file: %s\n' "$path" >&2
			return 1
		fi
		description=$(file -Lb "$path" 2>/dev/null)
		if ! printf '%s\n' "$description" | grep -qF 'ELF 64-bit LSB' ||
			! printf '%s\n' "$description" | grep -qF 'x86-64' ||
			! printf '%s\n' "$description" | grep -qF 'executable'; then
			printf 'corpus: expected a Linux x86_64 ELF executable: %s (%s)\n' \
				"$path" "$description" >&2
			return 1
		fi
		about=$("$path" --about 2>&1)
		if [ "$?" -ne 0 ] || printf '%s\n' "$about" | grep -qF 'DEBUG BUILD'; then
			printf 'corpus: executable failed its ReleaseFast --about probe: %s\n' "$path" >&2
			return 1
		fi
	done

	source_size=$(corpus_file_size "$source_binary")
	target_size=$(corpus_file_size "$target_binary")
	corpus_assert_exact_size "$source_binary" "$source_size" || return 1
	corpus_assert_exact_size "$target_binary" "$target_size" || return 1
	source_hash=$(sha256sum "$source_binary" | cut -d' ' -f1)
	target_hash=$(sha256sum "$target_binary" | cut -d' ' -f1)
	if [ "$source_hash" = "$target_hash" ]; then
		printf 'corpus: independently revised binaries have identical SHA-256 hashes\n' >&2
		return 1
	fi

	if ! cp "$source_binary" "$file_a" || ! cp "$target_binary" "$file_b"; then
		printf 'corpus: could not install real binary pair\n' >&2
		rm -f "$file_a" "$file_b"
		return 1
	fi
	if ! printf '%s\n' \
		"repository=$repository" \
		"source_revision=$source_revision" \
		"target_revision=$target_revision" \
		"source_sha256=$source_hash" \
		"target_sha256=$target_hash" > "$provenance"; then
		printf 'corpus: could not record real binary provenance\n' >&2
		rm -f "$file_a" "$file_b" "$provenance"
		return 1
	fi
}
