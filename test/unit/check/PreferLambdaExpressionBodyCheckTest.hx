package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferArrowCallback;
import anyparse.check.PreferLambdaExpressionBody;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `prefer-lambda-expression-body` check: an ARROW lambda whose `{ … }` body holds one
 * value `return`, one bare expression statement, or one control-flow expression statement
 * (`if` / `switch` / `for` / `while` / `throw`) is flagged `Info` and `fix` replaces the
 * whole block with that expression. A multi-statement body, a value-less `return;`, a
 * declaration, a `do … while`, a `#if` region, an empty brace pair, a `function` literal
 * (owned by `prefer-arrow-callback`) and a comment in a dropped region are all left alone.
 *
 * Two gates guard the emitted text, and one fixture each pins them: a lambda in the
 * brace-less then-branch of an `if` that HAS an `else` is refused when its body could absorb
 * that `else` (`testDanglingElsePositionRefused`, `testDanglingElseOnTheValueArmRefused` for
 * the same hazard on the value arms, and `testDanglingElseThroughConditionalRegionRefused`
 * for the flat-sibling projection of a `#if` region), and a control-flow statement whose
 * terminator cannot be recovered structurally — `while (c);`, `if (c) return;`, a `#if`
 * region on the tail — is refused outright rather than emitted without it.
 */
class PreferLambdaExpressionBodyCheckTest extends Test {

	public function testValueReturnBodyFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tg(v -> { return v + 1; });\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('prefer-lambda-expression-body', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this single-statement lambda body can be an expression body', vs[0].message);
	}

