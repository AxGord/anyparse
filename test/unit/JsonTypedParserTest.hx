package unit;

import anyparse.runtime.ParseError;
import unit.JsonTypedFixtures.TestConfig;
import unit.JsonTypedFixtures.TestConfigParser;
import unit.JsonTypedFixtures.TestPolicy;
import utest.Assert;
import utest.Test;

/**
 * τ₄ — exercises the ByName struct lowering: JSON object →
 * typed Haxe struct via the macro-generated `TestConfigParser`.
 * Separate from `HaxeFormatConfigLoaderTest` so the core codepath
 * (optional fields, missing-required errors, unknown-key skipping,
 * enum-abstract string terminals, nested structs) is validated in
 * isolation before the loader rewrite layers on top.
 */
@:nullSafety(Strict)
class JsonTypedParserTest extends Test {

	public function new():Void {
		super();
	}

	public function testAllRequiredPresentOptionalsDefaultToNull():Void {
		final src:String = '{"name":"foo","count":3,"policy":"first","nested":{"kind":"leaf"}}';
		final cfg:TestConfig = TestConfigParser.parse(src);
		Assert.equals('foo', cfg.name);
		Assert.equals(3, cfg.count);
		Assert.equals((First : String), (cfg.policy : String));
		Assert.equals('leaf', cfg.nested.kind);
		Assert.isNull(cfg.nested.count);
		Assert.isNull(cfg.tag);
		Assert.isNull(cfg.ratio);
		Assert.isNull(cfg.enabled);
	}

	public function testOptionalPrimitivesPassThrough():Void {
		final src:String = '{"name":"a","count":1,"policy":"second","nested":{"kind":"x"},"tag":"t","ratio":1.5,"enabled":true}';
		final cfg:TestConfig = TestConfigParser.parse(src);
		Assert.equals('t', cfg.tag);
		Assert.equals(1.5, cfg.ratio);
		Assert.equals(true, cfg.enabled);
	}

	public function testFieldOrderIndependent():Void {
		final src:String = '{"policy":"third","nested":{"kind":"k","count":7},"count":42,"name":"bar"}';
		final cfg:TestConfig = TestConfigParser.parse(src);
		Assert.equals('bar', cfg.name);
		Assert.equals(42, cfg.count);
		Assert.equals((Third : String), (cfg.policy : String));
		Assert.equals('k', cfg.nested.kind);
		Assert.equals(7, cfg.nested.count);
	}

	public function testUnknownKeysIgnored():Void {
		final src:String = '{"name":"z","count":0,"policy":"first","nested":{"kind":"n"},"future":"skipped","listed":[1,2,3],"nestedFuture":{"a":1}}';
		final cfg:TestConfig = TestConfigParser.parse(src);
		Assert.equals('z', cfg.name);
		Assert.equals(0, cfg.count);
	}

	public function testMissingRequiredThrows():Void {
		final src:String = '{"count":1,"policy":"first","nested":{"kind":"k"}}';
		Assert.raises(() -> TestConfigParser.parse(src), ParseError);
	}

	public function testMissingNestedRequiredThrows():Void {
		final src:String = '{"name":"a","count":1,"policy":"first","nested":{}}';
		Assert.raises(() -> TestConfigParser.parse(src), ParseError);
	}

	public function testInvalidEnumValueThrows():Void {
		final src:String = '{"name":"a","count":1,"policy":"nope","nested":{"kind":"k"}}';
		Assert.raises(() -> TestConfigParser.parse(src), ParseError);
	}

	public function testEmptyObjectMissingAllThrows():Void {
		Assert.raises(() -> TestConfigParser.parse('{}'), ParseError);
	}

	public function testStringEscapesDecoded():Void {
		final src:String = '{"name":"a\\tb","count":1,"policy":"first","nested":{"kind":"k"}}';
		final cfg:TestConfig = TestConfigParser.parse(src);
		Assert.equals('a\tb', cfg.name);
	}

	public function testIrregularWhitespaceAccepted():Void {
		final src:String = '{\n  "name" : "ws",\n  "count" : 1 ,\n  "policy":"first",\n  "nested":{"kind":"n"}\n}';
		final cfg:TestConfig = TestConfigParser.parse(src);
		Assert.equals('ws', cfg.name);
	}

	public function testNegativeAndDecimalNumbers():Void {
		final src:String = '{"name":"n","count":-5,"policy":"first","nested":{"kind":"n"},"ratio":-0.25}';
		final cfg:TestConfig = TestConfigParser.parse(src);
		Assert.equals(-5, cfg.count);
		Assert.equals(-0.25, cfg.ratio);
	}
}
