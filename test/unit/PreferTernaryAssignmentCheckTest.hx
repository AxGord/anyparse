package unit;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferIfExpressionAssignment;
import anyparse.check.PreferTernaryAssignment;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `prefer-ternary-assignment` check: an `if (cond) lhs = a; else lhs = b;`
 * whose two branches assign the same l-value with a plain `=` is flagged
 * `Info` and `fix` collapses the pair to `lhs = cond ? a : b;`. Only a real
 * `if`/`else` (no else-if) of two single-statement plain `=` assignments to a
 * textually identical l-value qualifies; a compound operator (`+=`, `??=`) is
 * excluded (collapsing it can change behaviour or break r-value unification);
 * the condition is parenthesised only when it binds no tighter than `?:`.
 */
class PreferTernaryAssignmentCheckTest extends Test {

	/** A flat 2-branch assignment whose ELSE r-value is a ternary — the third leaf, so `prefer-if-expression-assignment`'s. */
	private static inline final TERNARY_TAILED_ELSE: String =
		'class C {\n\tfunction f() {\n\t\tif (a) x = 1;\n\t\telse x = p ? q : r;\n\t}\n}';

	/** The same shape with a comment inside the ternary — the claiming rule fails closed, so this one keeps it. */
	private static inline final COMMENTED_TERNARY_TAIL: String =
		'class C {\n\tfunction f() {\n\t\tif (a) x = 1;\n\t\telse x = p /* why */ ? q : r;\n\t}\n}';

