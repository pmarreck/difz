{ pkgs, oracle, zstdz, random }:
pkgs.rustPlatform.buildRustPackage {
	pname = "difz-rust-core-tests";
	version = "0.1.0";
	src = pkgs.lib.fileset.toSource {
		root = ./.;
		fileset = pkgs.lib.fileset.unions [ ./Cargo.toml ./Cargo.lock ./src ./zstdz ./consumer ];
	};
	cargoLock.lockFile = ./Cargo.lock;
	strictDeps = true;
	nativeBuildInputs = [ pkgs.jq pkgs.rust-bindgen pkgs.rustPlatform.bindgenHook ];
	nativeCheckInputs = [ pkgs.b3sum pkgs.gnugrep ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.binutils ];
	DIFZ_ZSTDZ_ROOT = zstdz;
	DIFZ_ORACLE = "${oracle}/bin/difz";
	B3SUM = "${pkgs.b3sum}/bin/b3sum";
	DIFZ_RANDOM = "${random}/bin/random";
	doCheck = true;
	buildPhase = ''
		runHook preBuild
		${pkgs.stdenv.cc}/bin/cc consumer/native_params.c -I${zstdz}/include ${zstdz}/lib/libzstd.a -pthread -o native-params
		./native-params > native-params.json
		export DIFZ_NATIVE_PARAMS="$PWD/native-params.json"
		printf '#define ZSTD_STATIC_LINKING_ONLY\n#include <zstd.h>\nenum { DIFZ_ZSTD_WINDOWLOG_MAX = ZSTD_WINDOWLOG_MAX };\n' > bindings.h
		bindgen bindings.h --use-core --no-layout-tests --formatter none \
			--allowlist-function 'ZSTD_(getCParams|isError|compressBound|createCCtx|freeCCtx|CCtx_setParameter|CCtx_refPrefix|compress2|createDCtx|freeDCtx|DCtx_setMaxWindowSize|DCtx_refPrefix|decompressDCtx)' \
			--allowlist-var 'ZSTD_(c_.*|btlazy2|WINDOWLOG_.*)|DIFZ_ZSTD_WINDOWLOG_MAX' --no-prepend-enum-name \
			-- -I${zstdz}/include > zstdz_bindings.rs
		export DIFZ_ZSTDZ_BINDINGS="$PWD/zstdz_bindings.rs"
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
		test "$test_count" -ge 11
		"$test_binary" --test-threads=1 --include-ignored
		"$consumer"
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
