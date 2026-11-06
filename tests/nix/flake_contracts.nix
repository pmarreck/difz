{ source }:
let
	# source is the immutable, Git-filtered path from `nix flake metadata`.
	flake = builtins.getFlake ("path:" + source);
	system = builtins.currentSystem;
	checks = flake.checks.${system};
	shell = flake.devShells.${system}.default;
	names = inputs: map (input: input.pname or input.name or "") inputs;
	membership = root: required: excluded:
		let present = path: builtins.pathExists (root + "/${path}");
		in { required = map present required; excluded = map present excluded; };
in {
	systems = builtins.attrNames flake.packages;
	randomInputs = builtins.filter (name: builtins.match "^random($|-).*" name != null)
		(names checks.benchmark-contract.nativeBuildInputs);
	zstdUrl = (builtins.head (builtins.filter (input: (input.pname or "") == "zstd") shell.nativeBuildInputs)).src.url;
	windowsCheck = checks.windows-gnu.name;
	armPackage = flake.packages.aarch64-linux.default.name;
	rustTools = builtins.sort builtins.lessThan
		(builtins.filter (name: builtins.elem name [ "cargo" "rustc" ]) (names shell.nativeBuildInputs));
	codecOutputs = builtins.mapAttrs (_: packages:
		builtins.filter (name: name == "rust-codec-tests") (builtins.attrNames packages)
	) flake.packages;
	codecCheck = checks.rust-codec.name;
	hostOutputs = builtins.mapAttrs (_: packages: builtins.hasAttr "host-tests" packages) flake.packages;
	rustFfiCheck = checks.rust-ffi.name;
	rustCoreCheck = checks.rust-core.name;
	rustSdkTargets = builtins.mapAttrs (_: packages: packages.rust-zstdz-sdk.rustTarget) flake.packages;
	rustCoreSdk = builtins.elem flake.packages.${system}.rust-zstdz-sdk.drvPath
		(map (input: input.drvPath) checks.rust-core.buildInputs);
	rustSdkSource = membership flake.packages.${system}.rust-zstdz-sdk.src
		[ "zstdz-sdk-setup-hook.sh" ] [ "Cargo.toml" "qa.nix" "src/lib.rs" "zstdz/build.rs" ];
	buildWrapperCheck = checks.build-wrapper.name;
	debugPackages = builtins.mapAttrs (nativeSystem: packages: packages.debug.drvPath == flake.checks.${nativeSystem}.test.drvPath) flake.packages;
	buildWrapperSource = membership checks.build-wrapper.src
		[ "build" "tests/integration/test-build-wrapper.bash" ]
		[ "PLAN.md" "README.md" "flake.nix" "src/zstd_patch.zig" "rust/src/lib.rs" ];
	rustCoreOutputs = builtins.mapAttrs (_: packages: builtins.hasAttr "rust-core-tests" packages) flake.packages;
	rustCoreSource = membership flake.packages.${system}.rust-core-tests.src
		[ "Cargo.toml" "Cargo.lock" "src/lib.rs" "src/tests.rs" "src/file.rs" "src/file_tests.rs" "src/directory.rs" "src/directory_tests.rs" "src/directory_record.rs" "src/directory_record_tests.rs" "src/directory_canonical.rs" "src/directory_canonical_tests.rs" "src/directory_structure.rs" "src/directory_structure_tests.rs" "src/tree_patch.rs" "src/tree_patch_tests.rs" "src/tree_patch_decode.rs" "src/tree_patch_decode_tests.rs" "src/metadata_borrow.rs" "src/tree_patch_encode.rs" "src/tree_patch_encode_tests.rs" "src/tree_patch_apply.rs" "src/tree_patch_apply_tests.rs" "src/symlink_transport.rs" "src/symlink_transport_tests.rs" "src/linux_acl.rs" "src/linux_acl_tests.rs" "src/path_filter.rs" "src/path_filter_tests.rs" "src/metadata.rs" "src/metadata_record.rs" "src/metadata_canonical.rs" "src/metadata_canonical_tests.rs" "src/metadata_decode.rs" "src/metadata_restore.rs" "src/metadata_restore_tests.rs" "src/metadata_tests.rs" "zstdz/Cargo.toml" "zstdz/build.rs" "zstdz/src/lib.rs" "consumer/Cargo.toml" "consumer/src/main.rs" "consumer/src/measurement.rs" "consumer/native_params.c" "c-api/Cargo.toml" "c-api/src/lib.rs" "c-api/include/difz-rust.h" "c-api/tests/caller.c" "platform/Cargo.toml" "platform/src/lib.rs" "platform/src/tests.rs" "platform/src/entry.rs" "platform/src/names.rs" "platform/src/names_tests.rs" "platform/src/xattr.rs" "platform/src/xattr_tests.rs" ]
		[ "PLAN.md" "flake.nix" "qa.nix" "src/zstd_patch.zig" "tests/codec_rust/interop.rs" "tests/acceptance/cross-apply" "zstdz-sdk.nix" "zstdz-sdk-setup-hook.sh" ];
	crossApplyCheck = checks.cross-apply.name;
	ciTargets = let
		ciChecks = flake.checks.x86_64-linux;
		package = flake.packages.x86_64-linux.default;
		# Package aliases are already covered by the package target.
		required = builtins.filter (name: ciChecks.${name}.drvPath != package.drvPath)
			(builtins.attrNames ciChecks);
	in [ "packages.x86_64-linux.default" ] ++ map (name: "checks.x86_64-linux.${name}") required;
	crossApplySource = membership checks.cross-apply.src
		[ "tests/acceptance/cross-apply" "tests/integration/test-cross-apply.bash" ]
		[ "PLAN.md" "flake.nix" "src/lib.zig" "tests/codec_rust/interop.rs" "tests/cli/test_cli.bash" "README.md" ];
	zigSource = membership flake.packages.${system}.default.src
		[ "build.zig" "build.zig.zon" "src/lib.zig" "src/difz.c" "src/difz.h" "scripts/flatten-static-lib" "tests/cli/test_cli.bash" "tests/ffi/caller.c" "tests/ffi/rust_caller.rs" "tests/ffi/test_installed_lib.bash" ]
		[ "PLAN.md" "README.md" "flake.nix" "scripts/run-tests-isolated" "tests/run-prepared-host" "tests/codec_rust/interop.rs" "tests/codec_rust/test_runner.bash" "docs/plan_context/rust-port.md" ];
	benchmarkSource = membership checks.benchmark-contract.src
		[ "bm" "profiling.json" "README.md" "tests/benchmark/test_bm.bash" "tests/benchmark/corpus.bash" "tests/benchmark/results.bash" "tests/benchmark/engine_case.bash" "tests/benchmark/verify_engine_sample.bash" "tests/benchmark/test_profiler_timeout.lua" "tests/benchmark/benchmark_log_v2.csv" "tests/benchmark/benchmark_log_v3.csv" ]
		[ "PLAN.md" "flake.nix" "build.zig" "src/lib.zig" "tests/nix/test_flake_outputs.bash" "tests/codec_rust/interop.rs" "docs/plan_context/test-preparation.md" "scripts/run-tests-isolated" ];
}
