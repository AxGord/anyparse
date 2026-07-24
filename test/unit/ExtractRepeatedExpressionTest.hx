package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.ExtractRepeatedExpression;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `extract-repeated-expression` check: a non-trivial, PURE value expression
 * repeated three or more co-executing times within one function body is flagged
 * `Info` as a candidate for a `final` local. Report-only — `fix` yields no edits.
 */
class ExtractRepeatedExpressionTest extends Test {

	public function testFieldChainRepeatedThriceFlagged(): Void {
		final vs: Array<Violation> = violations('class C { function m() { k(a.b.c); k(a.b.c); k(a.b.c); } }');
		Assert.equals(1, vs.length);
		Assert.equals('extract-repeated-expression', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('a.b.c') != -1);
		Assert.isTrue(vs[0].message.indexOf('repeated 3 times') != -1);
	}

	public function testTwoOccurrencesNotFlagged(): Void {
		Assert.equals(0, violations('class C { function m() { k(a.b.c); k(a.b.c); } }').length);
	}

	public function testSingleHopNotFlagged(): Void {
		// `this.x` is one hop and holds no call — caching it buys nothing.
		Assert.equals(0, violations('class C { var x:Int; function m() { p(this.x); p(this.x); p(this.x); } }').length);
	}

	public function testBareFieldAccessNotFlagged(): Void {
		// `a.b` is a single-hop read — trivial.
		Assert.equals(0, violations('class C { function m() { p(a.b); p(a.b); p(a.b); } }').length);
	}

	public function testImpureCallNotFlagged(): Void {
		// A local/instance call of unknown effect is impure — never a candidate.
		Assert.equals(0, violations('class C { function m() { f(getData()); f(getData()); f(getData()); } }').length);
	}

	public function testPureStdlibCallFlagged(): Void {
		final vs: Array<Violation> =
			violations('class C { function m(a:Int, b:Int) { s(Math.max(a, b)); s(Math.max(a, b)); s(Math.max(a, b)); } }');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('Math.max(a, b)') != -1);
	}

	public function testNonDeterministicCallExcluded(): Void {
		// `Std.random` is not referentially transparent — extracting would change behaviour.
		Assert.equals(0, violations('class C { function m() { u(Std.random(10)); u(Std.random(10)); u(Std.random(10)); } }').length);
	}

	public function testMutuallyExclusiveBranchesExcluded(): Void {
		// One occurrence per exclusive switch case — only one runs, so a shared local is pointless.
		Assert.equals(
			0, violations('class C { function m(x:Int) { switch x { case 0: k(a.b.c); case 1: k(a.b.c); case 2: k(a.b.c); } } }').length
		);
	}

	public function testCoExecutingBranchOccurrencesFlagged(): Void {
		// Two occurrences co-execute in the then-branch, so the repeat is real.
		final vs: Array<Violation> = violations('class C { function m(c:Bool) { if (c) { k(a.b.c); k(a.b.c); } else { k(a.b.c); } } }');
		Assert.equals(1, vs.length);
	}

	public function testNestedFunctionIsSeparateBody(): Void {
		// Two in the outer body + one in a nested function — neither body reaches the threshold.
		Assert.equals(0, violations('class C { function m() { k(a.b.c); k(a.b.c); function inner() { k(a.b.c); } } }').length);
	}

	public function testSubsumedSubExpressionDropped(): Void {
		// Only the maximal chain is reported, not its equally-frequent prefix.
		final vs: Array<Violation> = violations('class C { function m() { k(a.b.c.d); k(a.b.c.d); k(a.b.c.d); } }');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('a.b.c.d') != -1);
	}

	public function testGetterReadExcluded(): Void {
		// A field read through a property GETTER is treated as impure (may have effects).
		final src: String = 'class D { public var prop(get, never):Int; function get_prop():Int return 1; } '
			+ 'class C { var obj:D; function m() { k(obj.prop.x); k(obj.prop.x); k(obj.prop.x); } }';
		Assert.equals(0, violations(src).length);
	}

	public function testFixYieldsNoEdits(): Void {
		final src: String = 'class C { function m() { k(a.b.c); k(a.b.c); k(a.b.c); } }';
		final check: ExtractRepeatedExpression = new ExtractRepeatedExpression();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('extract-repeated-expression'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('extract-repeated-expression'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { k(a.b.c);').length);
	}

	private function violations(src: String): Array<Violation> {
		return new ExtractRepeatedExpression().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
