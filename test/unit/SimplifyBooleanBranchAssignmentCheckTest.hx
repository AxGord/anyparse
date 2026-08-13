package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.SimplifyBooleanBranchAssignment;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `simplify-boolean-branch-assignment` check: an `if`/`else` whose two branch blocks assign
 * opposite boolean literals to the same ordered set of two or more targets is flagged `Info`,
 * and `fix` replaces the whole `if` with one `lhs = cond;` / `lhs = !cond;` per target. The
 * condition must be a plain read path (it is duplicated once per target), must share no path
 * segment with any target (else a later statement would read an overwritten value), and the
 * `if` must sit in a statement list (a brace-less body position would strand every statement
 * after the first).
 */
class SimplifyBooleanBranchAssignmentCheckTest extends Test {

	public function testBasicFlagged(): Void {
		final vs: Array<Violation> = violations(twoTargets('flag'));
		Assert.equals(1, vs.length);
		Assert.equals('simplify-boolean-branch-assignment', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('these if/else branches can assign the condition to each target directly', vs[0].message);
	}

	public function testFixBasic(): Void {
		final es: Array<{ span: Span, text: String }> = edits(twoTargets('flag'));
		Assert.equals(1, es.length);
		Assert.equals('a = flag;\n\t\tb = !flag;', es[0].text);
	}

	/** The repro this check was written for: two bitmaps toggled by one property. */
	public function testFieldTargetsFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f() {\n\t\tif (selected) {\n\t\t\t_selectedBitmap.visible = true;\n\t\t\t_deselectedBitmap.visible = '
			+ 'false;\n\t\t} else {\n\t\t\t_selectedBitmap.visible = false;\n\t\t\t_deselectedBitmap.visible = true;\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('_selectedBitmap.visible = selected;\n\t\t_deselectedBitmap.visible = !selected;', es[0].text);
	}

	/** A negated condition sheds its `!` on the positive target rather than stacking `!!`. */
	public function testNegatedConditionFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(twoTargets('!flag'));
		Assert.equals(1, es.length);
		Assert.equals('a = !flag;\n\t\tb = flag;', es[0].text);
	}

	/** A field-path condition is a plain read, so it duplicates safely. */
	public function testFieldPathConditionFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(twoTargets('this.state.active'));
		Assert.equals(1, es.length);
		Assert.equals('a = this.state.active;\n\t\tb = !this.state.active;', es[0].text);
	}

