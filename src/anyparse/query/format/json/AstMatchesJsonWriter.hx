package anyparse.query.format.json;

/**
 * Macro-generated JSON serializer for the `AstMatchesJson` envelope — the `{ "file", "matches" }` output of `apq ast <file> --json --select <path>` (selected-nodes mode). Instantiated only through its generated static `write`; the private constructor blocks direct construction.
 */
@:build(anyparse.macro.Build.buildWriter(anyparse.query.format.json.AstMatchesJson, anyparse.query.format.json.AstMatchesJsonWriteOptions))
@:nullSafety(Strict)
class AstMatchesJsonWriter {

	private function new() {}

}
