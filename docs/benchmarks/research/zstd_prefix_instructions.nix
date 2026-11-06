{ source }:
let
  flake = builtins.getFlake ("path:" + source);
  system = builtins.currentSystem;
  pkgs = flake.inputs.nixpkgs.legacyPackages.${system};
  zstdz = builtins.head (builtins.filter (x: (x.pname or "") == "zstd") flake.devShells.${system}.default.nativeBuildInputs);
  random = flake.inputs.random.packages.${system}.random-luajit;
in pkgs.stdenv.mkDerivation {
  pname = "difz-zstd-seeded-instruction-diagnostic";
  version = "0";
  dontUnpack = true;
  strictDeps = true;
  nativeBuildInputs = [ pkgs.valgrind ];
  buildInputs = [ pkgs.valgrind.dev ];
  buildPhase = ''
    $CC -O2 -DZSTD_MULTITHREAD -I${zstdz.src}/lib -I${zstdz.src}/lib/compress \
      ${./zstd_prefix_instructions.c} ${zstdz}/lib/libzstd.a -pthread -o diagnostic
  '';
  doCheck = true;
  checkPhase = ''
    ${random}/bin/random --seed 41 -b -c 8388608 > source.bin
    valgrind --tool=callgrind --instr-atstart=no --callgrind-out-file=counts ./diagnostic source.bin > parameters.ndjson
  '';
  installPhase = ''
    install -Dm755 diagnostic "$out/bin/diagnostic"
    install -Dm644 parameters.ndjson "$out/parameters.ndjson"
    mkdir -p "$out/counts"
    find . -maxdepth 1 -type f -name 'counts*' -exec cp -t "$out/counts" '{}' +
  '';
}
