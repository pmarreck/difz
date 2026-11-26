{ pkgs, sdk, buildStamp, debug ? false }:
# Production ABI artifact. The separate rust-abi and rust-cli checks exercise
# this installed library; production builds do not build test/oracle programs.
(pkgs.rustPlatform.buildRustPackage {
	pname = "difz-rust-library";
	version = "0.1.0";
	src = pkgs.lib.fileset.toSource {
		root = ./.;
		# Cargo resolves all workspace manifests and target entry points. It does
		# not compile the benchmark consumer or cfg(test) modules for this product.
		# Keep those inputs in qa.nix, so test edits do not rebuild every product.
		fileset = pkgs.lib.fileset.difference
			(pkgs.lib.fileset.unions [ ./Cargo.toml ./Cargo.lock ./src ./zstdz ./consumer/Cargo.toml ./consumer/src/main.rs ./c-api ./platform ])
			(pkgs.lib.fileset.unions [ ./c-api/tests (pkgs.lib.fileset.fileFilter
				(file: file.name == "tests.rs" || pkgs.lib.hasSuffix "_tests.rs" file.name) ./.) ]);
	};
	cargoLock.lockFile = ./Cargo.lock;
	strictDeps = true;
	buildType = if debug then "debug" else "release";
	nativeBuildInputs = [ pkgs.buildPackages.jq ] ++ pkgs.lib.optional pkgs.stdenv.hostPlatform.isWindows pkgs.buildPackages.gnused;
	buildInputs = [ sdk ];
	doCheck = false;
	buildPhase = ''
		runHook preBuild
		cmp ${buildStamp.json} ${sdk}/nix-support/build-provenance.json
		export CC=false CXX=false AR=false
		if ! cargo build --locked --offline --target ${pkgs.stdenv.hostPlatform.rust.rustcTarget} ${pkgs.lib.optionalString (!debug) "--release"} -p difz-c-api --lib --message-format=json > artifacts.json; then
			jq -r 'select(.reason == "compiler-message") | .message.rendered // empty' artifacts.json >&2
			exit 1
		fi
		archive=$(jq -ser '[.[] | select(.reason == "compiler-artifact" and .target.name == "difz_rust") | .filenames[] | select(endswith(".a"))] | if length == 1 then .[0] else error("expected one public ABI archive") end' artifacts.json)
		${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isWindows ''
			# Ask the actual target compiler for the platform libraries required
			# by an external C consumer of this static archive.
			if ! cargo rustc --color never --locked --offline --target ${pkgs.stdenv.hostPlatform.rust.rustcTarget} ${pkgs.lib.optionalString (!debug) "--release"} -p difz-c-api --lib -- --print native-static-libs > native-libs.out 2> native-libs.err; then
				cat native-libs.err >&2; exit 1
			fi
			sed -n 's/^note: native-static-libs: //p' native-libs.err > native-static-libs
			test -s native-static-libs
			test "$(wc -l < native-static-libs)" -eq 1
		''}
		runHook postBuild
	'';
	installPhase = ''
		runHook preInstall
		install -Dm644 "$archive" "$out/lib/libdifz_rust.a"
		install -Dm644 c-api/include/difz-rust.h "$out/include/difz-rust.h"
		mkdir -p "$out/nix-support"
		printf '%s\n' '${pkgs.stdenv.hostPlatform.rust.rustcTarget}' > "$out/nix-support/rust-target"
		printf '%s\n' '${if debug then "debug" else "release"}' > "$out/nix-support/rust-profile"
		${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isWindows ''
			install -m644 native-static-libs "$out/nix-support/native-static-libs"
		''}
		${buildStamp.install}
		runHook postInstall
	'';
	passthru.rustTarget = pkgs.stdenv.hostPlatform.rust.rustcTarget;
	passthru.rustProfile = if debug then "debug" else "release";
}).overrideAttrs (old: pkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.isLinux || pkgs.stdenv.hostPlatform.isWindows) {
	# Cargo's staticlib already bundles the native archive. External consumers
	# must link the installed archive without a build-time SDK dependency.
	buildInputs = (old.buildInputs or []) ++ (old.propagatedBuildInputs or []);
	propagatedBuildInputs = [];
	allowedReferences = [];
})
