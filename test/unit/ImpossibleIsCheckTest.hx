package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.ImpossibleIsCheck;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `impossible-is-check` check: an `is` type-check `x is T` that is provably ALWAYS
 * FALSE — `x`'s declared type `S` and the checked type `T` are two unrelated classes,
 * so under Haxe single inheritance no value of `S` can be a `T`. Conservative: both
 * sides must resolve to a unique indexed class with fully index-resolved supertype
 * closures; an interface, an external/un-indexed type, a generic, or an unresolved
 * supertype link keeps the conservative default (not flagged).
 */
class ImpossibleIsCheckTest extends Test {

	public function testUnrelatedClassesFlagged(): Void {
		Assert.equals(1, violations('class A {} class B {} class C { function f(a:A) { var b = a is B; } }').length);
	}

	public function testSameTypeNotFlagged(): Void {
		// `a:A is A` — same type; never an unrelated-class pair, so not flagged.
		Assert.equals(0, violations('class A {} class C { function f(a:A) { var b = a is A; } }').length);
	}

	public function testSubtypeOperandNotFlagged(): Void {
		// `s:Sub is Base` — Base is a supertype of Sub; always true, not always false.
		Assert.equals(0, violations('class Base {} class Sub extends Base {} class C { function f(s:Sub) { var b = s is Base; } }').length);
	}

	public function testSupertypeOperandNotFlagged(): Void {
		// `b:Base is Sub` — may be true at runtime (b could hold a Sub).
		Assert.equals(0, violations('class Base {} class Sub extends Base {} class C { function f(b:Base) { var x = b is Sub; } }').length);
	}

	public function testInterfaceCheckedNotFlagged(): Void {
		// `a:A is I` — any subclass of A could implement interface I (open world).
		Assert.equals(0, violations('interface I {} class A {} class C { function f(a:A) { var b = a is I; } }').length);
	}

	public function testInterfaceOperandNotFlagged(): Void {
		// `i:I is B` — i could be any implementor, some of which subclass B.
		Assert.equals(0, violations('interface I {} class B {} class C { function f(i:I) { var b = i is B; } }').length);
	}

	public function testExternalTypeNotFlagged(): Void {
		// `String` is not in the indexed corpus — its hierarchy is unknown.
		Assert.equals(0, violations('class A {} class C { function f(a:A) { var b = a is String; } }').length);
	}

	public function testGenericOperandNotFlagged(): Void {
		Assert.equals(0, violations('class B {} class C { function f(a:Array<Int>) { var b = a is B; } }').length);
	}

	public function testGenericCheckedNotFlagged(): Void {
		Assert.equals(0, violations('class A {} class C { function f(a:A) { var b = a is Array<Int>; } }').length);
	}

	public function testUnresolvedSupertypeNotFlagged(): Void {
		// Sub extends Mid, but Mid is not in the lint set — Sub's closure is not fully
		// resolved, so its relation to Top is unknown → not flagged (soundness guard).
		Assert.equals(0, violations('class Sub extends Mid {} class Top {} class C { function f(s:Sub) { var b = s is Top; } }').length);
	}

	public function testFlaggedAsWarning(): Void {
		final vs: Array<Violation> = violations('class A {} class B {} class C { function f(a:A) { var b = a is B; } }');
		Assert.equals(1, vs.length);
		Assert.equals('impossible-is-check', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	public function testFixIsNoop(): Void {
		final check: ImpossibleIsCheck = new ImpossibleIsCheck();
		final src: String = 'class A {} class B {} class C { function f(a:A) { var b = a is B; } }';
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		Assert.equals(0, edits.length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			new ImpossibleIsCheck().run([{ file: 'Bad.hx', source: 'class Bad { function f() { var b = x is ' }], new HaxeQueryPlugin())
				.length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('impossible-is-check'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('impossible-is-check'));
	}

	public function testUnrelatedSiblingsFlagged(): Void {
		// A and B share a common base but neither is the other's ancestor — exercises the
		// recursive closure walk reaching Base and still proving the pair unrelated.
		Assert.equals(
			1,
			violations('class Base {} class A extends Base {} class B extends Base {} class C { function f(a:A) { var b = a is B; } }').length
		);
	}

	public function testNonIdentifierOperandNotFlagged(): Void {
		// A non-identifier operand has no resolvable declared type → skip.
		Assert.equals(
			0, violations('class A {} class B {} class C { function f() { var b = make() is B; } function make():A return null; }').length
		);
	}

	private function violations(src: String): Array<Violation> {
		return new ImpossibleIsCheck().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
