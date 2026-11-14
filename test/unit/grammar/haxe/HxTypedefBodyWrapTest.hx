package unit.grammar.haxe;

import anyparse.format.wrap.WrapMode;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * `wrapping.typedefBody`: the wrap cascade of a typedef's own body, read apart from the inline anonymous types that stay on
 * `wrapping.anonType`. A config without the key loads it equal to `anonType`.
 */
@:nullSafety(Strict)
final class HxTypedefBodyWrapTest extends Test {

	private static final RULES: String = '[{"conditions":[{"cond":"itemCount >= n","value":5}],"type":"onePerLine"},'
		+ '{"conditions":[{"cond":"itemCount >= n","value":4},{"cond":"typeParamItemCount >= n","value":1}],"type":"onePerLine"}]';
	private static final BODY_CONFIG: String = '{"indentation":{"character":"tab","tabWidth":4},'
		+ '"wrapping":{"maxLineLength":140,"typedefBody":{"defaultWrap":"noWrap","rules":$RULES}}}';
	private static final INHERIT_CONFIG: String = '{"indentation":{"character":"tab","tabWidth":4},'
		+ '"wrapping":{"maxLineLength":140,"anonType":{"defaultWrap":"noWrap","rules":$RULES}}}';
	private static final SRC: String = 'typedef A = {a:Int, b:String, c:Bool, d:Float};\ntypedef B = {'
		+ 'a:Int, b:String, c:Bool, d:Float, e:Int};\ntypedef C = {a:Array<Int>, b:String, c:Bool};\ntypedef D = {'
		+ 'a:Array<Int>, b:String, c:Bool, d:Float};\ntypedef E = {a:Null<String>, b:String, c:Bool, d:Float};\n'
		+ 'typedef F = {a:Int->Void, b:String, c:Bool, d:Float};\n'
		+ 'typedef G = {> Base, a:Int, b:String, c:Bool};\n'
		+ 'typedef H = {> Base, a:Int, b:String, c:Bool, d:Float};';
	private static final BODY_OUT: String = 'typedef A = {a:Int, b:String, c:Bool, d:Float};\n\ntypedef B = {\n\ta:Int,\n\tb:String,\n'
		+ '\tc:Bool,\n\td:Float,\n\te:Int\n};\n\ntypedef C = {a:Array<Int>, b:String, c:Bool};\n\n'
		+ 'typedef D = {\n\ta:Array<Int>,\n\tb:String,\n\tc:Bool,\n\td:Float\n};\n\ntypedef E = {\n'
		+ '\ta:Null<String>,\n\tb:String,\n\tc:Bool,\n\td:Float\n};\n\n'
		+ 'typedef F = {a:Int->Void, b:String, c:Bool, d:Float};\ntypedef G = {> Base, a:Int, b:String, '
		+ 'c:Bool};\n\ntypedef H = {\n\t> Base,\n\ta:Int,\n\tb:String,\n\tc:Bool,\n\td:Float\n};';

	public function new(): Void {
		super();
	}

	/** A typedef body breaks by its own rules; the five-field type in a parameter keeps the `anonType` layout. */
	@:pin('control')
	@:killer('M-TYPEDEF-BODY-WRAP-OFF')
	public function testTypedefBodyReadsItsOwnCascade(): Void {
		Assert.equals(BODY_OUT, HxWriteFixture.triviaWrite(SRC, BODY_CONFIG));
		Assert.equals(BODY_OUT, HxWriteFixture.triviaWrite(BODY_OUT, BODY_CONFIG));
	}

	/** An inline anonymous type in a parameter lays out exactly as without the section. */
	@:pin('guard')
	public function testInlineAnonTypeIgnoresTheSection(): Void {
		final src: String = 'class K {\n\tfunction f(o:{a:Array<Int>, b:String, c:Bool, d:Float, e:Int}) {}\n}';
		final plain: String = '{"indentation":{"character":"tab","tabWidth":4},"wrapping":{"maxLineLength":140}}';
		Assert.equals(HxWriteFixture.triviaWrite(src, plain), HxWriteFixture.triviaWrite(src, BODY_CONFIG));
	}

	/** Without the key a typedef body follows `anonType`, so the same rules break the inline type too. */
	@:pin('guard')
	public function testWithoutTheKeyTheBodyInheritsAnonType(): Void {
		final src: String = 'typedef B = {a:Int, b:String, c:Bool, d:Float, e:Int};\nclass K {\n'
			+ '\tfunction f(o:{a:Int, b:String, c:Bool, d:Float, e:Int}) {}\n}';
		final out: String = HxWriteFixture.triviaWrite(src, INHERIT_CONFIG);
		Assert.isTrue(out.indexOf('typedef B = {\n\ta:Int,') == 0);
		Assert.isTrue(out.indexOf('function f(o:{\n\t\ta:Int,') > 0);
	}

	/** The section ingests into its own option and leaves `anonType` alone; an absent key copies `anonType`. */
	@:pin('guard')
	public function testSectionIngestsIntoItsOwnOption(): Void {
		final own: HxModuleWriteOptions = HxWriteOptionsKit.strictJson(BODY_CONFIG);
		Assert.equals(2, own.typedefBodyWrap.rules.length);
		Assert.equals(WrapMode.NoWrap, own.typedefBodyWrap.defaultMode);
		Assert.notEquals(2, own.anonTypeWrap.rules.length);
		final inherited: HxModuleWriteOptions = HxWriteOptionsKit.strictJson(INHERIT_CONFIG);
		Assert.equals(2, inherited.typedefBodyWrap.rules.length);
		Assert.equals(WrapMode.NoWrap, inherited.typedefBodyWrap.defaultMode);
	}

}
