package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.RedundantReplaceLoop;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;

/**
 * The `redundant-replace-loop` check: `while (x.indexOf(S) != -1) x = x.replace(S, B);`
 * (plus its reversed-comparison and `.contains()` spellings) is redundant BY
 * CONSTRUCTION — `StringTools.replace` already replaces every occurrence of `S` in one
 * call. Arm A (`B` does not contain `S`): `Info`, autofix collapses the loop to the
 * single unconditional assignment. Arm B (`B` contains `S`): `Warning`, report-only —
 * the loop is infinite for any input containing `S`. `DefaultOff`.
 */
class RedundantReplaceLoopCheckTest extends Test {

	// --- arm A: flagged + fixed ---

	public function testIndexOfShapeFlagged(): Void {
		final vs: Array<Violation> = violations(wrapFn('while (now.indexOf(\' \') != -1) now = now.replace(\' \', \'_\');'));
		Assert.equals(1, vs.length);
		Assert.equals('redundant-replace-loop', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testCanarySiteOneFlaggedAndFixed(): Void {
		// crashdumper/SessionData.hx:49 — ' ' -> '_', B does not contain S.
		assertFixCanonical(
			wrapFn('while (now.indexOf(\' \') != -1) now = now.replace(\' \', \'_\');'), 'now = now.replace(\' \', \'_\');', 'while ('
		);
	}

	public function testCanarySiteTwoFlaggedAndFixed(): Void {
		// crashdumper/SessionData.hx:50 — ':' -> "'", B does not contain S.
		assertFixCanonical(
			wrapFn('while (now.indexOf(\':\') != -1) now = now.replace(\':\', "\'");'), 'now = now.replace(\':\', "\'");', 'while ('
		);
	}

	public function testReversedComparisonFlagged(): Void {
		Assert.equals(1, violations(wrapFn('while (-1 != now.indexOf(\' \') ) now = now.replace(\' \', \'_\');')).length);
	}

	public function testContainsShapeFlagged(): Void {
		Assert.equals(1, violations(wrapFn('while (now.contains(\' \')) now = now.replace(\' \', \'_\');')).length);
	}

	public function testBracedBodyFlagged(): Void {
		Assert.equals(1, violations(wrapFn('while (now.indexOf(\' \') != -1) { now = now.replace(\' \', \'_\'); }')).length);
	}

	public function testFixCollapsesBracedBody(): Void {
		assertFixCanonical(
			wrapFn('while (now.indexOf(\' \') != -1) { now = now.replace(\' \', \'_\'); }'), 'now = now.replace(\' \', \'_\');', 'while ('
		);
	}

	public function testFixKeepsUnaffectedOuterCode(): Void {
		final src: String = wrapFn('trace(\'a\');\n\t\twhile (now.indexOf(\' \') != -1) now = now.replace(\' \', \'_\');\n\t\ttrace(\'b\');');
		final r = runAndExpectOne(src);
		switch RefactorSupport.canonicalize(src, r.check.fix(src, r.vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('trace(\'a\');') >= 0);
				Assert.isTrue(text.indexOf('trace(\'b\');') >= 0);
				Assert.isTrue(text.indexOf('while (') == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	// --- arm B: flagged, report-only, no fix ---

	public function testGrowingReplacementFlaggedAsWarning(): Void {
		final vs: Array<Violation> = violations(wrapFn('while (now.indexOf(\'a\') != -1) now = now.replace(\'a\', \'aa\');'));
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	public function testGrowingReplacementNotFixed(): Void {
		assertFixRefused(wrapFn('while (now.indexOf(\'a\') != -1) now = now.replace(\'a\', \'aa\');'));
	}

	public function testSelfReplacementFlaggedAsWarning(): Void {
		// B == S is the degenerate case of "B contains S" — still an infinite loop.
		Assert.equals(
			Severity.Warning, violations(wrapFn('while (now.indexOf(\'a\') != -1) now = now.replace(\'a\', \'a\');'))[0].severity
		);
	}

	// --- gates: not this pattern, left alone ---

	public function testDifferentSearchLiteralNotFlagged(): Void {
		// indexOf looks for 'a', replace targets 'b' — not the same-S pattern.
		Assert.equals(0, violations(wrapFn('while (now.indexOf(\'a\') != -1) now = now.replace(\'b\', \'c\');')).length);
	}

	public function testEqualityInsteadOfInequalityNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('while (now.indexOf(\' \') == -1) now = now.replace(\' \', \'_\');')).length);
	}

	public function testNonLiteralSearchNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('while (now.indexOf(needle) != -1) now = now.replace(needle, \'_\');')).length);
	}

