package unit.cli;

import anyparse.check.LintConfig;
import anyparse.query.Cli;
import utest.Assert;
import utest.Test;

/**
 * End-to-end wiring of an `apqlint.json` sitting in the linted file's
 * directory. Asserted via `Cli.run(['lint', ...])` exit codes: a disabled rule
 * produces no finding (cannot trip `--fail-on`), a promoted severity can trip a
 * gate the default level would not, and a tightened `complexity.max` flags a
 * function the built-in default (10) leaves alone. Each is paired with a
 * config-less control so the difference is attributable to the config.
 */
class LintConfigCliTest extends Test {

	public function testDisabledRuleNotReported(): Void {
		#if (sys || nodejs)
		final foo: String = "package p;\n/** C. */\nclass C {\n\tpublic static final S:String = 'a' + 'b';\n}";
		final off: String = dirWith('{"rules":{"fold-adjacent-string-literals":{"enabled":false}}}', foo);
		Assert.equals(0, Cli.run(['lint', '--all', '--fail-on', 'info', '$off/Foo.hx']), 'disabled fold cannot trip --fail-on info');
		CliFixture.removeDir(off);

		final on: String = dirWith(null, foo);
		Assert.equals(1, Cli.run(['lint', '--all', '--fail-on', 'info', '$on/Foo.hx']), 'without config the fold Info fires');
		CliFixture.removeDir(on);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSeverityPromotionTripsFailOn(): Void {
		#if (sys || nodejs)
		final foo: String = 'package p;\nimport a.b.Unused;\nclass C {}';
		final promoted: String = dirWith('{"rules":{"unused-import":{"severity":"error"}}}', foo);
		Assert.equals(1, Cli.run(['lint', '--fail-on', 'error', '$promoted/Foo.hx']), 'promoted unused-import trips --fail-on error');
		CliFixture.removeDir(promoted);

		final plain: String = dirWith(null, foo);
		Assert.equals(0, Cli.run(['lint', '--fail-on', 'error', '$plain/Foo.hx']), 'default Warning does not trip --fail-on error');
		CliFixture.removeDir(plain);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Both scope-gap notices are WIRED, not merely written.
	 *
	 * `ConfigDisagreement` is pinned at its message seam, which says nothing about a run reaching it,
	 * and the two calls hang on positions that are easy to move without failing anything: the
	 * missing-roots one sits four lines above `runLint`'s `if (o.fix) return LintFixDriver…`, so
	 * below it the sentence would vanish for exactly the audience that WRITES files, and the
	 * unreachable-roots one lives in `readResolutionRoots`, reached only once a check demands the
	 * index — which is why the second half asks for `unused-private` and the first, deliberately, for
	 * a rule that demands nothing at all: the missing-roots notice is ungated by design, and this is
	 * where that is observable.
	 */
	@:access(anyparse.check.LintConfig)
	@:pin('control')
	@:killer('M-SCOPE-GAP-UNWIRED')
	@:killer('M-SCOPE-GAP-ROOT-UNWIRED')
	public function testTheScopeGapNoticesReachTheRun(): Void {
		#if (sys || nodejs)
		final foo: String = 'package p;\n/** C. */\nclass C {\n\tprivate var f:Int = 0;\n}';
		// The ledger is once-per-process and the suite shares one, so a sibling test reaching either
		// key first would leave this one reading empty stderr and blaming the wiring. Two keys, not
		// the whole array: re-arming every config warning the suite has already emitted is somebody
		// else's regression to debug.
		LintConfig.warnedConfigs.remove('scope-gap:the project source roots');
		final libsOnly: String = dirWith('{"resolutionLibs":["utest"]}', foo);
		final gap: String = CliFixture.captureStderr(() ->
			Cli.run(['lint', '--rule', 'prefer-single-quotes', '--no-oracle', '$libsOnly/Foo.hx'])
		);
		CliFixture.removeDir(libsOnly);

		LintConfig.warnedConfigs.remove('scope-gap:unreachable project source roots');
		final nowhere: String = dirWith('{"resolutionRoots":["nowhere"]}', foo);
		final root: String = CliFixture.captureStderr(() ->
			Cli.run(['lint', '--rule', 'unused-private', '--no-oracle', '$nowhere/Foo.hx'])
		);
		CliFixture.removeDir(nowhere);
		#if nodejs
		Assert.isTrue(gap.indexOf('resolutionLibs and no resolutionRoots') >= 0, 'the missing-roots notice must reach a run: $gap');
		Assert.isTrue(root.indexOf('match no .hx') >= 0, 'the unreachable-root notice must reach a run: $root');
		#end
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testComplexityMaxOverride(): Void {
		#if (sys || nodejs)
		final foo: String = 'package p;\nclass C {\n\tpublic function f(a:Bool, b:Bool):Bool { return a && b; }\n}';
		final tight: String = dirWith('{"rules":{"complexity":{"max":1}}}', foo);
		Assert.equals(1, Cli.run(['lint', '--fail-on', 'warning', '$tight/Foo.hx']), 'max 1 flags the score-2 function');
		CliFixture.removeDir(tight);

		final loose: String = dirWith(null, foo);
		Assert.equals(0, Cli.run(['lint', '--fail-on', 'warning', '$loose/Foo.hx']), 'default max 20 leaves score 2 alone');
		CliFixture.removeDir(loose);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private function dirWith(config: Null<String>, foo: String): String {
		final files: Array<{ name: String, source: String }> = [{ name: 'Foo.hx', source: foo }];
		if (config != null) files.push({ name: 'apqlint.json', source: config });
		return CliFixture.writeDir('lintcfg', files);
	}
	#end

}
