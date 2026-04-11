package unit;

// Importing JValue first ensures its @:build macro has run before the
// compiler tries to resolve JValueFastParser below — the latter is
// defined at macro time via `Context.defineType` rather than existing
// as a source file on disk.
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueFastParser;

/**
 * Macro parity suite: runs the shared JSON parser corpus against the
 * macro-generated `JValueFastParser`. Every assertion in
 * `JsonParserTestBase` must produce the same result it produces for
 * `JsonParserTest` (the hand-written baseline).
 */
class JsonMacroParserTest extends JsonParserTestBase {

	public function new() {
		super();
	}

	private function parseJson(source:String):JValue {
		return JValueFastParser.parse(source);
	}
}
