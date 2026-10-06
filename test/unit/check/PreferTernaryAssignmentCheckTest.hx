package unit.check;

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

	/** An `untyped` condition would swallow the `? 1 : 2` bare; `ParenGuard` gives it the pair. */
	public function testUntypedConditionWrapped(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f() {\n\t\tif (untyped c) x = 1;\n\t\telse x = 2;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('x = (untyped c) ? 1 : 2;', es[0].text);
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

	/**
	 * REPRODUCTION: a short-circuit `??=` must NOT be flagged — the ternary RHS is skipped when the l-value
	 * is non-null, so the conditions stop being evaluated (silent behaviour change). Currently flagged (bug).
	 */
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
	 * then reports, on the text this fix had just written. Seen at a dozen sites over the
	 * external corpora, each adding a finding to that rule. The site keeps a finding at the
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
	 * The deferral asks the other rule for its whole derivation, gates and all — the shape a
	 * mirror was seen losing a fifth of its sites to. A shape-only deferral would silence this check
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

	/** The decl arm: the declaration supplies the value of the missing `else`, keyed on the declaration. */
	public function testDeclSinglePlainBranchFolded(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tvar k:Int = -1;\n\t\tif (id == 1) k = 5;\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('this declaration and the else-less if assignment after it can be a single ternary initializer', vs[0].message);
		Assert.equals(src.indexOf('var k'), vs[0].span?.from);
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.equals('var k:Int = id == 1 ? 5 : -1;', es[0].text);
	}

	/** The condition stays a `ParenGuard` hole in the decl arm too. */
	public function testDeclConditionParenthesised(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f() {\n\t\tvar k:Int = 0;\n\t\tif (p ? q : r) k = 5;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('var k:Int = (p ? q : r) ? 5 : 0;', es[0].text);
	}

	/** Two or more branches are `prefer-if-expression-assignment`'s decl arm — the split is `DeclFallbackChain.ownedByTernary`. */
	public function testDeclChainNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f() {\n\t\tvar k:Int = 0;\n\t\tif (a) k = 5;\n\t\telse if (b) k = 6;\n\t}\n}').length
		);
	}

	/** The ordinary arm's narrowing refusal: a bool-literal collapse would hand the guard to a flattening that loses it. */
	@:pin('control') @:killer('M-DECLTERN-NARROWING')
	public function testDeclNullNarrowingBoolNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f() {\n\t\tvar b:Bool = false;\n\t\tif (o != null && o.f) b = true;\n\t}\n}').length
		);
	}

	/** A comment in a region the rebuild drops (the `if` header, the target) refuses the site. */
	@:pin('control') @:killer('M-DECLTERN-COMMENT')
	public function testDeclDroppedCommentNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tvar k:Int = 0;\n\t\tif (a) /* why */ k = 5;\n\t}\n}').length);
	}

	/**
	 * A decl arm whose ternary would only pass a nullable value through writes the value: the shape
	 * `LanguageManager.t` had, which the ternary-then-`??` cascade turned into `strKey ?? null`.
	 */
	@:pin('control') @:killer('M-PASSTHROUGH-TERNARY')
	public function testDeclNullPassThroughWritesTheValue(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction t(?strKey:String, ?intKey:Int) {\n\t\tvar key:String = null;\n\t\tif (strKey != null) key = strKey;\n'
			+ '\t\tif (intKey != null) key = \'$$intKey\';\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('var key:String = strKey;', es[0].text);
	}

	/** The ordinary arm too, in both comparison spellings. */
	@:pin('control') @:killer('M-PASSTHROUGH-TERNARY')
	public function testNullPassThroughAssignmentWritesTheValue(): Void {
		final notEq: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f() {\n\t\tif (x != null) y = x;\n\t\telse y = null;\n\t}\n}');
		Assert.equals(1, notEq.length);
		Assert.equals('y = x;', notEq[0].text);
		final eq: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f() {\n\t\tif (null == x) y = null;\n\t\telse y = x;\n\t}\n}');
		Assert.equals(1, eq.length);
		Assert.equals('y = x;', eq[0].text);
	}

	/** A guarded value that calls is evaluated twice by the ternary, so it keeps the ternary. */
	@:pin('control') @:killer('M-NULLPASS-MUTATES')
	public function testMutatingPassThroughKeepsTheTernary(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f() {\n\t\tvar k:String = null;\n\t\tif (g() != null) k = g();\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('var k:String = g() != null ? g() : null;', es[0].text);
	}

	/** A fallback other than `null` is an ordinary ternary. */
	public function testNonNullFallbackKeepsTheTernary(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f() {\n\t\tvar k:String = \'d\';\n\t\tif (s != null) k = s;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('var k:String = s != null ? s : \'d\';', es[0].text);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferTernaryAssignment().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: PreferTernaryAssignment = new PreferTernaryAssignment();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
