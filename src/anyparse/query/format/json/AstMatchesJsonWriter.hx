package anyparse.query.format.json;

@:build(anyparse.macro.Build.buildWriter(
	anyparse.query.format.json.AstMatchesJson,
	anyparse.query.format.json.AstMatchesJsonWriteOptions
))
@:nullSafety(Strict)
class AstMatchesJsonWriter {

	private function new() {}
}
