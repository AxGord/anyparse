package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.JoinDeclarationAssignment;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * The `join-declaration-assignment` check: a bare local declaration immediately followed by
 * its first plain `=` assignment is flagged `Info`, and `fix` joins them into
 * `<decl> = <rhs>;` -- keyword and `:type` preserved (the `var`->`final` upgrade is
 * `prefer-final`'s job). A declaration with an initializer, a non-adjacent assignment, an
 * assignment to a member / index / different name, a compound operator, an r-value that
 * references the declared name, a multi-declarator, and a comment in a dropped region are
 * all safe misses.
 */
class JoinDeclarationAssignmentCheckTest extends Test {

	public function testBasicFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('var x;\n\t\tx = 1;'));
		Assert.equals(1, vs.length);
		Assert.equals('join-declaration-assignment', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this declaration and its next-line assignment can be joined into an initialized declaration', vs[0].message);
	}

	public function testFixVar(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('var x;\n\t\tx = 1 + 2;'));
		Assert.equals(1, es.length);
		Assert.equals('var x = 1 + 2;', es[0].text);
	}

	/** The `final` keyword is preserved (a definite-assignment `final`). */
	public function testFixFinalKeepsKeyword(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('final x;\n\t\tx = 1;'));
		Assert.equals(1, es.length);
		Assert.equals('final x = 1;', es[0].text);
	}

	/** A `:type` annotation is preserved verbatim. */
	public function testFixTypedKeepsType(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('var x:Int;\n\t\tx = 1;'));
		Assert.equals(1, es.length);
		Assert.equals('var x:Int = 1;', es[0].text);
	}

	public function testAlreadyInitializedNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x = 0;\n\t\tx = 1;')).length);
	}

	/** A statement between the declaration and the assignment blocks the join (evaluation would reorder). */
	public function testNonAdjacentNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x;\n\t\tg();\n\t\tx = 1;')).length);
	}

	public function testAssignToFieldNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x;\n\t\tx.f = 1;')).length);
	}

	public function testAssignToIndexNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x;\n\t\tx[0] = 1;')).length);
	}

	public function testAssignToDifferentNameNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x;\n\t\ty = 1;')).length);
	}

	public function testCompoundAssignNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x;\n\t\tx += 1;')).length);
	}

	/** `var x; x = x + 1;` reads an uninitialized x — joining it is a self-reference compile error. */
	public function testRhsReferencesNameNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x;\n\t\tx = x + 1;')).length);
	}

	/** A braceless `$name` interpolation is a self-reference too — it projects as a distinct kind, not `IdentExpr`. */
	public function testRhsInterpolationReferencesNameNotFlagged(): Void {
		Assert.equals(0, violations(wrap("var y:String;\n\t\ty = 'v $y';")).length);
	}

	/** A multi-declarator (`var a, b;`) projects as one decl but must never be joined. */
	public function testMultiDeclaratorNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var a, b;\n\t\ta = 1;')).length);
	}

	/** A comma INSIDE a generic type is not a second declarator — a typed single-var decl still joins. */
	public function testTypeCommaStillFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('var m:Map<Int, String>;\n\t\tm = null;'));
		Assert.equals(1, es.length);
		Assert.equals('var m:Map<Int, String> = null;', es[0].text);
	}

	/** A function-type arrow inside a type param must not confuse the comma scan. */
	public function testFunctionTypeCommaStillFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('var m:Map<Int->Int, String>;\n\t\tm = null;'));
		Assert.equals(1, es.length);
		Assert.equals('var m:Map<Int->Int, String> = null;', es[0].text);
	}

	/** A comment between the declaration and the assignment would be dropped by the join. */
	public function testCommentInDroppedRegionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x;\n\t\t// note\n\t\tx = 1;')).length);
	}

	/** End-to-end through the canonical writer: the emitted file holds the joined declaration. */
	public function testFixOutputJoins(): Void {
		final out: String = applyFixOnce(wrap('var x;\n\t\tx = 1 + 2;'));
		Assert.isTrue(out.indexOf('var x = 1 + 2;') != -1);
		Assert.equals(-1, out.indexOf('\tx = 1 + 2;')); // the standalone assignment line is gone
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('join-declaration-assignment'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('join-declaration-assignment'));
	}

	/** Wrap a statement body in a minimal parseable class + method. */
	private function wrap(body: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$body\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new JoinDeclarationAssignment().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: JoinDeclarationAssignment = new JoinDeclarationAssignment();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

	/** Run `fix` and re-emit through the canonical writer — the `lint --fix` path in one pass. */
	private function applyFixOnce(src: String): String {
		return switch RefactorSupport.canonicalize(src, edits(src), true, new HaxeQueryPlugin(), null) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}
