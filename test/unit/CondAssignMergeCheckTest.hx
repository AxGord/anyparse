package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.CondAssignMerge;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * The `cond-assign-merge` check: a statement-scope `#if … #else … #end` region whose every
 * arm is a single assignment to the SAME l-value (or a single declaration of the same local)
 * collapses into ONE statement whose r-value carries the directives. `Info`, DEFAULT OFF.
 *
 * The gates all fail closed: a missing `#else`, an arm with zero or two statements, a
 * non-plain assignment, a chained `a = b = c`, a differing l-value / declaration prefix, a
 * r-value that itself holds directives, a comment inside the region, and a region that is
 * not a direct child of a statement list are safe misses.
 */
class CondAssignMergeCheckTest extends Test {

	public function testAssignPairFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('#if mobile\n\t\tscale = 2;\n\t\t#else\n\t\tscale = 1.2;\n\t\t#end'));
		Assert.equals(1, vs.length);
		Assert.equals('cond-assign-merge', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(
			'every branch of this conditional-compilation region assigns the same target - merge it into one assignment with a conditional r-value',
			vs[0].message
		);
	}

	public function testFixAssignPair(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('#if mobile\n\t\tscale = 2;\n\t\t#else\n\t\tscale = 1.2;\n\t\t#end'));
		Assert.equals(1, es.length);
		Assert.equals('scale = #if mobile 2 #else 1.2 #end;', es[0].text);
	}

	/** An `#elseif` chain merges too, each clause keeping its own condition. */
	public function testFixElseifChain(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('#if mobile\n\t\tscale = 2;\n\t\t#elseif air\n\t\tscale = 3;\n\t\t#else\n\t\tscale = 1.2;\n\t\t#end')
		);
		Assert.equals(1, es.length);
		Assert.equals('scale = #if mobile 2 #elseif air 3 #else 1.2 #end;', es[0].text);
	}

	/** A dotted / indexed l-value merges as long as its text is identical in every arm. */
	public function testFixMemberLvalue(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('#if mobile\n\t\ta.b[0] = 2;\n\t\t#else\n\t\ta.b[0] = 3;\n\t\t#end'));
		Assert.equals(1, es.length);
		Assert.equals('a.b[0] = #if mobile 2 #else 3 #end;', es[0].text);
	}

	/** The declaration sibling: same keyword, name and type in every arm collapses to one declaration. */
	public function testFixVarDeclaration(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('#if mobile\n\t\tvar q: Int = 2;\n\t\t#else\n\t\tvar q: Int = 3;\n\t\t#end'));
		Assert.equals(1, es.length);
		Assert.equals('var q: Int = #if mobile 2 #else 3 #end;', es[0].text);
	}

	public function testFixFinalDeclaration(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('#if mobile\n\t\tfinal q = 2;\n\t\t#else\n\t\tfinal q = 3;\n\t\t#end'));
		Assert.equals(1, es.length);
		Assert.equals('final q = #if mobile 2 #else 3 #end;', es[0].text);
	}

	/** A missing `#else` leaves the assignment conditional — merging would make it unconditional. */
	public function testNoElseArmNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tscale = 2;\n\t\t#end')).length);
	}

	/** An `#elseif` chain that never reaches `#else` is still a conditional assignment. */
	public function testElseifChainWithoutElseNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tscale = 2;\n\t\t#elseif air\n\t\tscale = 3;\n\t\t#end')).length);
	}

	public function testEmptyArmNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tscale = 2;\n\t\t#elseif air\n\t\t#else\n\t\tscale = 3;\n\t\t#end')).length);
	}

	public function testTwoStatementArmNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tscale = 2;\n\t\tg();\n\t\t#else\n\t\tscale = 3;\n\t\t#end')).length);
	}

	public function testDifferentLvalueNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tscale = 2;\n\t\t#else\n\t\tother = 3;\n\t\t#end')).length);
	}

	public function testCompoundAssignNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tscale += 2;\n\t\t#else\n\t\tscale += 3;\n\t\t#end')).length);
	}

	/** `a = b = c` would leave the inner assignment inside the merged r-value. */
	public function testChainedAssignNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\ta = b = 2;\n\t\t#else\n\t\ta = b = 3;\n\t\t#end')).length);
	}

	/** A call statement is not a bare assignment. */
	public function testCallArmNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tg(1);\n\t\t#else\n\t\tg(2);\n\t\t#end')).length);
	}

	/** A declaration with no initializer has no r-value to carry the directives. */
	public function testBareDeclarationNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tvar q: Int;\n\t\t#else\n\t\tvar q: Int;\n\t\t#end')).length);
	}

	public function testDifferentDeclarationTypeNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tvar q: Int = 2;\n\t\t#else\n\t\tvar q: Float = 3;\n\t\t#end')).length);
	}

	public function testDifferentDeclarationKeywordNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tvar q = 2;\n\t\t#else\n\t\tfinal q = 3;\n\t\t#end')).length);
	}

	/** A multi-declarator arm (`var a = 1, b = 2;`) cannot be expressed as one conditional r-value. */
	public function testMultiDeclaratorNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tvar a = 1, b = 2;\n\t\t#else\n\t\tvar a = 3, b = 4;\n\t\t#end')).length);
	}

	/** A declaration arm paired with an assignment arm is not one shape. */
	public function testMixedDeclarationAndAssignNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tvar q = 2;\n\t\t#else\n\t\tq = 3;\n\t\t#end')).length);
	}

	/** An r-value that already carries directives would nest `#if` inside `#if`. */
	public function testNestedDirectiveRvalueNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\ta = #if air 1 #else 2 #end;\n\t\t#else\n\t\ta = 3;\n\t\t#end')).length);
	}

	/** A comment in the region cannot be placed in the merged form — the finding stays report-only. */
	public function testCommentInRegionReportOnly(): Void {
		final src: String = wrap('#if mobile\n\t\t// note\n\t\tscale = 2;\n\t\t#else\n\t\tscale = 1.2;\n\t\t#end');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.stringContains('comment', vs[0].message);
		Assert.equals(0, edits(src).length);
	}

	/** A member-scope `#if` region wraps declarations, not statements — out of scope. */
	public function testMemberScopeRegionNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\t#if mobile\n\tvar a: Int = 1;\n\t#else\n\tvar a: Int = 2;\n\t#end\n}').length);
	}

	/** A directive marker inside a string literal must never split the region into arms. */
	public function testDirectiveInStringLiteralNotFlagged(): Void {
		Assert.equals(0, violations(wrap("#if mobile\n\t\ta = '#else';\n\t\t#else\n\t\ta = 'x';\n\t\t#end")).length);
	}

	/** A condition holding a STRING must survive verbatim — the header slice is never whitespace-normalised. */
	public function testFixStringInCondition(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('#if (haxe_ver >= "3.1.3")\n\t\ts = b.getString(0);\n\t\t#else\n\t\ts = b.readString(0);\n\t\t#end')
		);
		Assert.equals(1, es.length);
		Assert.equals('s = #if (haxe_ver >= "3.1.3") b.getString(0) #else b.readString(0) #end;', es[0].text);
	}

	/** A ternary r-value goes inline as written — the branch value is a whole expression, whatever its shape. */
	public function testFixTernaryRvalue(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('#if !html5\n\t\tloader = fast ? new A() : new B();\n\t\t#else\n\t\tloader = new C();\n\t\t#end')
		);
		Assert.equals(1, es.length);
		Assert.equals('loader = #if !html5 fast ? new A() : new B() #else new C() #end;', es[0].text);
	}

	/** A condition broken across lines cannot go inline verbatim. */
	public function testMultiLineConditionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if (mobile\n\t\t\t|| air)\n\t\tscale = 2;\n\t\t#else\n\t\tscale = 3;\n\t\t#end')).length);
	}

	/** End-to-end through the canonical writer: the region is gone and the merged statement is there. */
	public function testFixOutputMerges(): Void {
		final out: String = applyFixOnce(wrap('#if mobile\n\t\tscale = 2;\n\t\t#else\n\t\tscale = 1.2;\n\t\t#end'));
		Assert.isTrue(out.indexOf('scale = #if mobile 2 #else 1.2 #end;') != -1);
		Assert.equals(-1, out.indexOf('#end\n'));
	}

	/** The merged inline form is a writer fixed point: a second canonicalize pass is byte-identical. */
	public function testMergedFormIsWriterIdempotent(): Void {
		final once: String = applyFixOnce(wrap('#if mobile\n\t\tscale = 2;\n\t\t#else\n\t\tscale = 1.2;\n\t\t#end'));
		Assert.equals(once, canonicalize(once, []));
		Assert.equals(once, canonicalize(canonicalize(once, []), []));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testIsDefaultOff(): Void {
		Assert.isTrue(new CondAssignMerge() is DefaultOff);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('cond-assign-merge'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('cond-assign-merge'));
	}

	/** Wrap a statement body in a minimal parseable class + method. */
	private function wrap(body: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$body\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new CondAssignMerge().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: CondAssignMerge = new CondAssignMerge();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

	/** Run `fix` and re-emit through the canonical writer — the `lint --fix` path in one pass. */
	private function applyFixOnce(src: String): String {
		return canonicalize(src, edits(src));
	}

	private function canonicalize(src: String, es: Array<{ span: Span, text: String }>): String {
		return switch RefactorSupport.canonicalize(src, es, true, new HaxeQueryPlugin(), null) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}
