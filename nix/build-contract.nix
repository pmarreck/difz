{ lib, source, selector }:
let
	implementations = {
		zig = { frontend = "c"; profiles = { release = "ReleaseFast"; debug = "Debug"; }; };
		rust = { frontend = "rust"; profiles = { release = "release"; debug = "debug"; }; };
	};
	platforms = [ "linux-amd64" "linux-arm64" "macos-arm64" "mswin-amd64" "mswin-arm64" ];
	lines = builtins.filter (line: line != "" && !(lib.hasPrefix "#" line)) (lib.splitString "\n" source);
	rows = map (line:
		let fields = lib.splitString "\t" line;
		in assert lib.assertMsg (builtins.length fields == 7) "build registry requires seven tab-separated fields"; {
			implementation = builtins.elemAt fields 0;
			frontend = builtins.elemAt fields 1;
			pf = builtins.elemAt fields 2;
			variant = builtins.elemAt fields 3;
			mode = builtins.elemAt fields 4;
			profile = builtins.elemAt fields 5;
			output = let value = builtins.elemAt fields 6; in if value == "-" then null else value;
		}
	) lines;
	validRow = row:
		builtins.hasAttr row.implementation implementations &&
		builtins.elem row.pf platforms && builtins.elem row.mode [ "release" "debug" ] &&
		row.frontend == implementations.${row.implementation}.frontend &&
		row.profile == implementations.${row.implementation}.profiles.${row.mode} &&
		(if lib.hasPrefix "linux-" row.pf then row.variant == "musl"
			else if lib.hasPrefix "mswin-" row.pf then row.variant == "gnu" else row.variant == "-") &&
		(row.output == null || builtins.match "(packages|checks)\\.[A-Za-z0-9_.-]+" row.output != null);
	key = row: "${row.implementation}/${row.pf}/${row.mode}/${row.variant}";
	keys = map key rows;
	coverage = lib.all (implementation: lib.all (pf: lib.all (mode:
		lib.any (row: row.implementation == implementation && row.pf == pf && row.mode == mode) rows
	) [ "release" "debug" ]) platforms) (builtins.attrNames implementations);
	canonical = lib.removeSuffix "\n" selector;
in
assert lib.assertMsg (builtins.hasAttr canonical implementations && (selector == canonical || selector == canonical + "\n")) "CANONICAL_IMPL must contain one registered backend, optionally followed by one LF";
assert lib.assertMsg (lib.all validRow rows) "invalid build registry target, profile, frontend, variant or output";
assert lib.assertMsg (builtins.length keys == builtins.length (lib.unique keys)) "duplicate build registry target";
assert lib.assertMsg coverage "build registry must cover every backend/platform/profile; unavailable builders use -";
{ inherit canonical implementations platforms rows; }
