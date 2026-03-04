{
	description = "difz - a binary differ written in Zig";

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
		# BLIP depends on an older progrez (f338840); bzip2z depends on a newer one (377256d).
		# Both must be provided since Zig resolves packages by content hash.
		progrez-blip-src = {
			url = "github:pmarreck/progrez/f338840d063e05cb6f886e365a8ddb1ade4a2bcd";
			flake = false;
		};
		bzip2z-src = {
			url = "github:pmarreck/bzip2z/76d3ca8f35dad2c1393eb35d97332d5a8e9da2bb";
			flake = false;
		};
		lz4-src = {
			url = "github:pmarreck/lz4/675532cbcc0609ddfc44a6e13240902574579a25";
			flake = false;
		};
	};

	outputs = { self, nixpkgs, flake-utils, blip-src, z7z-src, printable-binary-src, progrez-src, progrez-blip-src, bzip2z-src, lz4-src }:
		flake-utils.lib.eachDefaultSystem (system:
			let
				pkgs = import nixpkgs { inherit system; };
				# Zig package hashes — must match build.zig.zon dep chains
				blipHash = "blip-0.1.0-rcNuGDPUCwDSRBBRestQfjkD4DFXTGMr7qAOmZsnuKsl";
				z7zHash = "z7z-0.1.0-rkKuF0UdBQDsZxiiNFWuuoHVeGLFO078oGD6yQQiSXoA";
				pbHash = "printable_binary-1.0.0-SdPiyoM4FwByo5ia901HzoUGSGjeolkmQuxJ5UYZzdW1";
				progrezHash = "progrez-0.1.0-0YJXrl0CAgCI-gvYCSEWEnW2rsWMTPbehyOnOveB4EJp";
				progrezBlipHash = "progrez-0.1.0-0YJXrt4AAgAa3oScbj1pXFwos1rhFzR50M6sQSJBmZHg";
				bzip2zHash = "bzip2z-0.1.0-m5NdlvkqAwCEafj8KkeEu4fIXSTRp-sKQewGM28tYrcr";
				lz4Hash = "lz4-1.10.0-TtaqjVLWBwDiQxASdpBmT-44zoqcVnVkA9kQGAonGWDf";
			in
			let
				zigBuild = { optimize ? "ReleaseFast", doCheck ? false }: pkgs.stdenv.mkDerivation {
					pname = "difz";
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
						mkdir -p "$TMPDIR/zig-pkgs/${progrezBlipHash}"
						cp -r ${progrez-blip-src}/* "$TMPDIR/zig-pkgs/${progrezBlipHash}/"
						mkdir -p "$TMPDIR/zig-pkgs/${bzip2zHash}"
						cp -r ${bzip2z-src}/* "$TMPDIR/zig-pkgs/${bzip2zHash}/"
						mkdir -p "$TMPDIR/zig-pkgs/${lz4Hash}"
						cp -r ${lz4-src}/* "$TMPDIR/zig-pkgs/${lz4Hash}/"

						zig build -Doptimize=${optimize} --system "$TMPDIR/zig-pkgs" --prefix $out
					'';

					doCheck = doCheck;
					checkPhase = ''
						export XDG_CACHE_HOME="$TMPDIR/zig-cache"
						zig build test -Doptimize=ReleaseFast --system "$TMPDIR/zig-pkgs" 2>&1
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
