{
	description = "difz - a binary differ written in Zig";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
		flake-utils.url = "github:numtide/flake-utils";
		performance-profiling.url = "github:pmarreck/performance_profiling/a04d62a441a5b9315e81f6277f57f7eddb9a57af";
		random = {
			url = "github:pmarreck/random/yolo";
			inputs.flake-utils.follows = "flake-utils";
		};
	};

	outputs = { self, nixpkgs, flake-utils, random, performance-profiling }:
		flake-utils.lib.eachSystem [
			"x86_64-linux"
			"aarch64-linux"
			"aarch64-darwin"
		] (system:
			let
				pkgs = import nixpkgs { inherit system; };
				randomPackage = random.packages.${system}.random-luajit;
				# Local Unix-only fix until the shared profiler supports long cases
				# and kills the workload's children when its deadline expires.
				performancePackage = performance-profiling.packages.${system}.default.overrideAttrs (old: {
					patches = (old.patches or []) ++ [ ./nix/performance-profile-timeout.patch ];
				});
				zigSource = pkgs.lib.fileset.toSource {
					root = ./.;
					fileset = pkgs.lib.fileset.unions [
						./build.zig
						./build.zig.zon
						./src
						./scripts/flatten-static-lib
						./tests/cli
						./tests/ffi
					];
				};

				# Single hash for the entire Zig dependency tree.
				# To update: set to "" or pkgs.lib.fakeHash, run `nix build`,
				# copy the correct hash from the error message.
				zigDepsHash = "sha256-hCvMZ21yHfazNLfJnlLRa9nh8VnrRcY0qah6++FAPwM=";

				zigDeps = pkgs.stdenv.mkDerivation {
					pname = "difz-zig-deps";
					version = "0.1.0";
					src = zigSource;
					nativeBuildInputs = with pkgs; [ zig git cacert ];
					outputHashMode = "recursive";
					outputHashAlgo = "sha256";
					outputHash = zigDepsHash;
					buildPhase = ''
						export HOME=$TMPDIR
						export ZIG_GLOBAL_CACHE_DIR=$out
						export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
						export GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
						zig build --fetch=all
					'';
					dontInstall = true;
					dontFixup = true;
				};

				# Zig's package omits programs/. Fetch the complete archive from
				# the library's authoritative URL instead of using nixpkgs zstd.
				zstdPin = builtins.elemAt (pkgs.lib.splitString ".zstdz = .{"
					(builtins.readFile ./build.zig.zon)) 1;
				zstdUrl = builtins.elemAt (pkgs.lib.splitString "\"" zstdPin) 1;
				zstdBenchmark = pkgs.stdenv.mkDerivation {
					pname = "zstd";
					version = "1.6.0-zstdz";
					src = pkgs.fetchzip {
						url = zstdUrl;
						hash = "sha256-+EADC0wwFqkD/QpXYkPOxoZBTTCrRzmIfua8HKZb8s8=";
					};
					strictDeps = true;
					dontConfigure = true;
					enableParallelBuilding = true;
					makeFlags = [ "-C" "programs" "zstd" "ZSTD_LEGACY_SUPPORT=0"
						"HAVE_ZLIB=0" "HAVE_LZMA=0" "HAVE_LZ4=0" ];
					installPhase = ''
						runHook preInstall
						install -Dm755 programs/zstd $out/bin/zstd
						runHook postInstall
					'';
				};

				zigBuild = { optimize ? "ReleaseFast", doCheck ? false }: pkgs.stdenv.mkDerivation {
					pname = "difz";
					version = "0.1.0";
					src = zigSource;

					nativeBuildInputs = [ pkgs.zig ];
				nativeCheckInputs = with pkgs; [ bash coreutils diffutils gnugrep gcc binutils ];

					dontConfigure = true;
					dontInstall = true;

					buildPhase = ''
						export HOME=$TMPDIR
						export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
						mkdir -p $ZIG_GLOBAL_CACHE_DIR
						cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
						chmod -R u+w $ZIG_GLOBAL_CACHE_DIR

						zig build -Doptimize=${optimize} --prefix $out
					'';

					doCheck = doCheck;
					checkPhase = ''
						export HOME=$TMPDIR
						errors=0
						if ! zig build test -Doptimize=${optimize} 2>&1; then
							errors=$((errors + 1))
						fi
					# The sandbox can prohibit xattr writes needed for Linux birth time.
					# ./test requires the default metadata path through the host CLI too.
					if ! DIFZ="$out/bin/difz" DIFZ_PREBUILT=1 DIFZ_TEST_DIRECTORY_OMIT=timestamps bash tests/cli/test_cli.bash; then
						errors=$((errors + 1))
					fi
					if ! DIFZ_PREFIX="$out" bash tests/ffi/test_installed_lib.bash; then
						errors=$((errors + 1))
					fi
					exit "$errors"
				'';
			};

			releaseFast = zigBuild {};
				rustCodecTests = pkgs.rustPlatform.buildRustPackage {
					pname = "difz-rust-codec-tests";
					version = "0.0.0";
					src = pkgs.lib.fileset.toSource {
						root = ./tests/codec_rust;
						fileset = pkgs.lib.fileset.unions [
							./tests/codec_rust/Cargo.toml
							./tests/codec_rust/Cargo.lock
							./tests/codec_rust/interop.rs
						];
					};
					cargoLock.lockFile = ./tests/codec_rust/Cargo.lock;
					strictDeps = true;
					nativeBuildInputs = [ pkgs.jq ];
					doCheck = false;
					buildPhase = ''
						runHook preBuild
						CC=false CXX=false AR=false cargo test --locked --offline --release \
							--lib --no-run --message-format=json > cargo-artifacts.json
						runHook postBuild
					'';
					installPhase = ''
						runHook preInstall
						executable=$(jq -er 'select(.reason == "compiler-artifact" and .profile.test == true and .executable != null) | .executable' cargo-artifacts.json)
						test -f "$executable"
						install -Dm755 "$executable" "$out/bin/difz-codec-check"
						runHook postInstall
					'';
				};
		in
			{
				packages.default = releaseFast;
				packages.zstd-benchmark = zstdBenchmark;
				packages.performance-benchmark = performancePackage;
				packages.rust-codec-tests = rustCodecTests;

				checks = {
					build = releaseFast;
					test = zigBuild { optimize = "Debug"; doCheck = true; };
					rust-codec = pkgs.runCommand "difz-rust-codec-check" {
						nativeBuildInputs = with pkgs; [ bash coreutils diffutils ];
					} ''
						export HOME="$TMPDIR/home"
						mkdir -p "$HOME"
						bash ${./tests/codec_rust}/test_runner.bash
						DIFZ_ORACLE=${releaseFast}/bin/difz \
							ZSTD_CLI=${zstdBenchmark}/bin/zstd \
							DIFZ_CODEC_TEST=${rustCodecTests}/bin/difz-codec-check \
							bash ${./tests/codec_rust}/test --test-threads=1
						touch "$out"
					'';
					windows-gnu = pkgs.stdenv.mkDerivation {
						pname = "difz-windows-gnu";
						version = "0.1.0";
						src = zigSource;
						nativeBuildInputs = [ pkgs.zig pkgs.binutils ];
						dontConfigure = true;
						dontInstall = true;
						buildPhase = ''
							export HOME=$TMPDIR
							export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
							mkdir -p $ZIG_GLOBAL_CACHE_DIR
							cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
							chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
							zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu --prefix $out
							test -f $out/bin/difz.exe
							if ! strings "$out/bin/difz.exe" | grep -q setmode; then
								echo "FAIL: Windows binary does not reference setmode" >&2
								exit 1
							fi
						'';
					};
					benchmark-contract = pkgs.runCommand "difz-benchmark-contract"
						{
							nativeBuildInputs = with pkgs; [
								bash coreutils file gnugrep gnused gawk time jq hyperfine luajit randomPackage zstdBenchmark
							];
							PERFORMANCE_PROCESS_MODULE = "${performancePackage}/share/performance-profile/src/process.lua";
						} ''
							cp -r ${./.} work
							chmod -R u+w work
							cd work
							DIFZ=${releaseFast}/bin/difz \
								RANDOM_BIN=${randomPackage}/bin/random \
								GNU_TIME_BIN=${pkgs.time}/bin/time \
								bash tests/benchmark/test_bm.bash
							touch $out
						'';
				};

				devShells.default = pkgs.mkShell {
					packages = with pkgs; [
						zig
						rustc
						cargo
						rustfmt
						hyperfine
						bsdiff
						xdelta
						zstdBenchmark
						time
						file
						git
						jq
						luajit
						performancePackage
						randomPackage
					];
					PERFORMANCE_PROCESS_MODULE = "${performancePackage}/share/performance-profile/src/process.lua";
				};
			}
		);
}
