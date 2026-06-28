package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.ImpossibleCast;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `impossible-cast` check: a runtime-checked cast `cast(x, T)` that can never succeed
 * because `x`'s declared type `S` and the target `T` are two unrelated classes — the cast
 * always throws. Only the runtime `cast(x, T)` form is inspected (not the compile-time
 * `(x : T)`). Same-type, subtype either direction, interface, external/un-indexed, and
 * generic targets keep the conservative default.
 */
class ImpossibleCastTest extends Test {

	public function testUnrelatedClassesFlagged(): Void {
		Assert.equals(1, violations('class A {} class B {} class C { function f(a:A) { var b = cast(a, B); } }').length);
	}

	public function testSameTypeNotFlagged(): Void {
		// `cast(a, A)` — same type; that is redundant-cast's domain, not an impossible cast.
		Assert.equals(0, violations('class A {} class C { function f(a:A) { var b = cast(a, A); } }').length);
	}

	public function testUpcastNotFlagged(): Void {
		// `cast(s:Sub, Base)` — Sub<:Base, the upcast always succeeds.
		Assert.equals(
			0, violations('class Base {} class Sub extends Base {} class C { function f(s:Sub) { var b = cast(s, Base); } }').length
		);
	}

	public function testDowncastNotFlagged(): Void {
		// `cast(b:Base, Sub)` — may succeed at runtime (b could hold a Sub).
		Assert.equals(
			0, violations('class Base {} class Sub extends Base {} class C { function f(b:Base) { var x = cast(b, Sub); } }').length
		);
	}

	public function testInterfaceTargetNotFlagged(): Void {
		// `cast(a, I)` — a subclass of A could implement interface I (open world).
		Assert.equals(0, violations('interface I {} class A {} class C { function f(a:A) { var b = cast(a, I); } }').length);
	}

	public function testExternalTypeNotFlagged(): Void {
		Assert.equals(0, violations('class A {} class C { function f(a:A) { var b = cast(a, String); } }').length);
	}

	public function testGenericTargetNotFlagged(): Void {
		Assert.equals(0, violations('class A {} class C { function f(a:A) { var b = cast(a, Array<Int>); } }').length);
	}

	public function testCompileTimeCheckNotFlagged(): Void {
		// `(a : B)` is a compile-time ascription (ECheckTypeExpr), not the runtime cast form.
		Assert.equals(0, violations('class A {} class B {} class C { function f(a:A) { var b = (a : B); } }').length);
	}

	public function testNonIdentifierOperandNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class A {} class B {} class C { function f() { var b = cast(make(), B); } function make():A return null; }').length
		);
	}

	public function testFlaggedAsWarning(): Void {
		final vs: Array<Violation> = violations('class A {} class B {} class C { function f(a:A) { var b = cast(a, B); } }');
		Assert.equals(1, vs.length);
		Assert.equals('impossible-cast', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	public function testFixIsNoop(): Void {
		final check: ImpossibleCast = new ImpossibleCast();
		final src: String = 'class A {} class B {} class C { function f(a:A) { var b = cast(a, B); } }';
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		Assert.equals(0, edits.length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			new ImpossibleCast().run([{ file: 'Bad.hx', source: 'class Bad { function f() { var b = cast(a, ' }], new HaxeQueryPlugin())
				.length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('impossible-cast'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('impossible-cast'));
	}

	private function violations(src: String): Array<Violation> {
		return new ImpossibleCast().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
