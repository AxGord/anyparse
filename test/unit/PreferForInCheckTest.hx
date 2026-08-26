package unit;

import anyparse.check.Check;
import anyparse.check.Linter;
import anyparse.check.PreferForIn;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * The `prefer-for-in` check: a hand-rolled iterator protocol
 * `while (it.hasNext()) { final x = it.next(); … }` is flagged `Info` and rewritten to
 * `for (x in it) { … }`. The `for` form desugars to exactly that loop, so the rewrite is
 * behaviour-preserving including `break` / `continue` and the iterator's exhausted state after
 * the loop.
 *
 * Two arms. The plain arm rewrites the loop alone and leaves the iterator binding in place. The
 * INLINING arm fires when the statement immediately before the loop DECLARES the iterator and
 * nothing else in the scope reads it — then the declaration is dropped and its initializer
 * becomes the `for` iterable.
 *
 * The refusals carry the census that motivated the rule: a bare non-emptiness test
 * `if (it.hasNext())`, the peek idiom `it.hasNext() ? it.next() : null`, a second `it.next()` in
 * the body, a body whose first statement is not the `next()` binding, a one-statement body (a
 * pure drain, which would leave an empty loop), and an iterator read after the loop (which
 * refuses only the INLINING arm, not the rewrite).
 */
class PreferForInCheckTest extends Test {

