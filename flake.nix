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
			{
				packages.default = pkgs.stdenv.mkDerivation {
					pname = "zdiff";
					version = "0.1.0";
					src = ./.;

					nativeBuildInputs = [ pkgs.zig ];

					dontConfigure = true;
					dontInstall = true;

					buildPhase = ''
						export XDG_CACHE_HOME="$TMPDIR/zig-cache"
						mkdir -p "$XDG_CACHE_HOME"
						zig build -Doptimize=ReleaseFast --prefix $out
					'';
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
