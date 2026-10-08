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

				# Single hash for the entire Zig dependency tree.
				# To update: set to "" or pkgs.lib.fakeHash, run `nix build`,
				# copy the correct hash from the error message.
				zigDepsHash = "sha256-hCvMZ21yHfazNLfJnlLRa9nh8VnrRcY0qah6++FAPwM=";

				zigDeps = pkgs.stdenv.mkDerivation {
					pname = "difz-zig-deps";
					version = "0.1.0";
					src = ./.;
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
					src = ./.;

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
					if ! DIFZ="$out/bin/difz" DIFZ_PREBUILT=1 bash tests/cli/test_cli.bash; then
						errors=$((errors + 1))
					fi
					if ! DIFZ_PREFIX="$out" bash tests/ffi/test_installed_lib.bash; then
						errors=$((errors + 1))
					fi
					exit "$errors"
				'';
			};

			releaseFast = zigBuild {};
		in
			{
				packages.default = releaseFast;
				packages.zstd-benchmark = zstdBenchmark;

				checks = {
					build = releaseFast;
					test = zigBuild { optimize = "Debug"; doCheck = true; };
					windows-gnu = pkgs.stdenv.mkDerivation {
						pname = "difz-windows-gnu";
						version = "0.1.0";
						src = ./.;
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
								bash coreutils file gnugrep gnused gawk time jq hyperfine randomPackage zstdBenchmark
							];
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
						hyperfine
						bsdiff
						xdelta
						zstdBenchmark
						time
						file
						git
						jq
						performance-profiling.packages.${system}.default
						randomPackage
					];
				};
			}
		);
}
