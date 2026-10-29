package unit.check.common.control;

import anyparse.check.Severity;
import anyparse.check.common.control.PreferIfExpressionReturn;
import anyparse.check.scan.CheckScan;
import anyparse.query.CanonicalEdit;
import anyparse.query.QueryNode;
import anyparse.query.SourceComments;
import haxe.Exception;

using Lambda;

/**
 * The `prefer-if-expression-return` check: an `if / else if / … / else` CHAIN whose every
 * branch is a valued `return` is flagged `Info`, and `fix` collapses it to
 * `return if (c1) a else if (c2) b … else n;`. Disjoint from `prefer-ternary-return`
 * (which handles the if/return + fall-through-return shape): only a chain with at least
 * one `else if` terminating in a plain `else`, of single valued-`return` branches,
 * qualifies. A bare `return;` in any branch disqualifies.
 */
class PreferIfExpressionReturnCheckTest extends Test {

	public function testBasicChainFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('if (a) return 1;\n\t\telse if (b) return 2;\n\t\telse return 3;'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-if-expression-return', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this if/else-if return chain can be a single if-expression return', vs[0].message);
	}

	public function testFixThreeBranch(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('if (a) return 1;\n\t\telse if (b) return 2;\n\t\telse return 3;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1 else if (b) 2 else 3;', es[0].text);
	}

	public function testFixFourBranch(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) return 1;\n\t\telse if (b) return 2;\n\t\telse if (c) return 3;\n\t\telse return 4;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1 else if (b) 2 else if (c) 3 else 4;', es[0].text);
	}

	public function testBracedBranchesFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('if (a) {\n\t\t\treturn 1;\n\t\t} else if (b) {\n\t\t\treturn 2;\n\t\t} else {\n\t\t\treturn 3;\n\t\t}')
		);
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1 else if (b) 2 else 3;', es[0].text);
	}

	/** A chain with no terminal `else` is not collapsible. */
	public function testNoTerminalElseNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) return 1;\n\t\telse if (b) return 2;')).length);
	}

	/** A bare `return;` is a distinct node kind (no value) — it disqualifies the chain. */
	public function testBareReturnNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) return 1;\n\t\telse if (b) return;\n\t\telse return 3;')).length);
	}

	public function testNonReturnBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) return 1;\n\t\telse if (b) g();\n\t\telse return 3;')).length);
	}

	public function testMultiStatementBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) {\n\t\t\tg();\n\t\t\treturn 1;\n\t\t} else if (b) return 2;\n\t\telse return 3;')).length);
	}

	/**
	 * A comment between a branch's condition and its value sits in a region holding nothing but
	 * the closing `)`, an opening `{` and the dropped `return ` — no keyword that could make it
	 * belong to a neighbouring branch — so the collapse CARRIES it into that branch's leading
	 * slot, where it keeps the position the author gave it.
	 */
	public function testCommentBetweenConditionAndValueCarried(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) return 1;\n\t\telse if (b) /* keep */ return 2;\n\t\telse return 3;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1 else if (b) /* keep */ 2 else 3;', es[0].text);
	}

	/**
	 * A leading comment the author put on its OWN line keeps it — welded
	 * onto the `if (…)` line it would re-read as being about the CONDITION.
	 */
	public function testOwnLineLeadingCommentKeepsItsLine(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a)\n\t\t\t// why one\n\t\t\treturn 1;\n\t\telse if (b) return 2;\n\t\telse return 3;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a)\n// why one\n1 else if (b) 2 else 3;', es[0].text);
	}

	/**
	 * A trailing `// …` after a branch's `;` rides that branch's slot into the rebuilt chain.
	 *
	 * An earlier slice briefly REFUSED this site, on a probe that had no `hxformat.json` beside it: under compiled
	 * defaults the rebuilt chain fits one line, the writer cannot keep a `//` there, and `--fix`
	 * answered `the edit cannot be applied without losing the comment`. Under a config that WRAPS the
	 * branches - this project's own - the same edit lands and the comment survives, so the refusal was
	 * config-blindness, not a writer limit. The gate is gone; the review that caught it ran every probe
	 * with the project config beside the fixture.
	 */
	public function testTrailingLineCommentRidesItsBranch(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) return 1; // why one\n\t\telse if (b) return 2;\n\t\telse return 3;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1 // why one\nelse if (b) 2 else 3;', es[0].text);
	}

	/**
	 * A comment sitting on its own line BEFORE the `else` still describes the
	 * branch that ends there — it rides the trailing slot and keeps its line.
	 */
	public function testOwnLineCommentBeforeElseCarried(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) return 1;\n\t\t// which branch?\n\t\telse if (b) return 2;\n\t\telse return 3;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1\n// which branch?\nelse if (b) 2 else 3;', es[0].text);
	}

	/**
	 * Layout does not decide the trailing slot — only what PRECEDES the comment
	 * does, so a same-line block comment before the `else` rides it too.
	 */
	public function testSameLineCommentBeforeElseCarried(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('if (a) return 1; /* x */ else if (b) return 2;\n\t\telse return 3;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1 /* x */ else if (b) 2 else 3;', es[0].text);
	}

	/**
	 * The trailing slot's region runs on THROUGH the `else` that opens the next branch, and the
	 * parser projects no node for that keyword — so a comment written after it describes the
	 * branch that FOLLOWS, and emitting it in front of the rebuilt ` else ` would re-read it as
	 * being about the branch before. The gate is what SEPARATES the comment from the value
	 * (whitespace / `;` / `}` only), never how the author broke the lines.
	 */
	public function testCommentAfterElseNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) return 1; else // about the b branch\n\t\tif (b) return 2;\n\t\telse return 3;')).length);
	}

	/** A comment outside every branch seat — here in front of the head condition — has no slot and still fails the site closed. */
	public function testCommentBeforeHeadConditionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (/* x */ a) return 1;\n\t\telse if (b) return 2;\n\t\telse return 3;')).length);
	}

	/** End-to-end through the canonical writer: the emitted file holds the collapsed return, valid Haxe (canonicalize re-parses it). */
	public function testFixOutputCollapsesChain(): Void {
		final out: String = applyFixOnce(wrap('if (a) return 1;\n\t\telse if (b) return 2;\n\t\telse return 3;'));
		Assert.isTrue(out.indexOf('return if (a) 1 else if (b) 2 else 3;') != -1);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-if-expression-return'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-if-expression-return'));
	}

	/**
	 * A NON-terminal branch value ending in an else-less `if` would ABSORB the emitted ` else `:
	 * the collapse of this chain reads `return if (a) if (q) 1 else if (b) 2 else 3;`, where the
	 * outer condition has LOST its else and `else if (b) 2 else 3` has become `if (q)`'s else
	 * branch. The braces are what let the source `else` bind outward; the single-statement
	 * unwrap re-exposes the else-less tail, and the result re-parses, so only this gate catches it.
	 */
	public function testElseLessConditionalInBranchValueNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap('if (a) {\n\t\t\treturn if (q) 1;\n\t\t} else if (b) {\n\t\t\treturn 2;\n\t\t} else {\n\t\t\treturn 3;\n\t\t}'))
				.length
		);
	}

	/** An `if` WITH its else cannot absorb another one, so the branch is accepted — the gate is arity, not kind. */
	public function testCompleteConditionalInBranchValueFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('if (a) {\n\t\t\treturn if (q) 1 else 9;\n\t\t} else if (b) {\n\t\t\treturn 2;\n\t\t} else {\n\t\t\treturn 3;\n\t\t}')
		);
		Assert.equals(1, es.length);
		Assert.equals('return if (a) if (q) 1 else 9 else if (b) 2 else 3;', es[0].text);
	}

	/**
	 * The TERMINAL value is exempt from the else-less gate: nothing the rebuild emits follows it
	 * but the closing `;`, so there is no ` else ` for it to absorb. The else-less `if` sits in a
	 * delimited interior here, which is the shape the whole-subtree scan would otherwise refuse —
	 * a bare `if (q) 3` terminal hits a SEPARATE pre-existing defect (its span swallows the
	 * statement's own `;`, so the rebuild emits `;;`, which Haxe rejects).
	 */
	public function testElseLessConditionalInTerminalFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('if (a) {\n\t\t\treturn 1;\n\t\t} else if (b) {\n\t\t\treturn 2;\n\t\t} else {\n\t\t\treturn g(if (q) 3);\n\t\t}')
		);
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1 else if (b) 2 else g(if (q) 3);', es[0].text);
	}

	/**
	 * A comment the parser folded into a returned value's TRAILING trivia is cut out of the kept
	 * span by `IfExpressionChain.tokenSpan` — which is exactly what lets the carry SEE it and ride
	 * it into the branch slot. Without the trim the raw value span SWALLOWS `// why`, the guard
	 * reads it as kept, and the emitted text welds it in front of the ` else `, commenting the
	 * rest of the chain out.
	 */
	public function testTrailingLineCommentInsideValueSpanCarried(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) return u + v // why\n\t\t\t;\n\t\telse if (b) return 2;\n\t\telse return 3;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a) u + v // why\nelse if (b) 2 else 3;', es[0].text);
	}

	/**
	 * An else-less conditional at the TERMINAL value's ROOT is refused for a SPAN reason, not a
	 * re-parenting one: the parser folds the statement's own `;` into it, so the copied text is
	 * `if (q) k();` and the rebuild appends another, writing `return … else if (q) k();;`. That
	 * re-parses under anyparse, so the `--fix` gate passes it, but `haxe --interp` 4.3.7 rejects
	 * it with `Expected }` — while the INPUT compiles and runs whenever the carrier is
	 * `Void`-typed (verified). So without this gate the fix turns working code into code that
	 * does not compile.
	 */
	public function testElseLessConditionalAtTerminalRootNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) return g();\n\t\telse if (b) return h();\n\t\telse return if (q) k();')).length);
	}

	/**
	 * The march gate governs the CHAIN arm too, and `redundant-else-after-return` keeps its finding
	 * when it refuses - the claim is what silences that rule, so a chain this one will not rewrite
	 * must not be claimed. Same fixture both ways: bool-literal rungs are refused, value rungs are
	 * claimed.
	 */
	public function testBoolLiteralElseChainNotClaimed(): Void {
		Assert.isFalse(
			claims('if (a) return false;\n\t\telse if (b) return g();\n\t\telse return h();'),
			'a bool-literal rung is left to the pairwise march, so the de-nest keeps its finding'
		);
		Assert.isTrue(
			claims('if (a) return e();\n\t\telse if (b) return g();\n\t\telse return h();'), 'the same chain with value rungs is claimed'
		);
	}

	/**
	 * The FALL-THROUGH spelling - a run of no-`else` `if`s each returning a value, plus the sibling
	 * return past the run - is OWNED by this rule but never rewritten into a value chain: three or
	 * more values the author wrote as guard statements read better as those statements than as an
	 * `if` / `else if` / `else` value (the formatter's `expressionIfFitMaxBranches: 2`). Owning it is
	 * what keeps `prefer-ternary-return` from marching it pairwise into the same chain by the long
	 * route, so the cascade is claimed and the finding count is zero.
	 *
	 * Two leaf values are a ternary and not this rule's at all; a longer cascade is claimed at its head.
	 */
	@:pin('control')
	@:killer('M-PIER-CASCADE-UNMERGED-REPORTED')
	public function testFallThroughCascadeClaimedNotRewritten(): Void {
		Assert.equals(0, violations(wrap('if (a) return 1;\n\t\tif (b) return 2;\n\t\treturn 3;')).length);
		Assert.isTrue(claimsCascade('if (a) return 1;\n\t\tif (b) return 2;\n\t\treturn 3;'), 'the cascade stays this rule\'s');
		Assert.isFalse(claimsCascade('if (a) return 1;\n\t\treturn 3;'), 'two leaf values are a ternary, not a chain');
		Assert.isTrue(
			claimsCascade('if (a) return 1;\n\t\tif (b) return 2;\n\t\tif (c) return 3;\n\t\treturn 4;'),
			'a longer cascade is claimed at its head'
		);
	}

	/**
	 * A guard plus a terminal TERNARY is the shape N55's self-fix turned into a six-line chain that
	 * spelled `null` twice (`MoveToHelper.accessedProperty`). The fold still COUNTS the ternary's
	 * leaves - that is what makes the cascade this rule's, so `prefer-ternary-return` does not write
	 * a three-leaf ternary - but distinct values leave the statements alone.
	 */
	@:pin('control')
	@:killer('M-PIER-CASCADE-UNMERGED-REPORTED')
	public function testGuardBeforeTernaryClaimedNotRewritten(): Void {
		Assert.equals(0, violations(wrap('if (a) return 1;\n\t\treturn p ? q : r;')).length);
		Assert.isTrue(claimsCascade('if (a) return 1;\n\t\treturn p ? q : r;'));
	}

	/**
	 * When the guard's value is the one the ternary's ELSE repeats, the three branches carry two
	 * values and merge into one condition: `!c1 && c2 ? v2 : v1`. Sound with no purity proof - `c1`
	 * is still evaluated first and `c2` only when `c1` is false, exactly as the statements did - and
	 * the conjunction keeps the null narrowing the guard gave `c2` (`m != null && m.x`). The rung
	 * condition sat in a `?:` slot and binds looser than `&&`, so it regains its parentheses.
	 */
	@:pin('control')
	@:killer('M-PIER-OUTER-UNNEGATED')
	@:killer('M-PIER-MERGE-NO-PARENS')
	public function testGuardRepeatingTheTernaryElseMerges(): Void {
		final src: String = wrap('if (m == null) return null;\n\t\treturn (g ? m.a : m.b) ? p : null;');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('this if/return cascade repeats a value and can be a single ternary return', vs[0].message);
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.equals('return m != null && (g ? m.a : m.b) ? p : null;', es[0].text);
	}

	/** Two LEADING branches with one value merge by `||`: order and short-circuit are the statements' own. */
	@:pin('control')
	@:killer('M-PIER-LEADING-AS-OUTER')
	public function testRepeatedLeadingValueMergesByOr(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('if (a) return null;\n\t\tif (b) return null;\n\t\treturn x;'));
		Assert.equals(1, es.length);
		Assert.equals('return a || b ? null : x;', es[0].text);
	}

	/**
	 * The merge applies to a WRITTEN chain as well, and wins over the chain there: two values are a
	 * ternary however many branches spelled them.
	 */
	public function testWrittenChainRepeatingAValueMerges(): Void {
		final src: String = wrap('if (a) return 1;\n\t\telse if (b) return 2;\n\t\telse return 1;');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('this if/else-if return chain repeats a value and can be a single ternary return', vs[0].message);
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.equals('return !a && b ? 2 : 1;', es[0].text);
		Assert.isTrue(applyFixOnce(src).indexOf('return !a && b ? 2 : 1;') != -1, 'the merged return survives the canonical writer');
	}

	/**
	 * A written chain of TWO branches whose terminal is a ternary was a chain of three only by the
	 * fold, and the fold is not something the author wrote: it is neither reported nor claimed, so
	 * `redundant-else-after-return` keeps its de-nest and the guard plus ternary it leaves behind is
	 * the cascade the test above owns.
	 */
	@:pin('control')
	@:killer('M-PIER-REWRITES-FOLDED')
	@:killer('M-PIER-CLAIMSCHAIN-OWNS')
	public function testTwoWrittenBranchesAndAFoldedTailAreNotAChain(): Void {
		Assert.equals(0, violations(wrap('if (a) return 1;\n\t\telse return p ? q : r;')).length);
		Assert.isFalse(claims('if (a) return 1;\n\t\telse return p ? q : r;'), 'the de-nest keeps its finding');
		Assert.isTrue(
			claims('if (a) return 1;\n\t\telse if (b) return 2;\n\t\telse return p ? q : r;'), 'three written branches stay a chain'
		);
	}

	/**
	 * The merge's refusals, each beside the shape it would otherwise take:
	 *
	 * - the repeated value must be a LITERAL or a NAME. Equal text is the same value only when the
	 *   binding environment is (it is - the statements are siblings) AND its type does not depend on
	 *   the narrowing the merged condition no longer gives it; a literal or a name is the positive
	 *   list for which the second holds, a call or a field read is not on it.
	 * - a repeated BOOL literal is `simplify-boolean-*`'s, and the march owns that cascade.
	 * - the MIDDLE value repeating the last would drop `c2`'s evaluation, which no merge here does.
	 * - a comment anywhere in the region fails the merge closed: the rebuild re-orders and drops pieces.
	 * - a run of FOUR values does not merge its FIRST three: the edit is built from two rungs and the
	 *   terminal, so a merge that does not end at the terminal would drop a condition. Only the last
	 *   three can merge (`testTailOfALongerCascadeMerges`), and here they do not repeat.
	 */
	@:pin('control')
	@:killer('M-PIER-MERGE-ANY-VALUE')
	@:killer('M-PIER-MERGE-COMMENT')
	public function testMergeRefusals(): Void {
		Assert.equals(
			0, violations(wrap('if (a) return g();\n\t\tif (b) return g();\n\t\treturn h();')).length, 'a call is not a repeated value'
		);
		Assert.equals(0, violations(wrap('if (a) return m.x;\n\t\tif (b) return m.x;\n\t\treturn h();')).length, 'nor is a field read');
		Assert.equals(1, violations(wrap('if (a) return k;\n\t\tif (b) return k;\n\t\treturn h();')).length, 'a name is');
		Assert.equals(0, violations(wrap('if (a) return true;\n\t\tif (b) return true;\n\t\treturn h();')).length, 'a bool literal is not');
		Assert.equals(0, violations(wrap('if (a) return 1;\n\t\tif (b) return 2;\n\t\treturn 2;')).length, 'dropping c2 is not a merge');
		Assert.equals(0, violations(wrap('if (a) return null; // none\n\t\treturn b ? p : null;')).length, 'a comment fails it closed');
		Assert.equals(1, violations(wrap('if (a) return null;\n\t\treturn b ? p : null;')).length, 'the same cascade without it merges');
		Assert.equals(
			0, violations(wrap('if (a) return 1;\n\t\tif (b) return 1;\n\t\tif (c) return 2;\n\t\treturn 3;')).length,
			'four values do not merge, even where the first two repeat'
		);
	}

	/**
	 * A STATEMENT-LIKE value - a `switch` used as a value - is refused by the merge exactly as the
	 * pairwise march refuses it: a ternary branch holding a multi-line `switch` reads no better than
	 * the statements. A written chain of three branches keeps the chain fix instead.
	 */
	@:pin('control')
	@:killer('M-PIER-MERGE-UNMARCHABLE')
	public function testStatementLikeValueIsNotMerged(): Void {
		final vs: Array<Violation> = violations(
			wrap('if (a) return null;\n\t\telse if (b) return switch x {\n\t\t\tcase _: 1;\n\t\t};\n\t\telse return null;')
		);
		Assert.equals(1, vs.length);
		Assert.equals('this if/else-if return chain can be a single if-expression return', vs[0].message);
	}

	/**
	 * The march gate decides the CLAIM: a cascade `prefer-ternary-return` would refuse to march is
	 * not claimed, or the claim silences that rule and CHANGES the fixed point. A bool-literal rung is
	 * the gate's largest class; a statement-like value and a boolean ternary mid-reduction are the
	 * other two. Each sits beside the same cascade with plain value rungs, which IS claimed.
	 */
	public function testMarchGateDecidesTheClaim(): Void {
		Assert.isFalse(claimsCascade('if (a) return false;\n\t\tif (b) return g();\n\t\treturn h();'), 'a bool-literal rung');
		Assert.isTrue(claimsCascade('if (a) return e();\n\t\tif (b) return g();\n\t\treturn h();'), 'the same cascade with value rungs');
		Assert.isFalse(
			claimsCascade('if (a) return switch x {\n\t\t\tcase _: 1;\n\t\t};\n\t\tif (b) return g();\n\t\treturn h();'),
			'a switch rung value'
		);
		Assert.isFalse(
			claimsCascade('if (a) return c ? true : g();\n\t\tif (b) return g();\n\t\treturn h();'), 'a boolean ternary mid-reduction'
		);
		Assert.isTrue(claimsCascade('if (a) return c ? e() : g();\n\t\tif (b) return g();\n\t\treturn h();'), 'a VALUE ternary rung');
	}

	/**
	 * A rung condition is copied paren-UNWRAPPED, the way `PreferIfExpressionChain.spine` unwraps its
	 * own: the emitted `if (` … `)` supplies the delimiters, so a copied pair only draws a
	 * `redundant-parens` finding on the result. Seen on openfl\'s `Tile.__findTileset`.
	 */
	public function testRungConditionParensDropped(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('if ((a)) return 1;\n\t\telse if (b) return 2;\n\t\telse return 3;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1 else if (b) 2 else 3;', es[0].text);
	}

	/**
	 * A cascade inside a conditional-compilation region is seen, because this rule reads the
	 * BRANCH-AWARE projection: in the plain one a `#if` region is ONE node whose branches are
	 * flattened children with no statement list at all. Seen on openfl\'s `Lib.isXMLName`.
	 */
	public function testCascadeInsideConditionalRegionMerged(): Void {
		final src: String =
			'class C {\n\tfunction f():Int {\n\t\t#if js\n\t\tif (a) return 1;\n\t\tif (b) return 1;\n\t\treturn 3;\n\t\t#end\n\t}\n}';
		Assert.equals(1, violations(src).length, 'the branch-aware projection gives the region its own statement list');
		Assert.equals(1, edits(src).length, 'and `fix` reads the same projection, or the finding would have no edit');
	}

	/**
	 * The head of a run is the index whose predecessor is not a rung THIS rule would collect, and
	 * "rung" has to mean a valued `return`: a leading `if (x) g();` is a rung by shape alone, and the
	 * shape-only test hid the whole cascade behind it.
	 */
	public function testNonReturnStatementDoesNotHideTheCascade(): Void {
		Assert.equals(
			1, violations(wrap('if (x) g();\n\t\tif (a) return 1;\n\t\tif (b) return 1;\n\t\treturn 3;')).length,
			'a leading non-return guard does not swallow the cascade behind it'
		);
	}

	/**
	 * A run of FOUR values whose LAST three carry two merges those three alone: the guard in front
	 * keeps its statement and the merged return replaces only the tail. the client's
	 * `DiskSystemBase.localPathBeforeMove` is the shape - an early return, a guard returning `null` and
	 * a ternary whose else repeats it. The finding sits on the first statement the edit replaces. The
	 * conditions still run in their written order (`f(h)` first, `g(h)` only when it was false), so a
	 * call in either is no obstacle.
	 */
	@:pin('control')
	@:killer('M-PIER-MERGE-ANY-COUNT')
	@:killer('M-PIER-TAIL-SPAN-WHOLE')
	@:killer('M-PIER-TAIL-REPORTED-AT-HEAD')
	public function testTailOfALongerCascadeMerges(): Void {
		final src: String = wrap('if (o != null) return o.p;\n\t\tif (f(h)) return null;\n\t\treturn g(h) ? h : null;');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('the last three values of this if/return cascade repeat one and can be a single ternary return', vs[0].message);
		Assert.equals(src.indexOf('if (f(h))'), vs[0].span?.from, 'reported where the edit starts');
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.equals('return !f(h) && g(h) ? h : null;', es[0].text);
		Assert.equals(src.indexOf('if (f(h))'), es[0].span.from, 'the guard in front is not replaced');
		final fixed: String = applyFixOnce(src);
		Assert.isTrue(fixed.indexOf('if (o != null) return o.p;\n\t\treturn !f(h) && g(h) ? h : null;') != -1, fixed);
		Assert.equals(0, violations(fixed).length, 'a run merges once: the next pass has nothing left to merge');
	}

	/** The tail merges by `||` as well, when its first two values repeat. */
	@:pin('control')
	@:killer('M-PIER-MERGE-ANY-COUNT')
	public function testTailRepeatingLeadingValueMergesByOr(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) return 0;\n\t\tif (b) return 1;\n\t\tif (c) return 1;\n\t\treturn 3;'));
		Assert.equals(1, es.length);
		Assert.equals('return b || c ? 1 : 3;', es[0].text);
	}

	/**
	 * The tail's refusals, each a run that would merge but for one thing:
	 *
	 * - a comment in the replaced tail fails it closed, exactly as in a three-value run;
	 * - values that do not repeat stay statements;
	 * - the MIDDLE value repeating the last is still refused: the merge would drop the evaluation of
	 *   the condition between them, and that condition may have a side effect (`next()`);
	 * - a repeated call is not one value;
	 * - the first merged value must come from a WRITTEN rung: in `return b ? 1 : c ? 1 : 3` the last
	 *   three values live inside one ternary, and re-shaping a ternary is not a cascade merge (the run
	 *   stays owned, so `prefer-ternary-return` does not march it either);
	 * - an else-linked chain of four values keeps its chain fix: the tail merge is the fall-through
	 *   spelling's, whose guards in front of the tail are statements already.
	 */
	@:pin('control')
	@:killer('M-PIER-TAIL-FROM-FOLDED')
	public function testTailMergeRefusals(): Void {
		Assert.equals(
			0, violations(wrap('if (a) return 0;\n\t\tif (b) return null; // none\n\t\treturn c ? p : null;')).length,
			'a comment in the tail'
		);
		Assert.equals(
			0, violations(wrap('if (a) return 0;\n\t\tif (b) return 1;\n\t\tif (c) return 2;\n\t\treturn 3;')).length, 'distinct values'
		);
		Assert.equals(
			0, violations(wrap('if (a) return 0;\n\t\tif (b) return 1;\n\t\tif (next()) return 2;\n\t\treturn 2;')).length,
			'dropping a condition that may have a side effect'
		);
		Assert.equals(
			0, violations(wrap('if (a) return 0;\n\t\tif (b) return g();\n\t\tif (c) return g();\n\t\treturn 3;')).length,
			'a repeated call'
		);
		Assert.equals(0, violations(wrap('if (a) return 0;\n\t\treturn b ? 1 : c ? 1 : 3;')).length, 'a tail inside the ternary');
		Assert.isTrue(claimsCascade('if (a) return 0;\n\t\treturn b ? 1 : c ? 1 : 3;'), 'which stays owned');
		final chain: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) return 0;\n\t\telse if (b) return 1;\n\t\telse if (c) return 1;\n\t\telse return 3;'));
		Assert.equals(1, chain.length);
		Assert.equals('return if (a) 0 else if (b) 1 else if (c) 1 else 3;', chain[0].text);
	}

	/**
	 * A guard LADDER stays the ladder it is (FU6's decision): when the value returned just ahead of
	 * the tail repeats one of the tail's values, the merged return would leave a run of three that the
	 * next pass merges AGAIN, and three guards of `null` would end as one nested
	 * `a || (b || c) ? null : x`. So the tail is refused, and a run merges at most once - the run
	 * repeating the tail's OTHER value (`5` here) is refused for the same reason.
	 */
	@:pin('control')
	@:killer('M-PIER-TAIL-LADDER')
	public function testGuardLadderIsNotMerged(): Void {
		Assert.equals(
			0, violations(wrap('if (a) return null;\n\t\tif (b) return null;\n\t\tif (c) return null;\n\t\treturn x;')).length,
			'three guards'
		);
		Assert.equals(
			0,
			violations(
				wrap('if (a) return null;\n\t\tif (b) return null;\n\t\tif (c) return null;\n\t\tif (d) return null;\n\t\treturn x;')
			).length,
			'four guards'
		);
		Assert.equals(
			0,
			violations(wrap(
				'if (a) return null;\n\t\tif (b) return null;\n\t\tif (c) return null;\n\t\tif (d) return null;\n'
				+ '\t\tif (e) return null;\n\t\treturn x;'
			)).length,
			'five guards'
		);
		Assert.equals(
			0, violations(wrap('if (a) return 5;\n\t\tif (b) return null;\n\t\tif (c) return 5;\n\t\treturn null;')).length,
			'the value before the tail repeats the tail\'s other value'
		);
		Assert.isTrue(
			claimsCascade('if (a) return null;\n\t\tif (b) return null;\n\t\tif (c) return null;\n\t\treturn x;'), 'the ladder stays owned'
		);
	}

	/**
	 * The terminal-ternary fold is refused when a comment sits inside that spine, asked of the parsed
	 * comment TOKENS rather than a text scan: a `//` inside a STRING literal is not a comment.
	 */
	public function testStringLiteralSlashesDoNotBlockTheFold(): Void {
		Assert.isTrue(
			claimsCascade('if (a) return "x";\n\t\treturn b ? "http://example.com" : "y";'),
			'a `//` inside a string literal is not a comment'
		);
		Assert.isFalse(
			claimsCascade('if (a) return "x";\n\t\treturn b ? /* why */ "p" : "y";'),
			'a real comment inside the folded spine still refuses'
		);
	}

	/** Run `fix` and re-emit through the canonical writer — the `lint --fix` path in one pass. */
	private function applyFixOnce(src: String): String {
		return switch CanonicalEdit.canonicalize(src, edits(src), true, new HaxeQueryPlugin(), null) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

	/** Wrap a statement body in a minimal parseable class + method. */
	private function wrap(body: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$body\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new PreferIfExpressionReturn(), src);
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: PreferIfExpressionReturn = new PreferIfExpressionReturn();
		return CheckFixture.edits(check, src);
	}

	/** Whether the rule CLAIMS the chain headed by the first `if` of `body` - the question the two deferring rules ask. */
	private function claims(body: String): Bool {
		final source: String = wrap(body);
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		// Both nulls are "cannot happen" for a fixture this file wrote, and a quiet `false` would make
		// every `isFalse` assertion pass vacuously the day one stops parsing.
		final tree: Null<QueryNode> = CheckScan.parseBranchAwareOrNull(plugin, source);
		if (tree == null) throw new Exception('fixture does not parse: $source');
		final head: Null<QueryNode> = firstIf(tree, plugin.refShape().ifStatementKinds ?? []);
		if (head == null) throw new Exception('fixture holds no if statement: $source');
		return PreferIfExpressionReturn.claimsChain(
			head, source, SourceComments.collectCommentTokens(plugin.lexicalRegions(source)), plugin.refShape()
		);
	}

	/**
	 * Whether the rule CLAIMS the fall-through cascade that starts at the first `if` of `body` - the
	 * question `prefer-ternary-return` asks before it collapses a pair of it.
	 */
	private function claimsCascade(body: String): Bool {
		final source: String = wrap(body);
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: Null<QueryNode> = CheckScan.parseBranchAwareOrNull(plugin, source);
		if (tree == null) throw new Exception('fixture does not parse: $source');
		final ifKinds: Array<String> = plugin.refShape().ifStatementKinds ?? [];
		final block: Null<QueryNode> = parentOfFirstIf(tree, ifKinds);
		if (block == null) throw new Exception('fixture holds no if statement: $source');
		final at: Int = block.children.findIndex(c -> ifKinds.contains(c.kind));
		return PreferIfExpressionReturn.claimsCascade(
			block.children, at, source, SourceComments.collectCommentTokens(plugin.lexicalRegions(source)), plugin.refShape()
		);
	}

	/** The node whose child is the first `if` STATEMENT in document order, or null. */
	private function parentOfFirstIf(node: QueryNode, ifKinds: Array<String>): Null<QueryNode> {
		for (c in node.children) {
			if (ifKinds.contains(c.kind)) return node;
			final hit: Null<QueryNode> = parentOfFirstIf(c, ifKinds);
			if (hit != null) return hit;
		}
		return null;
	}

	/** The first `if` STATEMENT in document order, or null. */
	private function firstIf(node: QueryNode, ifKinds: Array<String>): Null<QueryNode> {
		if (ifKinds.contains(node.kind)) return node;
		for (c in node.children) {
			final hit: Null<QueryNode> = firstIf(c, ifKinds);
			if (hit != null) return hit;
		}
		return null;
	}

}
