package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferTernaryExpression;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import anyparse.check.Linter;

/**
 * The `prefer-ternary-expression` check: a 2-branch `if`-EXPRESSION in value position is
 * flagged `Info` and `fix` rewrites it to `cond ? then : else`. A CHAIN (its `else` another
 * `if`-expression, or the node itself an `else if` link), a bodied-construct branch, a control
 * -exit branch, and a comment in a dropped region are all left alone.
 */
class PreferTernaryExpressionCheckTest extends Test {

	public function testInitializerIfExpressionFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tvar x = if (c) 1 else 2;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('prefer-ternary-expression', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this two-branch if-expression can be a ternary', vs[0].message);
	}

	public function testFixInitializer(): Void {
		final es: Array<{ span: Span, text: String }> = edits('class C {\n\tfunction f():Void {\n\t\tvar x = if (c) 1 else 2;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('c ? 1 : 2', es[0].text);
	}

	/** Value position is a property of the KIND, so `return` / argument positions need no extra handling. */
	public function testFixReturnPosition(): Void {
		final es: Array<{ span: Span, text: String }> = edits('class C {\n\tfunction f():Int {\n\t\treturn if (c) 1 else 2;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('c ? 1 : 2', es[0].text);
	}

	public function testFixArgumentPosition(): Void {
		final es: Array<{ span: Span, text: String }> = edits('class C {\n\tfunction f():Void {\n\t\tg(if (c) 1 else 2);\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('c ? 1 : 2', es[0].text);
	}

	/** The multi-line TM shape this check was written for (`ReadyMadeFileSystem.getFileName`, anonymized). */
	public function testFixMultiLineFixture(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f(pathText:String):Int {\n\t\tfinal start:Int = if (lastSepIndex > 1 || !pathText.startsWith(\':\'))\n\t\t\tlastSepIndex\n\t\telse\n\t\t\t1;\n\t\treturn start;\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('lastSepIndex > 1 || !pathText.startsWith(\':\') ? lastSepIndex : 1', es[0].text);
	}

	/**
	 * A CHAIN belongs to `prefer-if-expression-*`, and BOTH ends are refused: the head by the
	 * branch gate (its `else` is another `if`-expression) and the inner `else if` LINK by the
	 * slot gate (its parent is that head, which is no delimited slot). Reverting either flips
	 * this test. Before either existed, the fixed point unravelled a chain one level per pass
	 * into a nested ternary.
	 */
	public function testChainNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar x = if (a) 1 else if (b) 2 else 3;\n\t}\n}').length);
	}

	public function testNoElseNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar x = if (c) 1;\n\t}\n}').length);
	}

