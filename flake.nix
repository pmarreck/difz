{
	description = "zdiff - a binary differ written in Zig";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
		flake-utils.url = "github:numtide/flake-utils";
		blip-src = {
			url = "github:pmarreck/BLIP/yolo";
			flake = false;
		};
		z7z-src = {
			url = "github:pmarreck/z7z/18e094eab1cb545c86a6b6e72cc9c48db3539ddd";
			flake = false;
		};
		printable-binary-src = {
			url = "github:pmarreck/printable-binary/yolo";
			flake = false;
		};
		progrez-src = {
			url = "github:pmarreck/progrez/yolo";
			flake = false;
		};
	};

	outputs = { self, nixpkgs, flake-utils, blip-src, z7z-src, printable-binary-src, progrez-src }:
		flake-utils.lib.eachDefaultSystem (system:
			let
				pkgs = import nixpkgs { inherit system; };
				# Zig package hashes — must match build.zig.zon dep chains
				blipHash = "blip-0.1.0-rcNuGD64CQDEBryxAj93lMCAMkFO0IpknB0MwWnjrGas";
				z7zHash = "z7z-0.1.0-rkKuF0UdBQDsZxiiNFWuuoHVeGLFO078oGD6yQQiSXoA";
				pbHash = "printable_binary-1.0.0-SdPiyoM4FwByo5ia901HzoUGSGjeolkmQuxJ5UYZzdW1";
				progrezHash = "progrez-0.1.0-0YJXrvO-AQBZNa3mhSjZ4Wc_QVnCMBdqTiT2KxVEpQUH";
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

						# Create a system package directory with all transitive deps
						# so Zig doesn't need network access (Nix sandbox blocks it)
						mkdir -p "$TMPDIR/zig-pkgs/${blipHash}"
						cp -r ${blip-src}/* "$TMPDIR/zig-pkgs/${blipHash}/"
						mkdir -p "$TMPDIR/zig-pkgs/${z7zHash}"
						cp -r ${z7z-src}/* "$TMPDIR/zig-pkgs/${z7zHash}/"
						mkdir -p "$TMPDIR/zig-pkgs/${pbHash}"
						cp -r ${printable-binary-src}/* "$TMPDIR/zig-pkgs/${pbHash}/"
						mkdir -p "$TMPDIR/zig-pkgs/${progrezHash}"
						cp -r ${progrez-src}/* "$TMPDIR/zig-pkgs/${progrezHash}/"

						zig build -Doptimize=${optimize} --system "$TMPDIR/zig-pkgs" --prefix $out
					'';

					doCheck = doCheck;
					checkPhase = ''
						export XDG_CACHE_HOME="$TMPDIR/zig-cache"
						zig build test --system "$TMPDIR/zig-pkgs" 2>&1
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
