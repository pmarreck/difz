{ pkgs, metadataSource, directorySource, patchSources, zstdz }:
pkgs.stdenv.mkDerivation {
    pname = "difz-metadata-reference";
    version = "0.1.0";
    src = pkgs.lib.fileset.toSource {
        root = ./.;
        fileset = pkgs.lib.fileset.unions [ ./metadata.zig ./metadata_fixture.zig ./restore.zig ./directory.zig ./snapshot_fixture.zig ./tree_patch.zig ./reference.zig ./main.c ];
    };
    nativeBuildInputs = [ pkgs.zig ];
    buildInputs = [ pkgs.pcre2 ];
    dontConfigure = true;
    buildPhase = ''
        runHook preBuild
        export HOME="$TMPDIR/home" ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
        mkdir -p "$HOME" "$ZIG_GLOBAL_CACHE_DIR"
        mkdir reference
        cp ${metadataSource} reference/metadata.zig
        cp ${directorySource} reference/directory.zig
        ${pkgs.lib.concatMapStringsSep "\n" (source: "cp ${pkgs.lib.escapeShellArg "${source}"} reference/${builtins.baseNameOf source}") patchSources}
        cp reference.zig reference/reference.zig
        zig build-lib -O ReleaseSafe -fPIC -fcompiler-rt -mcpu=baseline -lc \
            --dep reference -Mroot=metadata.zig -I${pkgs.lib.getDev pkgs.pcre2}/include -I${zstdz}/include \
            -Mreference=reference/reference.zig -femit-bin=metadata.a
        $CC main.c metadata.a ${zstdz}/lib/libzstd.a -lpcre2-8 -pthread ${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux "-lubsan"} -o metadata-oracle
        runHook postBuild
    '';
    installPhase = ''
        runHook preInstall
        install -Dm755 metadata-oracle "$out/bin/difz-metadata-oracle"
        runHook postInstall
    '';
}
