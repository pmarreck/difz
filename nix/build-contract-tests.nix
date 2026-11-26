{ lib }:
let
	source = builtins.readFile ./build-targets.tsv;
	decode = source: selector: import ./build-contract.nix { inherit lib source selector; };
	valid = selector: builtins.deepSeq (decode source selector) true;
	rejected = source: selector: !(builtins.tryEval (builtins.deepSeq (decode source selector) true)).success;
	rows = builtins.filter (line: line != "" && !(lib.hasPrefix "#" line)) (lib.splitString "\n" source);
	invalidSelectors = [ "" " " "zig " " zig" "unknown" "zig\n\n" "zig\nrust" "zig\r\n" "$(touch must-not-execute)" ];
	invalidSources = [
		(lib.concatStringsSep "\n" (builtins.tail rows))
		(source + builtins.head rows + "\n")
		(builtins.replaceStrings [ "linux-amd64" ] [ "linux-wrong" ] source)
		(builtins.replaceStrings [ "zig\tc\t" ] [ "zig\trust\t" ] source)
		(builtins.replaceStrings [ "\tReleaseFast\t" ] [ "\tdebug\t" ] source)
		(builtins.replaceStrings [ "\tmusl\t" ] [ "\tgnu\t" ] source)
		(builtins.replaceStrings [ "\tmusl\t" ] [ "\t-\t" ] source)
		(builtins.replaceStrings [ "packages.x86_64-linux.zig-release" ] [ "packages.bad;command" ] source)
		(source + "not\tseven\tfields\n")
	];
	model = decode source (builtins.readFile ../CANONICAL_IMPL);
in
assert lib.all valid [ "zig" "zig\n" "rust" "rust\n" ];
assert lib.all (rejected source) invalidSelectors;
assert lib.all (data: rejected data "zig\n") invalidSources;
assert builtins.length model.rows == 20;
assert builtins.length (builtins.filter (row: row.output == null) model.rows) == 4;
assert lib.all (row: row.implementation != "zig" || row.output != null) model.rows;
assert builtins.attrNames model.implementations == [ "rust" "zig" ];
true
