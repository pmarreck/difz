#!/usr/bin/env bash

# Versioned benchmark logging and deterministic regression calculations.

benchmark_log_v2_header() {
	printf '%s\n' 'timestamp,test_name,corpus_shape,source_size,target_size,op_count,min_ops,difz_diff_ms,difz_diff_peak_rss_kb,bsdiff_diff_ms,xdelta_diff_ms,zstd_diff_ms,difz_patch_ms,difz_patch_peak_rss_kb,bspatch_patch_ms,xdelta_patch_ms,zstd_patch_ms,difz_size,bsdiff_size,xdelta_size,zstd_size'
}

init_benchmark_log_v2() {
	local log_file="$1"
	if [ ! -f "$log_file" ]; then
		benchmark_log_v2_header > "$log_file"
	fi
}

# Return success when milliseconds per operation grew beyond the threshold.
apply_complexity_regressed() {
	local previous_ms="$1"
	local previous_ops="$2"
	local current_ms="$3"
	local current_ops="$4"
	local threshold_percent="$5"
	local current_scaled previous_threshold

	if [ "$previous_ms" -le 0 ] || [ "$previous_ops" -le 0 ] ||
		[ "$current_ms" -lt 0 ] || [ "$current_ops" -le 0 ]; then
		return 1
	fi

	current_scaled=$(( current_ms * previous_ops * 100 ))
	previous_threshold=$(( previous_ms * current_ops * (100 + threshold_percent) ))
	[ "$current_scaled" -gt "$previous_threshold" ]
}

# Return success when a positive scalar grew beyond the threshold.
metric_regressed() {
	local previous="$1"
	local current="$2"
	local threshold_percent="$3"

	if [ "$previous" -le 0 ] || [ "$current" -lt 0 ]; then
		return 1
	fi

	[ "$(( current * 100 ))" -gt "$(( previous * (100 + threshold_percent) ))" ]
}
