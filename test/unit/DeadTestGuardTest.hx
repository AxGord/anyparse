package unit;

import anyparse.check.CondRegionLiveness;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CondDirectives;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

/**
 * Every `#if` guard under `test/` must be one THIS build can prove live.
 *
 * js/node is the only runner this project has, and `sys` is not defined there — hxnodejs
 * supplies `sys.FileSystem` / `sys.io.File` without the flag. A test method whose body sits
 * inside a bare `#if sys` therefore compiles to its `#else` arm, which in this repo is
 * `Assert.pass('non-sys target')`: the method reports a success and asserts nothing. At the
 * fork point of the slice that added this gate the tree held 218 such guard sites across 23
 * classes — 167 whole test methods and 178 compiled `Assert.pass('non-sys target')` calls,
 * counted twice over (a preprocessor simulation over `test/`, and the literal's occurrence
 * count in the emitted `bin/test.js`) with the two counts agreeing exactly.
 *
 * ## Why a suite gate rather than a lint check
 *
 * A check would have to be TOLD which flags are dead, and that is not a property of the
 * language — it is a property of one build. `src/` carries `#elseif sys` on purpose at six
 * sites (the core also targets neko and hxcpp; `tools/jvm-portability.hxml` probes it), so a
 * rule reporting `sys` as dead over `src test` is wrong at every one of them; and a
 * `deadDefines` key in `test/apqlint.json` would re-create the original defect one level up —
 * a claim about the build that nothing verifies, going stale in silence the day a sys-target
 * runner appears. `CondRegionLiveness` already declines to make that claim: its define set is
 * positive-only and its docs call `#if sys` on a js compile UNKNOWN rather than dead.
 *
 * This gate carries no claim. `definedFlags` asks the compiler through `#if <flag>` in this
 * very file, so the set is the answer for the binary the suite is running. The directive scan
 * is `CondDirectives.scan` and the condition evaluation is `CondRegionLiveness.evaluate`, so
 * there is no second, worse lexer and no second, worse evaluator.
 *
 * Four of the five methods here are unguarded on purpose — they must not be able to fall into
 * the hole they police — and the one that needs a filesystem fails, rather than passes, on a
 * target where it is compiled out.
 */
@:nullSafety(Strict)
class DeadTestGuardTest extends Test {

	/** The directory whose guards this gate enforces, relative to the runner's cwd. */
	private static final TEST_ROOT: String = 'test';

	/**
	 * The one file whose unprovable guards are expected: `BuildDefines` asks `#if <flag>` for
	 * each probed flag, and a flag this build does not define is unprovable by construction —
	 * that IS the question it asks. The exemption is derived, not blanket: only a guard whose
	 * text is exactly `#if <undefined probed flag>` is dropped, so any OTHER guard added to
	 * that module is still reported. Text-exactness is not quite airtight on its own — an
	 * INLINE region (`#if sys <code> #end` on one line) carries that same text and would be
	 * exempted with its code — which is why the exemption is spent on a module holding no
	 * test method: there is nothing there for a dead guard to swallow.
	 */
	private static final PROBE_FILE: String = 'test/unit/BuildDefines.hx';

