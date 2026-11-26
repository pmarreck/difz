# The Git-aware collector establishes history and binds its export to the
# prefetched source. This pure consumer validates that handoff against the
# source Nix actually evaluates; it cannot reconstruct Git history itself.
{ record, sourceNarHash, expectedCommit ? null, requireClean ? false }:
let
	check = condition: message: if condition then true else throw "difz build provenance: ${message}";
	hash = value: builtins.isString value &&
		(builtins.match "[0-9a-f]{40}" value != null || builtins.match "[0-9a-f]{64}" value != null);
	narHash = value: builtins.isString value && builtins.match "sha256-[A-Za-z0-9+/]{43}=" value != null;
	availableFields = [ "available" "dirty" "primary_base" "primary_count" "primary_ref" "primary_tip" "revision" "schema" "source_commit" "source_nar_hash" ];
	unavailableFields = [ "available" "reason" "schema" ];
in
assert check (narHash sourceNarHash) "the actual source NAR hash is required";
assert check (expectedCommit == null || hash expectedCommit) "invalid expected source commit";
assert check (builtins.isBool requireClean) "requireClean must be boolean";
assert check (builtins.isAttrs record && (record.schema or null) == "build-provenance/v1" && builtins.isBool (record.available or null)) "unsupported record schema or availability";
assert check (builtins.attrNames record == (if record.available then availableFields else unavailableFields)) "missing or unknown record fields";
assert check (if record.available then
	hash record.source_commit && hash record.primary_tip && hash record.primary_base &&
	record.primary_ref == "refs/heads/yolo" &&
	builtins.isInt record.primary_count && record.primary_count > 0 &&
	builtins.isBool record.dirty &&
	narHash record.source_nar_hash && record.source_nar_hash == sourceNarHash &&
	(expectedCommit == null || record.source_commit == expectedCommit) &&
	(record.primary_tip != record.source_commit || record.primary_base == record.source_commit) &&
	record.revision == "r${toString record.primary_count}-${builtins.substring 0 6 record.source_commit}"
	else builtins.isString record.reason && builtins.match "[a-z0-9][a-z0-9-]*" record.reason != null
) "invalid or source-mismatched record";
assert check (!requireClean || (record.available && !record.dirty)) "release requires available clean provenance";
record
