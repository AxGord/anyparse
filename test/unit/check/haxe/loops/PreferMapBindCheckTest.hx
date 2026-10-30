package unit.check.haxe.loops;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.RiskyFix;
import anyparse.check.Severity;
import anyparse.check.haxe.loops.PreferMapBind;

/**
 * The `prefer-map-bind` check: an array comprehension over an `Array` whose body is one call taking the loop binder
 * as one argument is flagged `Info` and rewritten to `xs.map(<partial application>)`. Another collection, a binder
 * read twice, an argument `bind` would read at the wrong time and a body that is not one call are left alone. The fix
 * is risky: the comprehension's element type comes from where it is written.
 */
class PreferMapBindCheckTest extends Test {

	public function testComprehensionFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('final ys = [for (x in xs) g(k, x)];'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-map-bind', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this comprehension maps each element through one call — it can be xs.map(g.bind(k))', vs[0].message);
	}

	/** The binder last is dropped, first takes `_`, alone leaves the bare callee. */
	public function testFixSpellsPartialApplication(): Void {
		Assert.equals(wrap('final ys = xs.map(g.bind(k));'), fixed(wrap('final ys = [for (x in xs) g(k, x)];')));
		Assert.equals(wrap('final ys = xs.map(g.bind(_, 2));'), fixed(wrap('final ys = [for (x in xs) g(x, 2)];')));
		Assert.equals(wrap('final ys = xs.map(one);'), fixed(wrap('final ys = [for (x in xs) one(x)];')));
	}

	/** `List.map` returns a `List`: only an `Array` keeps the comprehension's type. */
	@:pin('control')
	@:killer('M-PMB-ANY-ITERABLE')
	public function testOtherCollectionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = [for (x in ls) one(x)];')).length);
	}

	public function testBinderTwiceNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = [for (x in xs) g(x, x)];')).length);
	}

	/** A field may change between the comprehension's iterations; `bind` would read it once. */
	public function testFieldArgumentNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = [for (x in xs) g(fld, x)];')).length);
	}

	public function testBodyNotOneCallNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = [for (x in xs) g(k, x) + 1];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (x in xs) if (x > 0) one(x)];')).length);
	}

	public function testDefaultOffAndRisky(): Void {
		Assert.isTrue(Std.isOfType(new PreferMapBind(), DefaultOff));
		Assert.isTrue(Std.isOfType(new PreferMapBind(), RiskyFix));
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new PreferMapBind(), src);
	}

	private function fixed(src: String): String {
		return CheckFixture.fixedSource(new PreferMapBind(), src);
	}

	private static function wrap(statement: String): String {
		return 'class C {\n\tvar fld: Int = 0;\n\n\tfunction g(a: Int, b: Int): Int {\n\t\treturn a + b;\n\t}\n\n\tfunction one(a: Int): '
			+ 'Int {\n\t\treturn a;\n\t}\n\n\tfunction f(xs: Array<Int>, ls: List<Int>, k: Int): Void {\n\t\t$statement\n\t}\n}';
	}

}
