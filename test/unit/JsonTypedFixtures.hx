package unit;

/**
 * Fixtures exercising the ByName struct codepath added in τ₄.
 *
 * These types live outside the regular grammar packages so that the
 * test suite owns its synthetic schemas without polluting
 * `anyparse.grammar.*` with demo types. Marker classes are private
 * to the module — only the referenced `typedef` / `enum abstract`
 * leak out to the test body, which reaches the generated parser
 * through `TestConfigParser.parse`.
 */

/** Closed set of policy strings for `TestConfig.policy`. */
enum abstract TestPolicy(String) from String to String {
	final First = 'first';
	final Second = 'second';
	final Third = 'third';
}

/** Nested section to test recursive ByName parsing. */
@:peg typedef TestNested = {
	var kind:String;
	@:optional var count:Int;
};

/**
 * Root config grammar — covers every ByName field shape τ₄ needs:
 * required primitives (`name`, `count`), optional primitives (`tag`,
 * `ratio`, `enabled`), a required enum-abstract string (`policy`),
 * and a required nested struct (`nested`).
 */
@:peg @:schema(anyparse.format.text.JsonFormat) @:ws
typedef TestConfig = {
	var name:String;
	var count:Int;
	var policy:TestPolicy;
	var nested:TestNested;
	@:optional var tag:String;
	@:optional var ratio:Float;
	@:optional var enabled:Bool;
};

@:build(anyparse.macro.Build.buildParser(unit.JsonTypedFixtures.TestConfig))
@:nullSafety(Strict)
class TestConfigParser {

	private function new() {}
}
