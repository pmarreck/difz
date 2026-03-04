{
	description = "difz - a binary differ written in Zig";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
		flake-utils.url = "github:numtide/flake-utils";
	};

	outputs = { self, nixpkgs, flake-utils }:
		flake-utils.lib.eachDefaultSystem (system:
			let
				pkgs = import nixpkgs { inherit system; };

				# Single hash for the entire Zig dependency tree.
				# To update: set to "" or pkgs.lib.fakeHash, run `nix build`,
				# copy the correct hash from the error message.
				zigDepsHash = "sha256-O2zLdF/gN3xcxt0pLDDhDapRUCHIBA50fW9wUZa7r8A=";

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

				zigBuild = { optimize ? "ReleaseFast", doCheck ? false }: pkgs.stdenv.mkDerivation {
					pname = "difz";
					version = "0.1.0";
					src = ./.;

					nativeBuildInputs = [ pkgs.zig ];

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
						zig build test -Doptimize=ReleaseFast 2>&1
					'';
				};
			in
			{
				packages.default = zigBuild {};

				checks = {
					build = zigBuild {};
					tests = zigBuild { doCheck = true; };
				};

				devShells.default = pkgs.mkShell {
					buildInputs = with pkgs; [
						zig
						hyperfine
						bsdiff
						xdelta
						zstd
					];
				};
			}
		);
}