	public function testFixValueReturn(): Void {
		final es: Array<{ span: Span, text: String }> = edits('class C {\n\tfunction f():Void {\n\t\tg(v -> { return v + 1; });\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('v + 1', es[0].text);
	}

	/** The Void twin: a block holding one bare expression. A Haxe block's value IS its last expression, so the collapse is type-preserving. */
	public function testFixExpressionStatementBody(): Void {
		final es: Array<{ span: Span, text: String }> = edits('class C {\n\tfunction f():Void {\n\t\tg(v -> { trace(v); });\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('trace(v)', es[0].text);
	}

	/** The multi-line TM shape this check was written for (`FileSystemBase` move comparator, anonymized). */
	public function testFixTmComparatorFixture(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f():Void {\n\t\titems.sort((a:SortedPairEntryDetail, b:SortedPairEntryDetail) -> {\n'
			+ '\t\t\treturn a.nodeName < b.nodeName ? -1 : a.nodeName > b.nodeName ? 1 : 0;\n\t\t});\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('a.nodeName < b.nodeName ? -1 : a.nodeName > b.nodeName ? 1 : 0', es[0].text);
	}

	/**
	 * The parenthesised form is a DIFFERENT node kind — a `params…, body` struct rather than
	 * the 2-child infix `v -> …` — so it exercises the "body is the last child" invariant a
	 * second time, on the layout that could break it.
	 */
	public function testFixParenLambdaForm(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Void {\n\t\tg((a, b) -> { return a - b; });\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('a - b', es[0].text);
	}

	public function testMultipleStatementsNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg(v -> { trace(v); trace(v); });\n\t}\n}').length);
	}

	/** A value-less `return;` is a distinct kind, absent from `valueReturnKinds` — `(…) -> return;` is not an expression body. */
	public function testVoidReturnNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg(v -> { return; });\n\t}\n}').length);
		// `return;` projects with ZERO children, so the arity guard rejects it before the
		// kind test ever runs. A local declaration projects as `VarStmt t (IdentExpr v)` —
		// exactly one child — so it clears that guard and is the fixture that actually
		// isolates the kind whitelist.
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg(v -> { var t = v; });\n\t}\n}').length);
	}

	public function testLocalDeclarationBodyNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg(v -> { var t:Int = v; });\n\t}\n}').length);
	}

	/**
	 * A `#if` region projects as ONE `Conditional` child of the block, which is neither
	 * accepted statement kind — so a branch-dependent body fails closed. This is also why the
	 * check reads the PLAIN tree: the branch-aware projection would split the region into
	 * per-branch statement lists and could present one branch as the whole body.
	 */
	public function testConditionalRegionNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f():Void {\n\t\tg(v -> {\n\t\t\t#if js\n\t\t\ttrace(v);\n\t\t\t#end\n\t\t});\n\t}\n}').length
		);
	}

	/** An already-collapsed body is the 0-finding fixed point. */
	public function testExpressionBodyNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg(v -> v + 1);\n\t}\n}').length);
	}

	/** `() -> {}` parses as an empty OBJECT literal, not a block — no block kind, no match. */
	public function testEmptyBraceBodyNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg(() -> {});\n\t}\n}').length);
	}

	/** The braces, the `return` keyword and the `;` all go away, so a comment sitting there fails the guard closed. */
	public function testCommentInDroppedRegionNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f():Void {\n\t\tg(v -> {\n\t\t\t// why\n\t\t\treturn v;\n\t\t});\n\t}\n}').length
		);
	}

	/** A comment INSIDE the copied expression rides along, so the site still fires. */
	public function testCommentInsideValueFlagged(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Void {\n\t\tg(v -> { return h(/* why */ v); });\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('h(/* why */ v)', es[0].text);
	}

	/**
	 * A `function` literal is `prefer-arrow-callback`'s node — it normalises the literal INTO an
	 * arrow, which this check collapses on the next pass. Matching it here too would report one
	 * site twice; this asserts the split, not just the silence.
	 */
	public function testFunctionLiteralOwnedByArrowCallback(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tg(function(v) { return v + 1; });\n\t}\n}';
		Assert.equals(0, violations(src).length);
		Assert.equals(1, new PreferArrowCallback().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()).length);
	}

	/** A reification subtree is spliced code a consumer may pattern-match, not source anyone reads. */
	public function testMacroSubtreeNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\treturn macro var q = v -> { return v; };\n\t}\n}').length);
	}

	/**
	 * Nested lambdas both match, but the outer edit CONTAINS the inner one, so only the outer
	 * is emitted; the inner surfaces on the next fixed-point pass.
	 */
	public function testNestedLambdasEmitOnlyTheOuterEdit(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tg(v -> { return w -> { return w; }; });\n\t}\n}';
		Assert.equals(2, violations(src).length);
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.equals('w -> { return w; }', es[0].text);
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tg(v -> w -> { return w; });\n\t}\n}', CanonicalEdit.applyEdits(src, es));
	}

	/**
	 * The replaced region is the BLOCK's span, which ends at `}` — trailing trivia is outside
	 * it, so the emitted body cannot swallow a following comment nor weld onto what comes
	 * next. Only a fixture with trivia AFTER the brace pins that.
	 */
	public function testEditStopsAtTheClosingBrace(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tg(v -> { return v; } /* tail */);\n\t}\n}';
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.equals(src.indexOf('} /* tail */') + 1, es[0].span.to);
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tg(v -> v /* tail */);\n\t}\n}', CanonicalEdit.applyEdits(src, es));
	}

	/**
	 * A block that is not the lambda's TAIL is not its body — `->` parses its body greedily,
	 * so `v -> { return 1; } != null` projects the block as a grandchild. That greediness is
	 * what spares this check the slot analysis `prefer-ternary-expression` needs.
	 */
	public function testBlockUnderAnOperatorNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = v -> { return 1; } != null;\n\t}\n}').length);
	}

	/**
	 * An `if` is an EXPRESSION in Haxe and a block's value is its last expression, so the
	 * collapse preserves the body's type. Its span runs through the `;` that ended its
	 * then-branch, and that terminator is dropped: `if (c) f();` emits `if (c) f()`.
	 */
	public function testIfWithoutElseFlagged(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tg(() -> { if (c) f(); });\n\t}\n}';
		Assert.equals(1, violations(src).length);
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.equals('if (c) f()', es[0].text);
	}

	/**
	 * With an `else` the INTERIOR `;` survives — only the trailing one is dropped. A `;`
	 * before `else` is legal Haxe, so `if (c) f(); else g()` is the verbatim slice minus its
	 * own terminator, not a re-assembled text.
	 */
	public function testIfElseBodyRefusedOffTheTrailingSlot(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg(() -> { if (c) f(); else g2(); }, onError);\n\t}\n}').length);
	}

	/**
	 * … and accepted IN the trailing argument slot, where nothing follows the body but `)`, so
	 * the `;`/`else`/comma run the braces separate elsewhere cannot form.
	 */
	public function testIfElseBodyAcceptedInTheTrailingSlot(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tg(() -> { if (c) f(); else g2(); });\n\t}\n}').length);
	}

	/**
	 * The canary shape for the terminator strip: a braced then-branch ends on `}`, not on a
	 * `;`, so the recursion must stop at the block and keep both braces. Stripping there
	 * would emit `if (c) { a(); b() }` and lose a statement's terminator.
	 */
	public function testMultiStatementThenBranchKeepsItsBraces(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Void {\n\t\tg(() -> { if (c) { a(); b(); } });\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (c) { a(); b(); }', es[0].text);
	}

	/** A bare `switch` ends on its own `}`, which is NOT a droppable terminator — the full span is kept. */
	public function testSwitchBodyRefused(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f():Void {\n\t\tg(() -> { switch v { case 1: f(); } }, onError);\n\t}\n}').length
		);
	}

	/** Both loop forms whose body is their LAST child end on their body's `;`, which the strip drops. */
	public function testLoopBodiesDropTheirTerminator(): Void {
		final forEdits: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Void {\n\t\tg(() -> { for (x in xs) f(x); });\n\t}\n}');
		Assert.equals(1, forEdits.length);
		Assert.equals('for (x in xs) f(x)', forEdits[0].text);
		final whileEdits: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Void {\n\t\tg(() -> { while (c) f(); });\n\t}\n}');
		Assert.equals(1, whileEdits.length);
		Assert.equals('while (c) f()', whileEdits[0].text);
	}

	/**
	 * A `throw` is an expression that unifies with any type, so a block holding one collapses
	 * like the others. This is the shape the check used to REFUSE, and the refusal fixture
	 * moved to the local declaration in `testVoidReturnNotFlagged`.
	 */
	public function testThrowBodyFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits('class C {\n\tfunction f():Void {\n\t\tg(v -> { throw v; });\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('throw v', es[0].text);
	}

	/**
	 * A lambda argument FOLLOWED by more arguments: the emitted body ends before the `,` that
	 * separates them, so the call's argument list survives the collapse intact. Only an
	 * applied edit pins that — the edit text alone cannot show what it welds onto.
	 */
	public function testLambdaArgumentFollowedByMoreArguments(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tm(() -> { if (c) f(); }, 2);\n\t}\n}';
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tm(() -> if (c) f(), 2);\n\t}\n}', CanonicalEdit.applyEdits(src, es));
	}

	/** An `else if` chain is ONE `if` statement, so it collapses whole — every link rides along in the verbatim slice. */
	public function testIfElseIfChainBodyRefused(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f():Void {\n\t\tg(() -> { if (a) x() else if (b) y() else z(); }, onError);\n\t}\n}').length
		);
	}

	/**
	 * THE hazard the position gate exists for. `if (x) cb = () -> { if (c) g(); }; else h();`
	 * collapsed to `if (x) cb = () -> if (c) g(); else h();` re-parents `else h()` onto the
	 * INNER `if (c)` — Haxe allows a `;` before `else` — so the outer else-branch stops
	 * running. The output still PARSES, so the `--fix` re-parse gate waves it through; only
	 * this gate stops it. The lambda sits in the brace-less then-branch of an `if` that has an
	 * `else`, the one position where an `else` can follow, and its body holds an else-less
	 * conditional, the one construct that would absorb it.
	 */
	public function testDanglingElsePositionRefused(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (x) cb = () -> { if (c) g(); }; else h();\n\t}\n}').length);
	}

	/**
	 * The same unshielded position with a body that holds NO else-less conditional: a `switch`
	 * cannot absorb the trailing `else`, so the site is accepted. This is what proves the gate
	 * is the else-less scan and not a blanket "unshielded ⇒ refuse".
	 */
	public function testUnshieldedPositionWithoutElseLessConditionalFlagged(): Void {
		Assert.equals(
			1, violations('class C {\n\tfunction f():Void {\n\t\tif (x) cb = () -> { for (i in xs) g(i); }; else h();\n\t}\n}').length
		);
	}

	/**
	 * The VALUE arms carry the same hazard and the same gate answers it: `return if (c) g();`
	 * emits an else-less `if`, so in the unshielded then-branch position the trailing
	 * `else h()` re-parents onto it exactly as in `testDanglingElsePositionRefused`. This
	 * shape predates the control-flow arm — it was simply unanswerable before the position
	 * walk existed.
	 */
	public function testDanglingElseOnTheValueArmRefused(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f():Void {\n\t\tif (x) cb = () -> { return if (c) g(); }; else h();\n\t}\n}').length
		);
	}

	/**
	 * The same hazard reached THROUGH a `#if` region. A conditional projects every branch's
	 * nodes as FLAT siblings, so the region's first child has a following sibling and the
	 * "separated by a non-`else` token" rule would call it shielded — but that sibling is the
	 * `#else` branch, and under `-D A` the child is the last thing the then-branch emits, with
	 * `else h()` next. Collapsed, `else h()` re-parents onto the inner `if (c)` and the outer
	 * else-branch stops running (reproduced with `--interp`), so a conditional region's
	 * children inherit its exposure instead of claiming a sibling shield.
	 */
	public function testDanglingElseThroughConditionalRegionRefused(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tif (x)\n\t\t\t#if A\n\t\t\tcb = () -> { if (c) g(); };\n\t\t\t#else\n'
				+ '\t\t\tcb = null;\n\t\t\t#end\n\t\telse\n\t\t\th();\n\t}\n}'
			).length
		);
	}

	/**
	 * A control-flow statement whose TAIL is a `#if` region has no recoverable terminator: the
	 * region closes on a mandatory `#end` and the `;` to drop sits inside it, ahead of that
	 * keyword. Emitting the region whole gives `() -> if (c) #if A f(); #end`, which the Haxe
	 * compiler rejects once the branch is active — and anyparse's own parser accepts it, so
	 * the `--fix` re-parse gate is not the net here either.
	 */
	public function testConditionalRegionOnTheTailNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tg(() -> {\n\t\t\tif (c)\n\t\t\t\t#if A\n\t\t\t\tf();\n\t\t\t\t#end\n\t\t});\n\t}\n}'
			).length
		);
	}

	/**
	 * A metadata-prefixed sole statement projects ONE `MetaExpr` whose span swallows the `;`,
	 * so the value arm's verbatim slice would emit `@:privateAccess if (c) h();` — text `haxe`
	 * rejects and this parser accepts, so the re-parse gate is no net. The gapless-terminator
	 * test refuses it. Predates the control-flow arm.
	 */
	public function testGaplessTerminatedStatementNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg(() -> { @:privateAccess if (c) h(); });\n\t}\n}').length);
	}

	/**
	 * `while (c);` ends on an EMPTY statement whose whole source IS the terminator, so no
	 * structural end survives the strip — emitting `while (c)` would not compile. The
	 * recursion returns null and the site is refused.
	 */
	public function testEmptyStatementLoopTailNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg(() -> { while (c); });\n\t}\n}').length);
	}

	/**
	 * A value-less `return;` / `break;` is a CHILDLESS terminated node — its `;` is not
	 * recoverable from any child span — so a control-flow statement ending in one is refused
	 * rather than emitted with the terminator still attached.
	 */
	public function testValuelessExitInsideControlFlowNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg(() -> { if (c) return; });\n\t}\n}').length);
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg(() -> { for (x in xs) break; });\n\t}\n}').length);
	}

	/**
	 * `do … while` is deliberately outside the accepted set: its condition is the LAST child,
	 * so the body-tail recursion the strip relies on does not describe it. It falls through to
	 * the arity guard (two children) and is refused there.
	 */
	public function testDoWhileNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg(() -> { do f(); while (c); });\n\t}\n}').length);
	}

	/** The fail-closed comment guard holds on the new arm too: the braces go away, so a comment sitting there refuses the site. */
	public function testCommentInDroppedRegionAroundControlFlowNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f():Void {\n\t\tg(() -> {\n\t\t\t// why\n\t\t\tif (c) f();\n\t\t});\n\t}\n}').length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-lambda-expression-body'));
		Assert.isTrue([for (c in Linter.builtins()) c.id()].contains('prefer-lambda-expression-body'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	/**
	 * SYMPTOM (a), ARG-LIST EXPLOSION. The collapsed head line no longer fits, so the writer
	 * breaks the ENCLOSING call's argument list apart: `Api.authenticate(` is left alone on its
	 * own line with the arguments re-flowed under it. The head line loses 46 characters (63 ->
	 * 17), but the rendering is LINE-NEUTRAL at 9 lines either way, so CLAUSE 1 is what refuses
	 * this site and clause 2 never runs on it — the clause-2 pin is
	 * `testOrphanArrowWithBlankLinesRefused`. Nothing structural distinguishes this site from an
	 * accepted one — only the rendering does.
	 */
	public function testArgListExplosionRefused(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tApi.authenticate(emailAddress, passwordValue, errorMessage -> {\n'
			+ '\t\t\tif (errorMessage != null) presenter.showErrorBanner(errorMessage);\n\t\t}, false);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * DE-BRACE IN PLACE. The body is too wide for the head line, so it stays one line down and
	 * the collapse removes exactly the braces: the head loses its ` {`, the closing `});`
	 * becomes `);`, and no interior line moves — line-neutral at 9 lines either way, head two
	 * characters shorter (40 -> 38). Clause 2 accepts it: a one-statement body carries no
	 * braces under the brace policy, and saving a line was never the point. Recorded here as
	 * the shape that used to be refused for being line-neutral.
	 */
	public function testOrphanArrowDeBracesInPlace(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\titemData.forEachChild(childItemData -> {\n'
			+ '\t\t\tcollectedEntries.push(new EntryDescriptor(childItemData.identifier, childItemData.displayName,'
			+ ' childItemData.sortIndex));\n\t\t});\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	/**
	 * THE BLANK-LINE CASE, refused. Structurally the de-brace above, with a blank line on each
	 * side of the statement inside the block. The braces take those blanks with them, so the
	 * collapse shrinks the file (11 rendered lines to 9) on the author's blank lines alone — and
	 * `interiorSurvives` refuses exactly that: the region changed by more than the two brace
	 * tokens. It was accepted while the check only looked at the head line, which is the residual
	 * the interior test closes.
	 */
	public function testOrphanArrowWithBlankLinesRefused(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\titemData.forEachChild(childItemData -> {\n\n'
			+ '\t\t\tcollectedEntries.push(new EntryDescriptor(childItemData.identifier, childItemData.displayName,'
			+ ' childItemData.sortIndex));\n\n\t\t});\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * THE CONSTRUCT BODY. A block-bodied `if` whose condition is itself too wide for one line.
	 * This used to be refused for two reasons at once: the collapse was line-neutral, and the
	 * writer hoisted the wrapped condition into the arrow head. The writer no longer does that
	 * (`BodyFit.arrowConstructHeadWidth` moves the body to the continuation line), so what is
	 * left is a plain de-brace — 11 lines either way, head shortened by its ` {` and nothing
	 * else — and clause 2 accepts it. The real-tree site this fixture was drawn from is the one
	 * the whole slice exists for.
	 */
	public function testWrappedConditionConstructBodyDeBracesInPlace(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tsession.forEachShare(sessionUser -> {\n'
			+ '\t\t\tif (sessionUser.isActive && !collectedResults.exists(candidate -> candidate.identifier == sessionUser.identifier)) {\n'
			+ '\t\t\t\tcollectedResults.push(sessionUser);\n\t\t\t}\n\t\t});\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	/**
	 * CANARY for the accept side, control-flow arm: the collapsed `-> if (…) …` fits on the head
	 * line, so the body's two lines disappear and the head gains 33 characters. Both clauses
	 * hold and the site still fires — the precondition is a payoff test, not a blanket refusal
	 * of the control-flow arm.
	 */
	public function testControlFlowCollapseThatFitsStillFlagged(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tpopupQueue.forEach(entry -> {\n'
			+ '\t\t\tif (entry.isModal) entry.close();\n\t\t});\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	/** CANARY for the accept side, value arm: a `return` body collapsing onto the head line. */
	public function testReturnArmCollapseToOneLineStillFlagged(): Void {
		final src: String =
			'class C {\n\tfunction f():Void {\n\t\tmoves.sort((a, b) -> {\n\t\t\treturn a.path < b.path ? -1 : 1;\n\t\t});\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	/**
	 * A comment TRAILING the single statement is appended after the emitted body instead of
	 * refusing the site — the gap between them is the statement's own terminator, which
	 * `emittedEnd` strips because a `;` before the enclosing `)` does not parse.
	 */
	public function testTrailingCommentIsAppendedNotDropped(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f():Void {\n\t\twaitToken(success -> {\n\t\t\tif (success) doRequest(); // handlers\n\t\t});\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('if (success) doRequest() // handlers\n', es[0].text);
	}

	/**
	 * GUARD: the appended comment carries a NEWLINE. Without it the enclosing `)` would follow a
	 * `//` comment on one line and the collapsed source would not parse — `renderedLines` would
	 * fold to null and the site would be refused with no diagnostic, which is how this was found.
	 */
	public function testAppendedTrailingCommentEndsWithABreak(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f():Void {\n\t\twaitToken(success -> {\n\t\t\tif (success) doRequest(); // handlers\n\t\t});\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.isTrue(StringTools.endsWith(es[0].text, '\n'));
	}

	/** GUARD: a comment BETWEEN two statements is not a trailing one — the site still refuses. */
	public function testInteriorCommentStillRefuses(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg(() -> {\n\t\t\t// why\n\t\t\tf();\n\t\t});\n\t}\n}').length);
	}

	/**
	 * The de-brace strips the emitted body's own `;`, and a trailing comment rides along with
	 * it - the last interior line reads `tokenError(); // handlers` before and
	 * `tokenError() // handlers` after. Comparing that line modulo a `;` at the LINE end
	 * instead of at the CODE end refused every multi-line body documented this way.
	 */
	public function testTrailingCommentOnTheLastInteriorLineStillCollapses(): Void {
		Assert.equals(
			1,
			violations(
				'class C {\n\tfunction f():Void {\n\t\twaitToken(success -> {\n\t\t\tif (success)\n\t\t\t\tdoRequest();\n\t\t\telse\n'
				+ '\t\t\t\ttokenError(); // handlers\n\t\t});\n\t}\n}'
			).length
		);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferLambdaExpressionBody().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: PreferLambdaExpressionBody = new PreferLambdaExpressionBody();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
