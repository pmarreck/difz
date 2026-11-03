{ pkgs, oracle }:
pkgs.rustPlatform.buildRustPackage {
	pname = "difz-rust-core-tests";
	version = "0.1.0";
	src = pkgs.lib.fileset.toSource {
		root = ./.;
		fileset = pkgs.lib.fileset.unions [ ./Cargo.toml ./Cargo.lock ./src ];
	};
	cargoLock.lockFile = ./Cargo.lock;
	nativeBuildInputs = [ pkgs.jq ];
	nativeCheckInputs = [ pkgs.b3sum pkgs.gnugrep ];
	DIFZ_ORACLE = "${oracle}/bin/difz";
	B3SUM = "${pkgs.b3sum}/bin/b3sum";
	doCheck = true;
	buildPhase = ''
		runHook preBuild
		if ! cargo test --locked --offline --no-run --message-format=json > cargo-tests.json; then
			jq -r 'select(.reason == "compiler-message") | .message.rendered // empty' cargo-tests.json >&2
			exit 1
		fi
		test_binary=$(jq -er 'select(.reason == "compiler-artifact" and .profile.test == true and .executable != null) | .executable' cargo-tests.json)
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
		test "$test_count" -ge 6
		"$test_binary" --test-threads=1 --include-ignored
		runHook postCheck
	'';
	installPhase = ''
		runHook preInstall
		install -Dm755 "$test_binary" "$out/bin/difz-rust-core-tests"
		runHook postInstall
	'';
}
