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
	buildContract = flake.buildContract;
	buildProvenance = flake.buildProvenance;
	buildRegistryOutputs = map (row: row.output == null ||
		flake.inputs.nixpkgs.lib.attrByPath (flake.inputs.nixpkgs.lib.splitString "." row.output) null flake != null
	) flake.buildContract.rows;
	randomInputs = builtins.filter (name: builtins.match "^random($|-).*" name != null)
		(names checks.benchmark-contract.nativeBuildInputs);
	zstdUrl = (builtins.head (builtins.filter (input: (input.pname or "") == "zstd") shell.nativeBuildInputs)).src.url;
	windowsCheck = checks.windows-gnu.name;
	windowsProducts = map (name: { inherit (checks.${name}) pf profile; })
		[ "windows-gnu" "windows-gnu-debug" "windows-arm64-gnu" "windows-arm64-gnu-debug" ];
	windowsEmulation = let check = checks.windows-amd64-emulated; in {
		inherit (check) execution;
		products = builtins.length check.products;
		source = membership check.source [ "tests/acceptance/cross-apply" ]
			[ "src/difz.c" "src/lib.zig" "rust/src/file.rs" ];
	};
	armPackage = flake.packages.aarch64-linux.default.name;
	armEmulation = let
		check = flake.checks.x86_64-linux.linux-arm64-emulated;
		products = flake.packages.x86_64-linux;
	in {
		inherit (check) execution;
		products = builtins.length check.products;
		registry = map (row: row.output) (builtins.filter (row: row.pf == "linux-arm64") flake.buildContract.rows);
		rustTargets = map (p: p.components.library.rustTarget)
			[ products.linux-arm64-rust-release products.linux-arm64-rust-debug ];
		source = membership check.source
			[ "scripts/check-static-linux.bash" "tests/cli/test_cli.bash" "tests/acceptance/cross-apply" ]
			[ "rust/src/lib.rs" "rust/cli/src/main.rs" "src/lib.zig" ];
	};
	rustTools = builtins.sort builtins.lessThan
		(builtins.filter (name: builtins.elem name [ "cargo" "rustc" ])
			(map (input: input.meta.mainProgram or (input.pname or input.name or "")) shell.nativeBuildInputs));
	codecOutputs = builtins.mapAttrs (_: packages:
		builtins.filter (name: name == "rust-codec-tests") (builtins.attrNames packages)
	) flake.packages;
	codecCheck = checks.rust-codec.name;
	hostOutputs = builtins.mapAttrs (_: packages: builtins.hasAttr "host-tests" packages) flake.packages;
	rustFfiCheck = checks.rust-ffi.name;
	rustCoreCheck = checks.rust-core.name;
	rustAbiCheck = checks.rust-abi.name;
	rustAbiDebugCheck = checks.rust-abi-debug.name;
	rustCliCheck = checks.rust-cli.name;
	runtimeCheck = checks.runtime-independence.name;
	runtimeSource = membership checks.runtime-independence.source
		[ "scripts/check-static-linux.bash" "tests/integration/test-standalone-linux.bash" ]
		[ "flake.nix" "rust/src/lib.rs" "src/lib.zig" ];
	linuxRustLibcs = builtins.mapAttrs (_: packages: map (package: package.stdenv.hostPlatform.libc)
		[ packages.rust-library packages.rust-library-debug packages.rust-cli packages.rust-cli-debug packages.rust-core-tests packages.rust-codec-tests packages.rust-zstdz-sdk ])
		(builtins.removeAttrs flake.packages [ "aarch64-darwin" ]);
	testEntryCheck = checks.test-entry.name;
	testEntrySource = membership checks.test-entry.src
		[ "test" "big_o" ".mechatron-prime/targets" "tests/integration/test-test-entry.bash" "tests/integration/test_prepared_runners.bash" "tests/run-prepared-host" "tests/run-host-tests" "tests/ffi/test_rust_lib.bash" "scripts/prepared-host-artifacts.bash" ]
		[ "rust/src/lib.rs" "rust/cli/src/main.rs" "flake.nix" "tests/cli/test_cli.bash" ];
	rustCliOutputs = builtins.mapAttrs (_: packages: builtins.hasAttr "rust-cli" packages && builtins.hasAttr "rust-cli-debug" packages) flake.packages;
	rustProducts = builtins.mapAttrs (_: packages:
		packages.rust-product.implementation == "rust" && packages.rust-product.profile == "release" &&
		packages.rust-product-debug.profile == "debug" &&
		packages.rust-product.components.library.drvPath == packages.rust-library.drvPath &&
		packages.rust-product-debug.components.library.drvPath == packages.rust-library-debug.drvPath &&
		packages.rust-product.components.cli.drvPath == packages.rust-cli.drvPath &&
		packages.rust-product-debug.components.cli.drvPath == packages.rust-cli-debug.drvPath
	) flake.packages;
	rustCliSource = membership flake.packages.${system}.rust-cli.src
		[ "Cargo.toml" "Cargo.lock" "build.rs" "src/main.rs" "src/args.rs" "src/catalog.rs" "src/ffi.rs" "src/io.rs" "src/limits.rs" "src/platform.rs" ]
		[ "src/lib.rs" "c-api/src/lib.rs" "platform/src/lib.rs" "src/lib.zig" "src/difz.c" "qa.nix" ];
	rustCliAcceptanceSource = membership checks.rust-cli.src
		[ "tests/cli/test_cli.bash" ] [ "rust/cli/src/main.rs" "rust/src/lib.rs" "src/lib.zig" ];
	rustCliLibrary = builtins.elem flake.packages.${system}.rust-library.drvPath
		(map (input: input.drvPath) flake.packages.${system}.rust-cli.buildInputs);
	rustDebugCliLibrary = builtins.elem flake.packages.${system}.rust-library-debug.drvPath
		(map (input: input.drvPath) flake.packages.${system}.rust-cli-debug.buildInputs);
	rustDebugAbiLibrary = builtins.elem flake.packages.${system}.rust-library-debug.drvPath
		(map (input: input.drvPath) checks.rust-abi-debug.buildInputs);
	rustAbiLibrary = builtins.elem flake.packages.${system}.rust-library.drvPath
		(map (input: input.drvPath) checks.rust-abi.buildInputs);
	rustLibraryInputs = names flake.packages.${system}.rust-library.buildInputs;
	rustLibrarySource = membership flake.packages.${system}.rust-library.src
		[ "Cargo.toml" "Cargo.lock" "src/lib.rs" "zstdz/src/lib.rs" "c-api/src/lib.rs" "c-api/src/filesystem.rs" "c-api/include/difz-rust.h" "platform/src/lib.rs" "consumer/Cargo.toml" "consumer/src/main.rs" ]
		[ "qa.nix" "library.nix" "cli/src/main.rs" "tests/ffi/rust_caller.rs" "src/lib.zig" "src/tests.rs" "src/file_tests.rs" "platform/src/tests.rs" "platform/src/xattr_tests.rs" "consumer/src/measurement.rs" "consumer/src/structure_measurement.rs" "consumer/src/tree_measurement.rs" "consumer/native_params.c" "c-api/tests/caller.c" ];
	rustAbiSource = membership checks.rust-abi.src
		[ "rust/c-api/tests/caller.c" ]
		[ "rust/src/lib.rs" "rust/c-api/src/lib.rs" "rust/c-api/include/difz-rust.h" "rust/Cargo.toml" "src/lib.zig" "src/difz.c" ];
	rustSdkTargets = builtins.mapAttrs (_: packages: packages.rust-zstdz-sdk.rustTarget) flake.packages;
	rustCoreSdk = builtins.elem flake.packages.${system}.rust-zstdz-sdk.drvPath
		(map (input: input.drvPath) (checks.rust-core.buildInputs ++ (checks.rust-core.propagatedBuildInputs or [])));
	rustSdkSource = membership flake.packages.${system}.rust-zstdz-sdk.src
		[ "zstdz-sdk-setup-hook.sh" ] [ "Cargo.toml" "qa.nix" "src/lib.rs" "zstdz/build.rs" ];
	buildWrapperCheck = checks.build-wrapper.name;
	debugPackages = builtins.mapAttrs (nativeSystem: packages: packages.debug.drvPath ==
		(if flake.buildContract.canonical == "zig" then packages.zig-debug.drvPath else packages.rust-product-debug.drvPath)
	) flake.packages;
	buildWrapperSource = membership checks.build-wrapper.src
		[ "build" "run" "CANONICAL_IMPL" "nix/build-targets.tsv" "scripts/build-selection.bash" "scripts/build-driver.bash" "scripts/capture-build-provenance.bash" "scripts/verify-build-output.bash" "tests/integration/test-build-provenance.bash" "tests/integration/test-build-wrapper.bash" "tests/integration/test-build-selection.bash" "tests/integration/test-build-verification.bash" "tests/integration/test-build-nix-roots.bash" ]
		[ "PLAN.md" "README.md" "flake.nix" "src/zstd_patch.zig" "rust/src/lib.rs" ];
	rustCoreOutputs = builtins.mapAttrs (_: packages: builtins.hasAttr "rust-core-tests" packages) flake.packages;
	rustCoreSource = membership flake.packages.${system}.rust-core-tests.src
		[ "Cargo.toml" "Cargo.lock" "src/lib.rs" "src/tests.rs" "src/file.rs" "src/file_tests.rs" "src/directory.rs" "src/directory_tests.rs" "src/directory_record.rs" "src/directory_record_tests.rs" "src/directory_canonical.rs" "src/directory_select.rs" "src/directory_canonical_tests.rs" "src/directory_structure.rs" "src/directory_structure_tests.rs" "src/tree_patch.rs" "src/tree_patch_tests.rs" "src/tree_patch_decode.rs" "src/tree_patch_decode_tests.rs" "src/metadata_borrow.rs" "src/tree_patch_encode.rs" "src/tree_patch_encode_tests.rs" "src/tree_patch_apply.rs" "src/tree_patch_apply_tests.rs" "src/symlink_transport.rs" "src/symlink_transport_tests.rs" "src/linux_acl.rs" "src/linux_acl_tests.rs" "src/path_filter.rs" "src/path_filter_tests.rs" "src/metadata.rs" "src/attribute_name.rs" "src/attribute_name_tests.rs" "src/metadata_record.rs" "src/metadata_canonical.rs" "src/metadata_canonical_tests.rs" "src/metadata_decode.rs" "src/metadata_restore.rs" "src/metadata_restore_tests.rs" "src/metadata_tests.rs" "zstdz/Cargo.toml" "zstdz/build.rs" "zstdz/src/lib.rs" "consumer/Cargo.toml" "consumer/src/main.rs" "consumer/src/measurement.rs" "consumer/native_params.c" "c-api/Cargo.toml" "c-api/src/lib.rs" "c-api/src/filesystem.rs" "c-api/include/difz-rust.h" "c-api/tests/caller.c" "platform/Cargo.toml" "platform/src/lib.rs" "platform/src/tests.rs" "platform/src/entry.rs" "platform/src/names.rs" "platform/src/names_tests.rs" "platform/src/xattr.rs" "platform/src/xattr_tests.rs" "platform/src/linux_metadata.rs" "platform/src/sparse.rs" "platform/src/linux_times.rs" "platform/src/write.rs" "platform/src/stage.rs" "platform/src/linux_capture.rs" "platform/src/linux_transport.rs" "platform/src/linux_snapshot_metadata.rs" "platform/src/linux_acl_restore.rs" "platform/src/linux_attribute_restore.rs" "platform/src/linux_sparse_restore.rs" "platform/src/linux_symlink_capture.rs" "platform/src/linux_tree_capture.rs" "platform/src/linux_symlink_restore.rs" "platform/src/linux_tree_write.rs" "platform/src/linux_tree_patch.rs" "platform/src/linux_stage_metadata.rs" "platform/src/new_file.rs" "src/growth.rs" "consumer/src/structure_measurement.rs" "consumer/src/tree_measurement.rs" ]
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
	zigSource = membership flake.packages.${system}.zig-release.src
		[ "build.zig" "build.zig.zon" "src/lib.zig" "src/difz.c" "src/difz.h" "scripts/flatten-static-lib" "tests/cli/test_cli.bash" "tests/ffi/caller.c" "tests/ffi/rust_caller.rs" "tests/ffi/test_installed_lib.bash" ]
		[ "PLAN.md" "README.md" "flake.nix" "scripts/run-tests-isolated" "tests/run-prepared-host" "tests/codec_rust/interop.rs" "tests/codec_rust/test_runner.bash" "docs/plan_context/rust-port.md" ];
	benchmarkSource = membership checks.benchmark-contract.src
		[ "bm" "profiling.json" "README.md" "tests/benchmark/test_bm.bash" "tests/benchmark/corpus.bash" "tests/benchmark/results.bash" "tests/benchmark/engine_case.bash" "tests/benchmark/verify_engine_sample.bash" "tests/benchmark/test_profiler_timeout.lua" "tests/benchmark/benchmark_log_v2.csv" "tests/benchmark/benchmark_log_v3.csv" "profiling-rust-structure.json" "tests/benchmark/rust-structure-case" "tests/benchmark/rust-structure-growth.lua" "tests/benchmark/test-rust-structure-registry.bash" "tests/benchmark/test-rust-growth-routing.bash" ]
		[ "PLAN.md" "flake.nix" "build.zig" "src/lib.zig" "tests/nix/test_flake_outputs.bash" "tests/codec_rust/interop.rs" "docs/plan_context/test-preparation.md" "scripts/run-tests-isolated" ];
}
