package unit;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JsonParser;

/**
 * Runs the shared JSON parser corpus (`JsonParserTestBase`) against
 * the hand-written `JsonParser`. This class remains the regression
 * baseline in Phase 2 — the macro-generated parser is validated by a
 * parallel subclass that overrides `parseJson` only.
 */
class JsonParserTest extends JsonParserTestBase {

	public function new() {
		super();
	}

	private function parseJson(source:String):JValue {
		return JsonParser.parse(source);
	}
}
