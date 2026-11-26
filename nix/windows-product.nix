{ pkgs, source, zigDeps, buildStamp, arch ? "amd64", debug ? false }:
let
	compilerArch = { amd64 = "x86_64"; arm64 = "aarch64"; }.${arch};
	profile = if debug then "Debug" else "ReleaseFast";
	name = if arch == "amd64" && !debug then "difz-windows-gnu"
		else "difz-windows-${arch}-${if debug then "debug" else "release"}";
in pkgs.stdenv.mkDerivation {
	pname = name;
	version = "0.1.0";
	src = source;
	nativeBuildInputs = [ pkgs.zig pkgs.binutils pkgs.file ];
	dontConfigure = true;
	dontInstall = true;
	buildPhase = ''
		runHook preBuild
		export HOME=$TMPDIR
		export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
		mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
		cp -r ${zigDeps}/. "$ZIG_GLOBAL_CACHE_DIR/"
		chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR"
		zig build -Dcpu=baseline -Doptimize=${profile} -Dtarget=${compilerArch}-windows-gnu -Dbuild-revision=${buildStamp.revision} -Dbuild-dirty=${buildStamp.dirty} --prefix "$out"
		${buildStamp.install}
		test -x "$out/bin/difz.exe"
		test -s "$out/lib/libdifz.a"
		test -s "$out/include/difz.h"
		description=$(file -Lb "$out/bin/difz.exe")
		case "$description" in
			'PE32+ executable '*${if arch == "amd64" then "x86-64" else "Aarch64"}*) :;;
			*) printf 'FAIL Windows executable header: %s\n' "$description" >&2; exit 1;;
		esac
		if ! strings "$out/bin/difz.exe" | grep -q setmode; then
			printf 'FAIL Windows binary does not reference setmode\n' >&2; exit 1
		fi
		mkdir -p "$out/nix-support"
		printf '%s\n' '${compilerArch}-windows-gnu' > "$out/nix-support/compiler-target"
		printf '%s\n' '${profile}' > "$out/nix-support/build-profile"
		runHook postBuild
	'';
	passthru = { pf = "mswin-${arch}"; inherit profile; };
}
