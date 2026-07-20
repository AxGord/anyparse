package anyparse.query.format.json;

/**
 * Macro-generated JSON serializer for the `AstSearchMatches` envelope — the `{ "matches" }` output of `apq search`. Instantiated only through its generated static `write`; the private constructor blocks direct construction.
 */
@:build(anyparse.macro.Build.buildWriter(
	anyparse.query.format.json.AstSearchMatches, anyparse.query.format.json.AstSearchMatchesWriteOptions
))
@:nullSafety(Strict)
class AstSearchMatchesWriter {

	private function new() {}

}