	public function testEveryGuardUnderTestIsProvablyLiveOnThisRunner(): Void {
		#if (sys || nodejs)
		if (!FileSystem.exists(TEST_ROOT) || !FileSystem.isDirectory(TEST_ROOT)) {
			Assert.fail('$TEST_ROOT is not reachable from the runner cwd — this gate cannot run');
			return;
		}
		final paths: Array<String> = SourceTree.collect(TEST_ROOT);
		final shape: RefShape = new HaxeQueryPlugin().refShape();
		final unproven: Array<String> = [];
		final expected: Array<String> = BuildDefines.undefinedFlags().map(flag -> '#if $flag');
		for (path in paths) {
			final source: String = File.getContent(path);
			for (guard in unprovenGuards(source, shape)) if (path != PROBE_FILE || !expected.contains(guard.text))
				unproven.push('$path:${guard.line}: ${guard.text}');
		}
		unproven.sort((a: String, b: String) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
		Assert.isTrue(paths.length > 0, '$TEST_ROOT must contain .hx files');
		Assert.equals(
			0, unproven.length,
			'guard(s) this build cannot prove live — a test inside one compiles to its #else arm and asserts nothing. Widen it ('
			+ '`#if sys` becomes `#if (sys || nodejs)`), or extend `BuildDefines` when this build really does define the flag:\n  '
			+ unproven.join('\n  ')
		);
		#else
		Assert.fail('this gate is compiled out on the current target, so nothing enforces the guards it checks');
		#end
	}

	public function testTheScanReportsAGuardOnAFlagThisBuildDoesNotDefine(): Void {
		final absent: Null<String> = BuildDefines.undefinedFlags()[0];
		if (absent == null) {
			Assert.fail('every probed flag is defined in this build — the detect-proof has no dead flag to plant');
			return;
		}
		final shape: RefShape = new HaxeQueryPlugin().refShape();
		final source: String = 'class C {\n\t#if $absent\n\tvar x: Int = 0;\n\t#end\n}\n';
		// A condition split across lines is legal Haxe and really does compile its body out, but
		// `CondDirectives` delimits a condition to one line and hands back none — the same absence
		// `#else` produces. Reported on the keyword, or a line-wrapped dead guard walks through.
		final wrapped: String = 'class C {\n\t#if ($absent\n\t)\n\tvar y: Int = 0;\n\t#end\n}\n';
		Assert.equals(1, unprovenGuards(source, shape).length, 'a planted `#if $absent` must be reported');
		Assert.equals(1, unprovenGuards(wrapped, shape).length, 'a guard whose condition spans a line must be reported too');
	}

	public function testTheScanAcceptsAGuardWidenedToIncludeADefinedFlag(): Void {
		final absent: Null<String> = BuildDefines.undefinedFlags()[0];
		final present: Null<String> = BuildDefines.definedFlags()[0];
		if (absent == null || present == null) {
			Assert.fail('this build defines every probed flag, or none — the widened-guard shape cannot be built');
			return;
		}
		final source: String = 'class C {\n\t#if ($absent || $present)\n\tvar x: Int = 0;\n\t#end\n}\n';
		Assert.equals(
			0, unprovenGuards(source, new HaxeQueryPlugin().refShape()).length,
			'`#if ($absent || $present)` is live and must not be reported'
		);
	}

	public function testTheScanIgnoresAGuardWrittenInACommentOrAStringLiteral(): Void {
		final absent: Null<String> = BuildDefines.undefinedFlags()[0];
		if (absent == null) {
			Assert.fail('every probed flag is defined in this build — nothing to plant');
			return;
		}
		final shape: RefShape = new HaxeQueryPlugin().refShape();
		// A line-start `#if` inside a block comment is what separates the shared reader from a
		// hand-rolled line scanner; the string form is what `test/` is full of, since the grammar
		// fixtures quote conditional sources by the dozen.
		final commented: String = '/*\n#if $absent\n*/\nclass C {}\n';
		final quoted: String = 'class C {\n\tvar s: String = "#if $absent";\n}\n';
		Assert.equals(0, unprovenGuards(commented, shape).length, 'a `#if` inside a block comment is not a guard');
		Assert.equals(0, unprovenGuards(quoted, shape).length, 'a `#if` inside a string literal is not a guard');
	}

	public function testProbedFlagsAndDefinedFlagsAgree(): Void {
		final defined: Array<String> = BuildDefines.definedFlags();
		for (flag in defined)
			Assert.isTrue(BuildDefines.PROBED.contains(flag), 'definedFlags() returned "$flag", which BuildDefines.PROBED does not list');
		Assert.isTrue(defined.length > 0, 'no probed flag is defined in this build — every guard would read as unproven');
	}

	/**
	 * Every `#if` / `#elseif` guard in `source` whose condition this build cannot prove LIVE,
	 * with its 1-based line and its verbatim directive text. A keyword that takes no condition
	 * (`#else` / `#end`) is skipped by `CondDirectives.takesCondition`, never by the condition
	 * being absent — a dead `#else` under a live `#if` is the correct shape, not the defect.
	 */
	private static function unprovenGuards(source: String, shape: RefShape): Array<UnprovenGuard> {
		final ifKeyword: Null<String> = shape.conditionalIfKeyword;
		if (ifKeyword == null) return [];
		final defines: Array<String> = BuildDefines.definedFlags();
		final unproven: Array<UnprovenGuard> = [];
		for (directive in CondDirectives.scan(source, shape, new HaxeQueryPlugin().lexicalRegions.bind(source)))
			if (CondDirectives.takesCondition(directive.keyword, ifKeyword, shape.conditionalEndKeyword)) {
				final condition: Null<Span> = directive.condition;
				// A NULL condition on a keyword that takes one means the reader could not delimit
				// it, which is not the same fact as `#else`/`#end` carrying none — `#if (a\n)` is
				// legal Haxe that really does compile its body out. `CondRegionLiveness.apply`
				// discriminates the two with `takesCondition`; conflating them here would let a
				// line-wrapped dead guard through, so an undelimited condition is unproven.
				final live: Null<Bool> = condition == null
					? null
					: CondRegionLiveness.evaluate(source.substring(condition.from, condition.to), defines);
				if (live != true) unproven.push({
					line: new Span(directive.span.from, directive.span.from).lineCol(source).line,
					text: CondDirectives.text(source, directive)
				});
			}
		return unproven;
	}

}

/** One conditional-compilation guard the running build cannot prove live: its 1-based line and its verbatim directive text. */
private typedef UnprovenGuard = {
	final line: Int;
	final text: String;
};
