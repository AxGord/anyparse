package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * Object, array, map and anonymous-type lists lay out by the wrapping rules under the Haxe defaults:
 * a break the source put between items, grid rows included, never keeps a list open.
 */
@:nullSafety(Strict)
final class HxListLayoutByWidthDefaultTest extends Test {

	public function new(): Void {
		super();
	}

	/** A source-broken object literal that fits collapses onto its line. */
	@:pin('control')
	@:killer('M-DEFAULT-OBJECT-IGNORE')
	public function testASourceBrokenObjectLiteralCollapses(): Void {
		Assert.equals('class C {\n\tstatic var o = {a: 1, b: 2};\n}', write('class C {\n\tstatic var o = {\n\t\ta: 1,\n\t\tb: 2\n\t};\n}'));
	}

	/** A source-broken array literal that fits collapses onto its line. */
	@:pin('control')
	@:killer('M-DEFAULT-ARRAY-IGNORE')
	public function testASourceBrokenArrayLiteralCollapses(): Void {
		Assert.equals('class C {\n\tstatic var a = [1, 2];\n}', write('class C {\n\tstatic var a = [\n\t\t1,\n\t\t2\n\t];\n}'));
	}

	/** A map literal reads its own cascade; the same default collapses it. */
	@:pin('control')
	@:killer('M-DEFAULT-ARRAY-IGNORE')
	public function testASourceBrokenMapLiteralCollapses(): Void {
		Assert.equals(
			"class C {\n\tstatic var m = ['a' => 1, 'b' => 2];\n}",
			write("class C {\n\tstatic var m = [\n\t\t'a' => 1,\n\t\t'b' => 2\n\t];\n}")
		);
	}

	/** A source-broken anonymous type outside a typedef collapses too; a typedef right-hand side is another decision. */
	@:pin('control')
	@:killer('M-DEFAULT-ANON-IGNORE')
	public function testASourceBrokenAnonTypeCollapses(): Void {
		Assert.equals('class C {\n\tstatic var t:{a:Int, b:Int};\n}', write('class C {\n\tstatic var t:{\n\t\ta:Int,\n\t\tb:Int\n\t};\n}'));
	}

	/** Grid rows are source breaks like any other: under the default the rules, not the rows, decide. */
	@:pin('control')
	@:killer('M-MATRIX-UNDER-IGNORE')
	public function testAGridOfRowsCollapsesLikeAnyOtherList(): Void {
		Assert.equals('class C {\n\tstatic var g = [1, 2, 3, 4];\n}', write('class C {\n\tstatic var g = [\n\t\t1, 2,\n\t\t3, 4\n\t];\n}'));
	}

	/** The rules still break a list: an object over the item count goes one per line whatever its source shape. */
	@:pin('guard')
	public function testTheRulesStillBreakAFlatListOverTheItemCount(): Void {
		final broken: String = 'class C {\n\tstatic var o = {\n\t\ta: 1,\n\t\tb: 2,\n\t\tc: 3,\n\t\td: 4,\n\t\te: 5\n\t};\n}';
		Assert.equals(broken, write('class C {\n\tstatic var o = {a: 1, b: 2, c: 3, d: 4, e: 5};\n}'));
	}

	/** A comment on an anonymous-type field keeps the fields one per line, with the comment on its own field. */
	@:pin('control')
	@:killer('M-ANON-MULTILINE-ONE-PER-LINE')
	public function testACommentOnAnAnonFieldKeepsEachFieldOnItsLine(): Void {
		final leading: String = 'class C {\n\tvar t:{\n\t\t// doc\n\t\tc:Int\n\t};\n}';
		final between: String = 'class C {\n\tvar t:{\n\t\t@:optional var c:Int;\n\t\t// doc\n\t\tvar d:Int;\n\t};\n}';
		Assert.equals(leading, write(leading));
		Assert.equals(between, write(between));
	}

	/** A list the rules break carries hardlines, so a parameter list holding it stays on the signature line. */
	@:pin('control')
	@:killer('M-IGNORE-HARDLINE-LIST-DEFERRED')
	public function testASignatureHugsARuleBrokenAnonTypeParameter(): Void {
		Assert.equals(
			'class C {\n\tfunction f(a:Int, o:{\n\t\tc:Int,\n\t\td:Int,\n\t\te:Int,\n\t\tf:Int,\n\t\tg:Int\n\t}, z:Int):Void {}\n}',
			write('class C {\n\tfunction f(a:Int, o:{c:Int, d:Int, e:Int, f:Int, g:Int}, z:Int):Void {}\n}')
		);
		Assert.equals(
			'class C {\n\tstatic var f = function(a:Int, o:{\n\t\tc:Int,\n\t\td:Int,\n\t\te:Int,\n\t\tf:Int,\n\t\tg:Int\n\t}) {};\n}',
			write('class C {\n\tstatic var f = function(a:Int, o:{c:Int, d:Int, e:Int, f:Int, g:Int}) {};\n}')
		);
		Assert.equals(
			'class C {\n\tfunction f(a:Int, o:Array<{\n\t\tc:Int,\n\t\td:Int,\n\t\te:Int,\n\t\tf:Int,\n\t\tg:Int\n\t}>) {}\n}',
			write('class C {\n\tfunction f(a:Int, o:Array<{c:Int, d:Int, e:Int, f:Int, g:Int}>) {}\n}')
		);
	}

	/**
	 * An object literal in expression position keeps its count in its host's width: a
	 * parameter default holding a rule-broken one wraps the signature, unlike an anon type.
	 */
	@:pin('control')
	@:killer('M-IGNORE-DEFER-BRACED-ONLY')
	public function testAParameterDefaultObjectLiteralWrapsTheSignature(): Void {
		Assert.equals(
			'class C {\n\tfunction f(a:Int,\n\t\to:Dynamic = {\n\t\t\tc: 1,\n\t\t\td: 2,\n\t\t\te: 3,\n\t\t\tf: 4,\n\t\t\tg: 5\n'
			+ '\t\t}, z:Int = 0):Void {}\n}',
			write('class C {\n\tfunction f(a:Int, o:Dynamic = {c: 1, d: 2, e: 3, f: 4, g: 5}, z:Int = 0):Void {}\n}')
		);
	}

	private static function write(src: String): String {
		return HxWriteFixture.triviaWrite(src, '{}');
	}

}
