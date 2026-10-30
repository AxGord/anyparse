package unit.grammar.haxe;

import anyparse.format.wrap.WrapRule;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import utest.Assert;
import utest.Test;

/**
 * A wrapped list's continuation indent is one unit plus the `additionalIndent` of the
 * cascade rule that matched, the cascade's `defaultAdditionalIndent` when none did —
 * haxe-formatter's per-rule `additionalIndent`. A function signature over an empty body
 * takes none, and a leading-break line stays at one unit.
 */
@:nullSafety(Strict)
class HxWrapAdditionalIndentTest extends Test {

	/** An anonymous function whose signature overflows a 100-column line once. */
	private static final ANON: String = 'class C {\n\tfunction f():Void {\n\t\tvar cb = function(firstParameter:Int, secondParameter:String, '
		+ 'thirdParameter:Float, fourth:Bool):Void {\n\t\t\ttrace(1);\n\t\t};\n\t}\n}';

	/** The same overflowing signature over an empty body, a body holding only a comment, and a body with a statement. */
	private static final NAMED: String = 'class C {\n'
		+ '\tfunction emptyBodyFunction(firstParameter:Int, secondParameter:String, thirdParameter:Float, fourth:Bool):Void {}\n\n'
		+ '\tfunction commentBodyFunc(firstParameter:Int, secondParameter:String, thirdParameter:Float, fourth:Bool):Void { // c\n\t}\n\n'
		+ '\tfunction statementBodyFn(firstParameter:Int, secondParameter:String, thirdParameter:Float, fourth:Bool):Void {\n'
		+ '\t\ttrace(1);\n\t}\n}';

	private static final HEADER: String = 'class LongerName extends LongBaseClass implements ILongFormInterface implements ILongFormInterface1 '
		+ 'implements ILongFormInterface2 {}';
	private static final PREFIX: String = '{"indentation": {"character": "tab"}, "wrapping": {"maxLineLength": 100, ';
	private static final EXCEEDS: String = '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine"';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-CONTCOLS-NO-ADDITIONAL')
	public function testTheMatchedRuleChargesItsIndent(): Void {
		final cfg: String = '$PREFIX"anonFunctionSignature": {"defaultWrap": "noWrap", "rules": [$EXCEEDS, "additionalIndent": 1}]}}}';
		final out: String = HxWriteFixture.triviaWrite(ANON, cfg);
		Assert.stringContains('thirdParameter:Float,\n\t\t\t\tfourth:Bool):Void {', out, out);
	}

	@:pin('control')
	@:killer('M-CONTCOLS-DEFAULT-ONLY')
	public function testTheDefaultIndentAnswersOnlyWhenNoRuleMatches(): Void {
		final cfg: String = '$PREFIX"anonFunctionSignature": {"defaultWrap": "fillLine", "defaultAdditionalIndent": 2, "rules": [$EXCEEDS'
			+ ', "additionalIndent": 0}]}}}';
		final out: String = HxWriteFixture.triviaWrite(ANON, cfg);
		Assert.stringContains('thirdParameter:Float,\n\t\t\tfourth:Bool):Void {', out, out);
	}

	@:pin('control')
	@:killer('M-CONTCOLS-IGNORE-SUPPRESS')
	public function testAnEmptyBodyTakesNoAdditionalIndent(): Void {
		final out: String = HxWriteFixture.triviaWrite(
			NAMED, '$PREFIX"functionSignature": {"defaultWrap": "fillLine", "defaultAdditionalIndent": 1, "rules": []}}}'
		);
		Assert.stringContains('thirdParameter:Float,\n\t\tfourth:Bool):Void {}', out, out);
		Assert.stringContains('thirdParameter:Float,\n\t\t\tfourth:Bool):Void {\n\t\ttrace(1);', out, out);
	}

	@:pin('control')
	@:killer('M-FNBODY-COMMENT-EMPTY')
	public function testABodyHoldingOnlyACommentIsNotEmpty(): Void {
		final out: String = HxWriteFixture.triviaWrite(
			NAMED, '$PREFIX"functionSignature": {"defaultWrap": "fillLine", "defaultAdditionalIndent": 1, "rules": []}}}'
		);
		Assert.stringContains('thirdParameter:Float,\n\t\t\tfourth:Bool):Void { // c', out, out);
	}

