package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.FoldStringLiterals;
import anyparse.check.JoinStringAppend;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * The `join-string-append` check: a run of >= 2 adjacent `x += e;` statements on the same
 * target (optionally started by one plain `x = e0;`) is flagged `Info`, and `fix` joins them
 * into a single `x += e1 + e2 + …;` / `x = e0 + e1 + …;`. `DefaultOff` — an opt-in
 * simplification, not a correctness rule.
 */
class JoinStringAppendCheckTest extends Test {

	public function testBasicFlagged(): Void {
		final vs: Array<Violation> = violations(wrap("str += ' line '; str += line;"));
		Assert.equals(1, vs.length);
		Assert.equals('join-string-append', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testFixTwoTerms(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap("str += ' line '; str += line;"));
		Assert.equals(1, es.length);
		Assert.equals("str += ' line ' + line;", es[0].text);
	}

	/** The Method-arm canary: three adjacent `+=`, a string literal proves the string context. */
	public function testFixThreeTerms(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap("str += cname; str += '.'; str += meth;"));
		Assert.equals(1, es.length);
		Assert.equals("str += cname + '.' + meth;", es[0].text);
	}

	/** Bonus arm: a plain `=` immediately followed by `+=` runs joins into one `=`. */
	public function testBonusArmFlaggedAndFixed(): Void {
		final vs: Array<Violation> = violations(wrap("str = 'a';\n\t\tstr += b;"));
		Assert.equals(1, vs.length);
		final es: Array<{ span: Span, text: String }> = edits(wrap("str = 'a';\n\t\tstr += b;"));
		Assert.equals("str = 'a' + b;", es[0].text);
	}

	public function testSingleStatementNotFlagged(): Void {
		Assert.equals(0, violations(wrap("str += line;")).length);
	}

	public function testDifferentTargetsNotFlagged(): Void {
		Assert.equals(0, violations(wrap("x += a;\n\t\ty += b;")).length);
	}

	/** A statement between the two `+=` blocks the join (evaluation would reorder). */
	public function testNonAdjacentNotFlagged(): Void {
		Assert.equals(0, violations(wrap("str += a;\n\t\tg();\n\t\tstr += b;")).length);
	}

	/** `str += str;` reads the run's own accumulating target — the fused form loses the intermediate value. */
	public function testSelfReferenceBlocksTwoStatementRun(): Void {
		Assert.equals(0, violations(wrap("str += a;\n\t\tstr += str;")).length);
	}

	/**
	 * The self-reference gate truncates rather than vetoes the whole block: `str += str.length`
	 * cannot join with the run BEFORE it (its own reference would read the wrong intermediate
	 * value), but it can start a fresh run of its own since a run's OWN first term always reads
	 * the pre-run value in both the original and the fused form.
	 */
	public function testSelfReferenceTruncatesAndRecovers(): Void {
		final body: String = 'var str:String;\n\t\tstr += a;\n\t\tstr += str.length;\n\t\tstr += c;';
		final vs: Array<Violation> = violations(wrap(body));
		Assert.equals(1, vs.length);
		final es: Array<{ span: Span, text: String }> = edits(wrap(body));
		Assert.equals(1, es.length);
		Assert.equals('str += str.length + c;', es[0].text);
	}

