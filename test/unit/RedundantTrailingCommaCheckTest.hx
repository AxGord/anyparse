package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check;
import anyparse.check.Linter;
import anyparse.check.RedundantTrailingComma;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `redundant-trailing-comma` check: a `,` between the last element of a
 * comma-separated list and its closing delimiter, which the parser absorbs into
 * the host's own span so no node marks it. `Info`; `fix` deletes the comma — the
 * whole physical line when the comma sits alone on it.
 */
class RedundantTrailingCommaCheckTest extends Test {

	public function testOneLineArrayLiteralFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tvar a = [1, 2,];\n}');
		Assert.equals(1, vs.length);
		Assert.equals('redundant-trailing-comma', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('redundant trailing comma', vs[0].message);
	}

	public function testOneLineArrayLiteralFixed(): Void {
		Assert.equals('class C {\n\tvar a = [1, 2];\n}', applyFix('class C {\n\tvar a = [1, 2,];\n}'));
	}

	public function testSingleElementArrayFixed(): Void {
		Assert.equals('class C {\n\tvar a = [1];\n}', applyFix('class C {\n\tvar a = [1,];\n}'));
	}

	public function testMultiLineArrayLiteralFixed(): Void {
		final src: String = 'class C {\n\tvar a = [\n\t\t1,\n\t\t2,\n\t];\n}';
		Assert.equals('class C {\n\tvar a = [\n\t\t1,\n\t\t2\n\t];\n}', applyFix(src));
	}

	public function testMapLiteralFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tvar m = [1 => 2, 3 => 4,];\n}').length);
	}

	public function testComprehensionFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tvar a = [for (i in 0...3) i,];\n}').length);
	}

	public function testObjectLiteralFixed(): Void {
		Assert.equals('class C {\n\tvar o:Dynamic = {x: 1, y: 2};\n}', applyFix('class C {\n\tvar o:Dynamic = {x: 1, y: 2,};\n}'));
	}

	public function testAnonTypeFieldsFixed(): Void {
		Assert.equals('typedef T = {x:Int, y:Int};', applyFix('typedef T = {x:Int, y:Int,};'));
	}

	public function testNewArgsFixed(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tnew D(1, 2,);\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tnew D(1, 2);\n\t}\n}', applyFix(src));
	}

	public function testCallArgsFixed(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tg(1, 2,);\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tg(1, 2);\n\t}\n}', applyFix(src));
	}

	public function testFunctionParamsFixed(): Void {
		final src: String = 'class C {\n\tfunction f(a:Int, b:Int,):Void {}\n}';
		Assert.equals('class C {\n\tfunction f(a:Int, b:Int):Void {}\n}', applyFix(src));
	}

	public function testEnumConstructorParamsFlagged(): Void {
		Assert.equals(1, violations('enum E {\n\tA(x:Int, y:Int,);\n}').length);
	}

	public function testAnonFunctionParamsFixed(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar g = function(a:Int, b:Int,):Int return a;\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tvar g = function(a:Int, b:Int):Int return a;\n\t}\n}', applyFix(src));
	}

	public function testArrowParamsFixed(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar g = (a:Int, b:Int,) -> a;\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tvar g = (a:Int, b:Int) -> a;\n\t}\n}', applyFix(src));
	}

	/** The last parameter is not always a plain required one - an optional and a rest end a list too. */
	public function testOptionalAndRestLastParamFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f(a:Int, ?b:Int,):Void {}\n}').length);
		Assert.equals(1, violations('class C {\n\tfunction f(a:Int, ...r:Int,):Void {}\n}').length);
	}

	/**
	 * The `,` after a `> Base` anon-type extension entry is MANDATORY - `{> Base,}`
	 * compiles and `{> Base}` is `Expected ,`, so deleting it breaks the build. The
	 * veto is keyed on the LAST ELEMENT: the same host with an ordinary field last is
	 * still flagged.
	 */
	public function testAnonTypeExtensionCommaNotFlagged(): Void {
		Assert.equals(0, violations('typedef R = {\n\t> Base,\n}').length);
		Assert.equals(0, violations('typedef R = {\n\t> A,\n\t> B,\n}').length);
		Assert.equals(1, violations('typedef R = {\n\t> Base,\n\tx:Int,\n}').length);
		Assert.equals('typedef R = {\n\t> Base,\n\tx:Int\n}', applyFix('typedef R = {\n\t> Base,\n\tx:Int,\n}'));
	}

	public function testMetadataArgsFlagged(): Void {
		Assert.equals(1, violations('@:meta(a, b,)\nclass C {}').length);
	}

	/** Every list written without a trailing comma, and every empty one, stays silent. */
	public function testWellFormedListsNotFlagged(): Void {
		final src: String = 'class C {\n\tvar a = [1, 2];\n\tvar e:Array<Int> = [];\n\tvar o:Dynamic = {x: 1};\n'
			+ '\tvar d:Dynamic = {};\n\tfunction f(a:Int, b:Int):Void {\n\t\tg(1, 2);\n\t\tg();\n\t\tnew D(1, 2);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	/** A comment between the comma and the closer is trivia — the comma is still flagged, and only it is deleted. */
	public function testCommentBeforeCloserFixed(): Void {
		final src: String = 'class C {\n\tvar a = [1, 2, /* tail */];\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C {\n\tvar a = [1, 2 /* tail */];\n}', applyFix(src));
	}

	/** A LINE comment in the gap is trivia too, and it owns the rest of its line. */
	public function testLineCommentBeforeCloserFixed(): Void {
		final src: String = 'class C {\n\tvar a = [\n\t\t1,\n\t\t2, // tail\n\t];\n}';
		Assert.equals('class C {\n\tvar a = [\n\t\t1,\n\t\t2 // tail\n\t];\n}', applyFix(src));
	}

	/** A comma alone on its line takes the whole line, so the delete leaves no blank residue. */
	public function testCommaAloneOnLineDeletesLine(): Void {
		final src: String = 'class C {\n\tvar a = [\n\t\t1,\n\t\t2\n\t\t,\n\t];\n}';
		Assert.equals('class C {\n\tvar a = [\n\t\t1,\n\t\t2\n\t];\n}', applyFix(src));
	}

	/**
	 * A `#if … #end` region as the last element ends AT `#end`, so the gap before the
	 * closer holds no comma and the comma inside the region is left alone — the branch
	 * it terminates is not the list's last element under every define.
	 */
	public function testConditionalRegionLastNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tfinal a:Array<Int> = [\n\t\t\t1,\n\t\t\t#if js\n'
			+ '\t\t\t2,\n\t\t\t#end\n\t\t];\n\t\tg(a);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	/** The same, for a parameter list: the region node holds the last parameter, so the gap never starts at a comma. */
	public function testConditionalRegionLastParamNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(\n\t\ta:Int,\n\t\t#if js\n\t\tb:Int,\n\t\t#end\n\t):Void {}\n}';
		Assert.equals(0, violations(src).length);
	}

	/** Nested lists are independent hosts — each keeps its own finding and its own edit. */
	public function testNestedListsBothFlagged(): Void {
		final src: String = 'class C {\n\tvar a = [[1,], 2,];\n}';
		Assert.equals(2, violations(src).length);
		Assert.equals('class C {\n\tvar a = [[1], 2];\n}', applyFix(src));
	}

	public function testRegisteredInBuiltinsAsDefaultOff(): Void {
		final registered: Null<Check> = Linter.byId('redundant-trailing-comma');
		Assert.notNull(registered);
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-trailing-comma'));
		Assert.isTrue(registered is DefaultOff, 'a trailing comma is a project style call, so the rule is opt-in');
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantTrailingComma().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		return CheckFixture.fixedSource(new RedundantTrailingComma(), src);
	}

}