	public function testFlagged(): Void {
		final vs: Array<Violation> = violations(fn('while (it.hasNext()) {\n\t\t\tfinal cp = it.next();\n\t\t\tuse(cp);\n\t\t}'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-for-in', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('for-in') != -1);
	}

	public function testPlainArmFixed(): Void {
		Assert.equals(
			fn('for (cp in it) {\n\t\t\tuse(cp);\n\t\t}'),
			applyFix(fn('while (it.hasNext()) {\n\t\t\tfinal cp = it.next();\n\t\t\tuse(cp);\n\t\t}'))
		);
	}

	public function testAnnotationOnBinderDropped(): Void {
		Assert.equals(
			fn('for (cp in it) {\n\t\t\tuse(cp);\n\t\t}'),
			applyFix(fn('while (it.hasNext()) {\n\t\t\tfinal cp:Int = it.next();\n\t\t\tuse(cp);\n\t\t}'))
		);
	}

	public function testVarBinderFixed(): Void {
		// A `for` binder IS writable in Haxe (measured on --interp, -js and -cpp), so a `var`
		// binding the body reassigns converts as safely as a `final` one.
		Assert.equals(
			fn('for (cp in it) {\n\t\t\tcp = 0;\n\t\t\tuse(cp);\n\t\t}'),
			applyFix(fn('while (it.hasNext()) {\n\t\t\tvar cp = it.next();\n\t\t\tcp = 0;\n\t\t\tuse(cp);\n\t\t}'))
		);
	}

	public function testLeadingCommentInBodyKept(): Void {
		Assert.equals(
			fn('for (cp in it) {\n\t\t\t// note\n\t\t\tuse(cp);\n\t\t}'),
			applyFix(fn('while (it.hasNext()) {\n\t\t\t// note\n\t\t\tfinal cp = it.next();\n\t\t\tuse(cp);\n\t\t}'))
		);
	}

	public function testInliningArmDropsTheDeclaration(): Void {
		Assert.equals(
			fn('for (cp in xs.iterator()) {\n\t\t\tuse(cp);\n\t\t}'),
			applyFix(fn('final iter = xs.iterator();\n\t\twhile (iter.hasNext()) {\n\t\t\tfinal cp = iter.next();\n\t\t\tuse(cp);\n\t\t}'))
		);
	}

	public function testIteratorReadAfterLoopKeepsTheDeclaration(): Void {
		Assert.equals(
			fn('final iter = xs.iterator();\n\t\tfor (cp in iter) {\n\t\t\tuse(cp);\n\t\t}\n\t\tuse(iter);'),
			applyFix(fn(
				'final iter = xs.iterator();\n\t\twhile (iter.hasNext()) {\n\t\t\tfinal cp = iter.next();\n\t\t\tuse(cp);\n\t\t}\n'
				+ '\t\tuse(iter);'
			))
		);
	}

	public function testCommentBetweenDeclAndLoopKeepsTheDeclaration(): Void {
		Assert.equals(
			fn('final iter = xs.iterator();\n\t\t// note\n\t\tfor (cp in iter) {\n\t\t\tuse(cp);\n\t\t}'),
			applyFix(fn(
				'final iter = xs.iterator();\n\t\t// note\n\t\twhile (iter.hasNext()) {\n\t\t\tfinal cp = iter.next();\n\t\t\tuse(cp);\n'
				+ '\t\t}'
			))
		);
	}

	public function testSameNameInASiblingFunctionStillInlines(): Void {
		// The occurrence scan is bounded by the nearest enclosing BLOCK, not by the file: `it` /
		// `iter` are among the most reused local names there are, and a whole-file count would
		// leave the inlining arm dead in any file with two iterator loops.
		Assert.equals(
			twoFunctions('for (v in xs.iterator()) {\n\t\t\tuse(v);\n\t\t}', 'for (w in ys.iterator()) {\n\t\t\tuse(w);\n\t\t}'),
			applyFix(twoFunctions(
				'final it = xs.iterator();\n\t\twhile (it.hasNext()) {\n\t\t\tfinal v = it.next();\n\t\t\tuse(v);\n\t\t}',
				'final it = ys.iterator();\n\t\twhile (it.hasNext()) {\n\t\t\tfinal w = it.next();\n\t\t\tuse(w);\n\t\t}'
			))
		);
	}

	public function testConditionalRegionIsNotAScope(): Void {
		// A `#if` region does not bind names in Haxe, so a declaration inside one is still visible
		// after `#end`, and the inlining arm must not delete it. What makes this pass is that the
		// raw `Conditional` kind is not a block kind AT ALL, so the scope stays the function body —
		// NOT the `CondBranch` subtraction in `readScopeKinds`, which no fixture can reach while
		// checks parse through `parseFile` (see that method's doc).
		final loop: String = 'while (iter.hasNext()) {\n\t\t\tfinal cp = iter.next();\n\t\t\tuse(cp);\n\t\t}';
		final rewritten: String = 'for (cp in iter) {\n\t\t\tuse(cp);\n\t\t}';
		Assert.equals(conditional(rewritten), applyFix(conditional(loop)));
	}

	public function testNonEmptinessCheckNotFlagged(): Void {
		Assert.equals(0, violations(fn('if (it.hasNext()) use(1);')).length);
	}

	public function testPeekIdiomNotFlagged(): Void {
		Assert.equals(0, violations(fn('final v = it.hasNext() ? it.next() : null;\n\t\tuse(v);')).length);
	}

	public function testSecondNextInBodyNotFlagged(): Void {
		Assert.equals(
			0,
			violations(fn('while (it.hasNext()) {\n\t\t\tfinal a = it.next();\n\t\t\tfinal b = it.next();\n\t\t\tuse(a + b);\n\t\t}'))
				.length
		);
	}

	public function testBodyNotStartingWithTheBindingNotFlagged(): Void {
		Assert.equals(
			0, violations(fn('while (it.hasNext()) {\n\t\t\tuse(0);\n\t\t\tfinal cp = it.next();\n\t\t\tuse(cp);\n\t\t}')).length
		);
	}

	/**
	 * An unbraced drain body USED to be refused, on the stated ground that it has no statement to
	 * take the binder's name from and inventing one is not a fixer's job. It converts now because
	 * the name is DERIVED rather than invented — see `deriveBinder`.
	 */
	public function testUnbracedBodyConverts(): Void {
		Assert.stringContains('for (value in it) out.push(value);', applyFix(fn('while (it.hasNext()) out.push(it.next());')));
	}

	public function testDrainOnlyBodyNotFlagged(): Void {
		Assert.equals(0, violations(fn('while (it.hasNext()) {\n\t\t\tfinal cp = it.next();\n\t\t}')).length);
	}

	public function testBinderNamedAfterTheIteratorNotFlagged(): Void {
		// The body must NOT re-read the name, or the occurrence gate refuses first and this
		// fixture would prove nothing about the binder-collision gate it is written for.
		Assert.equals(0, violations(fn('while (it.hasNext()) {\n\t\t\tfinal it = it.next();\n\t\t\tuse(0);\n\t\t}')).length);
	}

	public function testQualifiedReceiverNotFlagged(): Void {
		Assert.equals(0, violations(fn('while (this.it.hasNext()) {\n\t\t\tfinal cp = this.it.next();\n\t\t\tuse(cp);\n\t\t}')).length);
	}

	public function testInterpolatedIteratorUseNotFlagged(): Void {
		Assert.equals(0, violations(fn("while (it.hasNext()) {\n\t\t\tfinal cp = it.next();\n\t\t\tuse('$it');\n\t\t}")).length);
	}

	public function testMacroReificationNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tmacro function f() {\n\t\treturn macro {\n\t\t\twhile (it.hasNext()) {\n\t\t\t\tfinal cp = it.next();'
				+ '\n\t\t\t\tuse(cp);\n\t\t\t}\n\t\t};\n\t}\n}'
			).length
		);
	}

	/** The drain shape: no statement to take a name from, so the binder is the generic fallback. */
	public function testInlineBodyLoopConverts(): Void {
		Assert.stringContains('for (value in it) use(value);', applyFix(fn('while (it.hasNext()) use(it.next());')));
	}

	/** The comprehension header, whose element type is the ONE real naming signal in the source. */
	public function testComprehensionHeaderTakesTheElementTypeName(): Void {
		final src: String = 'class C {\n\tfunction f(it:Iterator<CodePoint>):Void {\n'
			+ '\t\tfinal a:Array<CodePoint> = [while (it.hasNext()) it.next()];\n\t}\n}';
		Assert.stringContains('[for (codePoint in it) codePoint]', applyFix(src));
	}

	/** A BASIC element type reads as a type, not as a value, so it falls through to the generic name. */
	public function testBasicElementTypeFallsBackToTheGenericBinder(): Void {
		final src: String =
			'class C {\n\tfunction f(it:Iterator<Int>):Void {\n\t\tfinal a:Array<Int> = [while (it.hasNext()) it.next()];\n\t}\n}';
		Assert.stringContains('[for (value in it) value]', applyFix(src));
	}

	/** A derived name already live at the loop is skipped, so the rewrite can never capture it. */
	public function testLiveBinderNameIsSkipped(): Void {
		Assert.stringContains(
			'for (element in it) use(element);', applyFix(fn('final value = 1;\n\t\twhile (it.hasNext()) use(it.next());'))
		);
	}

	/** TWO `next()` calls advance the iterator twice where `for` advances once — refused. */
	public function testTwoNextCallsRefused(): Void {
		Assert.equals(0, violations(fn('while (it.hasNext()) use(it.next() + it.next());')).length);
	}

	/** `hasNext()` must be the WHOLE condition. */
	public function testCompoundConditionRefused(): Void {
		Assert.equals(0, violations(fn('while (it.hasNext() && xs.length > 0) use(it.next());')).length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { while (it.hasNext()) { final cp = it.next(); use(cp);').length);
	}

	public function testRegisteredAndDefaultOff(): Void {
		final check: Null<Check> = Linter.byId('prefer-for-in');
		Assert.notNull(check);
		Assert.isTrue(Std.isOfType(check, DefaultOff), 'prefer-for-in is opt-in');
	}

	private function twoFunctions(first: String, second: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>):Void {\n\t\t$first\n\t}\n\n\tfunction g(ys:Array<Int>):Void {\n\t\t$second\n\t}\n}';
	}

	private function conditional(loop: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>):Void {\n\t\t#if A\n\t\tfinal iter = xs.iterator();\n\t\t$loop\n\t\t#end\n'
			+ '\t\tuse(iter);\n\t}\n}';
	}

	private function fn(stmts: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>, it:Iterator<Int>, out:Array<Int>):Void {\n\t\t$stmts\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new PreferForIn().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function applyFix(source: String): String {
		return CheckFixture.fixedSource(new PreferForIn(), source);
	}

}
