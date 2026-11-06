{ pkgs, oracle, metadataOracle, zstdz, sdk, random }:
pkgs.rustPlatform.buildRustPackage {
	pname = "difz-rust-core-tests";
	version = "0.1.0";
	src = pkgs.lib.fileset.toSource {
		root = ./.;
		fileset = pkgs.lib.fileset.unions [ ./Cargo.toml ./Cargo.lock ./src ./zstdz ./consumer ];
	};
	cargoLock.lockFile = ./Cargo.lock;
	strictDeps = true;
	nativeBuildInputs = [ pkgs.jq ];
	buildInputs = [ sdk ];
	nativeCheckInputs = [ pkgs.b3sum pkgs.gnugrep pkgs.coreutils ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.binutils ];
	DIFZ_ORACLE = "${oracle}/bin/difz";
	DIFZ_METADATA_ORACLE = "${metadataOracle}/bin/difz-metadata-oracle";
	B3SUM = "${pkgs.b3sum}/bin/b3sum";
	DIFZ_RANDOM = "${random}/bin/random";
	doCheck = true;
	buildPhase = ''
		runHook preBuild
		${pkgs.stdenv.cc}/bin/cc consumer/native_params.c -DZSTD_MULTITHREAD \
			-I${zstdz.src}/lib -I${zstdz.src}/lib/compress ${zstdz}/lib/libzstd.a -pthread -o native-params
		./native-params > native-params.json
		export DIFZ_NATIVE_PARAMS="$PWD/native-params.json"
		export CC=false CXX=false AR=false
		if ! cargo test --locked --offline -p difz-core --lib --no-run --message-format=json > cargo-tests.json; then
			jq -r 'select(.reason == "compiler-message") | .message.rendered // empty' cargo-tests.json >&2
			exit 1
		fi
		test_binary=$(jq -er 'select(.reason == "compiler-artifact" and .profile.test == true and .executable != null) | .executable' cargo-tests.json)
		if ! cargo build --locked --offline --release -p difz-core-consumer --message-format=json > consumer.json; then
			jq -r 'select(.reason == "compiler-message") | .message.rendered // empty' consumer.json >&2
			exit 1
		fi
		consumer=$(jq -er 'select(.reason == "compiler-artifact" and .target.name == "difz-core-consumer" and .executable != null) | .executable' consumer.json)
		if ! cargo test --locked --offline --release -p difz-core-consumer --no-run --message-format=json > consumer-tests.json; then
			jq -r 'select(.reason == "compiler-message") | .message.rendered // empty' consumer-tests.json >&2
			exit 1
		fi
		consumer_tests=$(jq -er 'select(.reason == "compiler-artifact" and .profile.test == true and .executable != null) | .executable' consumer-tests.json)
		runHook postBuild
	'';
	checkPhase = ''
		runHook preCheck
		export HOME="$TMPDIR/header-home"
		export XDG_CONFIG_HOME="$HOME/config" XDG_DATA_HOME="$HOME/data"
		export XDG_STATE_HOME="$HOME/state" XDG_CACHE_HOME="$HOME/cache"
		export XDG_RUNTIME_DIR="$HOME/runtime"
		mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR"
		chmod 700 "$XDG_RUNTIME_DIR"
		test_count=$("$test_binary" --list | grep -c ': test$')
		test "$test_count" -ge 50
		# Include the reference children in a bounded process group if IPC stalls.
		${pkgs.coreutils}/bin/timeout --kill-after=5s 120s "$test_binary" --test-threads=1 --include-ignored
		consumer_test_count=$("$consumer_tests" --list | grep -c ': test$')
		test "$consumer_test_count" -ge 4
		${pkgs.coreutils}/bin/timeout --kill-after=5s 120s "$consumer_tests" --test-threads=1 --include-ignored
		"$consumer"
		( unset DIFZ_ZSTDZ_ROOT; source ${sdk}/nix-support/setup-hook; test "$DIFZ_ZSTDZ_ROOT" = ${sdk}; source ${sdk}/nix-support/setup-hook )
		if ( export DIFZ_ZSTDZ_ROOT=conflicting-sdk; source ${sdk}/nix-support/setup-hook ) 2> "$TMPDIR/sdk-conflict-error"; then
			printf 'FAIL conflicting SDK root was accepted\n' >&2
			exit 1
		fi
		grep -F 'Conflicting difz zstdz SDK roots' "$TMPDIR/sdk-conflict-error"
		# This parent is outside the difz Cargo workspace and receives no link flags.
		parent="$TMPDIR/sdk-parent"
		mkdir -p "$parent/src"
		cat > "$parent/Cargo.toml" <<EOF
[package]
name = "difz-sdk-parent"
version = "0.0.0"
edition = "2024"
[workspace]
[dependencies]
difz-core = { path = "$PWD" }
EOF
		cat > "$parent/src/main.rs" <<'EOF'
fn main() {
    let source = b"\0\xfforiginal";
    let target = b"\0\xffupdated";
    let patch = difz_core::file::encode(source, target).unwrap();
    assert_eq!(difz_core::file::apply(source, &patch, 1024).unwrap(), target);
}
EOF
		cargo metadata --offline --format-version 1 --manifest-path "$parent/Cargo.toml" > "$parent/metadata.json"
		cargo build --locked --offline --release --manifest-path "$parent/Cargo.toml" --message-format=json > "$parent/artifacts.json"
		parent_binary=$(jq -er 'select(.reason == "compiler-artifact" and .target.name == "difz-sdk-parent" and .executable != null) | .executable' "$parent/artifacts.json")
		"$parent_binary"
		wrong="$TMPDIR/wrong-sdk"
		mkdir -p "$wrong/nix-support"
		ln -s ${sdk}/lib "$wrong/lib"
		printf 'wrong-sdk-target\n' > "$wrong/nix-support/rust-target"
		if DIFZ_ZSTDZ_ROOT="$wrong" CARGO_TARGET_DIR="$TMPDIR/wrong-target" cargo check --locked --offline --manifest-path "$parent/Cargo.toml" > "$parent/wrong-output" 2> "$parent/wrong-error"; then
			printf 'FAIL wrong-target zstdz SDK was accepted\n' >&2
			exit 1
		fi
		grep -F 'zstdz SDK target mismatch' "$parent/wrong-error"
		# A parent must not silently link two providers of the ZSTD C namespace.
		control="$TMPDIR/native-provider-control"
		mkdir -p "$control/src" "$control/other/src"
		cat > "$control/Cargo.toml" <<EOF
[package]
name = "difz-native-provider-control"
version = "0.0.0"
edition = "2024"
[workspace]
[dependencies]
difz-core = { path = "$PWD" }
other-provider = { path = "other" }
EOF
		cat > "$control/other/Cargo.toml" <<'EOF'
[package]
name = "other-provider"
version = "0.0.0"
edition = "2024"
links = "unrelated_native"
EOF
		printf 'fn main() {}\n' > "$control/other/build.rs"
		printf '// independent native provider fixture\n' > "$control/other/src/lib.rs"
		printf 'fn main() {}\n' > "$control/src/main.rs"
		cargo metadata --offline --format-version 1 --manifest-path "$control/Cargo.toml" > "$control/positive.json"
		substituteInPlace "$control/other/Cargo.toml" --replace-fail '"unrelated_native"' '"zstd"'
		if cargo metadata --locked --offline --format-version 1 --manifest-path "$control/Cargo.toml" > "$control/negative.json" 2> "$control/error"; then
			printf 'FAIL competing native zstd provider was accepted\n' >&2
			exit 1
		fi
		grep -F 'Only one package' "$control/error"
		grep -F 'zstd' "$control/error" > /dev/null
		${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
			(ulimit -v 131072; "$consumer" --allocation-proof)
			nm "$consumer" | grep -E ' T ZSTD_compress2$'
			nm "$consumer" | grep -E ' T ZSTD_decompressDCtx$'
			if readelf -d "$consumer" | grep NEEDED | grep -Ei 'zstd|difz'; then exit 1; fi
		''}
		runHook postCheck
	'';
	installPhase = ''
		runHook preInstall
		install -Dm755 "$test_binary" "$out/bin/difz-rust-core-tests"
		install -Dm755 "$consumer" "$out/bin/difz-core-consumer"
		runHook postInstall
	'';
}