	public function testFloatTargetNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x:Float;\n\t\tx += 1;\n\t\tx += 2;')).length);
	}

	public function testIntTargetFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('var x:Int;\n\t\tx += 1;\n\t\tx += 2;'));
		Assert.equals(1, es.length);
		Assert.equals('x += 1 + 2;', es[0].text);
	}

	/** An unresolved target type with no string-literal proof stays a safe miss. */
	public function testUnresolvedTypeNoLiteralNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x:Foo;\n\t\tx += a;\n\t\tx += b;')).length);
	}

	/** No declared type at all, but a string literal in the run proves the context. */
	public function testStringLiteralProvesContextEvenUntyped(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap("var s;\n\t\ts += 'x';\n\t\ts += y;"));
		Assert.equals(1, es.length);
		Assert.equals("s += 'x' + y;", es[0].text);
	}

	/** A ternary term binds looser than `+` — the fold wraps it in parens. */
	public function testParensAroundNonAtomicOperand(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap("var str:String;\n\t\tstr += cond ? a : b;\n\t\tstr += 'x';"));
		Assert.equals(1, es.length);
		Assert.equals("str += (cond ? a : b) + 'x';", es[0].text);
	}

	/** A comment between the two statements would be dropped by the join. */
	public function testCommentBetweenStatementsNotFlagged(): Void {
		Assert.equals(0, violations(wrap("var str:String;\n\t\tstr += 'x';\n\t\t// note\n\t\tstr += y;")).length);
	}

	/** A field / index target is not a bare identifier and is left alone. */
	public function testFieldTargetNotFlagged(): Void {
		Assert.equals(0, violations(wrap('this.str += a;\n\t\tthis.str += b;')).length);
	}

	public function testOtherCompoundOperatorNotFlagged(): Void {
		Assert.equals(0, violations(wrap('x -= a;\n\t\tx -= b;')).length);
	}

	/**
	 * A `switch` case body is a statement list too, deliberately NOT one of
	 * `ControlFlowSupport.blockKinds()` (that set's other consumers reason about
	 * fall-through) — scanned separately via `caseBranchKind` / `defaultBranchKind`. The
	 * `Method(cname, meth)` shape from the TM `CrashDumper.printStackItem` canary.
	 */
	public function testSwitchCaseBodyFlagged(): Void {
		final body: String = "switch (itm) {\n\t\t\tcase Method(cname, meth):\n\t\t\t\tstr += cname;\n\t\t\t\tstr += '.';\n\t\t\t\tstr += meth;\n\t\t}";
		final es: Array<{ span: Span, text: String }> = edits(wrap(body));
		Assert.equals(1, es.length);
		Assert.equals("str += cname + '.' + meth;", es[0].text);
	}

	/** The `default:` branch has no leading pattern child — scanned the same way as a `case`. */
	public function testDefaultBranchBodyFlagged(): Void {
		final body: String = "switch (itm) {\n\t\t\tdefault:\n\t\t\t\tstr += cname;\n\t\t\t\tstr += '.';\n\t\t\t\tstr += meth;\n\t\t}";
		final es: Array<{ span: Span, text: String }> = edits(wrap(body));
		Assert.equals(1, es.length);
		Assert.equals("str += cname + '.' + meth;", es[0].text);
	}

	/** End-to-end through the canonical writer: the emitted file holds the joined statement. */
	public function testFixOutputJoins(): Void {
		final out: String = applyFixOnce(wrap("str += ' line '; str += line;"));
		Assert.isTrue(out.indexOf("str += ' line ' + line;") != -1);
	}

	/**
	 * Fixpoint cascade: `join-string-append` produces `str += ' line ' + line;`, and a
	 * SUBSEQUENT `fold-adjacent-string-literals` pass over that output folds it further
	 * into `str += ' line $line';` — the composition the two rules are designed to reach
	 * over successive `lint --fix` passes.
	 */
	public function testCascadesWithFoldStringLiterals(): Void {
		final afterJoin: String = applyFixOnce(wrap("str += ' line '; str += line;"));
		final fold: FoldStringLiterals = new FoldStringLiterals();
		final vs2: Array<Violation> = fold.run([{ file: 'C.hx', source: afterJoin }], new HaxeQueryPlugin());
		final es2: Array<{ span: Span, text: String }> = fold.fix(afterJoin, vs2, new HaxeQueryPlugin());
		final afterFold: String = switch RefactorSupport.canonicalize(afterJoin, es2, true, new HaxeQueryPlugin(), null) {
			case Ok(text): text;
			case Err(message): throw message;
		};
		Assert.isTrue(afterFold.indexOf("str += ' line $line';") != -1, 'expected interpolated form in: $afterFold');
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('join-string-append'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('join-string-append'));
	}

	/** Wrap a statement body in a minimal parseable class + method. */
	private function wrap(body: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$body\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new JoinStringAppend().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: JoinStringAppend = new JoinStringAppend();
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