	public function testNonLiteralReplacementNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('while (now.indexOf(\' \') != -1) now = now.replace(\' \', filler);')).length);
	}

	public function testExtraBodyStatementNotFlagged(): Void {
		Assert.equals(
			0, violations(wrapFn('while (now.indexOf(\' \') != -1) { now = now.replace(\' \', \'_\'); trace(now); }')).length
		);
	}

	public function testFieldAccessReceiverNotFlagged(): Void {
		// `this.now` is not a bare identifier binding — never a plain local/param.
		final src: String =
			'class C {\n\tpublic var now:String;\n\tfunction f():Void {\n\t\twhile (this.now.indexOf(\' \') != -1) this.now = this.now.replace(\' \', \'_\');\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testNonStringReceiverNotFlagged(): Void {
		final src: String =
			'class C {\n\tfunction f(now:Array<String>):Void {\n\t\twhile (now.indexOf(\' \') != -1) now = now.replace(\' \', \'_\');\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testUnannotatedReceiverNotFlagged(): Void {
		// No declared type to confirm String — a silent miss, not a wrong flag.
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(now):Void {\n\t\twhile (now.indexOf(\' \') != -1) now = now.replace(\' \', \'_\');\n\t}\n}'
			).length
		);
	}

	public function testDifferentBindingNotFlagged(): Void {
		// The assignment target is a DIFFERENT local (`other`), not the guarded receiver.
		final src: String =
			'class C {\n\tfunction f(now:String):Void {\n\t\tvar other:String = now;\n\t\twhile (now.indexOf(\' \') != -1) other = other.replace(\' \', \'_\');\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testPlainWhileLoopNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('while (now.length > 0) now = now.substring(1);')).length);
	}

	// --- registry / robustness ---

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('redundant-replace-loop'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-replace-loop'));
	}

	public function testDefaultOffSuppressed(): Void {
		Assert.equals(0, runGated(wrapFn('while (now.indexOf(\' \') != -1) now = now.replace(\' \', \'_\');'), '{}', true).length);
	}

	public function testOptInEnabled(): Void {
		final json: String = '{"rules":{"redundant-replace-loop":{"enabled":true}}}';
		Assert.equals(1, runGated(wrapFn('while (now.indexOf(\' \') != -1) now = now.replace(\' \', \'_\');'), json, true).length);
	}

	public function testExplicitSelectionBypassesGate(): Void {
		// applyEnablement=false is the --rule path: a DefaultOff rule runs regardless.
		Assert.equals(1, runGated(wrapFn('while (now.indexOf(\' \') != -1) now = now.replace(\' \', \'_\');'), '{}', false).length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0, violations('class Bad { function f(now:String) { while (now.indexOf(\' \') != -1) now = now.replace(\' \', \'_\');').length
		);
	}

	private function wrapFn(body: String): String {
		return 'class C {\n\tfunction f(now:String):Void {\n\t\t$body\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new RedundantReplaceLoop().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function assertFixCanonical(src: String, present: String, absent: String): Void {
		final r = runAndExpectOne(src);
		switch RefactorSupport.canonicalize(src, r.check.fix(src, r.vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf(present) >= 0);
				Assert.isTrue(text.indexOf(absent) == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	private function assertFixRefused(src: String): Void {
		final r = runAndExpectOne(src);
		Assert.equals(0, r.check.fix(src, r.vs, new HaxeQueryPlugin()).length);
	}

	private function runAndExpectOne(src: String): { check: RedundantReplaceLoop, vs: Array<Violation> } {
		final check: RedundantReplaceLoop = new RedundantReplaceLoop();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		return { check: check, vs: vs };
	}

	private function runGated(source: String, json: String, applyEnablement: Bool): Array<Violation> {
		final resolver: (String) -> LintConfig = function(file: String): LintConfig return LintConfig.parse(json);
		return Linter.run(
			[{ file: 'C.hx', source: source }], new HaxeQueryPlugin(), [new RedundantReplaceLoop()], resolver, applyEnablement
		);
	}

}
