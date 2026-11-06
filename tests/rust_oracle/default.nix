{ pkgs, metadataSource }:
pkgs.stdenv.mkDerivation {
    pname = "difz-metadata-reference";
    version = "0.1.0";
    src = pkgs.lib.fileset.toSource {
        root = ./.;
        fileset = pkgs.lib.fileset.unions [ ./metadata.zig ./main.c ];
    };
    nativeBuildInputs = [ pkgs.zig ];
    dontConfigure = true;
    buildPhase = ''
        runHook preBuild
        export HOME="$TMPDIR/home" ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
        mkdir -p "$HOME" "$ZIG_GLOBAL_CACHE_DIR"
        zig build-lib -O ReleaseSafe -fPIC -fcompiler-rt -mcpu=baseline -lc \
            --dep metadata -Mroot=metadata.zig -Mmetadata=${metadataSource} -femit-bin=metadata.a
        $CC main.c metadata.a ${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux "-lubsan"} -o metadata-oracle
        runHook postBuild
    '';
    installPhase = ''
        runHook preInstall
        install -Dm755 metadata-oracle "$out/bin/difz-metadata-oracle"
        runHook postInstall
    '';
}
