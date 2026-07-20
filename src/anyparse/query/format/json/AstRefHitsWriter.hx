package anyparse.query.format.json;

/**
 * Macro-generated JSON serializer for the `AstRefHits` envelope — the `{ "hits" }` output of `apq refs`. Instantiated only through its generated static `write`; the private constructor blocks direct construction.
 */
@:build(anyparse.macro.Build.buildWriter(anyparse.query.format.json.AstRefHits, anyparse.query.format.json.AstRefHitsWriteOptions))
@:nullSafety(Strict)
class AstRefHitsWriter {

	private function new() {}

}
