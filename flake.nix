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
				profilingLua = pkgs.luajit.withPackages (p: [ p.lua-cjson p.luv ]);
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
				benchmarkSource = pkgs.lib.fileset.toSource {
					root = ./.;
					fileset = pkgs.lib.fileset.unions [ ./bm ./profiling.json ./README.md ./tests/benchmark ];
				};
				crossApplySource = pkgs.lib.fileset.toSource {
					root = ./.;
					fileset = pkgs.lib.fileset.unions [
						./tests/acceptance/cross-apply
						./tests/integration/test-cross-apply.bash
					];
				};
				buildWrapperSource = pkgs.lib.fileset.toSource {
					root = ./.;
					fileset = pkgs.lib.fileset.unions [ ./build ./tests/integration/test-build-wrapper.bash ];
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
					postBuild = ''
						make -C lib libzstd.a ZSTD_LEGACY_SUPPORT=0 CPPFLAGS_STATICLIB=-DZSTD_MULTITHREAD
					'';
					installPhase = ''
						runHook preInstall
						install -Dm755 programs/zstd $out/bin/zstd
						install -Dm644 lib/libzstd.a $out/lib/libzstd.a
						install -Dm644 lib/zstd.h $out/include/zstd.h
						install -Dm644 lib/zstd_errors.h $out/include/zstd_errors.h
						runHook postInstall
					'';
				};

				zigBuild = { optimize ? "ReleaseFast", doCheck ? false, prepareTests ? false }: pkgs.stdenv.mkDerivation {
					pname = "difz";
					version = "0.1.0";
					src = zigSource;

					nativeBuildInputs = [ pkgs.zig ];
				nativeCheckInputs = with pkgs; [ bash coreutils diffutils gnugrep gcc binutils ]
					++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.util-linux ];

					dontConfigure = true;
					dontInstall = true;

					buildPhase = ''
						export HOME=$TMPDIR
						export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
						mkdir -p $ZIG_GLOBAL_CACHE_DIR
						cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
						chmod -R u+w $ZIG_GLOBAL_CACHE_DIR

						zig build ${pkgs.lib.optionalString prepareTests "test-artifacts"} -Doptimize=${optimize} --prefix $out
					'';

					doCheck = doCheck;
					checkPhase = ''
						export HOME=$TMPDIR
						errors=0
						if ! ${if prepareTests then "$out/libexec/difz-unit-tests" else "zig build test -Doptimize=${optimize}"} 2>&1; then
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
				debugTests = zigBuild { optimize = "Debug"; doCheck = true; prepareTests = true; };
				rustFfiTests = pkgs.stdenv.mkDerivation {
					pname = "difz-rust-ffi-tests";
					version = "0.0.0";
					src = zigSource;
					nativeBuildInputs = with pkgs; [ zig rustc binutils ];
					dontConfigure = true;
					buildPhase = ''
						runHook preBuild
						export HOME="$TMPDIR/home"
						export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
						mkdir -p "$HOME" "$ZIG_GLOBAL_CACHE_DIR"
						cp -r ${zigDeps}/* "$ZIG_GLOBAL_CACHE_DIR/"
						chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR"
						zig build lib -Dtarget=${if pkgs.stdenv.hostPlatform.isDarwin then "aarch64-macos" else if pkgs.stdenv.hostPlatform.isAarch64 then "aarch64-linux-gnu" else "x86_64-linux-gnu"} \
							-Doptimize=Debug --prefix "$TMPDIR/ffi"
						test -f "$TMPDIR/ffi/lib/libdifz.a"
						test -f "$TMPDIR/ffi/include/difz.h"
						test ! -e "$TMPDIR/ffi/bin/difz"
						rustc --edition=2024 tests/ffi/rust_caller.rs -L "native=$TMPDIR/ffi/lib" \
							${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux "-C link-arg=-no-pie -C link-arg=-lubsan"} -o rust-caller
						runHook postBuild
					'';
					installPhase = ''
						install -Dm755 rust-caller "$out/bin/difz-rust-caller"
					'';
				};
				hostTests = pkgs.symlinkJoin {
					name = "difz-host-tests";
					paths = [ debugTests rustFfiTests rustCoreTests ];
				};
				rustCodecTests = pkgs.rustPlatform.buildRustPackage {
					pname = "difz-rust-codec-tests";
					version = "0.0.0";
					src = pkgs.lib.fileset.toSource {
						root = ./tests/codec_rust;
						fileset = pkgs.lib.fileset.unions [
							./tests/codec_rust/Cargo.toml
							./tests/codec_rust/Cargo.lock
							./tests/codec_rust/interop.rs
							./tests/codec_rust/codecs.rs
							./tests/codec_rust/probe.rs
							./tests/codec_rust/parallel.rs
						];
					};
					cargoLock.lockFile = ./tests/codec_rust/Cargo.lock;
					strictDeps = true;
					nativeBuildInputs = [ pkgs.jq pkgs.rust-bindgen pkgs.rustPlatform.bindgenHook ];
					doCheck = false;
					buildPhase = ''
						runHook preBuild
						printf '#include <zstd.h>\n#include <time.h>\n' > probe_bindings.h
						bindgen probe_bindings.h \
							--allowlist-function 'ZSTD_(getCParams|isError|compressBound|createCCtx|freeCCtx|CCtx_setParameter|CCtx_refPrefix|compress2|createDCtx|freeDCtx|DCtx_setMaxWindowSize|DCtx_refPrefix|decompressDCtx|findFrameCompressedSize|getFrameContentSize)|clock_gettime' \
							--allowlist-var 'ZSTD_(c_.*|btlazy2|CONTENTSIZE_.*)|CLOCK_PROCESS_CPUTIME_ID' \
							--no-prepend-enum-name --no-layout-tests --formatter none \
							-- -I${zstdBenchmark}/include -DZSTD_STATIC_LINKING_ONLY > zstd_bindings.rs
						export DIFZ_ZSTD_BINDINGS="$PWD/zstd_bindings.rs"
						CC=false CXX=false AR=false cargo test --locked --offline --release \
							--lib --no-run --message-format=json > cargo-artifacts.json
						CC=false CXX=false AR=false cargo rustc --locked --offline --release \
							--bin difz-codec-probe --message-format=json -- \
							-L native=${zstdBenchmark}/lib -C link-arg=-pthread > probe-artifacts.json
						runHook postBuild
					'';
					installPhase = ''
						runHook preInstall
						executable=$(jq -er 'select(.reason == "compiler-artifact" and .profile.test == true and .executable != null) | .executable' cargo-artifacts.json)
						test -f "$executable"
						install -Dm755 "$executable" "$out/bin/difz-codec-check"
						probe=$(jq -er 'select(.reason == "compiler-artifact" and .target.name == "difz-codec-probe" and .executable != null) | .executable' probe-artifacts.json)
						install -Dm755 "$probe" "$out/bin/difz-codec-probe"
						runHook postInstall
					'';
				};
				pcre2Reference = pkgs.stdenv.mkDerivation {
					pname = "difz-pcre2-reference";
					version = "0.1.0";
					src = zigSource;
					nativeBuildInputs = [ pkgs.zig ];
					dontConfigure = true;
					dontInstall = true;
					buildPhase = ''
						export HOME="$TMPDIR/home" ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
						mkdir -p "$HOME" "$ZIG_GLOBAL_CACHE_DIR"
						cp -r ${zigDeps}/. "$ZIG_GLOBAL_CACHE_DIR/"
						chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR"
						zig build pcre2-reference -Dtarget=${if pkgs.stdenv.hostPlatform.isDarwin then "aarch64-macos" else if pkgs.stdenv.hostPlatform.isAarch64 then "aarch64-linux-gnu" else "x86_64-linux-gnu"} \
							-Doptimize=ReleaseFast --prefix "$out"
					'';
				};
				metadataOracle = import ./tests/rust_oracle/default.nix {
					inherit pkgs;
					xattrNames = let
						pin = builtins.elemAt (pkgs.lib.splitString ".xattr_stream = .{" (builtins.readFile ./build.zig.zon)) 1;
						hash = builtins.elemAt (pkgs.lib.splitString "\"" (builtins.elemAt (pkgs.lib.splitString ".hash = " pin) 1)) 1;
					in { archive = "${zigDeps}/p/${hash}.tar.gz"; member = "${hash}/src/names.zig"; };
					metadataSource = ./src/metadata.zig;
					directorySource = ./src/directory.zig;
					patchSources = [ ./src/directory_patch.zig ./src/symlink_transport.zig ./src/native_acl.zig ./src/path_filter.zig ./src/glob.zig ./src/pcre2.zig ./src/zstd_patch.zig ./src/patch.zig ];
					zstdz = zstdBenchmark;
					pcre2 = pcre2Reference;
				};
				rustZstdzSdk = import ./rust/zstdz-sdk.nix { inherit pkgs; zstdz = zstdBenchmark; };
				rustCoreTests = import ./rust/qa.nix { inherit pkgs metadataOracle; oracle = releaseFast; zstdz = zstdBenchmark; sdk = rustZstdzSdk; random = randomPackage; };
		in
			{
				packages.default = releaseFast;
				packages.debug = debugTests;
				packages.zstd-benchmark = zstdBenchmark;
				packages.performance-benchmark = performancePackage;
				packages.rust-codec-tests = rustCodecTests;
				packages.rust-core-tests = rustCoreTests;
				packages.rust-zstdz-sdk = rustZstdzSdk;
				packages.host-tests = hostTests;

				checks = {
					build = releaseFast;
					test = debugTests;
					rust-core = rustCoreTests;
					build-wrapper = pkgs.runCommand "difz-build-wrapper-check" {
						src = buildWrapperSource;
						nativeBuildInputs = with pkgs; [ bash coreutils gnugrep ];
					} ''
						cp -R "$src/." .
						chmod -R u+w .
						export HOME="$TMPDIR/home"
						mkdir -p "$HOME"
						bash tests/integration/test-build-wrapper.bash
						touch "$out"
					'';
					cross-apply = pkgs.runCommand "difz-cross-apply-check" {
						src = crossApplySource;
						nativeBuildInputs = with pkgs; [ bash coreutils diffutils findutils gnugrep ];
					} ''
						export HOME="$TMPDIR/home"
						mkdir -p "$HOME"
						cp -r "$src" work
						chmod -R u+w work
						patchShebangs work
						cd work
						DIFZ=${releaseFast}/bin/difz bash tests/integration/test-cross-apply.bash
						touch "$out"
					'';
					rust-ffi = pkgs.runCommand "difz-rust-ffi-check" {
						nativeBuildInputs = with pkgs; [ bash coreutils binutils ];
					} ''
						DIFZ_RUST_CALLER=${rustFfiTests}/bin/difz-rust-caller bash ${./tests/ffi}/test_rust_lib.bash
						touch "$out"
					'';
					rust-codec = pkgs.runCommand "difz-rust-codec-check" {
						nativeBuildInputs = with pkgs; [ bash coreutils diffutils jq luajit ];
					} ''
						export HOME="$TMPDIR/home"
						mkdir -p "$HOME"
						bash ${./tests/codec_rust}/test_runner.bash
						DIFZ_ORACLE=${releaseFast}/bin/difz \
							ZSTD_CLI=${zstdBenchmark}/bin/zstd \
							DIFZ_CODEC_TEST=${rustCodecTests}/bin/difz-codec-check \
							bash ${./tests/codec_rust}/test --test-threads=1
						DIFZ_CODEC_PROBE=${rustCodecTests}/bin/difz-codec-probe \
							DIFZ_SPLIT_ZSTD=${./tests/benchmark/parallel_apply/split_zstd.lua} \
							ZSTD_CLI=${zstdBenchmark}/bin/zstd \
							bash ${./tests/codec_rust}/test_probe.bash
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
							src = benchmarkSource;
							nativeBuildInputs = with pkgs; [
								bash coreutils file gnugrep gnused gawk time jq hyperfine luajit randomPackage zstdBenchmark
							];
							PERFORMANCE_PROCESS_MODULE = "${performancePackage}/share/performance-profile/src/process.lua";
						} ''
							cp -r "$src" work
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
						bash coreutils diffutils findutils gnugrep gnused gawk binutils
						zig
						rustc
						cargo
						rustfmt
						hyperfine
						bsdiff
						xdelta
						zstdBenchmark
						rustZstdzSdk
						time
						file
						git
						jq
						profilingLua
						performancePackage
						randomPackage
					] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.bubblewrap pkgs.util-linux ];
					PERFORMANCE_PROCESS_MODULE = "${performancePackage}/share/performance-profile/src/process.lua";
				};
			}
		);
}