	public function testThreeTargetsFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f() {\n\t\tif (flag) {\n\t\t\ta = true;\n\t\t\tb = false;\n\t\t\tc = true;\n'
			+ '\t\t} else {\n\t\t\ta = false;\n\t\t\tb = true;\n\t\t\tc = false;\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('a = flag;\n\t\tb = !flag;\n\t\tc = flag;', es[0].text);
	}

	/** A single target is `prefer-ternary-assignment`'s case — the two checks never both fire. */
	public function testSingleTargetNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f() {\n\t\tif (flag) {\n\t\t\ta = true;\n\t\t} else {\n\t\t\ta = false;\n\t\t}\n\t}\n}')
				.length
		);
	}

	/**
	 * The condition is assigned by the block, so `a = !a; b = a;` would read an overwritten
	 * value — the shared-segment gate refuses the site.
	 */
	public function testConditionAssignedNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\ta = false;\n\t\t\tb = true;\n'
				+ '\t\t} else {\n\t\t\ta = true;\n\t\t\tb = false;\n\t\t}\n\t}\n}'
			).length
		);
	}

	/** Same hazard through the `this.`-qualified spelling of the condition's own storage. */
	public function testQualifiedConditionAssignedNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tthis.a = false;\n\t\t\tb = true;\n'
				+ '\t\t} else {\n\t\t\tthis.a = true;\n\t\t\tb = false;\n\t\t}\n\t}\n}'
			).length
		);
	}

	/** Aliasing the condition's own field name through another receiver is refused too. */
	public function testSharedFieldNameNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f() {\n\t\tif (item.flag) {\n\t\t\tx.flag = true;\n\t\t\ty.on = false;\n'
				+ '\t\t} else {\n\t\t\tx.flag = false;\n\t\t\ty.on = true;\n\t\t}\n\t}\n}'
			).length
		);
	}

	/** A call condition would be evaluated once per target — refused. */
	public function testCallConditionNotFlagged(): Void {
		Assert.equals(0, violations(twoTargets('check()')).length);
	}

	/** A compound condition duplicates into a De Morgan negation that reads worse — refused. */
	public function testCompoundConditionNotFlagged(): Void {
		Assert.equals(0, violations(twoTargets('p && q')).length);
	}

	public function testComparisonConditionNotFlagged(): Void {
		Assert.equals(0, violations(twoTargets('n > 0')).length);
	}

	/** A `?.` access is its own kind, so a `Null<Bool>` condition never reaches the rewrite. */
	public function testNullSafeConditionNotFlagged(): Void {
		Assert.equals(0, violations(twoTargets('o?.flag')).length);
	}

	public function testIndexConditionNotFlagged(): Void {
		Assert.equals(0, violations(twoTargets('flags[0]')).length);
	}

	/** A target carrying the same literal in both branches is `tail-merge`'s job, not this one. */
	public function testSameLiteralTargetNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f() {\n\t\tif (flag) {\n\t\t\ta = true;\n\t\t\tb = true;\n'
				+ '\t\t} else {\n\t\t\ta = false;\n\t\t\tb = true;\n\t\t}\n\t}\n}'
			).length
		);
	}

	public function testValueRvalueNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f() {\n\t\tif (flag) {\n\t\t\ta = 1;\n\t\t\tb = 2;\n'
				+ '\t\t} else {\n\t\t\ta = 3;\n\t\t\tb = 4;\n\t\t}\n\t}\n}'
			).length
		);
	}

	public function testDifferentTargetOrderNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f() {\n\t\tif (flag) {\n\t\t\ta = true;\n\t\t\tb = false;\n'
				+ '\t\t} else {\n\t\t\tb = true;\n\t\t\ta = false;\n\t\t}\n\t}\n}'
			).length
		);
	}

	public function testCompoundAssignmentNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f() {\n\t\tif (flag) {\n\t\t\ta = true;\n\t\t\tb ??= false;\n'
				+ '\t\t} else {\n\t\t\ta = false;\n\t\t\tb ??= true;\n\t\t}\n\t}\n}'
			).length
		);
	}

	public function testNonAssignmentStatementNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f() {\n\t\tif (flag) {\n\t\t\ta = true;\n\t\t\tg();\n'
				+ '\t\t} else {\n\t\t\ta = false;\n\t\t\tg();\n\t\t}\n\t}\n}'
			).length
		);
	}

	public function testNoElseNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f() {\n\t\tif (flag) {\n\t\t\ta = true;\n\t\t\tb = false;\n\t\t}\n\t}\n}').length
		);
	}

	public function testElseIfChainNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f() {\n\t\tif (p) {\n\t\t\ta = true;\n\t\t\tb = false;\n\t\t} else if (flag) {\n\t\t\ta = true;\n'
				+ '\t\t\tb = false;\n\t\t} else {\n\t\t\ta = false;\n\t\t\tb = true;\n\t\t}\n\t}\n}'
			).length
		);
	}

	/**
	 * A brace-less body position: the rewrite emits several statements, and only the first would
	 * stay inside the loop — so the site is refused rather than silently moved.
	 */
	public function testBracelessBodyPositionNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f() {\n\t\tfor (x in xs) if (flag) {\n\t\t\ta = true;\n\t\t\tb = false;\n'
				+ '\t\t} else {\n\t\t\ta = false;\n\t\t\tb = true;\n\t\t}\n\t}\n}'
			).length
		);
	}

	/** A comment in a dropped region (the else branch) would be lost by the rebuild. */
	public function testCommentInElseNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f() {\n\t\tif (flag) {\n\t\t\ta = true;\n\t\t\tb = false;\n'
				+ '\t\t} else {\n\t\t\t// keep\n\t\t\ta = false;\n\t\t\tb = true;\n\t\t}\n\t}\n}'
			).length
		);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('simplify-boolean-branch-assignment'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('simplify-boolean-branch-assignment'));
	}

	private function twoTargets(cond: String): String {
		return 'class C {\n\tfunction f() {\n\t\tif ($cond) {\n\t\t\ta = true;\n\t\t\tb = false;\n'
			+ '\t\t} else {\n\t\t\ta = false;\n\t\t\tb = true;\n\t\t}\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new SimplifyBooleanBranchAssignment().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: SimplifyBooleanBranchAssignment = new SimplifyBooleanBranchAssignment();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
