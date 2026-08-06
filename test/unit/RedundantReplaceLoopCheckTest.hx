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
		final src: String = wrapFn(
			'trace(\'a\');\n\t\twhile (now.indexOf(\' \') != -1) now = now.replace(\' \', \'_\');\n\t\ttrace(\'b\');'
		);
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
		Assert.equals(0, violations(wrapFn('while (now.indexOf(\' \') != -1) { now = now.replace(\' \', \'_\'); trace(now); }')).length);
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
			violations('class C {\n\tfunction f(now):Void {\n\t\twhile (now.indexOf(\' \') != -1) now = now.replace(\' \', \'_\');\n\t}\n}')
				.length
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

	// --- arm C: a parameter operand, report-only ---

	public function testBothParametersFlaggedAsInfo(): Void {
		final vs: Array<Violation> = violations(wrapParams('while (line.indexOf(word) != -1) line = line.replace(word, replace);'));
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals('redundant-replace-loop', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(StringTools.startsWith(vs[0].message, 'potential infinite loop when'));
	}

	public function testCanaryReplaceWordFlagged(): Void {
		// crashdumper/SystemData.hx:310 — the equality guard reads like protection but covers only
		// the degenerate `word == replace`; a `replace` that merely CONTAINS `word` still loops.
		final src: String = 'class C {\n\tpublic static function replaceWord(line:String, word:String, replace:String):String {\n'
			+ '\t\tif (word == replace) return line;\n\t\twhile (line.indexOf(word) != -1) line = line.replace(word, replace);\n'
			+ '\t\treturn line;\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(StringTools.startsWith(vs[0].message, 'potential infinite loop when replace contains word'));
		Assert.isTrue(vs[0].message.indexOf('the word == replace guard does not cover containment') >= 0);
	}

	public function testCanaryStripWordFlagged(): Void {
		// crashdumper/SystemData.hx:317 — S is the parameter `word`, B the literal `''`. Exactly
		// why arm C must admit a literal / parameter MIX rather than demand two parameters.
		final vs: Array<Violation> = violations(stripWordSource());
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(StringTools.startsWith(vs[0].message, 'potential infinite loop when \'\' contains word'));
	}

	public function testEqualityGuardAloneDoesNotSuppress(): Void {
		// The caveat clause is only added when the guard is there; the finding stands either way.
		final vs: Array<Violation> = violations(wrapParams('while (line.indexOf(word) != -1) line = line.replace(word, replace);'));
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals(-1, vs[0].message.indexOf('does not cover containment'));
	}

	public function testContainmentGuardSuppressesArmC(): Void {
		Assert.equals(
			0,
			violations(wrapParams(
				'if (replace.indexOf(word) != -1) return line;\n\t\twhile (line.indexOf(word) != -1) line = line.replace(word, replace);'
			)).length
		);
	}

	public function testContainsGuardSuppressesArmC(): Void {
		Assert.equals(
			0,
			violations(wrapParams(
				'if (replace.contains(word)) return line;\n\t\twhile (line.indexOf(word) != -1) line = line.replace(word, replace);'
			)).length
		);
	}

	public function testGuardOnTheWrongOperandsDoesNotSuppress(): Void {
		// `line` is the receiver, not `B` — the guard says nothing about `replace` containing `word`.
		Assert.equals(
			1,
			violations(wrapParams(
				'if (line.indexOf(word) != -1) return line;\n\t\twhile (line.indexOf(word) != -1) line = line.replace(word, replace);'
			)).length
		);
	}

	public function testArmCNeverFixed(): Void {
		assertFixRefused(wrapParams('while (line.indexOf(word) != -1) line = line.replace(word, replace);'));
	}

	public function testLocalVarOperandNotFlagged(): Void {
		// A local `var` is not a parameter — the caller cannot choose it, and the check does not
		// track its value, so the loop is not this pattern.
		final src: String = 'class C {\n\tpublic static function f(line:String):String {\n\t\tvar word:String = \' \';\n'
			+ '\t\twhile (line.indexOf(word) != -1) line = line.replace(word, \'_\');\n\t\treturn line;\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testFieldAccessOperandNotFlagged(): Void {
		final src: String = 'class C {\n\tpublic var word:String = \' \';\n\tpublic function f(line:String):String {\n'
			+ '\t\twhile (line.indexOf(this.word) != -1) line = line.replace(this.word, \'_\');\n\t\treturn line;\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testMixedLiteralAndParameterSearchNotFlagged(): Void {
		// The two `S` positions must be the SAME thing: a literal in the guard and a parameter in
		// the `replace` call is not one search term.
		Assert.equals(0, violations(wrapParams('while (line.indexOf(\' \') != -1) line = line.replace(word, replace);')).length);
	}

	public function testParameterOfAnotherFunctionNotFlagged(): Void {
		// The loop sits in the LOCAL function `inner`, whose own parameters are just `line`; `word`
		// belongs to `outer`. The receiver type gate passes (`line:String`), so this exercises the
		// enclosing-function parameter gate and nothing else.
		final src: String = 'class C {\n\tpublic static function outer(word:String):String {\n'
			+ '\t\tfunction inner(line:String):String {\n\t\t\twhile (line.indexOf(word) != -1) line = line.replace(word, \'_\');\n'
			+ '\t\t\treturn line;\n\t\t}\n\t\treturn inner(\'x\');\n\t}\n}';
		Assert.equals(0, violations(src).length);
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

	/** A three-parameter static method body — the `replaceWord` shape arm C reads. */
	private function wrapParams(body: String): String {
		return
			'class C {\n\tpublic static function f(line:String, word:String, replace:String):String {\n\t\t$body\n\t\treturn line;\n\t}\n}';
	}

	/** The verbatim `stripWord` canary shape: a parameter `S` and a literal `B`. */
	private function stripWordSource(): String {
		return 'class C {\n\tpublic static function stripWord(line:String, word:String):String {\n'
			+ '\t\twhile (line.indexOf(word) != -1) line = line.replace(word, \'\');\n\t\treturn line;\n\t}\n}';
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
