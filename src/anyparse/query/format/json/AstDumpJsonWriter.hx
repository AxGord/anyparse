package anyparse.query.format.json;

/**
 * Macro-generated JSON serializer for the `AstDumpJson` envelope — the `{ "file", "tree" }` output of `apq ast <file> --json` in whole-tree mode (no `--select`). Instantiated only through its generated static `write`; the private constructor blocks direct construction.
 */
@:build(anyparse.macro.Build.buildWriter(anyparse.query.format.json.AstDumpJson, anyparse.query.format.json.AstDumpJsonWriteOptions))
@:nullSafety(Strict)
class AstDumpJsonWriter {

	private function new() {}

}
