package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-enum-begin-end / ω-enumabstract-begin-end — dedicated begin/end
 * blank-line scopes for `enum` and `enum abstract` bodies.
 *
 * haxe-formatter models `enumEmptyLines` and `enumAbstractEmptyLines`
 * as config sections distinct from `classEmptyLines`, all defaulting
 * `beginType` / `endType` to 0. A config that sets
 * `classEmptyLines.beginType` / `endType` drives the shared `beginType`
 * / `endType` knob (class / interface / abstract), and must NOT leak a
 * leading / trailing blank into an `enum` or `enum abstract` body. Enum
 * reads dedicated `enumBeginType` / `enumEndType`; `enum abstract`
 * shares the `HxAbstractDecl` grammar, so the writer flags the inner
 * decl with the transient `_inEnumAbstract` context and reads
 * `enumAbstractBeginType` / `enumAbstractEndType`.
 */
@:nullSafety(Strict)
class HxEnumScopeEmptyLinesSliceTest extends Test {

	static inline final CLASS_BEGIN_END: String = '{"emptyLines":{"classEmptyLines":{"beginType":1,"endType":1}}}';

	public function new(): Void {
		super();
	}

	private function write(src: String, json: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(json));
	}

	public function testDefaultEnumScopeKnobsZero(): Void {
		final d: HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(0, d.enumBeginType);
		Assert.equals(0, d.enumEndType);
		Assert.equals(0, d.enumAbstractBeginType);
		Assert.equals(0, d.enumAbstractEndType);
	}

	public function testClassBeginEndConfigDoesNotLeakIntoEnum(): Void {
		final out: String = write('enum E { A; B; }', CLASS_BEGIN_END);
		Assert.isTrue(out.indexOf('{\n\tA;') != -1, 'enum body must not gain a begin blank: <$out>');
		Assert.isTrue(out.indexOf('B;\n}') != -1, 'enum body must not gain an end blank: <$out>');
	}

	public function testClassBeginEndConfigDoesNotLeakIntoEnumAbstract(): Void {
		final out: String = write('enum abstract E(Int) { final A = 1; final B = 2; }', CLASS_BEGIN_END);
		Assert.isTrue(out.indexOf('{\n\tfinal A') != -1, 'enum abstract body must not gain a begin blank: <$out>');
		Assert.isTrue(out.indexOf('B = 2;\n}') != -1, 'enum abstract body must not gain an end blank: <$out>');
	}

	public function testClassBeginEndConfigStillAppliesToClass(): Void {
		final out: String = write('class C { var a = 1; }', CLASS_BEGIN_END);
		Assert.isTrue(out.indexOf('{\n\n\tvar a') != -1, 'class body must keep its begin blank under classEmptyLines.beginType: <$out>');
	}

	public function testEnumEmptyLinesConfigRoutesToEnumScope(): Void {
		final out: String = write('enum E { A; B; }', '{"emptyLines":{"enumEmptyLines":{"beginType":1}}}');
		Assert.isTrue(out.indexOf('{\n\n\tA;') != -1, 'enumEmptyLines.beginType must inject a begin blank into the enum body: <$out>');
	}

}
