package unit;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferIfExpressionChain;
import anyparse.check.PreferSwitchExpression;
import anyparse.check.PreferTernaryExpression;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `prefer-if-expression-chain` check: a right-nested ternary chain of three or more
 * values, in a whitelisted value host, is flagged `Info` and `fix` rewrites it to
 * `if (c1) v1 else if (c2) v2 … else vN`. A two-branch ternary, an already-canonical
 * if-expression chain, a chain in a non-host slot, one `prefer-switch-expression` claims,
 * and a comment in a dropped region are all left alone.
 */
class PreferIfExpressionChainCheckTest extends Test {

	/** The TM `FileSystemBase` move comparator after `prefer-lambda-expression-body` collapsed its block (anonymized). */
	private static inline final TM_TERNARY_COMPARATOR: String =
		'class C {\n\tfunction f():Void {\n\t\titems.sort((a:SortedPairEntryDetail, b:SortedPairEntryDetail) -> a.nodeName < b.nodeName ? -1 : a.nodeName > b.nodeName ? 1 : 0);\n\t}\n}';

	/** TM `SharedRelink.decide` after `prefer-ternary-return` folded its guard ladder (anonymized) — the carry flagship. */
	private static inline final TM_RELINK_DECISION: String =
		'class C {\n\tfunction f():RebindDecision {\n\t\treturn !visible || remoteHostTag < 0\n\t\t\t? KeepLink\n\t\t\t: dbLocalTag == remoteHostTag\n\t\t\t\t? KeepLink // already correctly paired\n\t\t\t\t: groupAllowEdit && pendingAction == QUEUED_STATE_LOCAL_PENDING ? RebindAsEdit : RebindAsSteady;\n\t}\n}';

	/** A ternary nested in the THEN arm — the shape inversion reaches, silent before it. */
	private static inline final THEN_NESTED: String = 'class C {\n\tfunction f():Int {\n\t\treturn a ? b ? 1 : 2 : 3;\n\t}\n}';

	/** TM `TimeInput.get_hrs` (anonymized) — a null guard duplicated into the conjunction, held by short-circuiting. */
	private static inline final TM_NULL_GUARDED_ACCESSOR: String =
		"class C {\n\tfunction f():String {\n\t\treturn sel != null ? sel.data.data == -1 ? 'N/A' : sel.data.text : '';\n\t}\n}";

	/** A ternary chain as the value of a `case` arm — the shape TM's `getColorPickerType` writes five times over. */
	private static inline final CASE_ARM_CHAIN: String =
		'class C {\n\tfunction f(v:Int):Void {\n\t\tswitch v {\n\t\t\tcase 1:\n\t\t\t\ta ? 1 : b ? 2 : 3;\n\t\t\tcase _:\n\t\t}\n\t}\n}';

	/** anyparse's own `ShardPlan.compareEntries`: an if-chain the author wrote, whose LAST rung value is a ternary. */
	private static inline final CANONICAL_CHAIN_WITH_TERNARY_RUNG_VALUE: String =
		'class C {\n\tfunction f(a:Entry, b:Entry):Int {\n\t\treturn if (a.sticky != b.sticky)\n\t\t\ta.sticky ? -1 : 1\n\t\telse if (a.weight != b.weight)\n\t\t\ta.weight > b.weight ? -1 : 1\n\t\telse\n\t\t\tcompareNames(a.cls, b.cls);\n\t}\n}';

	/** The TM `FileSystemBase` cloud-queue comparator — already canonical, so a 0-finding fixed point (anonymized). */
	private static inline final TM_IF_CHAIN_COMPARATOR: String =
		'class C {\n\tfunction f():Void {\n\t\tstack.sort((a:StoredEntryRecord, b:StoredEntryRecord) ->\n\t\t\tif (a.nested && !b.nested)\n\t\t\t\t-1\n\t\t\telse if (!a.nested && b.nested)\n\t\t\t\t1\n\t\t\telse\n\t\t\t\tSortHelper.orderTextValuesForKey(a.nodeName, b.nodeName)\n\t\t);\n\t}\n}';

