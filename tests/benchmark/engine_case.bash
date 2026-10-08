#!/usr/bin/env bash
# Measure whole CLI processes; prepare fixtures and verify bytes outside timing.
set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
engine="${1:?engine required}"
shape="${2:?shape required}"
sizes="${3:?comma-separated sizes required}"
seed="${4:?seed required}"
case "$engine" in
	cdc) binary="${DIFZ_CDC:?DIFZ_CDC required}" ;;
	zstd) binary="${DIFZ_ZSTD:?DIFZ_ZSTD required}" ;;
	*) printf 'unknown engine: %s\n' "$engine" >&2; exit 2 ;;
esac
case "$shape" in
	scattered|moved|replacement|real) ;;
	*) printf 'unknown shape: %s\n' "$shape" >&2; exit 2 ;;
esac
if [ -n "${MUTE_DEBUG_STATUS:-}" ]; then
	printf 'debug status must not be suppressed\n' >&2
	exit 1
fi
about=$("$binary" --about 2>&1) || exit 1
if [[ "$about" == *'DEBUG BUILD'* ]]; then
	printf 'optimized binary required\n' >&2
	exit 1
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/difz-engine.XXXXXXXX") || exit 1
# Only private, newly generated fixtures are removed by this adapter.
trap 'rm -rf -- "$work"' EXIT
source "$root/tests/benchmark/corpus.bash"
time_bin="${GNU_TIME_BIN:-$(type -P time)}"
rss_scale=1024
[ "$(uname -s)" != Darwin ] || rss_scale=1
cdc_flags=()
if [ "$engine" = cdc ]; then
	printf -v cdc_seed '2a%.0s' {1..32}
	cdc_flags=(--seed "$cdc_seed" --compress best)
