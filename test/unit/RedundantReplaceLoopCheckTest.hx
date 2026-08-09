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
 * call. Three arms. Arm A (two literals, `B` does not contain `S`): `Info`, autofix
 * collapses the loop to the single unconditional assignment. Arm B (two literals, `B`
 * contains `S`): `Warning`, report-only — the loop is infinite for any input containing
 * `S`. Arm C (either operand a PARAMETER): `Info`, report-only — the outcome is the
 * caller's to decide, and only a containment guard that DOMINATES the loop suppresses it.
 * A PARAMETER `S` with a LITERAL `B` splits out of arm C, since the literal decides the
 * verdict without the caller: an EMPTY `B` makes the loop merely REDUNDANT (report-only —
 * a collapse would change the degenerate empty-`S` hang into a return), a NON-EMPTY one
 * loops forever for exactly those `S` that occur in it. `DefaultOff`.
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
		final src: String = 'class C {\n\tpublic var now:String;\n\tfunction f():Void {\n'
			+ '\t\twhile (this.now.indexOf(\' \') != -1) this.now = this.now.replace(\' \', \'_\');\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testNonStringReceiverNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(now:Array<String>):Void {\n'
			+ '\t\twhile (now.indexOf(\' \') != -1) now = now.replace(\' \', \'_\');\n\t}\n}';
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
		final src: String = 'class C {\n\tfunction f(now:String):Void {\n\t\tvar other:String = now;\n'
			+ '\t\twhile (now.indexOf(\' \') != -1) other = other.replace(\' \', \'_\');\n\t}\n}';
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
		// crashdumper/SystemData.hx:314 — S is the parameter `word`, B the literal `''`. Exactly
		// why arm C must admit a literal / parameter MIX rather than demand two parameters.
		final vs: Array<Violation> = violations(stripWordSource());
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testUnguardedArmCCarriesNoCaveatClause(): Void {
		// No guard at all — the caveat clause is added only when an equality guard is there.
		final vs: Array<Violation> = violations(wrapParams('while (line.indexOf(word) != -1) line = line.replace(word, replace);'));
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals(-1, vs[0].message.indexOf('does not cover containment'));
	}

	public function testEqualityGuardDoesNotSuppress(): Void {
		// `S == B` rules out only the degenerate case; every `B` that merely CONTAINS `S` still
		// loops forever, so the guard sharpens the message and never removes the finding.
		final vs: Array<Violation> = violations(
			wrapParams('if (word == replace) return line;\n\t\twhile (line.indexOf(word) != -1) line = line.replace(word, replace);')
		);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.isTrue(vs[0].message.indexOf('does not cover containment') >= 0);
	}

	public function testLiteralSearchWithParameterReplacementFlagged(): Void {
		// The mirror of the `stripWord` mix: a LITERAL `S` in both positions and a PARAMETER `B`.
		final vs: Array<Violation> = violations(wrapParams('while (line.indexOf(\' \') != -1) line = line.replace(\' \', replace);'));
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(StringTools.startsWith(vs[0].message, 'potential infinite loop when replace contains \' \''));
	}

	public function testLambdaParameterOperandFlagged(): Void {
		// The `stripWord` canary written as a lambda: its parameters are just as caller-chosen as
		// a method's, so `lambdaKinds` must join the enclosing-function ancestor set.
		final src: String = 'class C {\n\tpublic static final strip = function(line:String, word:String):String {\n'
			+ '\t\twhile (line.indexOf(word) != -1) line = line.replace(word, \'\');\n\t\treturn line;\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testEnclosingMethodParameterInLambdaFlagged(): Void {
		// The loop sits in a LAMBDA, but `S` / `B` are the ENCLOSING METHOD's parameters — just as
		// caller-chosen as the lambda's own, so the parameter test walks OUTWARD through every
		// enclosing scope, not only the innermost one.
		final src: String = 'class C {\n\tpublic static function f(word:String, replace:String):String {\n'
			+ '\t\tfinal strip = function(line:String):String {\n'
			+ '\t\t\twhile (line.indexOf(word) != -1) line = line.replace(word, replace);\n\t\t\treturn line;\n\t\t};\n'
			+ '\t\treturn strip(\'x\');\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(StringTools.startsWith(vs[0].message, 'potential infinite loop when replace contains word'));
	}

	public function testEnclosingFunctionParameterInLocalFunctionFlagged(): Void {
		// The same outward walk through a named LOCAL function: `word` belongs to `outer`, which
		// ENCLOSES `inner`, so `outer`'s caller still chooses it and arm C applies.
		final src: String = 'class C {\n\tpublic static function outer(word:String):String {\n'
			+ '\t\tfunction inner(line:String):String {\n\t\t\twhile (line.indexOf(word) != -1) line = line.replace(word, \'_\');\n'
			+ '\t\t\treturn line;\n\t\t}\n\t\treturn inner(\'x\');\n\t}\n}';
		Assert.equals(1, violations(src).length);
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

	// --- arm C: only a guard that DOMINATES the loop suppresses it ---

	public function testGuardNestedInsideAnotherIfDoesNotSuppress(): Void {
		// The outer `if` may be false, so the guard need not have run at all.
		Assert.equals(
			1,
			violations(wrapParams(
				'if (line.length > 0) { if (replace.indexOf(word) != -1) return line; }\n'
				+ '\t\twhile (line.indexOf(word) != -1) line = line.replace(word, replace);'
			)).length
		);
	}

	public function testGuardInAnElseBranchDoesNotSuppress(): Void {
		// The `else` runs only when the head condition is false — not a proof about every path.
		Assert.equals(
			1,
			violations(wrapParams(
				'if (line.length > 0) return line;\n\t\telse if (replace.indexOf(word) != -1) return line;\n'
				+ '\t\twhile (line.indexOf(word) != -1) line = line.replace(word, replace);'
			)).length
		);
	}

	public function testGuardInsideALoopBodyDoesNotSuppress(): Void {
		// A `for` body may never run, so nothing inside it dominates what follows.
		Assert.equals(
			1,
			violations(wrapParams(
				'for (i in 0...0) if (replace.indexOf(word) != -1) return line;\n'
				+ '\t\twhile (line.indexOf(word) != -1) line = line.replace(word, replace);'
			)).length
		);
	}

	public function testGuardInsideASwitchArmDoesNotSuppress(): Void {
		// One arm of a switch is one path of several.
		Assert.equals(
			1,
			violations(wrapParams(
				'switch line {\n\t\t\tcase \'x\': if (replace.indexOf(word) != -1) return line;\n\t\t\tcase _:\n\t\t}\n'
				+ '\t\twhile (line.indexOf(word) != -1) line = line.replace(word, replace);'
			)).length
		);
	}

	public function testGuardInsideAConditionalRegionDoesNotSuppress(): Void {
		// A `#if windows` guard protects ONE target; suppressing on it silences every other.
		Assert.equals(
			1,
			violations(wrapParams(
				'#if windows\n\t\tif (replace.indexOf(word) != -1) return line;\n\t\t#end\n'
				+ '\t\twhile (line.indexOf(word) != -1) line = line.replace(word, replace);'
			)).length
		);
	}

	public function testGuardInsideANestedFunctionDoesNotSuppress(): Void {
		// A local function that nothing calls guards nothing.
		Assert.equals(
			1,
			violations(wrapParams(
				'function unused():String {\n\t\t\tif (replace.indexOf(word) != -1) return line;\n\t\t\treturn line;\n\t\t}\n'
				+ '\t\twhile (line.indexOf(word) != -1) line = line.replace(word, replace);'
			)).length
		);
	}

	public function testGuardOutsideTheLambdaDoesNotSuppress(): Void {
		// The containment guard sits in the enclosing METHOD, outside the lambda holding the loop.
		// Dominance is rooted at the INNERMOST function, so the guard is never read — the opposite
		// direction from the parameter test, which walks every enclosing scope.
		final src: String = 'class C {\n\tpublic static function f(word:String, replace:String):String {\n'
			+ '\t\tif (replace.indexOf(word) != -1) return word;\n\t\tfinal strip = function(line:String):String {\n'
			+ '\t\t\twhile (line.indexOf(word) != -1) line = line.replace(word, replace);\n\t\t\treturn line;\n\t\t};\n'
			+ '\t\treturn strip(\'x\');\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testGuardInsideTheLambdaSuppresses(): Void {
		// The same guard MOVED into the lambda does dominate the loop — the discriminating half of
		// the pair above, so neither test can pass for the other's reason.
		final src: String = 'class C {\n\tpublic static function f(word:String, replace:String):String {\n'
			+ '\t\tfinal strip = function(line:String):String {\n\t\t\tif (replace.indexOf(word) != -1) return line;\n'
			+ '\t\t\twhile (line.indexOf(word) != -1) line = line.replace(word, replace);\n\t\t\treturn line;\n\t\t};\n'
			+ '\t\treturn strip(\'x\');\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	// --- arm C: what a DOMINATING guard may look like ---

	public function testMultiStatementGuardBodySuppressesArmC(): Void {
		// The exit need not be the branch's ONLY statement — its LAST one is what decides.
		Assert.equals(
			0,
			violations(wrapParams(
				'if (replace.indexOf(word) != -1) { trace(\'refusing\'); return line; }\n'
				+ '\t\twhile (line.indexOf(word) != -1) line = line.replace(word, replace);'
			)).length
		);
	}

	public function testThrowingGuardSuppressesArmC(): Void {
		// A `throw` exits just as unconditionally as a `return`.
		Assert.equals(
			0,
			violations(wrapParams(
				'if (replace.indexOf(word) != -1) throw \'bad\';\n'
				+ '\t\twhile (line.indexOf(word) != -1) line = line.replace(word, replace);'
			)).length
		);
	}

	public function testBareVoidReturnGuardSuppressesArmC(): Void {
		final src: String = 'class C {\n\tpublic static function f(line:String, word:String, replace:String):Void {\n'
			+ '\t\tif (replace.indexOf(word) != -1) return;\n'
			+ '\t\twhile (line.indexOf(word) != -1) line = line.replace(word, replace);\n\t}\n}';
		Assert.equals(0, violations(src).length);
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
		// Behavioural, not gate-specific: `this.word` is neither a plain string literal nor a bare
		// identifier bound to a parameter, so it is not an operand this rule reads — several gates
		// agree on that and the test pins the OUTCOME rather than which one answers first.
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
		// `word` is a parameter of the SIBLING local function `helper`, which does NOT enclose the
		// loop — the outward walk climbs the loop's own chain of enclosing scopes and stops there.
		// The receiver type gate passes (`line:String`), so this pins the operand OUTCOME.
		final src: String = 'class C {\n\tpublic static function outer():String {\n\t\tfunction helper(word:String):String return word;\n'
			+ '\t\tfunction inner(line:String):String {\n\t\t\twhile (line.indexOf(word) != -1) line = line.replace(word, \'_\');\n'
			+ '\t\t\treturn line;\n\t\t}\n\t\treturn helper(\'y\') + inner(\'x\');\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	// --- arm C split: a LITERAL `B` with a PARAMETER `S` — the literal decides on its own ---

	public function testEmptyLiteralReplacementReportsRedundancyNotAnInfiniteLoop(): Void {
		// The `stripWord` canary. An empty `B` can never CONTAIN a non-empty `S`, and
		// `replace(word, '')` REMOVES rather than reinserts — the arm-C infinite-loop wording was
		// nonsense here, so the message must not carry a word of it.
		final vs: Array<Violation> = violations(stripWordSource());
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(-1, vs[0].message.indexOf('potential infinite loop'));
		Assert.equals(-1, vs[0].message.indexOf('reinserts'));
	}

	public function testEmptyLiteralReplacementNamesTheOneCallThatSuffices(): Void {
		final vs: Array<Violation> = violations(stripWordSource());
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.isTrue(
			StringTools.startsWith(vs[0].message, 'this while (line.indexOf(word) != -1) loop is redundant for any non-empty word')
		);
		Assert.isTrue(vs[0].message.indexOf('so one line = line.replace(word, \'\'); does the same work') >= 0);
	}

	public function testEmptyLiteralReplacementNotesTheDegenerateEmptySearch(): Void {
		// The one behavioural difference a collapse would make: `indexOf('') == 0`, so the ORIGINAL
		// loop hangs on an empty `word` — which is exactly why this stays report-only.
		final vs: Array<Violation> = violations(stripWordSource());
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.isTrue(vs[0].message.indexOf('the ORIGINAL loop spins forever on a degenerate word == \'\' (indexOf(\'\') == 0)') >= 0);
	}

	public function testEmptyLiteralReplacementNeverFixed(): Void {
		assertFixRefused(stripWordSource());
	}

	public function testEmptyLiteralReplacementSurvivesAnEqualityGuard(): Void {
		// `if (word == '') return line;` rules out the degenerate input, but redundancy is a property
		// of the loop shape, not of the caller — the verdict is guard-independent and the finding stays.
		final vs: Array<Violation> = violations(
			wrapParams('if (word == \'\') return line;\n\t\twhile (line.indexOf(word) != -1) line = line.replace(word, \'\');')
		);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.isTrue(
			StringTools.startsWith(vs[0].message, 'this while (line.indexOf(word) != -1) loop is redundant for any non-empty word')
		);
	}

	public function testNonEmptyLiteralReplacementNamesTheLiteralCondition(): Void {
		// A NON-empty literal `B` with a parameter `S` is still a live infinite-loop hazard, but a
		// precisely stated one: it fires for exactly those `word` that occur in the literal.
		final vs: Array<Violation> = violations(wrapParams('while (line.indexOf(word) != -1) line = line.replace(word, \'-*-\');'));
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(StringTools.startsWith(vs[0].message, 'potential infinite loop when word occurs in \'-*-\''));
		Assert.isTrue(vs[0].message.indexOf('those word that are a substring of \'-*-\'') >= 0);
		Assert.isTrue(vs[0].message.indexOf('the equal word == \'-*-\' included') >= 0);
	}

	public function testNonEmptyLiteralReplacementDropsTheOldContainsWording(): Void {
		// The old text read `when '-*-' contains word` — backwards, since it is `word` that must
		// occur in the literal, not the literal in `word`.
		final vs: Array<Violation> = violations(wrapParams('while (line.indexOf(word) != -1) line = line.replace(word, \'-*-\');'));
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals(-1, vs[0].message.indexOf('\'-*-\' contains word'));
	}

	public function testNonEmptyLiteralReplacementEqualityGuardSharpensTheMessage(): Void {
		final vs: Array<Violation> = violations(
			wrapParams('if (word == \'-*-\') return line;\n\t\twhile (line.indexOf(word) != -1) line = line.replace(word, \'-*-\');')
		);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.isTrue(vs[0].message.indexOf('rules out only the equal case') >= 0);
	}

	public function testNonEmptyLiteralReplacementContainmentGuardSuppresses(): Void {
		// The literal is the guard's RECEIVER here; the same `matchGuard` reads it, so the one static
		// proof still applies to the literal-`B` half of the split.
		Assert.equals(
			0,
			violations(wrapParams(
				'if (\'-*-\'.indexOf(word) != -1) return line;\n\t\twhile (line.indexOf(word) != -1) line = line.replace(word, \'-*-\');'
			)).length
		);
	}

	public function testNonEmptyLiteralReplacementNeverFixed(): Void {
		assertFixRefused(wrapParams('while (line.indexOf(word) != -1) line = line.replace(word, \'-*-\');'));
	}

	// --- message pins: the arms the split must leave byte-identical ---

	public function testArmAMessageUnchanged(): Void {
		Assert.equals(
			'this while (now.indexOf(\' \') != -1) loop runs at most once — replace() already replaces every occurrence; collapses to now = now.replace(\' \', \'_\');',
			violations(wrapFn('while (now.indexOf(\' \') != -1) now = now.replace(\' \', \'_\');'))[0].message
		);
	}

	public function testArmBMessageUnchanged(): Void {
		Assert.equals(
			'this loop never terminates for any now containing \'a\' — replace(\'a\', \'aa\') reintroduces it every time, since \'aa\' itself contains \'a\'',
			violations(wrapFn('while (now.indexOf(\'a\') != -1) now = now.replace(\'a\', \'aa\');'))[0].message
		);
	}

	public function testArmCBothParametersMessageUnchanged(): Void {
		Assert.equals(
			'potential infinite loop when replace contains word — replace(word, replace) reinserts word on every pass, so the guard never goes false',
			violations(wrapParams('while (line.indexOf(word) != -1) line = line.replace(word, replace);'))[0].message
		);
	}

	public function testArmCLiteralSearchParameterReplacementMessageUnchanged(): Void {
		// The MIRROR mix — a literal `S` with a parameter `B` — is still undecidable and keeps the
		// generic arm-C wording; only a literal `B` moved into the split.
		Assert.equals(
			'potential infinite loop when replace contains \' \' — replace(\' \', replace) reinserts \' \' on every pass, so the guard never goes false',
			violations(wrapParams('while (line.indexOf(\' \') != -1) line = line.replace(\' \', replace);'))[0].message
		);
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
	private inline function stripWordSource(): String {
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
		function resolver(file: String): LintConfig return LintConfig.parse(json);
		return Linter.run(
			[{ file: 'C.hx', source: source }], new HaxeQueryPlugin(), [new RedundantReplaceLoop()], resolver, applyEnablement
		);
	}

}
