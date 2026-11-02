package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * The spaces around a `macro` reification. In `macro : T` the space before the colon is always
 * written and the one after it follows `whitespace.typeHintColonPolicy`; `macro (e)` keeps its
 * space, as a construct, where a paren-led `cast(e)` is glued, as a call.
 */
@:nullSafety(Strict)
final class HxMacroSpacingTest extends Test {

	private static final SRC: String = 'class C {\n\tfunction f() {\n\t\tvar a = macro :Int;\n\t\tvar b = macro : Array<String>;\n\t}\n}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-WSP-ADD-NOOP')
	public function testColonAfterSpaceFollowsTypeHintAfter(): Void {
		final out: String = HxWriteFixture.triviaWrite(SRC, colonJson('after'));
		Assert.stringContains('var a = macro : Int;', out);
		Assert.stringContains('var b = macro : Array<String>;', out);
	}

	public function testColonAroundIsTheSameAsAfter(): Void {
		Assert.stringContains('var a = macro : Int;', HxWriteFixture.triviaWrite(SRC, colonJson('around')));
	}

	@:pin('control')
	@:killer('M-MACRO-LEAD-POLICY-OFF')
	public function testColonIsTightAfterUnderTheDefaultPolicy(): Void {
		final out: String = HxWriteFixture.triviaWrite(SRC, '{}');
		Assert.stringContains('var a = macro :Int;', out);
		Assert.stringContains('var b = macro :Array<String>;', out);
	}

	public function testColonBeforePolicyKeepsOneSpaceBefore(): Void {
		Assert.stringContains('var a = macro :Int;', HxWriteFixture.triviaWrite(SRC, colonJson('before')));
	}

	public function testPlainWriterFollowsTheSamePolicy(): Void {
		Assert.stringContains('var a = macro : Int;', HxWriteFixture.plainWrite(SRC, colonJson('after')));
	}

	@:pin('control')
	@:killer('M-MACRO-PAREN-GLUED')
	public function testParenOperandKeepsTheSpace(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tvar c = macro (x + 1);\n\t\tvar d = macro (x) + 1;\n'
			+ '\t\tvar e = macro (a : Int);\n\t\tg(macro (x));\n\t}\n}';
		for (out in [HxWriteFixture.triviaWrite(src, '{}'), HxWriteFixture.plainWrite(src, '{}')]) {
			Assert.stringContains('var c = macro (x + 1);', out);
			Assert.stringContains('var d = macro (x) + 1;', out);
			Assert.stringContains('var e = macro (a : Int);', out);
			Assert.stringContains('g(macro (x));', out);
		}
	}

	@:pin('control')
	@:killer('M-CAST-PAREN-SPACED')
	public function testCastParenOperandStaysGlued(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tvar c = cast (x);\n\t}\n}';
		Assert.stringContains('var c = cast(x);', HxWriteFixture.triviaWrite(src, '{}'));
		Assert.stringContains('var c = cast(x);', HxWriteFixture.plainWrite(src, '{}'));
	}

	public function testNonParenOperandKeepsTheSpace(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tvar c = macro x + 1;\n\t\tvar d = macro $$v{1};\n\t}\n}';
		final out: String = HxWriteFixture.triviaWrite(src, '{}');
		Assert.stringContains('var c = macro x + 1;', out);
		Assert.stringContains('var d = macro $$v{1};', out);
	}

	private static function colonJson(policy: String): String {
		return '{"whitespace": {"typeHintColonPolicy": "$policy"}}';
	}

}
