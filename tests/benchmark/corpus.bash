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

# Use a real executable as the source and apply distributed relocation-like
# byte changes. This preserves executable structure and exact file length.
generate_binary_shape_pair() {
	local output_dir="$1"
	local name="$2"
	local source_binary="$3"
	local file_a="$output_dir/${name}_a"
	local file_b="$output_dir/${name}_b"
	local declared_size

	declared_size=$(corpus_file_size "$source_binary")
	if [ "$declared_size" -le 0 ]; then
		printf 'corpus: binary source is empty: %s\n' "$source_binary" >&2
		return 1
	fi

	if ! cp "$source_binary" "$file_a"; then
		printf 'corpus: could not copy binary source %s\n' "$source_binary" >&2
		return 1
	fi
	corpus_assert_exact_size "$file_a" "$declared_size" || return 1

	if ! LC_ALL=C tr '\000' '\001' < "$file_a" > "$file_b"; then
		printf 'corpus: binary-shape transform failed for %s\n' "$file_b" >&2
		return 1
	fi
	corpus_assert_exact_size "$file_b" "$declared_size" || return 1

	if cmp -s "$file_a" "$file_b"; then
		printf 'corpus: binary-shape fixture contains no edits\n' >&2
		return 1
	fi
}
