package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferIfExpressionAssignment;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * The `prefer-if-expression-assignment` check: an `if / else if / … / else` CHAIN whose
 * every branch assigns the same l-value with the same operator is flagged `Info`, and
 * `fix` collapses it to `lhs op if (c1) a else if (c2) b … else n;`. Disjoint from
 * `prefer-ternary-assignment` (which owns the 2-branch case): only a chain with at least
 * one `else if` terminating in a plain `else`, of single-statement same-l-value / same-op
 * assignments, qualifies. Unlike the ternary sibling a null-narrowing condition IS
 * flagged — the if-expression preserves the narrowing.
 */
class PreferIfExpressionAssignmentCheckTest extends Test {

	public function testBasicChainFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('if (a) x = 1;\n\t\telse if (b) x = 2;\n\t\telse x = 3;'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-if-expression-assignment', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this if/else-if assignment chain can be a single if-expression assignment', vs[0].message);
	}

	public function testFixThreeBranch(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('if (a) x = 1;\n\t\telse if (b) x = 2;\n\t\telse x = 3;'));
		Assert.equals(1, es.length);
		Assert.equals('x = if (a) 1 else if (b) 2 else 3;', es[0].text);
	}

	public function testFixFourBranch(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) x = 1;\n\t\telse if (b) x = 2;\n\t\telse if (c) x = 3;\n\t\telse x = 4;'));
		Assert.equals(1, es.length);
		Assert.equals('x = if (a) 1 else if (b) 2 else if (c) 3 else 4;', es[0].text);
	}

	public function testBracedBranchesFixed(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) {\n\t\t\tx = 1;\n\t\t} else if (b) {\n\t\t\tx = 2;\n\t\t} else {\n\t\t\tx = 3;\n\t\t}'));
		Assert.equals(1, es.length);
		Assert.equals('x = if (a) 1 else if (b) 2 else 3;', es[0].text);
	}

	public function testFieldLvalueFixed(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) button.x = p;\n\t\telse if (b) button.x = q;\n\t\telse button.x = r;'));
		Assert.equals(1, es.length);
		Assert.equals('button.x = if (a) p else if (b) q else r;', es[0].text);
	}

	/** A compound operator (`+=`) is excluded — collapsing it can break per-branch type unification. */
	public function testCompoundOperatorNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) x += 1;\n\t\telse if (b) x += 2;\n\t\telse x += 3;')).length);
	}

	/** A short-circuit `??=` is excluded — collapsing would skip the conditions when the l-value is non-null. */
	public function testNullCoalAssignNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) x ??= 1;\n\t\telse if (b) x ??= 2;\n\t\telse x ??= 3;')).length);
	}

	/** The 2-branch case is `prefer-ternary-assignment` territory, never this rule's. */
	public function testTwoBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) x = 1;\n\t\telse x = 2;')).length);
	}

	/** A chain with no terminal `else` has no value on the missing path — not collapsible. */
	public function testNoTerminalElseNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) x = 1;\n\t\telse if (b) x = 2;')).length);
	}

	public function testDifferentLvalueNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) x = 1;\n\t\telse if (b) y = 2;\n\t\telse x = 3;')).length);
	}

	public function testDifferentOperatorNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) x = 1;\n\t\telse if (b) x += 2;\n\t\telse x = 3;')).length);
	}

	public function testMultiStatementBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) {\n\t\t\tx = 1;\n\t\t\ty = 2;\n\t\t} else if (b) x = 2;\n\t\telse x = 3;')).length);
	}

	public function testNonAssignmentBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) x = 1;\n\t\telse if (b) g();\n\t\telse x = 3;')).length);
	}

	/**
	 * A comment between a branch's condition and its r-value sits where only the `)`, a `{` and
	 * the dropped l-value are, so the collapse CARRIES it into that branch's leading slot instead
	 * of failing closed — it keeps the position the author gave it.
	 */
	public function testCommentBetweenConditionAndValueCarried(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('if (a) x = 1;\n\t\telse if (b) /* keep */ x = 2;\n\t\telse x = 3;'));
		Assert.equals(1, es.length);
		Assert.equals('x = if (a) 1 else if (b) /* keep */ 2 else 3;', es[0].text);
	}

	/**
	 * The TM `PitchAreaX.addPlayerToPitchX` shape (anonymized): a braced branch whose own-line
	 * comment precedes its single assignment. It rides the branch's leading slot and KEEPS its
	 * line — pulled onto the `else if (…)` line it would re-read as being about the condition.
	 */
	public function testOwnLineCommentInBracedBranchCarried(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap(
			'if (isFirstGroup) {\n\t\t\tx = new AlphaEntry(info);\n\t\t} else if (isOtherGroup) {\n\t\t\t// TODO: handle info later when it arrives from an open item\n\t\t\tx = new BetaEntry(info, true, true);\n\t\t} else {\n\t\t\tx = new BetaEntry(info, true, false);\n\t\t}'
		));
		Assert.equals(1, es.length);
		Assert.equals(
			'x = if (isFirstGroup) new AlphaEntry(info) else if (isOtherGroup)\n'
			+ '// TODO: handle info later when it arrives from an open item\n'
			+ 'new BetaEntry(info, true, true) else new BetaEntry(info, true, false);',
			es[0].text
		);
	}

	/** A comment at the END of a branch's own line rides that branch's r-value, and the ` else ` moves to the next line. */
	public function testTrailingLineCommentRidesItsBranch(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('if (a) x = 1; // one\n\t\telse if (b) x = 2;\n\t\telse x = 3;'));
		Assert.equals(1, es.length);
		Assert.equals('x = if (a) 1 // one\nelse if (b) 2 else 3;', es[0].text);
	}

	/** A comment on its own line BEFORE the `else` still describes the branch that ends there — it rides the trailing slot and keeps its line. */
	public function testOwnLineCommentBeforeElseCarried(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) x = 1;\n\t\t// which branch?\n\t\telse if (b) x = 2;\n\t\telse x = 3;'));
		Assert.equals(1, es.length);
		Assert.equals('x = if (a) 1\n// which branch?\nelse if (b) 2 else 3;', es[0].text);
	}

	/**
	 * Past the `else` the comment describes the branch that FOLLOWS, and the parser projects no
	 * node for that keyword — so the trailing slot is gated on what SEPARATES the comment from
	 * the value (whitespace / `;` / `}` only), and this site keeps failing closed.
	 */
	public function testCommentAfterElseNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) x = 1; else // about the b branch\n\t\tif (b) x = 2;\n\t\telse x = 3;')).length);
	}

	/**
	 * A branch whose value is a NESTED construct is several copied pieces, not one, so it opens
	 * no seat and a comment in front of it has nowhere to ride — the site stays refused. The
	 * carry is a slot around a single copied r-value, never a guess at a construct's interior.
	 */
	public function testCommentBeforeNestedConstructBranchNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap(
				'if (a) x = 1;\n\t\telse if (b) /* keep */ switch s {\n\t\t\tcase 1: x = 2;\n\t\t\tcase _: x = 3;\n\t\t}\n\t\telse x = 4;'
			)).length
		);
	}

	/**
	 * A null-narrowing guard condition IS flagged and collapsed — the if-expression keeps
	 * the verbatim `if (…)` condition, so the branch runs under the same narrowing (this is
	 * where the rule differs from `prefer-ternary-assignment`, which skips such conditions).
	 */
	public function testNullNarrowingChainFlagged(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (s != null && s.g()) x = 1;\n\t\telse if (b) x = 2;\n\t\telse x = 3;'));
		Assert.equals(1, es.length);
		Assert.equals('x = if (s != null && s.g()) 1 else if (b) 2 else 3;', es[0].text);
	}

	/** A chain yields exactly ONE finding (the head), not one per `else if` link. */
	public function testChainFlaggedOnce(): Void {
		Assert.equals(1, violations(wrap('if (a) x = 1;\n\t\telse if (b) x = 2;\n\t\telse if (c) x = 3;\n\t\telse x = 4;')).length);
	}

	/** End-to-end through the canonical writer: the emitted file holds the collapsed assignment, valid Haxe (canonicalize re-parses it). */
	public function testFixOutputCollapsesChain(): Void {
		final out: String = applyFixOnce(wrap('if (a) x = 1;\n\t\telse if (b) x = 2;\n\t\telse x = 3;'));
		Assert.isTrue(out.indexOf('x = if (a) 1 else if (b) 2 else 3;') != -1);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-if-expression-assignment'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-if-expression-assignment'));
	}

	/**
	 * The driving recursive case: a 2-branch `if`/`else` whose else-branch is a `switch` assigning the
	 * same l-value hoists to `x = if (c) v else switch subj { … };` — the if-expression form with the
	 * switch-expression as its else value. A flat 2-branch is the ternary rule's, but a nested-construct
	 * branch is not a plain assignment, so this rule claims it.
	 */
	public function testSwitchInElseFlagged(): Void {
		final src: String = wrap(
			'if (a) x = f();\n\t\telse switch line {\n\t\t\tcase \'3.1\': x = \'a\';\n\t\t\tcase _: x = \'b\';\n\t\t}'
		);
		Assert.equals(1, violations(src).length);
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.equals('x = if (a) f() else switch line { case \'3.1\': \'a\'; case _: \'b\'; };', es[0].text);
	}

	/** End-to-end through the canonical writer: the emitted file holds the hoisted if-expression whose else value is a switch-expression. */
	public function testSwitchInElseEndToEnd(): Void {
		final out: String = applyFixOnce(
			wrap('if (a) x = f();\n\t\telse switch line {\n\t\t\tcase \'3.1\': x = \'a\';\n\t\t\tcase _: x = \'b\';\n\t\t}')
		);
		Assert.isTrue(out.indexOf('x = if (a) f() else switch line {') != -1);
	}

	/** A chain with a nested construct but NO terminal `else` still yields no value on the missing path — skipped. */
	public function testNestedChainNoTerminalElseNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) x = 1;\n\t\telse if (b) switch v {\n\t\t\tcase _: x = 2;\n\t\t}')).length);
	}

	/** A tree whose branches assign DIFFERENT l-values (head `x`, switch `y`) does not collapse. */
	public function testMixedLvalueTreeNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) x = 1;\n\t\telse switch v {\n\t\t\tcase 1: y = 2;\n\t\t\tcase _: y = 3;\n\t\t}')).length);
	}

	/** A `#if` splice cutting through the construct (the `else` lands in a `Conditional`) leaves the `if` without an else — skipped. */
	public function testConditionalSplitNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) x = 1;\n\t\t#if foo\n\t\telse switch v {\n\t\t\tcase _: x = 2;\n\t\t}\n\t\t#end'))
			.length);
	}

	/**
	 * A NON-terminal branch value ending in an else-less `if` would ABSORB the emitted ` else `:
	 * the collapse reads `x = if (a) if (q) 1 else if (b) 2 else 3;`, where the outer condition
	 * has LOST its else and `else if (b) 2 else 3` has become `if (q)`'s else branch. The result
	 * re-parses, so only this gate catches it.
	 */
	public function testElseLessConditionalInBranchValueNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap('if (a) {\n\t\t\tx = if (q) 1;\n\t\t} else if (b) {\n\t\t\tx = 2;\n\t\t} else {\n\t\t\tx = 3;\n\t\t}')).length
		);
	}

	/**
	 * The TERMINAL branch is exempt from the else-less gate: nothing the rebuild emits follows it
	 * but the closing `;`, so there is no ` else ` for it to absorb. The else-less `if` sits in a
	 * delimited interior here, which is the shape the whole-subtree scan would otherwise refuse —
	 * a bare `x = if (q) 3;` terminal hits a SEPARATE pre-existing defect (the r-value span
	 * swallows the statement's own `;`, so the rebuild emits `;;`, which Haxe rejects).
	 */
	public function testElseLessConditionalInTerminalFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('if (a) {\n\t\t\tx = 1;\n\t\t} else if (b) {\n\t\t\tx = 2;\n\t\t} else {\n\t\t\tx = g(if (q) 3);\n\t\t}')
		);
		Assert.equals(1, es.length);
		Assert.equals('x = if (a) 1 else if (b) 2 else g(if (q) 3);', es[0].text);
	}

	/**
	 * The composition case: a NESTED chain's terminal is exempt at ITS level, but the nested chain
	 * sits in a NON-terminal branch of the outer one, so the outer ` else ` re-parents onto it
	 * (`x = if (a) if (e) 1 else if (q) 2; else if (b) 3 else 4;`). The gate scans each branch's
	 * whole STATEMENT subtree, which subsumes the inner chain's exempted terminal — that is what
	 * makes the per-level exemption safe under nesting.
	 */
	public function testNestedChainElseLessTerminalNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap(
				'if (a) {\n\t\t\tif (e) {\n\t\t\t\tx = 1;\n\t\t\t} else {\n\t\t\t\tx = if (q) 2;\n\t\t\t}\n\t\t} else if (b) {\n\t\t\tx = 3;\n\t\t} else {\n\t\t\tx = 4;\n\t\t}'
			)).length
		);
	}

	/**
	 * An else-less conditional at the terminal r-value's ROOT is refused for a SPAN reason, not a
	 * re-parenting one: the parser folds the statement's own `;` into it, so the copied r-value is
	 * `if (q) 3;` and the rebuild appends another, writing `x = … else if (q) 3;;` — which
	 * anyparse re-parses but Haxe rejects. The gate is ROOT-only, which is why the
	 * delimited-interior terminal above stays claimable.
	 */
	public function testElseLessConditionalAtTerminalRootNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) x = 1;\n\t\telse if (b) x = 2;\n\t\telse x = if (q) 3;')).length);
	}

	/** Run `fix` and re-emit through the canonical writer — the `lint --fix` path in one pass. */
	private function applyFixOnce(src: String): String {
		return switch RefactorSupport.canonicalize(src, edits(src), true, new HaxeQueryPlugin(), null) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

	/** Wrap a statement body in a minimal parseable class + method. */
	private function wrap(body: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$body\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new PreferIfExpressionAssignment().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: PreferIfExpressionAssignment = new PreferIfExpressionAssignment();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
