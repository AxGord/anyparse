package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferArrowCallback;
import anyparse.check.PreferLambdaExpressionBody;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * The `prefer-lambda-expression-body` check: an ARROW lambda whose `{ … }` body holds one
 * value `return` or one bare expression statement is flagged `Info` and `fix` replaces the
 * whole block with that expression. A multi-statement body, a value-less `return;`, a
 * declaration, a `#if` region, an empty brace pair, a `function` literal (owned by
 * `prefer-arrow-callback`) and a comment in a dropped region are all left alone.
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
			'class C {\n\tfunction f():Void {\n\t\titems.sort((a:SortedPairEntryDetail, b:SortedPairEntryDetail) -> {\n\t\t\treturn a.nodeName < b.nodeName ? -1 : a.nodeName > b.nodeName ? 1 : 0;\n\t\t});\n\t}\n}'
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
		// kind test ever runs. A `throw` has exactly one child and clears that guard, so it
		// is the fixture that actually isolates the kind whitelist.
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg(v -> { throw v; });\n\t}\n}').length);
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
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tg(v -> w -> { return w; });\n\t}\n}', RefactorSupport.applyEdits(src, es));
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
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tg(v -> v /* tail */);\n\t}\n}', RefactorSupport.applyEdits(src, es));
	}

	/**
	 * A block that is not the lambda's TAIL is not its body — `->` parses its body greedily,
	 * so `v -> { return 1; } != null` projects the block as a grandchild. That greediness is
	 * what spares this check the slot analysis `prefer-ternary-expression` needs.
	 */
	public function testBlockUnderAnOperatorNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = v -> { return 1; } != null;\n\t}\n}').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-lambda-expression-body'));
		Assert.isTrue([for (c in Linter.builtins()) c.id()].contains('prefer-lambda-expression-body'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferLambdaExpressionBody().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: PreferLambdaExpressionBody = new PreferLambdaExpressionBody();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
