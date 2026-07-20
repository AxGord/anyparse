package anyparse.query.format.json;

/**
 * Macro-generated JSON serializer for the `AstMetaHits` envelope — the `{ "hits" }` output of `apq meta`. Instantiated only through its generated static `write`; the private constructor blocks direct construction.
 */
@:build(anyparse.macro.Build.buildWriter(anyparse.query.format.json.AstMetaHits, anyparse.query.format.json.AstMetaHitsWriteOptions))
@:nullSafety(Strict)
class AstMetaHitsWriter {

	private function new() {}

}
