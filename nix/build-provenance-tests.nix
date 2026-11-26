{ lib, sourceNarHash }:
let
	decode = arguments: import ./build-provenance.nix ({ inherit sourceNarHash; } // arguments);
	accepts = arguments: (builtins.tryEval (builtins.deepSeq (decode arguments) true)).success;
	rejects = arguments: !(accepts arguments);
	commit = "0123456789abcdef0123456789abcdef01234567";
	other = "89abcdef0123456789abcdef0123456789abcdef";
	valid = {
		schema = "build-provenance/v1";
		available = true;
		source_commit = commit;
		primary_ref = "refs/heads/yolo";
		primary_tip = other;
		primary_base = other;
		primary_count = 42;
		source_nar_hash = sourceNarHash;
		dirty = false;
		revision = "r42-012345";
	};
	unavailable = { schema = "build-provenance/v1"; available = false; reason = "not-captured"; };
	dirty = valid // { dirty = true; };
	sha256 = lib.concatStrings (builtins.genList (_: "a") 64);
	wrongValues = [ null "" "wrong" 0 (-1) 42.0 [] {} false true ];
	# Mechanically sweep every declared field. The dirty flag has two valid
	# values for development; its true value is rejected separately for releases.
	fieldMutations = lib.concatMap (field: map (value: {
		record = valid // { ${field} = value; };
	}) (builtins.filter (value: value != valid.${field} && !(field == "dirty" && builtins.isBool value)) wrongValues)) (builtins.attrNames valid);
	omissions = map (field: { record = builtins.removeAttrs valid [ field ]; }) (builtins.attrNames valid);
	invalid = fieldMutations ++ omissions ++ [
		{ record = null; }
		{ record = valid // { extra = true; }; }
		{ record = valid // { source_commit = lib.toUpper commit; }; }
		{ record = valid // { primary_ref = "refs/heads/topic"; }; }
		{ record = valid // { primary_tip = commit; primary_base = other; }; }
		{ record = valid // { revision = "r43-012345"; }; }
		{ record = valid // { primary_count = 42.0; }; }
		{ record = valid // { source_nar_hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; }; }
		{ record = valid; expectedCommit = other; }
		{ record = valid; expectedCommit = "short"; }
		{ record = valid; sourceNarHash = null; }
		{ record = valid; requireClean = "true"; }
		{ record = dirty; requireClean = true; }
		{ record = unavailable; requireClean = true; }
		{ record = unavailable // { reason = ""; }; }
		{ record = unavailable // { reason = "two lines\nnot allowed"; }; }
		{ record = unavailable // { revision = "r42-012345"; }; }
	];
in
assert sourceNarHash != "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
assert decode { record = valid; } == valid;
assert decode { record = valid; expectedCommit = commit; requireClean = true; } == valid;
assert (decode { record = valid // { primary_tip = commit; primary_base = commit; }; }) == (valid // { primary_tip = commit; primary_base = commit; });
assert decode { record = dirty; } == dirty;
assert (decode { record = dirty; }).revision == valid.revision;
assert decode { record = unavailable; } == unavailable;
assert accepts { record = valid // { source_commit = sha256; revision = "r42-aaaaaa"; }; expectedCommit = sha256; };
assert lib.all rejects invalid;
true