	public function testTernaryChainFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Int {\n\t\treturn a ? 1 : b ? 2 : 3;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('prefer-if-expression-chain', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this nested ternary chain can be an if-expression chain', vs[0].message);
	}

	public function testFixTernaryChain(): Void {
		final es: Array<{ span: Span, text: String }> = edits('class C {\n\tfunction f():Int {\n\t\treturn a ? 1 : b ? 2 : 3;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (a) 1 else if (b) 2 else 3', es[0].text);
	}

	/** A four-value chain keeps going — every rung is a separate `else if`. */
	public function testFixThreeConditionChain(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Int {\n\t\tvar x = a ? 1 : b ? 2 : c ? 3 : 4;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (a) 1 else if (b) 2 else if (c) 3 else 4', es[0].text);
	}

	public function testFixTmComparatorFixture(): Void {
		final es: Array<{ span: Span, text: String }> = edits(TM_TERNARY_COMPARATOR);
		Assert.equals(1, es.length);
		Assert.equals('if (a.nodeName < b.nodeName) -1 else if (a.nodeName > b.nodeName) 1 else 0', es[0].text);
	}

	/** A 2-branch ternary IS the canon — one condition is below the minimum, and this is the whole disjointness proof against `prefer-ternary-expression`. */
	public function testTwoBranchTernaryNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Int {\n\t\treturn a ? 1 : 2;\n\t}\n}').length);
	}

	/** The already-canonical TM comparator: a chain with no ternary rung is the 0-finding fixed point. */
	public function testIfExpressionChainNotFlagged(): Void {
		Assert.equals(0, violations(TM_IF_CHAIN_COMPARATOR).length);
	}

	/**
	 * The ternary-rung minimum is asked of the SPINE, BEFORE the inversion folds anything in.
	 * anyparse's own `ShardPlan.compareEntries` is the shape: an if-chain the author wrote,
	 * whose last rung VALUE happens to be a ternary. Folding it in would claim a chain nobody
	 * wrote as a nested `?:` and invert the emphasis its author chose, so it stays out.
	 */
	public function testCanonicalChainWithATernaryRungValueNotFlagged(): Void {
		Assert.equals(0, violations(CANONICAL_CHAIN_WITH_TERNARY_RUNG_VALUE).length);
	}

	/** Neither direction moves the canon: a 2-rung ternary and a 3-rung if-chain are fixed points of BOTH rules. */
	public function testNoPingPongWithPreferTernaryExpression(): Void {
		final ternary: String = 'class C {\n\tfunction f():Int {\n\t\treturn a ? 1 : 2;\n\t}\n}';
		final chain: String = 'class C {\n\tfunction f():Int {\n\t\treturn if (a) 1 else if (b) 2 else 3;\n\t}\n}';
		Assert.equals(0, violations(ternary).length);
		Assert.equals(0, violations(chain).length);
		Assert.equals(0, ternaryExpressionViolations(ternary).length);
		Assert.equals(0, ternaryExpressionViolations(chain).length);
	}

	/**
	 * `prefer-ternary-return` collapses two guard returns into a 3-value nested ternary; this
	 * check converts that, and the result is a fixed point of both — the pipeline terminates.
	 */
	public function testGuardCollapsePipelineConverges(): Void {
		final collapsed: String = 'class C {\n\tfunction f():Int {\n\t\treturn a ? 1 : b ? 2 : 3;\n\t}\n}';
		final es: Array<{ span: Span, text: String }> = edits(collapsed);
		final converted: String = RefactorSupport.applyEdits(collapsed, es);
		Assert.equals('class C {\n\tfunction f():Int {\n\t\treturn if (a) 1 else if (b) 2 else 3;\n\t}\n}', converted);
		Assert.equals(0, violations(converted).length);
		Assert.equals(0, ternaryExpressionViolations(converted).length);
	}

