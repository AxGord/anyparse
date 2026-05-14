package anyparse.query.format.json;

@:build(anyparse.macro.Build.buildWriter(
	anyparse.query.format.json.AstDumpJson,
	anyparse.query.format.json.AstDumpJsonWriteOptions
))
@:nullSafety(Strict)
class AstDumpJsonWriter {

	private function new() {}
}