	public function testBasicFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f() {\n\t\tif (a) x = 1;\n\t\telse x = 2;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('prefer-ternary-assignment', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this if/else assignment can be a single ternary assignment', vs[0].message);
	}

	public function testFixBasic(): Void {
		final es: Array<{ span: Span, text: String }> = edits('class C {\n\tfunction f() {\n\t\tif (a) x = 1;\n\t\telse x = 2;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('x = a ? 1 : 2;', es[0].text);
	}

	public function testBracedBranchesFixed(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tx = 1;\n\t\t} else {\n\t\t\tx = 2;\n\t\t}\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('x = a ? 1 : 2;', es[0].text);
	}

	public function testFieldLvalueReproFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f() {\n\t\tif (value) _text.defaultTextFormat = _selectedTextFormat;\n'
			+ '\t\telse _text.defaultTextFormat = _blackTextFormat;\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('_text.defaultTextFormat = value ? _selectedTextFormat : _blackTextFormat;', es[0].text);
	}

	/** A compound operator (`+=`) is excluded — collapsing it can break r-value type unification. */
	public function testCompoundOperatorNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tif (a) x += 1;\n\t\telse x += 2;\n\t}\n}').length);
	}

	public function testCompoundDifferentOperatorNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tif (a) x += 1;\n\t\telse x -= 2;\n\t}\n}').length);
	}

	public function testPlainVsCompoundNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tif (a) x = 1;\n\t\telse x += 2;\n\t}\n}').length);
	}

	public function testDifferentLvalueNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tif (a) x = 1;\n\t\telse y = 2;\n\t}\n}').length);
	}

	public function testNoElseNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tif (a) x = 1;\n\t}\n}').length);
	}

	public function testElseIfChainNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f() {\n\t\tif (a) x = 1;\n\t\telse if (b) x = 2;\n\t\telse x = 3;\n\t}\n}').length
		);
	}

	public function testMultiStatementBranchNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tx = 1;\n\t\t\ty = 2;\n\t\t} else x = 3;\n\t}\n}').length
		);
	}

	public function testNonAssignmentBranchNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tif (a) g();\n\t\telse x = 2;\n\t}\n}').length);
	}

	public function testIncrementBranchesNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tif (a) x++;\n\t\telse x--;\n\t}\n}').length);
	}

	public function testTernaryConditionWrapped(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f() {\n\t\tif (a ? b : c) x = 1;\n\t\telse x = 2;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('x = (a ? b : c) ? 1 : 2;', es[0].text);
	}

	public function testComparisonConditionNotWrapped(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f() {\n\t\tif (x > 0) a = 1;\n\t\telse a = 2;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('a = x > 0 ? 1 : 2;', es[0].text);
	}

	public function testCommentInHeaderNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tif (a) /* keep */ x = 1;\n\t\telse x = 2;\n\t}\n}').length);
	}

	public function testNullGuardValueBranchesFlagged(): Void {
		// Value r-values: the collapse keeps the in-condition narrowing, so it is allowed.
		Assert.equals(
			1, violations('class C {\n\tfunction f(s:Null<S>) {\n\t\tif (s != null && s.g()) x = 1;\n\t\telse x = 2;\n\t}\n}').length
		);
	}

	public function testNullGuardBoolLiteralNotFlagged(): Void {
		// A bool-literal r-value hands off to simplify-boolean-ternary, whose flattening
		// would lose the narrowing — refused while the condition carries a null guard.
		Assert.equals(
			0, violations('class C {\n\tfunction f(s:Null<S>) {\n\t\tif (s != null && s.g()) x = true;\n\t\telse x = g();\n\t}\n}').length
		);
	}

	/** REPRODUCTION: a short-circuit `??=` must NOT be flagged — the ternary RHS is skipped when the l-value is non-null, so the conditions stop being evaluated (silent behaviour change). Currently flagged (bug). */
	public function testNullCoalAssignNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tif (a) x ??= 1;\n\t\telse x ??= 2;\n\t}\n}').length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	/**
	 * A flat `if`/`else` whose ELSE r-value is already a ternary is not this check's.
	 *
	 * RED at base, where this rule claimed it and collapsed it onto a value that is ALREADY a
	 * ternary — writing the three-rung `x = a ? 1 : p ? q : r`, which `prefer-if-expression-chain`
	 * then reports, on the text this fix had just written. Measured by S46 at 14 sites over 1029
	 * external files, taking that rule from 93 findings to 107. The site keeps a finding at the
	 * SAME line, from `prefer-if-expression-assignment`, whose single edit IS the canon.
	 */
	public function testTernaryTailedElseIsNotFlagged(): Void {
		Assert.equals(0, violations(TERNARY_TAILED_ELSE).length);
		Assert.equals(0, edits(TERNARY_TAILED_ELSE).length);
		// DETECT-PROOF, in one assertion with the deferral: the claiming rule really does own this
		// exact site, so the zeroes above are a deferral rather than a fixture this walk never
		// reached — and its edit is the canon, not another ternary.
		final claiming: PreferIfExpressionAssignment = new PreferIfExpressionAssignment();
		final own: Array<Violation> = claiming.run([{ file: 'C.hx', source: TERNARY_TAILED_ELSE }], new HaxeQueryPlugin());
		Assert.equals(1, own.length, 'prefer-if-expression-assignment claims the site: $own');
		final es: Array<{ span: Span, text: String }> = claiming.fix(TERNARY_TAILED_ELSE, own, new HaxeQueryPlugin());
		Assert.equals(1, es.length);
		Assert.equals('x = if (a) 1 else if (p) q else r;', es[0].text);
	}

	/**
	 * A comment inside that ternary keeps the site HERE, because the claiming rule refuses it.
	 *
	 * The deferral asks the other rule for its whole derivation, gates and all — the shape S46
	 * measured a mirror losing 14 of 69 sites to. A shape-only deferral would silence this check
	 * wherever the other one fails closed on a comment, and nobody would report the site at all.
	 */
	public function testCommentInTheTernaryTailKeepsTheFindingHere(): Void {
		Assert.equals(1, violations(COMMENTED_TERNARY_TAIL).length);
		Assert.equals(
			0, new PreferIfExpressionAssignment().run([{ file: 'C.hx', source: COMMENTED_TERNARY_TAIL }], new HaxeQueryPlugin()).length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-ternary-assignment'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-ternary-assignment'));
	}

	/**
	 * Two l-values differing ONLY by whitespace inside a string literal are two DIFFERENT
	 * l-values. The equality key was whitespace-normalised source, which collapses runs inside
	 * a literal too, so `m["a  b"]` and `m["a b"]` compared equal and `--fix` emitted
	 * `m["a  b"] = c ? 1 : 2;` — the else branch silently started writing a different map key.
	 * Reduced from the shipped binary; `structurallyEqual` now carries the literal content.
	 */
	public function testLValuesDifferingInsideAStringLiteralAreNotTheSame(): Void {
		final differing: String = 'class C {\n\tfunction f() {\n\t\tif (c) m["a  b"] = 1;\n\t\telse m["a b"] = 2;\n\t}\n}';
		Assert.equals(0, violations(differing).length, 'the two keys differ - collapsing them would change which entry is written');
		final same: String = 'class C {\n\tfunction f() {\n\t\tif (c) m["a  b"] = 1;\n\t\telse m["a  b"] = 2;\n\t}\n}';
		Assert.equals(1, violations(same).length, 'the identical key still collapses');
	}

	/**
	 * A whitespace RUN outside a literal is still normalised away — adding the shape test
	 * narrowed the key only where the projection differs, and layout does not reach it.
	 */
	public function testLValueLayoutDifferenceStillCollapses(): Void {
		final laidOut: String = 'class C {\n\tfunction f() {\n\t\tif (c) m[k\n\t\t\t] = 1;\n\t\telse m[k ] = 2;\n\t}\n}';
		Assert.equals(1, violations(laidOut).length, 'a newline+indent run and a single space still normalise equal');
	}

	private function violations(src: String): Array<Violation> {
		return new PreferTernaryAssignment().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: PreferTernaryAssignment = new PreferTernaryAssignment();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