fi
rows='[]'
IFS=',' read -r -a size_list <<< "$sizes"
for size in "${size_list[@]}"; do
	if [[ ! "$size" =~ ^[0-9]+$ ]] || [ "$size" -lt 16 ]; then
		printf 'invalid fixture size: %s\n' "$size" >&2
		exit 2
	fi
	export ENGINE_SOURCE="$work/source" ENGINE_TARGET="$work/target"
	export ENGINE_PATCH="$work/patch" ENGINE_REBUILT="$work/rebuilt"
	if [ "$shape" = real ]; then
		ENGINE_SOURCE="${DIFZ_BENCH_SOURCE:?DIFZ_BENCH_SOURCE required}"
		ENGINE_TARGET="${DIFZ_BENCH_TARGET:?DIFZ_BENCH_TARGET required}"
		export ENGINE_SOURCE ENGINE_TARGET
		corpus_assert_exact_size "$ENGINE_TARGET" "$size" || exit 1
	else
		random --seed "$seed" -b -c "$size" > "$ENGINE_SOURCE" 2> "$work/random.stderr" || exit 1
		corpus_assert_exact_size "$ENGINE_SOURCE" "$size" || exit 1
		case "$shape" in
			scattered) LC_ALL=C tr '\000' '\001' < "$ENGINE_SOURCE" > "$ENGINE_TARGET" || exit 1 ;;
			replacement) random --seed "$((seed + 1))" -b -c "$size" > "$ENGINE_TARGET" 2> "$work/random.stderr" || exit 1 ;;
			moved)
				# Rotate by a quarter, replacing the final eighth with new bytes.
				quarter=$((size / 4))
				eighth=$((size / 8))
				dd if="$ENGINE_SOURCE" of="$ENGINE_TARGET" iflag=skip_bytes,count_bytes skip="$quarter" count="$((size - quarter))" status=none || exit 1
				head -c "$((quarter - eighth))" "$ENGINE_SOURCE" >> "$ENGINE_TARGET" || exit 1
				random --seed "$((seed + 1))" -b -c "$eighth" >> "$ENGINE_TARGET" 2> "$work/random.stderr" || exit 1
				;;
		 esac
		corpus_assert_exact_size "$ENGINE_TARGET" "$size" || exit 1
		if cmp -s "$ENGINE_SOURCE" "$ENGINE_TARGET"; then
			printf 'fixture has no changes\n' >&2
			exit 1
		fi
	fi
	export ENGINE_BINARY="$binary"
	create=("$binary" "$ENGINE_SOURCE" "$ENGINE_TARGET" -o "$ENGINE_PATCH" --no-progress
		--max-rss-bytes 17179869184 --max-wall-ms 120000 "${cdc_flags[@]}")
	apply=("$binary" --patch "$ENGINE_SOURCE" "$ENGINE_PATCH" -o "$ENGINE_REBUILT" --no-progress
		--max-rss-bytes 17179869184 --max-wall-ms 120000)
	# A fresh CLI process is the product's normal lifecycle. Warm its files first.
	"${create[@]}" > "$work/warm.stdout" 2> "$work/warm.stderr" || { cat "$work/warm.stderr" >&2; exit 1; }
	"${apply[@]}" > "$work/warm.stdout" 2> "$work/warm.stderr" || exit 1
	cmp -s "$ENGINE_TARGET" "$ENGINE_REBUILT" || { printf 'warmup reconstruction mismatch\n' >&2; exit 1; }
	for phase in create apply; do
		command=("${create[@]}")
		[ "$phase" != apply ] || command=("${apply[@]}")
		printf -v timed '%q ' "$time_bin" -a -o "$work/$phase.resources" -f '%U %S %M %x' "${command[@]}"
		printf -v verify '%q ' bash "$root/tests/benchmark/verify_engine_sample.bash" "$phase"
		printf -v prepare '%q ' bash "$root/tests/benchmark/verify_engine_sample.bash" "prepare-$phase"
		if ! hyperfine --shell bash --warmup 0 --runs 3 --style none \
			--export-json "$work/$phase.json" --prepare "$prepare" --conclude "$verify" "$timed" \
			> "$work/hyperfine.stdout" 2> "$work/hyperfine.stderr"; then
			cat "$work/hyperfine.stderr" >&2
			exit 1
		fi
		if grep -q 'DEBUG BUILD' "$work/hyperfine.stderr"; then exit 1; fi
		resources=$(jq -Rn --argjson scale "$rss_scale" '
			[inputs | split(" ") | map(tonumber) | {user_s:.[0],system_s:.[1],rss_bytes:(if .[2] > 0 then .[2]*$scale else null end),exit:.[3]}]
		' < "$work/$phase.resources") || exit 1
		jq -e 'length == 3 and all(.[]; .exit == 0)' <<< "$resources" > /dev/null || exit 1
		measured=$(jq --argjson resources "$resources" '{
			wall_ns:(.results[0].times | map(. * 1000000000)),
			user_s:($resources | map(.user_s)),system_s:($resources | map(.system_s)),
			peak_bytes:($resources | map(.rss_bytes))
		}' "$work/$phase.json") || exit 1
		if [ "$phase" = create ]; then create_metrics="$measured"; else apply_metrics="$measured"; fi
		: > "$work/$phase.resources"
	done
	patch_bytes=$(corpus_file_size "$ENGINE_PATCH")
	source_sha=$(sha256sum "$ENGINE_SOURCE" | cut -d' ' -f1)
	target_sha=$(sha256sum "$ENGINE_TARGET" | cut -d' ' -f1)
	rows=$(jq --argjson size "$size" --argjson create "$create_metrics" --argjson apply "$apply_metrics" \
		--argjson bytes "$patch_bytes" --arg source "$source_sha" --arg target "$target_sha" \
		'. + [{size:$size,samples:$create,apply:$apply,patch_bytes:$bytes,source_sha256:$source,target_sha256:$target}]' <<< "$rows") || exit 1
	done
binary_sha=$(sha256sum "$binary" | cut -d' ' -f1)
jq -n --arg engine "$engine" --arg shape "$shape" --arg seed "$seed" --arg binary_sha "$binary_sha" --argjson rows "$rows" '{
	schema:"performance-measurement/v1",correct:true,build_mode:"ReleaseFast",
	engine:$engine,shape:$shape,seed:$seed,binary_sha256:$binary_sha,rows:$rows,
	measurement:"warm-file whole-process hyperfine wall time; GNU time user/system seconds (0.01 s resolution) and process peak RSS; verification outside timing",
	allocator_coverage:"process RSS only; null means the OS reported no RSS sample; no allocation or leak claims"
}'
