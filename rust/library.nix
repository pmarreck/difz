{ pkgs, sdk, debug ? false }:
# Production ABI artifact. The separate rust-abi and rust-cli checks exercise
# this installed library; production builds do not build test/oracle programs.
pkgs.rustPlatform.buildRustPackage {
	pname = "difz-rust-library";
	version = "0.1.0";
	src = pkgs.lib.fileset.toSource {
		root = ./.;
		# Cargo resolves every workspace member even when only c-api is built.
		fileset = pkgs.lib.fileset.unions [ ./Cargo.toml ./Cargo.lock ./src ./zstdz ./consumer ./c-api ./platform ];
	};
	cargoLock.lockFile = ./Cargo.lock;
	strictDeps = true;
	buildType = if debug then "debug" else "release";
	nativeBuildInputs = [ pkgs.jq ];
	buildInputs = [ sdk ];
	doCheck = false;
	buildPhase = ''
		runHook preBuild
		export CC=false CXX=false AR=false
		if ! cargo build --locked --offline --target ${pkgs.stdenv.hostPlatform.rust.rustcTarget} ${pkgs.lib.optionalString (!debug) "--release"} -p difz-c-api --lib --message-format=json > artifacts.json; then
			jq -r 'select(.reason == "compiler-message") | .message.rendered // empty' artifacts.json >&2
			exit 1
		fi
		archive=$(jq -ser '[.[] | select(.reason == "compiler-artifact" and .target.name == "difz_rust") | .filenames[] | select(endswith(".a"))] | if length == 1 then .[0] else error("expected one public ABI archive") end' artifacts.json)
		runHook postBuild
	'';
	installPhase = ''
		runHook preInstall
		install -Dm644 "$archive" "$out/lib/libdifz_rust.a"
		install -Dm644 c-api/include/difz-rust.h "$out/include/difz-rust.h"
		mkdir -p "$out/nix-support"
		printf '%s\n' '${pkgs.stdenv.hostPlatform.rust.rustcTarget}' > "$out/nix-support/rust-target"
		printf '%s\n' '${if debug then "debug" else "release"}' > "$out/nix-support/rust-profile"
		runHook postInstall
	'';
	passthru.rustTarget = pkgs.stdenv.hostPlatform.rust.rustcTarget;
	passthru.rustProfile = if debug then "debug" else "release";
}