	/** A MIXED chain moves nobody else — `prefer-ternary-expression` refuses the inner link — so this check is what converges it. */
	public function testMixedTernaryIfExpressionChainFlagged(): Void {
		final src: String = 'class C {\n\tfunction f():Int {\n\t\tvar x = a ? 1 : if (b) 2 else 3;\n\t}\n}';
		Assert.equals(0, ternaryExpressionViolations(src).length);
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.equals('if (a) 1 else if (b) 2 else 3', es[0].text);
	}

	/** A call argument is not a host: the rewrite parses there but reads worse than the ternary it replaced. */
	public function testCallArgumentNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg(a ? 1 : b ? 2 : 3);\n\t}\n}').length);
	}

	/** A bare expression STATEMENT yields no value anyone reads; converting it would hand the site to the statement-side family. */
	public function testStatementPositionNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\ta ? p() : b ? q() : r();\n\t}\n}').length);
	}

	/**
	 * A chain in the THEN-arm of an enclosing ternary is never reported as its OWN head — its
	 * parent kind is a chain kind, which is no host — so the site yields ONE finding, taken
	 * through the enclosing chain, whose inversion flattens the whole nest in one
	 * pass.
	 */
	public function testThenArmChainReportedOnceThroughItsHead(): Void {
		final src: String = 'class C {\n\tfunction f():Int {\n\t\treturn x ? a ? 1 : b ? 2 : 3 : y;\n\t}\n}';
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.equals('if (!x) y else if (a) 1 else if (b) 2 else 3', es[0].text);
	}

	/**
	 * An equality-shaped chain in a host `prefer-switch-expression` accepts belongs to THAT
	 * rule, and this one defers by asking it. Both halves are asserted: silence here, a finding
	 * there — silence alone would not prove the deferral rather than some unrelated gate.
	 */
	public function testEqualityChainDeferredToSwitchExpression(): Void {
		final src: String = 'class C {\n\tfunction f():String {\n\t\treturn n == 1 ? \'a\' : n == 2 ? \'b\' : \'c\';\n\t}\n}';
		Assert.equals(0, violations(src).length);
		Assert.equals(1, switchExpressionViolations(src).length);
	}

	/**
	 * The deferral is asymmetric: `prefer-switch-expression`'s host whitelist has no lambda
	 * body, so an equality-shaped comparator lambda is unclaimed there and converges here.
	 */
	public function testEqualityChainInLambdaHostFlagged(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\txs.map(n -> n == 1 ? \'a\' : n == 2 ? \'b\' : \'c\');\n\t}\n}';
		Assert.equals(0, switchExpressionViolations(src).length);
		Assert.equals(1, violations(src).length);
	}

	/** The `?` / `:` glue is dropped, so a comment sitting there fails the guard closed. */
	public function testCommentInDroppedRegionNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Int {\n\t\treturn a ? 1 : /* why */ b ? 2 : 3;\n\t}\n}').length);
	}

	/** A comment INSIDE a copied span rides along, so the site still fires. */
	public function testCommentInsideValueFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Int {\n\t\treturn a ? g(/* why */ 1) : b ? 2 : 3;\n\t}\n}').length);
	}

	/** `if (…)` writes its own delimiters, so a copied pair would only draw a `redundant-parens` finding on the result. */
	public function testRedundantConditionParensStripped(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Int {\n\t\treturn (a && b) ? 1 : (c) ? 2 : 3;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (a && b) 1 else if (c) 2 else 3', es[0].text);
	}

	/**
	 * The replaced region stops at the terminal VALUE: a conditional node's span runs on
	 * through the trivia after its last token, and splicing that away would weld the emitted
	 * chain onto what follows.
	 */
	public function testEditSpanStopsAtTerminalValue(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar x = a ? 1 : b ? 2 : 3 ;\n\t}\n}';
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.equals(src.indexOf('3 ;') + 1, es[0].span.to);
	}

	/**
	 * A rung value ending in an else-less `if` would ABSORB the emitted ` else `, silently
	 * making the rest of the chain that `if`'s else branch — and the result still parses, so
	 * only this gate catches it. Every carrier of the same tail is refused with it.
	 */
	public function testElseLessConditionalInRungValueNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg(() -> a ? if (q) p() : b ? r() : s());\n\t}\n}').length);
		Assert.equals(
			0, violations('class C {\n\tfunction f():Void {\n\t\tg(() -> a ? untyped if (q) p() : b ? r() : s());\n\t}\n}').length
		);
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg(() -> a ? cast if (q) p() : b ? r() : s());\n\t}\n}').length);
	}

	/** An `if` WITH its else cannot absorb another one, so the rung is accepted — the gate is arity, not kind. */
	public function testCompleteConditionalInRungValueFlagged(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Void {\n\t\tg(() -> a ? if (q) p() else t() : b ? r() : s());\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (a) if (q) p() else t() else if (b) r() else s()', es[0].text);
	}

	/**
	 * The TERMINAL value is exempt from the else-less gate, and that is a fact about the
	 * parse: an `else` that could have followed the chain would already have been bound INTO
	 * the terminal, making it a rung. So an else-less terminal proves nothing follows it.
	 */
	public function testElseLessConditionalInTerminalFlagged(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Void {\n\t\tg(() -> a ? p() : b ? r() : if (q) s());\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (a) p() else if (b) r() else if (q) s()', es[0].text);
	}

	/**
	 * A comment the parser folded into a rung CONDITION's trailing trivia is cut out of the kept
	 * span by `tokenSpan` — which is what lets the carry see it and ride it into the leading slot
	 * of that rung's value, where the `?` used to sit. Emitting it verbatim inside the copied
	 * condition would have welded `// why` in front of the ` else `, commenting the rest out.
	 */
	public function testTrailingLineCommentInsideRungSpanCarried(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Int {\n\t\treturn a < b // why\n\t\t\t? 1 : c ? 2 : 3;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (a < b) // why\n1 else if (c) 2 else 3', es[0].text);
	}

	/** A comment at the end of a RUNG VALUE's own line rides that value; the `:` it sat after is dropped, and the ` else ` moves to the next line. */
	public function testTrailingLineCommentOnRungValueCarried(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Int {\n\t\treturn a ? 1 // one\n\t\t\t: b ? 2 : 3;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (a) 1 // one\nelse if (b) 2 else 3', es[0].text);
	}

	/**
	 * The flagship: TM `SharedRelink.decide` as `prefer-ternary-return` leaves it (anonymized) —
	 * a guard ladder already folded into a nested ternary, one arm still carrying the trailing
	 * comment that used to sit after its `return`. Before the carry that comment refused the whole
	 * chain, so the fixed point of the pipeline was the ternary form; now it converges to the
	 * if-expression chain with the comment still on the arm it describes.
	 */
	public function testTmRelinkChainCarriesArmComment(): Void {
		final es: Array<{ span: Span, text: String }> = edits(TM_RELINK_DECISION);
		Assert.equals(1, es.length);
		Assert.equals(
			'if (!visible || remoteHostTag < 0) KeepLink else if (dbLocalTag == remoteHostTag) KeepLink // already correctly paired\n'
			+ 'else if (groupAllowEdit && pendingAction == QUEUED_STATE_LOCAL_PENDING) RebindAsEdit else RebindAsSteady',
			es[0].text
		);
		Assert.equals(0, violations(RefactorSupport.applyEdits(TM_RELINK_DECISION, es)).length);
	}

	/** Every copied piece is cut back to its last token — a non-leaf span runs on through the trivia after it. */
	public function testCopiedPiecesAreTokenTight(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Int {\n\t\treturn a < b ? -1 : a > b ? 1 : g(0);\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (a < b) -1 else if (a > b) 1 else g(0)', es[0].text);
	}

	/** A reification subtree is spliced code a consumer may pattern-match, not source anyone reads. */
	public function testMacroSubtreeNotFlagged(): Void {
		// The chain's parent inside the quotation is `ReturnExpr`, which IS a host — so only
		// the opaque-subtree skip can refuse it. A `macro var q = …` fixture would prove
		// nothing: `VarExpr` is not a host kind and the host gate would reject it first.
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tfinal e = macro return a ? 1 : b ? 2 : 3;\n\t}\n}').length);
		Assert.equals(1, violations('class C {\n\tfunction f():Int {\n\t\treturn a ? 1 : b ? 2 : 3;\n\t}\n}').length);
	}

	/**
	 * The VALUE POSITION OF A `case` ARM is a host: the arm's `:` and the statement's `;`
	 * delimit it exactly as a `return` does, and the formatter renders the ladder there under
	 * `expressionIf: "next"`. The five `getColorPickerType` arms in TM are the shape.
	 */
	public function testCaseArmValueFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(CASE_ARM_CHAIN);
		Assert.equals(1, es.length);
		Assert.equals('if (a) 1 else if (b) 2 else 3', es[0].text);
	}

	/** A `default:` arm is the same value slot as a `case` one. */
	public function testDefaultArmValueFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f(v:Int):Void {\n\t\tswitch v {\n\t\t\tdefault:\n\t\t\t\ta ? 1 : b ? 2 : 3;\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('if (a) 1 else if (b) 2 else 3', es[0].text);
	}

	/**
	 * The arm host reaches the chain THROUGH the expression-statement wrapper, and that
	 * transparency is scoped to an arm: a bare expression statement in an ordinary block is
	 * NOT a host, so the gate cannot come off wider than the slot it was opened for.
	 */
	public function testBareExpressionStatementNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\ta ? 1 : b ? 2 : 3;\n\t}\n}').length);
	}

	/** The emitted arm is the fixed point: the if-chain form draws nothing back. */
	public function testCaseArmOutputIsAFixedPoint(): Void {
		final once: String = RefactorSupport.applyEdits(CASE_ARM_CHAIN, edits(CASE_ARM_CHAIN));
		Assert.equals(0, violations(once).length);
		Assert.equals(0, ternaryExpressionViolations(once).length);
		Assert.equals(0, switchExpressionViolations(once).length);
	}

	/**
	 * A ternary nested in the THEN arm leaves only ONE condition on the else spine, below the
	 * minimum — so the chain was silent. INVERSION reaches it: `a ? (b ? A : B) : C` is
	 * `if (!a) C else if (b) A else B`. Both readings enumerate the same three outcomes,
	 * starting from opposite ends, so no implication between `a` and `b` is needed — and `a` is
	 * evaluated exactly ONCE, as the ternary evaluated it.
	 */
	public function testInvertedThenNestedChainFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(THEN_NESTED);
		Assert.equals(1, es.length);
		Assert.equals('if (!a) 3 else if (b) 1 else 2', es[0].text);
	}

	/** The negation goes through the `guard-*` family's engine, so a `||` compound De Morgans instead of taking a `!( … )` wrap. */
	public function testInvertedConditionDeMorgansACompound(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Int {\n\t\treturn a || c ? b ? 1 : 2 : 3;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (!a && !c) 3 else if (b) 1 else 2', es[0].text);
	}

	/** The same engine FLIPS an equality operator rather than wrapping it — `n == 0` negates to `n != 0`, which is what a reader expects. */
	public function testInvertedConditionFlipsAnEqualityOperator(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Int {\n\t\treturn n == 0 ? b ? 1 : 2 : 3;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (n != 0) 3 else if (b) 1 else 2', es[0].text);
	}

	/**
	 * The engine's own WORTH GATE is honoured where declining costs nothing: this chain already
	 * holds the minimum rungs, so the fold would buy ONE more and pay a `!( … )` wrap for it —
	 * the ordered comparison cannot be proven NaN- and null-free, so the rung keeps its inner
	 * ternary, which IS the canon.
	 */
	public function testInversionDeclinedForAnUnprovableOrderedComparison(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Int {\n\t\treturn d ? 0 : a < b ? c ? 1 : 2 : 3;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (d) 0 else if (a < b) c ? 1 : 2 else 3', es[0].text);
	}

	/**
	 * Below the minimum the same wrap IS taken, because declining would leave exactly the nested
	 * ternary this rule exists to remove — and the conjunctive form it replaces paid for that
	 * chain with the whole condition DUPLICATED, worse than one wrap on every axis.
	 */
	public function testUnprovableOrderedComparisonStillFoldsWhenTheFoldIsTheFinding(): Void {
		final es: Array<{ span: Span, text: String }> = edits('class C {\n\tfunction f():Int {\n\t\treturn a < b ? c ? 1 : 2 : 3;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (!(a < b)) 3 else if (c) 1 else 2', es[0].text);
	}

	/** With the operand types known the same comparison DOES flip — which is what proves the engine is being ASKED rather than mirrored. */
	public function testInversionFlipsAProvenOrderedComparison(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f(a:Int, b:Int):Int {\n\t\treturn a < b ? c ? 1 : 2 : 3;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (a >= b) 3 else if (c) 1 else 2', es[0].text);
	}

	/**
	 * Only the LAST rung can invert. A nested rung with more chain behind it has no flat form at
	 * all — every flat chain must test its condition, and one branch would still need the other
	 * condition — so its inner ternary survives, which IS the canon.
	 */
	public function testNonFinalNestedRungKeepsItsTernary(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Int {\n\t\treturn a ? b ? 1 : 2 : c ? 3 : 4;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (a) b ? 1 : 2 else if (c) 3 else 4', es[0].text);
	}

	/**
	 * NO DEPTH CAP. Inversion duplicates nothing, so it recurses: each level moves the current
	 * terminal up into a rung and exposes the next nested ternary as the new last rung. Growth is
	 * linear, and the whole nest flattens in one pass.
	 */
	public function testInversionRecursesThroughEveryNestedLevel(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Int {\n\t\treturn a ? b ? c ? 1 : 2 : 3 : 4;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (!a) 4 else if (!b) 3 else if (c) 1 else 2', es[0].text);
	}

	/**
	 * The TM `TimeInput` accessor (anonymized): the null guard inverts to `if (sel == null) …`,
	 * and `sel` still narrows to non-null in every branch behind it.
	 */
	public function testInvertedNullGuardStillNarrows(): Void {
		final es: Array<{ span: Span, text: String }> = edits(TM_NULL_GUARDED_ACCESSOR);
		Assert.equals(1, es.length);
		Assert.equals("if (sel == null) '' else if (sel.data.data == -1) 'N/A' else sel.data.text", es[0].text);
		Assert.equals(0, violations(RefactorSupport.applyEdits(TM_NULL_GUARDED_ACCESSOR, es)).length);
	}

	/** The output is the fixed point: the emitted chain has no ternary rung left, so nothing draws it back. */
	public function testInvertedOutputIsAFixedPoint(): Void {
		final once: String = RefactorSupport.applyEdits(THEN_NESTED, edits(THEN_NESTED));
		Assert.equals(0, violations(once).length);
		Assert.equals(0, ternaryExpressionViolations(once).length);
	}

	/**
	 * The condition is evaluated ONCE, so nothing has to be pure. A call and a getter-backed
	 * property read both convert now; both were refused while the emitted form duplicated the
	 * condition, and that gate is gone with the duplication.
	 */
	public function testImpureConditionInverts(): Void {
		final es: Array<{ span: Span, text: String }> = edits('class C {\n\tfunction f():Int {\n\t\treturn g() ? b ? 1 : 2 : 3;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (!g()) 3 else if (b) 1 else 2', es[0].text);
		Assert.equals(
			1,
			violations(
				'class C {\n\tpublic var p(get, never):Bool;\n\n\tfunction get_p():Bool {\n\t\treturn true;\n\t}\n\n'
				+ '\tfunction f():Int {\n\t\treturn p ? b ? 1 : 2 : 3;\n\t}\n}'
			).length
		);
	}

	/**
	 * A comment inside the condition span would be welded into a negation the engine REBUILDS, so
	 * the inversion fails closed. The chain still converts through its else spine, with the
	 * comment carried into the slot it came from and the nested ternary left alone.
	 */
	public function testCommentInTheConditionDeclinesTheInversion(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Int {\n\t\treturn d ? 0 : a == c // why\n\t\t\t? b ? 1 : 2 : 3;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (d) 0 else if (a == c) // why\nb ? 1 : 2 else 3', es[0].text);
	}

	/**
	 * The chain's OWN terminal is exempt from the else-less scan, and that exemption is about
	 * THAT node's parse. An inverted chain ends on a DIFFERENT node, so it is scanned like a rung
	 * value — an ` else ` written after the whole chain would otherwise re-parent onto it.
	 */
	public function testElseLessTerminalOfAnInvertedChainNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg(() -> a ? b ? p() : if (q) s() : r());\n\t}\n}').length);
	}

	/** The chain's terminal MOVES into a rung value, where the emitted ` else ` follows it — so an else-less conditional there is refused too. */
	public function testElseLessMovedTerminalNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg(() -> a ? b ? p() : r() : if (q) s());\n\t}\n}').length);
	}

	/** The replaced region still ends at the ORIGINAL chain's last token, not at the terminal the inversion promoted. */
	public function testInvertedEditSpanCoversTheWholeChain(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar x = a ? b ? 1 : 2 : 3 ;\n\t}\n}';
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.equals('if (!a) 3 else if (b) 1 else 2', es[0].text);
		Assert.equals(src.indexOf('3 ;') + 1, es[0].span.to);
	}

	/**
	 * An explicit `ParenExpr` is a host: the parens the author already wrote are the value's
	 * delimiters, so the ladder goes INSIDE them and the rule adds no punctuation of its own.
	 */
	public function testParenthesisedOperandIsAHost(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f():Float {\n\t\treturn h - ih - (folder ? shared ? 1.0 : 2.0 : 3.0);\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('if (!folder) 3.0 else if (shared) 1.0 else 2.0', es[0].text);
	}

	/**
	 * The edit replaces the ternary only, never the parens around it — which is the whole reason
	 * this host is safe. Dropping them would let a FOLLOWING operand bind into the `else` branch:
	 * measured on `-cpp` and `--interp`, `h - if (c) 1.0 else 2.0 - ih` is 118 where the
	 * parenthesised form is 78, and both compile, so nothing would catch the change.
	 */
	public function testParenthesisedOperandKeepsItsParens(): Void {
		final src: String = 'class C {\n\tfunction f():Float {\n\t\treturn (a ? b ? 1.0 : 2.0 : 3.0) / k;\n\t}\n}';
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		final rewritten: String = src.substring(0, es[0].span.from) + es[0].text + src.substring(es[0].span.to);
		Assert.isTrue(rewritten.indexOf('(if (!a) 3.0 else if (b) 1.0 else 2.0) / k') >= 0);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-if-expression-chain'));
		Assert.isTrue([for (c in Linter.builtins()) c.id()].contains('prefer-if-expression-chain'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferIfExpressionChain().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function ternaryExpressionViolations(src: String): Array<Violation> {
		return new PreferTernaryExpression().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function switchExpressionViolations(src: String): Array<Violation> {
		return new PreferSwitchExpression().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: PreferIfExpressionChain = new PreferIfExpressionChain();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
