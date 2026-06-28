package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.RedundantUpcast;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `redundant-upcast` check: a runtime-checked cast `cast(x, T)` where `x`'s declared
 * type is a strict subtype of `T`, so the cast always succeeds and is a no-op. Same-type
 * (redundant-cast), unrelated (impossible-cast), downcast, external, generic, and
 * compile-time `(x : T)` are not flagged.
 */
class RedundantUpcastTest extends Test {

	public function testUpcastFlagged(): Void {
		Assert.equals(
			1, violations('class Base {} class Sub extends Base {} class C { function f(s:Sub) { var b = cast(s, Base); } }').length
		);
	}

	public function testInterfaceUpcastFlagged(): Void {
		// `cast(a:A, I)` where A implements I — always succeeds.
		Assert.equals(1, violations('interface I {} class A implements I {} class C { function f(a:A) { var b = cast(a, I); } }').length);
	}

	public function testSameTypeNotFlagged(): Void {
		// `cast(a, A)` — same type; that is redundant-cast's domain (isSubtype is strict).
		Assert.equals(0, violations('class A {} class C { function f(a:A) { var b = cast(a, A); } }').length);
	}

	public function testUnrelatedNotFlagged(): Void {
		// `cast(a:A, B)` — unrelated; impossible-cast's domain.
		Assert.equals(0, violations('class A {} class B {} class C { function f(a:A) { var b = cast(a, B); } }').length);
	}

	public function testDowncastNotFlagged(): Void {
		// `cast(b:Base, Sub)` — a downcast may fail at runtime; not redundant.
		Assert.equals(
			0, violations('class Base {} class Sub extends Base {} class C { function f(b:Base) { var x = cast(b, Sub); } }').length
		);
	}

	public function testExternalTypeNotFlagged(): Void {
		Assert.equals(0, violations('class A {} class C { function f(a:A) { var b = cast(a, String); } }').length);
	}

	public function testGenericTargetNotFlagged(): Void {
		Assert.equals(0, violations('class A {} class C { function f(a:A) { var b = cast(a, Array<Int>); } }').length);
	}

	public function testCompileTimeCheckNotFlagged(): Void {
		Assert.equals(0, violations('class Base {} class Sub extends Base {} class C { function f(s:Sub) { var b = (s : Base); } }').length);
	}

	public function testNonIdentifierOperandNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class Base {} class Sub extends Base {} class C { function f() { var b = cast(make(), Base); } function make():Sub return null; }'
			).length
		);
	}

	public function testFlaggedAsInfo(): Void {
		final vs: Array<Violation> =
			violations('class Base {} class Sub extends Base {} class C { function f(s:Sub) { var b = cast(s, Base); } }');
		Assert.equals(1, vs.length);
		Assert.equals('redundant-upcast', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testFixIsNoop(): Void {
		final check: RedundantUpcast = new RedundantUpcast();
		final src: String = 'class Base {} class Sub extends Base {} class C { function f(s:Sub) { var b = cast(s, Base); } }';
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		Assert.equals(0, edits.length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			new RedundantUpcast().run([{ file: 'Bad.hx', source: 'class Bad { function f() { var b = cast(a, ' }], new HaxeQueryPlugin())
				.length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('redundant-upcast'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-upcast'));
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantUpcast().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
