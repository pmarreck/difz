{
	description = "zdiff - a binary differ written in Zig";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
		flake-utils.url = "github:numtide/flake-utils";
	};

	outputs = { self, nixpkgs, flake-utils }:
		flake-utils.lib.eachDefaultSystem (system:
			let
				pkgs = import nixpkgs { inherit system; };
			in
			let
				zigBuild = { optimize ? "ReleaseFast", doCheck ? false }: pkgs.stdenv.mkDerivation {
					pname = "zdiff";
					version = "0.1.0";
					src = ./.;

					nativeBuildInputs = [ pkgs.zig ];

					dontConfigure = true;
					dontInstall = true;

					buildPhase = ''
						export XDG_CACHE_HOME="$TMPDIR/zig-cache"
						mkdir -p "$XDG_CACHE_HOME"
						zig build -Doptimize=${optimize} --prefix $out
					'';

					doCheck = doCheck;
					checkPhase = ''
						export XDG_CACHE_HOME="$TMPDIR/zig-cache"
						zig build test 2>&1
					'';
				};
			in
			{
				packages.default = zigBuild {};

				checks = {
					build = zigBuild {};
					tests = zigBuild { optimize = "Debug"; doCheck = true; };
				};

				devShells.default = pkgs.mkShell {
					buildInputs = with pkgs; [
						zig
						hyperfine
						bsdiff
						xdelta
					];
				};
			}
		);
}
