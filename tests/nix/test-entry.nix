{ pkgs }:
pkgs.runCommand "difz-test-entry-check" {
	src = pkgs.lib.fileset.toSource {
		root = ../..;
		fileset = pkgs.lib.fileset.unions [
			../../test ../../big_o ../../.mechatron-prime/targets ../integration/test-test-entry.bash
			../integration/test_prepared_runners.bash ../run-prepared-host
			../run-host-tests ../ffi/test_rust_lib.bash
		];
	};
	nativeBuildInputs = with pkgs; [ bash coreutils gnugrep jq ];
} ''
	export HOME="$TMPDIR/home"
	mkdir -p "$HOME"
	${pkgs.coreutils}/bin/timeout --kill-after=5s 60s bash "$src/tests/integration/test-test-entry.bash"
	${pkgs.coreutils}/bin/timeout --kill-after=5s 60s bash "$src/tests/integration/test_prepared_runners.bash"
	touch "$out"
''
