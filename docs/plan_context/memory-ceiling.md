# Process memory ceiling

The CLI option `--max-rss-bytes` currently installs a POSIX `RLIMIT_AS` limit before reading inputs. This limits virtual address space, rather than measuring resident memory. Windows rejects the option. The existing CLI regressions require a 4 KiB ceiling to fail closed and an 8 GiB ceiling to allow a tiny create.

The earlier native Mac archive run rejected an 8 GiB ceiling with `EINVAL`. That observation remains an open defect; observing a lower peak RSS during an uncapped run does not establish enforcement.

Apple's current [resource-limit implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_resource.c) passes `RLIMIT_AS` to `vm_map_set_size_limit` and returns `EINVAL` when the requested limit cannot be lowered below current VM usage. Its [public resource header](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/resource.h) defines `RLIMIT_AS` and makes `RLIMIT_RSS` an alias. The current source therefore does not support treating every such failure as an unsupported API.

On 2026-10-14, separate Bash processes on macOS 26.7.1 ARM64 provided a native diagnostic. With initial VSZ 435,299,984 KiB and RSS 2,160 KiB, `ulimit -v 8388608` rejected the 8 GiB ceiling with `EINVAL`. A second process with VSZ 435,300,048 KiB accepted a 436,348,624 KiB ceiling, exactly 1 GiB above its initial VSZ. These are shell observations, not difz measurements. They support the current-VM explanation for those processes without establishing resident-memory enforcement.

The probe changes limits only in its two child shells:

```bash
for ceiling_case in fixed headroom; do
	/bin/bash -c '
		read -r initial_vm_kib initial_rss_kib < <(/bin/ps -o vsz= -o rss= -p "$$")
		if [ "$1" = fixed ]; then ceiling_kib=8388608; else ceiling_kib=$((initial_vm_kib + 1048576)); fi
		printf "case=%s initial_vm_kib=%s initial_rss_kib=%s ceiling_kib=%s\n" "$1" "$initial_vm_kib" "$initial_rss_kib" "$ceiling_kib"
		if ulimit -v "$ceiling_kib"; then printf "limit_result=accepted\n"; else printf "limit_result=rejected\n"; fi
	' -- "$ceiling_case"
done
```

Next reproduce the same boundary in the difz process and settle the documented quantity to bound. Any eventual fix must preserve fail-closed behavior without silently substituting RSS observation or additional virtual-space headroom for an RSS ceiling.