	public function testStatementIfNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (c) g();\n\t\telse h();\n\t}\n}').length);
	}

	public function testBlockBranchNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar x = if (c) { g(); h(); } else 2;\n\t}\n}').length);
	}

	public function testSwitchBranchNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f():Void {\n\t\tvar x = if (c) 1 else switch v {\n\t\t\tcase _: 2;\n\t\t};\n\t}\n}').length
		);
	}

	/** A real TM site before the exit gate existed: `a ? x : return` disguises control flow as a value. */
	public function testReturnBranchNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tfinal t:Float = if (c) 1 else return;\n\t}\n}').length);
	}

	public function testThrowBranchNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar x = if (c) 1 else throw "e";\n\t}\n}').length);
	}

	/** The `if (` / `)` / `else` glue is dropped, so a comment sitting there fails the guard closed. */
	public function testCommentInDroppedRegionNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar x = if (c) /* why */ 1 else 2;\n\t}\n}').length);
	}

	/** A comment INSIDE a copied span rides along, so the site still fires. */
	public function testCommentInsideBranchFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tvar x = if (c) g(/* why */ 1) else 2;\n\t}\n}').length);
	}

	/** A ternary condition binds no tighter than `?:`, so it is the one shape that gets parentheses. */
	public function testTernaryConditionParenthesised(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Void {\n\t\tvar x = if (a ? b : c) 1 else 2;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('(a ? b : c) ? 1 : 2', es[0].text);
	}

	public function testComparisonConditionBare(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Void {\n\t\tvar x = if (a > 1 && b) 1 else 2;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('a > 1 && b ? 1 : 2', es[0].text);
	}

	/**
	 * The SLOT gate. An `if`-expression is self-delimiting, a ternary is not: `a || if (c) x
	 * else y` groups as `a || (…)`, `a || c ? x : y` as `(a || c) ? x : y` — same tokens, a
	 * different value, and no compile error to catch it.
	 */
	public function testOperandPositionNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar v = a || if (c) x else y;\n\t}\n}').length);
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar n = 1 + if (c) 2 else 3;\n\t}\n}').length);
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = !if (c) x else y;\n\t}\n}').length);
	}

	/** An assignment r-value IS a delimited tail slot, so it is accepted (child 0, the target, is not). */
	public function testAssignmentRvalueFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits('class C {\n\tfunction f():Void {\n\t\tbtn.x = if (c) 1 else 2;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('c ? 1 : 2', es[0].text);
	}

	/**
	 * A nested `if`-expression in the THEN branch is refused BOTH ways — as a branch (absent
	 * from the whitelist) and as a node whose parent is no delimited slot. Rewriting the inner
	 * one used to splice away the trivia its span runs through, welding `q` onto the outer
	 * `else` into the identifier `qelse` — which still PARSES, so the `--fix` gate waved it on.
	 */
	public function testNestedThenBranchNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():String {\n\t\tfinal x:String = if (a)\n\t\t\tif (b)\n\t\t\t\tp\n\t\t\telse\n\t\t\t\tq\n\t\telse\n\t\t\tr;\n\t\treturn x;\n\t}\n}'
			).length
		);
	}

	/** A reification subtree is spliced code a consumer may pattern-match, not source anyone reads. */
	public function testMacroSubtreeNotFlagged(): Void {
		// The `if`-expression sits in a DELIMITED slot (`macro var q = …`), so only the
		// opaque-subtree skip can refuse it — a bare `macro if (…)` would already be
		// refused by the slot gate and would prove nothing about this one.
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\treturn macro var q = if (c) 1 else 2;\n\t}\n}').length);
	}

	/** Identifier branch values, not integers — the one lexical case where a bad splice does not re-space itself. */
	public function testFixIdentifierBranches(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f():String {\n\t\tfinal x:String = if (a)\n\t\t\tp\n\t\telse\n\t\t\tq;\n\t\treturn x;\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('a ? p : q', es[0].text);
	}

	/**
	 * The replaced region stops at the else-branch: an `if`-expression span runs on through
	 * the trivia after its last token, and consuming that would splice away spacing the
	 * author wrote. (The weld this was found through — `q` + a following `else` fusing into
	 * `qelse` — is refused one gate earlier now, by the slot gate.)
	 */
	public function testEditSpanStopsAtElseBranch(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tg(if (c) a else b , 1);\n\t}\n}';
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.equals(src.indexOf('b ,') + 1, es[0].span.to);
	}

	/**
	 * The array-INDEX slot is delimited on the same terms as a call argument — `[` and `]`
	 * bound it — so a bare `?:` may land there. Shares `RefShape.delimitedTailChildKinds`
	 * with `redundant-parens`; the RECEIVER at child 0 is an operand position, so nothing
	 * licenses a bare `?:` there — but an if-expression can only REACH that position already
	 * parenthesized (`if (c) p else q[i]` parses the index into the then-branch), and the
	 * paren is a delimited host in its own right. So the receiver case is flagged by the
	 * PAREN, not by the index slot, and the edit lands inside the parens it keeps — measured
	 * identical on the pre-`IndexAccess` engine, i.e. not this arm's doing.
	 */
	public function testIndexSlotFlagged(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Void {\n\t\tvar x = arr[if (c) 1 else 2];\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('c ? 1 : 2', es[0].text);
		final rec: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Void {\n\t\tvar x = (if (c) p else q)[i];\n\t}\n}');
		Assert.equals(1, rec.length);
		Assert.equals('c ? p : q', rec[0].text);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-ternary-expression'));
		Assert.isTrue([for (c in Linter.builtins()) c.id()].contains('prefer-ternary-expression'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	/**
	 * A `${ … }` interpolation is a delimited slot like any other — `${` and `}` bound its
	 * one expression, which parses at the loosest precedence — so a bare `?:` may land
	 * there. The plain-string twin discriminates: `"…"` never interpolates, so the same
	 * characters are text carrying no `if`-expression to flag.
	 */
	public function testInterpolationSlotFlagged(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits("class C {\n\tfunction f():Void {\n\t\tvar x = '${if (c) 1 else 2}';\n\t}\n}");
		Assert.equals(1, es.length);
		Assert.equals('c ? 1 : 2', es[0].text);
		Assert.equals(0, violations("class C {\n\tfunction f():Void {\n\t\tvar x = \"${if (c) 1 else 2}\";\n\t}\n}").length);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferTernaryExpression().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: PreferTernaryExpression = new PreferTernaryExpression();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
