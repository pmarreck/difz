{ pkgs, zstdz }:
let
	target = pkgs.stdenv.hostPlatform.rust.rustcTarget;
in pkgs.stdenv.mkDerivation {
	pname = "difz-zstdz-sdk";
	version = "0.1.0";
	src = pkgs.lib.fileset.toSource { root = ./.; fileset = ./zstdz-sdk-setup-hook.sh; };
	strictDeps = true;
	nativeBuildInputs = [ pkgs.rust-bindgen pkgs.rustPlatform.bindgenHook ];
	dontConfigure = true;
	buildPhase = ''
		runHook preBuild
		printf '#define ZSTD_STATIC_LINKING_ONLY\n#include <zstd.h>\nenum { DIFZ_ZSTD_WINDOWLOG_MAX = ZSTD_WINDOWLOG_MAX };\n' > bindings.h
		bindgen bindings.h --use-core --no-layout-tests --formatter none \
			--allowlist-function 'ZSTD_(getCParams|isError|compressBound|createCCtx|freeCCtx|CCtx_setParameter|CCtx_refPrefix|compress2|createDCtx|freeDCtx|DCtx_setMaxWindowSize|DCtx_refPrefix|decompressDCtx)' \
			--allowlist-var 'ZSTD_(c_.*|btlazy2|WINDOWLOG_.*)|DIFZ_ZSTD_WINDOWLOG_MAX' --no-prepend-enum-name \
			-- -I${zstdz}/include --target=${target} > bindings.rs
		runHook postBuild
	'';
	installPhase = ''
		runHook preInstall
		mkdir -p "$out/nix-support" "$out/share/difz-zstdz"
		ln -s ${zstdz}/lib "$out/lib"
		ln -s ${zstdz}/include "$out/include"
		install -m644 bindings.rs "$out/share/difz-zstdz/bindings.rs"
		printf '%s\n' '${target}' > "$out/nix-support/rust-target"
		substitute zstdz-sdk-setup-hook.sh "$out/nix-support/setup-hook" --subst-var-by sdk "$out"
		runHook postInstall
	'';
	passthru.rustTarget = target;
}