	@:pin('control')
	@:killer('M-CONTCOLS-LEADING-BREAK-INDENT')
	public function testALeadingBreakLineStaysAtOneUnit(): Void {
		final cfg: String =
			'$PREFIX"functionSignature": {"defaultWrap": "fillLineWithLeadingBreak", "defaultAdditionalIndent": 2, "rules": []}}}';
		final out: String = HxWriteFixture.triviaWrite(NAMED, cfg);
		Assert.stringContains('function statementBodyFn(\n\t\tfirstParameter:Int, secondParameter:String', out, out);
	}

	@:pin('control')
	@:killer('M-LOADER-DEFAULT-INDENT-INHERIT')
	public function testARestatedDefaultWrapDropsTheBuiltInIndent(): Void {
		final out: String = HxWriteFixture.triviaWrite(NAMED, '$PREFIX"functionSignature": {"defaultWrap": "fillLine"}}}');
		Assert.stringContains('thirdParameter:Float,\n\t\tfourth:Bool):Void {\n\t\ttrace(1);', out, out);
	}

	@:pin('control')
	@:killer('M-HERITAGE-RULE-INDENT')
	public function testAHeritageRuleChargesItsIndent(): Void {
		final cfg: String = '$PREFIX"implementsExtends": {"defaultWrap": "noWrap", "rules": [{"conditions": ['
			+ '{"cond": "lineLength >= n", "value": 100}], "type": "onePerLineAfterFirst", "additionalIndent": 1}]}}}';
		final out: String = HxWriteFixture.triviaWrite(HEADER, cfg);
		Assert.stringContains(
			'class LongerName extends LongBaseClass\n\timplements ILongFormInterface\n\timplements ILongFormInterface1', out, out
		);
	}

	@:pin('control')
	@:killer('M-LOADER-RULE-INDENT')
	public function testTheLoaderReadsARulesIndent(): Void {
		final cfg: String = '$PREFIX"anonFunctionSignature": {"rules": [$EXCEEDS, "additionalIndent": 3}]}}}';
		final rules: Array<WrapRule> = HaxeFormatConfigLoader.loadHxFormatJson(cfg).anonFunctionSignatureWrap.rules;
		Assert.equals(1, rules.length);
		Assert.equals(3, rules[0].additionalIndent);
	}

	@:pin('control')
	@:killer('M-FORCEMULTI-COLS-ONE-UNIT')
	public function testABraceListReachesItsIndentInOnePass(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tvar o = {a: 1, b: 2, c: 3};\n\t\tvar t:{a:Int, b:Int};\n\t}\n}';
		final cascade: String = '{"defaultWrap": "onePerLine", "defaultAdditionalIndent": 1, "rules": []}';
		final cfg: String = '$PREFIX"objectLiteral": $cascade, "anonType": $cascade}}';
		final out: String = HxWriteFixture.triviaWrite(src, cfg);
		Assert.stringContains('var o = {\n\t\t\t\ta: 1,', out, out);
		Assert.stringContains('var t:{\n\t\t\t\ta:Int,', out, out);
		Assert.equals(out, HxWriteFixture.triviaWrite(out, cfg), 'the second pass reads the first pass back unchanged');
	}

	@:pin('control')
	@:killer('M-TYPEDEF-BODY-TAKES-ANON-INDENT')
	public function testATypedefBodyTakesNoAnonTypeIndent(): Void {
		final src: String = 'typedef T = {\n\ta:Int,\n\tb:Int\n};\n\nclass C {\n\tfunction f() {\n\t\tvar t:{a:Int, b:Int};\n\t}\n}';
		final cfg: String = '$PREFIX"anonType": {"defaultWrap": "onePerLine", "defaultAdditionalIndent": 1, "rules": []}}}';
		final out: String = HxWriteFixture.triviaWrite(src, cfg);
		Assert.stringContains('typedef T = {\n\ta:Int,\n\tb:Int\n};', out, out);
		Assert.stringContains('var t:{\n\t\t\t\ta:Int,', out, out);
	}

}
