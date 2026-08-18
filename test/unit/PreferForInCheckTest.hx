package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferForIn;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `prefer-for-in` check: a hand-rolled iterator protocol
 * `while (it.hasNext()) { final x = it.next(); … }` is flagged `Info` and rewritten to
 * `for (x in it) { … }`. The `for` form desugars to exactly that loop, so the rewrite is
 * behaviour-preserving including `break` / `continue` and the iterator's exhausted state after
 * the loop.
 *
 * Two arms. The plain arm rewrites the loop alone and leaves the iterator binding in place. The
 * INLINING arm fires when the statement immediately before the loop DECLARES the iterator and
 * nothing else in the scope reads it — then the declaration is dropped and its initializer
 * becomes the `for` iterable.
 *
 * The refusals carry the census that motivated the rule: a bare non-emptiness test
 * `if (it.hasNext())`, the peek idiom `it.hasNext() ? it.next() : null`, a second `it.next()` in
 * the body, a body whose first statement is not the `next()` binding, a one-statement body (a
 * pure drain, which would leave an empty loop), and an iterator read after the loop (which
 * refuses only the INLINING arm, not the rewrite).
 */
class PreferForInCheckTest extends Test {

	public function testFlagged(): Void {
		final vs: Array<Violation> = violations(fn('while (it.hasNext()) {\n\t\t\tfinal cp = it.next();\n\t\t\tuse(cp);\n\t\t}'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-for-in', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('for-in') != -1);
	}

	public function testPlainArmFixed(): Void {
		Assert.equals(
			fn('for (cp in it) {\n\t\t\tuse(cp);\n\t\t}'),
			applyFix(fn('while (it.hasNext()) {\n\t\t\tfinal cp = it.next();\n\t\t\tuse(cp);\n\t\t}'))
		);
	}

	public function testAnnotationOnBinderDropped(): Void {
		Assert.equals(
			fn('for (cp in it) {\n\t\t\tuse(cp);\n\t\t}'),
			applyFix(fn('while (it.hasNext()) {\n\t\t\tfinal cp:Int = it.next();\n\t\t\tuse(cp);\n\t\t}'))
		);
	}

	public function testVarBinderFixed(): Void {
		// A `for` binder IS writable in Haxe (measured on --interp, -js and -cpp), so a `var`
		// binding the body reassigns converts as safely as a `final` one.
		Assert.equals(
			fn('for (cp in it) {\n\t\t\tcp = 0;\n\t\t\tuse(cp);\n\t\t}'),
			applyFix(fn('while (it.hasNext()) {\n\t\t\tvar cp = it.next();\n\t\t\tcp = 0;\n\t\t\tuse(cp);\n\t\t}'))
		);
	}

	public function testLeadingCommentInBodyKept(): Void {
		Assert.equals(
			fn('for (cp in it) {\n\t\t\t// note\n\t\t\tuse(cp);\n\t\t}'),
			applyFix(fn('while (it.hasNext()) {\n\t\t\t// note\n\t\t\tfinal cp = it.next();\n\t\t\tuse(cp);\n\t\t}'))
		);
	}

	public function testInliningArmDropsTheDeclaration(): Void {
		Assert.equals(
			fn('for (cp in xs.iterator()) {\n\t\t\tuse(cp);\n\t\t}'),
			applyFix(fn('final iter = xs.iterator();\n\t\twhile (iter.hasNext()) {\n\t\t\tfinal cp = iter.next();\n\t\t\tuse(cp);\n\t\t}'))
		);
	}

	public function testIteratorReadAfterLoopKeepsTheDeclaration(): Void {
		Assert.equals(
			fn('final iter = xs.iterator();\n\t\tfor (cp in iter) {\n\t\t\tuse(cp);\n\t\t}\n\t\tuse(iter);'),
			applyFix(fn(
				'final iter = xs.iterator();\n\t\twhile (iter.hasNext()) {\n\t\t\tfinal cp = iter.next();\n\t\t\tuse(cp);\n\t\t}\n\t\tuse(iter);'
			))
		);
	}

	public function testCommentBetweenDeclAndLoopKeepsTheDeclaration(): Void {
		Assert.equals(
			fn('final iter = xs.iterator();\n\t\t// note\n\t\tfor (cp in iter) {\n\t\t\tuse(cp);\n\t\t}'),
			applyFix(fn(
				'final iter = xs.iterator();\n\t\t// note\n\t\twhile (iter.hasNext()) {\n\t\t\tfinal cp = iter.next();\n\t\t\tuse(cp);\n\t\t}'
			))
		);
	}

	public function testNonEmptinessCheckNotFlagged(): Void {
		Assert.equals(0, violations(fn('if (it.hasNext()) use(1);')).length);
	}

	public function testPeekIdiomNotFlagged(): Void {
		Assert.equals(0, violations(fn('final v = it.hasNext() ? it.next() : null;\n\t\tuse(v);')).length);
	}

	public function testSecondNextInBodyNotFlagged(): Void {
		Assert.equals(
			0,
			violations(fn('while (it.hasNext()) {\n\t\t\tfinal a = it.next();\n\t\t\tfinal b = it.next();\n\t\t\tuse(a + b);\n\t\t}'))
				.length
		);
	}

	public function testBodyNotStartingWithTheBindingNotFlagged(): Void {
		Assert.equals(
			0, violations(fn('while (it.hasNext()) {\n\t\t\tuse(0);\n\t\t\tfinal cp = it.next();\n\t\t\tuse(cp);\n\t\t}')).length
		);
	}

	public function testUnbracedBodyNotFlagged(): Void {
		Assert.equals(0, violations(fn('while (it.hasNext()) out.push(it.next());')).length);
	}

	public function testDrainOnlyBodyNotFlagged(): Void {
		Assert.equals(0, violations(fn('while (it.hasNext()) {\n\t\t\tfinal cp = it.next();\n\t\t}')).length);
	}

	public function testBinderNamedAfterTheIteratorNotFlagged(): Void {
		// The body must NOT re-read the name, or the occurrence gate refuses first and this
		// fixture would prove nothing about the binder-collision gate it is written for.
		Assert.equals(0, violations(fn('while (it.hasNext()) {\n\t\t\tfinal it = it.next();\n\t\t\tuse(0);\n\t\t}')).length);
	}

	public function testQualifiedReceiverNotFlagged(): Void {
		Assert.equals(0, violations(fn('while (this.it.hasNext()) {\n\t\t\tfinal cp = this.it.next();\n\t\t\tuse(cp);\n\t\t}')).length);
	}

	public function testInterpolatedIteratorUseNotFlagged(): Void {
		Assert.equals(0, violations(fn("while (it.hasNext()) {\n\t\t\tfinal cp = it.next();\n\t\t\tuse('$it');\n\t\t}")).length);
	}

	public function testMacroReificationNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tmacro function f() {\n\t\treturn macro {\n\t\t\twhile (it.hasNext()) {\n\t\t\t\tfinal cp = it.next();'
				+ '\n\t\t\t\tuse(cp);\n\t\t\t}\n\t\t};\n\t}\n}'
			).length
		);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { while (it.hasNext()) { final cp = it.next(); use(cp);').length);
	}

	public function testRegisteredAndDefaultOff(): Void {
		final check: Null<Check> = Linter.byId('prefer-for-in');
		Assert.notNull(check);
		Assert.isTrue(Std.isOfType(check, DefaultOff), 'prefer-for-in is opt-in');
	}

	private function fn(stmts: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>, it:Iterator<Int>, out:Array<Int>):Void {\n\t\t$stmts\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new PreferForIn().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function applyFix(source: String): String {
		return CheckFixture.fixedSource(new PreferForIn(), source);
	}

}
