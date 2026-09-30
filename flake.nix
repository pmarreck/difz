{
	description = "difz - a binary differ written in Zig";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
		flake-utils.url = "github:numtide/flake-utils";
		random = {
			url = "github:pmarreck/random/yolo";
			inputs.flake-utils.follows = "flake-utils";
		};
	};

	outputs = { self, nixpkgs, flake-utils, random }:
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
				zigDepsHash = "sha256-ff4k0ALUNVRkKt+HQs8NvawWse52nTv2Imn0pLzEIF0=";

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

				# Static (musl) zlib for the default Linux build: blar's deflate_emit.zig
				# needs zlib for PNG/ZIP even with image support off, and our binaries
				# link statically (static-iff-musl), so a static archive is required.
				zlibStatic = pkgs.pkgsStatic.zlib;
				zlibFlags = "-Dzlib-include-path=${zlibStatic.dev}/include -Dzlib-lib-path=${zlibStatic}/lib";
				mingwZlib = pkgs.pkgsCross.mingwW64.zlib;
				windowsZlibFlags = "-Dtarget=x86_64-windows-gnu -Dzlib-include-path=${mingwZlib.dev}/include -Dzlib-lib-path=${mingwZlib}/lib";

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

						zig build -Doptimize=${optimize} ${zlibFlags} --prefix $out
					'';

					doCheck = doCheck;
					checkPhase = ''
						export HOME=$TMPDIR
						errors=0
						if ! zig build test -Doptimize=${optimize} ${zlibFlags} 2>&1; then
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
							zig build -Doptimize=ReleaseFast ${windowsZlibFlags} --prefix $out
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
								bash coreutils file gnugrep gnused gawk time randomPackage
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
						zstd
						time
						file
						git
						randomPackage
					];
				};
			}
		);
}
