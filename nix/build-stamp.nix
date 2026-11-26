# All products receive the same already-validated record. Keep display fields
# separate from the full source identity retained by the SDK manifest.
{ pkgs, record }:
let
	text = builtins.toJSON record;
	json = pkgs.writeText "difz-build-provenance.json" text;
in {
	inherit json text;
	revision = if record.available then record.revision else "unavailable";
	dirty = if record.available then (if record.dirty then "true" else "false") else "unknown";
	install = ''
		install -Dm644 ${json} "$out/nix-support/build-provenance.json"
	'';
}
