package unit.cli;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.Check.Violation;
import anyparse.check.Complexity;
import anyparse.check.LintConfig;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import utest.Assert;
import utest.Test;

/**
 * Per-file `apqlint.json` discovery across a multi-directory lint run. A rule
 * disabled (or a severity overridden) by a config in ONE directory must apply
 * ONLY to that directory's files, not leak to sibling directories through the
 * first-expanded-path — the defect where `runLint` discovered a single config
 * from `paths[0]` and applied it to the whole run. Exercised through `Cli.run`
 * exit codes and the on-disk `--fix` result; each ordering is checked so
 * neither leak direction survives.
 */
class LintPerFileConfigCliTest extends Test {

	/**
	 * Content producing exactly one finding: an unused-import Warning. Written
	 * in writer-canonical form so the `--fix` delete re-canonicalises cleanly.
	 */
	private static final UNUSED: String = 'package p;\n\nimport a.b.Unused;\n\nclass C {}\n';

	/** A function of cyclomatic score 2 (one `&&`) — flagged only when complexity.max is tightened to 1. */
	private static final SCORE_TWO: String =
		'package p;\n\nclass C {\n\tpublic function f(a:Bool, b:Bool):Bool {\n\t\treturn a && b;\n\t}\n}\n';

	/**
	 * A run whose scope spans two `apqlint.json` roots naming DIFFERENT `compilerOracle` builds
	 * says so once.
	 *
	 * `runLint` resolves the oracle from `paths[0]`, and that stays: an oracle names ONE build, and
	 * the per-file resolution this class exists to pin has no meaning for it. So every risky and
	 * oracle-assisted verdict in such a run is taken against a build the second root never
	 * declared — the same silence as the rest of this class one level up, where the answer was to
	 * resolve per file; here it can only be to stop being silent.
	 *
	 * Both arms in one test: `--no-oracle` takes no verdict and must stay quiet, an oracle-consulting
	 * run must not. Asserted through the once-per-process ledger, since the write is a bare
	 * `Sys.stderr` with no seam — and the ABSENCE assertion first is what keeps the pass from being
	 * an artefact of some earlier test having warned.
	 */
	@:access(anyparse.check.LintConfig)
	public function testAScopeSpanningTwoOraclesNamesTheDisagreement(): Void {
		#if (sys || nodejs)
		final key: String = 'scope-disagreement:the compiler oracle';
		// The once-per-process ledger is shared with every other test in this runner, so the arm
		// below owns its own starting state rather than assuming one.
		LintConfig.warnedConfigs.remove(key);
		final plain: String = dirWith('Foo.hx', UNUSED, '{"rules":{"unused-import":{"enabled":false}}}');
		final none: String = dirWith('Bar.hx', UNUSED, null);
		final mixed: Int = Cli.run(['lint', none, plain]);
		Assert.isFalse(
			LintConfig.warnedConfigs.contains(key),
			'two roots that both name NO oracle agree — an OMITTED optional constructor argument is `undefined` on js, so a'
			+ ' config-less directory rendered as `undefined|undefined` against a parsed document\'s `null|null`, and the very'
			+ ' first mixed scope this ran over warned about nothing (exit $mixed)'
		);
		final one: String = dirWith('Foo.hx', UNUSED, '{"compilerOracle":"one.hxml"}');
		final two: String = dirWith('Bar.hx', UNUSED, '{"compilerOracle":"two.hxml"}');
		final skipped: Int = Cli.run(['lint', '--no-oracle', one, two]);
		Assert.isFalse(
			LintConfig.warnedConfigs.contains(key), 'a run that takes no oracle verdict has nothing to warn about (exit $skipped)'
		);
		final consulted: Int = Cli.run(['lint', one, two]);
		Assert.isTrue(LintConfig.warnedConfigs.contains(key), 'a run that DOES consult one names the disagreement (exit $consulted)');
		CliFixture.removeDir(plain);
		CliFixture.removeDir(none);
		CliFixture.removeDir(one);
		CliFixture.removeDir(two);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The roster half of the same seam, through the same entry point — gated not on the oracle but on
	 * whether any `FrameworkAware` rule is active, because a roster decides findings whether or not a
	 * build is consulted, and decides none when nothing reads it.
	 *
	 * Asked from `Cli.runLint` rather than from `LintConfig.frameworksFor`, which is where it started:
	 * that runs once per framework-aware rule and re-runs the whole per-file scan each time, and for
	 * the `RiskyFix` half of those rules (`prefer-inline` under a configured oracle,
	 * `unused-public-member` when enabled) `FixVerifier` installs no resolver at all — so each scan was
	 * an uncached `LintConfig.discover` walk per file. Only the CLI holds a resolver memoised per
	 * directory.
	 *
	 * Four arms, and the first three are the ones that can go wrong quietly. Two roots that declare no
	 * roster must AGREE — the roster's own version of the `undefined`-vs-null trap the oracle test
	 * pins, safe here by a DIFFERENT mechanism (`LintConfig`'s constructor does
	 * `_frameworks = frameworks ?? []`), so it needs its own pin. The same two contracts in a different
	 * ORDER must agree, and so must the same names inside one contract. Only a real difference warns.
	 */
	@:access(anyparse.check.LintConfig)
	public function testAScopeSpanningTwoRostersNamesTheDisagreement(): Void {
		#if (sys || nodejs)
		final key: String = 'scope-disagreement:the framework roster';
		LintConfig.warnedConfigs.remove(key);
		final silent: String = dirWith('Foo.hx', UNUSED, '{"rules":{"unused-import":{"enabled":false}}}');
		final none: String = dirWith('Bar.hx', UNUSED, null);
		// EXIT_OK asserted, not just interpolated: an absence assertion after a run that never
		// linted anything would pass for the wrong reason.
		Assert.equals(0, Cli.run(['lint', '--no-oracle', none, silent]), 'two roots that declare no roster lint clean');
		Assert.isFalse(LintConfig.warnedConfigs.contains(key), 'and agree');
		// Same two contracts, opposite order, and one contract's names permuted: the consumer reads
		// a roster with `filter` / `exists`, so neither order carries meaning.
		final ordered: String = dirWith('Foo.hx', UNUSED, '{"frameworks":[{"root":"A","names":["x","y"]},{"root":"B","names":["z"]}]}');
		final permuted: String = dirWith('Bar.hx', UNUSED, '{"frameworks":[{"root":"B","names":["z"]},{"root":"A","names":["y","x"]}]}');
		Assert.equals(0, Cli.run(['lint', '--no-oracle', ordered, permuted]), 'a permuted roster lints clean');
		Assert.isFalse(LintConfig.warnedConfigs.contains(key), 'and is the same roster, not a disagreement');
		final godot: String = dirWith('Foo.hx', UNUSED, '{"frameworks":[{"root":"Node","names":["_ready"]}]}');
		final unity: String = dirWith('Bar.hx', UNUSED, '{"frameworks":[{"root":"MonoBehaviour","names":["Start"]}]}');
		// A run holding no `FrameworkAware` rule applies no roster, so it must not claim one did.
		final unrelated: Int = Cli.run(['lint', '--no-oracle', '--rule', 'prefer-single-quotes', godot, unity]);
		Assert.isFalse(LintConfig.warnedConfigs.contains(key), 'no FrameworkAware rule in the run, no roster claim (exit $unrelated)');
		final disagreeing: Int = Cli.run(['lint', '--no-oracle', godot, unity]);
		Assert.isTrue(
			LintConfig.warnedConfigs.contains(key),
			'two rosters ARE a disagreement, and `--no-oracle` does not silence this half (exit $disagreeing)'
		);
		CliFixture.removeDir(silent);
		CliFixture.removeDir(none);
		CliFixture.removeDir(ordered);
		CliFixture.removeDir(permuted);
		CliFixture.removeDir(godot);
		CliFixture.removeDir(unity);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testEnablementIsPerFile(): Void {
		#if (sys || nodejs)
		final off: String = dirWith('Foo.hx', UNUSED, '{"rules":{"unused-import":{"enabled":false}}}');
		final on: String = dirWith('Bar.hx', UNUSED, null);
		// Alone: the OFF config suppresses its own finding; the ON dir still warns.
		Assert.equals(0, Cli.run(['lint', '--fail-on', 'warning', off]), 'OFF config suppresses its own unused-import');
		Assert.equals(1, Cli.run(['lint', '--fail-on', 'warning', on]), 'ON dir warns');
		// Combined, config dir FIRST: the OFF disable must NOT leak to the ON dir,
		// whose Warning still trips. The single-config-from-paths[0] bug returns 0.
		Assert.equals(1, Cli.run(['lint', '--fail-on', 'warning', off, on]), 'OFF disable must not leak to ON (config dir first)');
		Assert.equals(1, Cli.run(['lint', '--fail-on', 'warning', on, off]), 'ON Warning trips regardless of order');
		CliFixture.removeDir(off);
		CliFixture.removeDir(on);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSeverityIsPerFile(): Void {
		#if (sys || nodejs)
		final promote: String = dirWith('Foo.hx', UNUSED, '{"rules":{"unused-import":{"severity":"error"}}}');
		final plain: String = dirWith('Bar.hx', UNUSED, null);
		Assert.equals(1, Cli.run(['lint', '--fail-on', 'error', promote]), 'promoted unused-import trips --fail-on error');
		Assert.equals(0, Cli.run(['lint', '--fail-on', 'error', plain]), 'default Warning does not trip --fail-on error');
		// Combined, config dir SECOND: the promotion must apply to the promote dir
		// even though paths[0] is under plain. The paths[0]-only bug returns 0.
		Assert.equals(
			1, Cli.run(['lint', '--fail-on', 'error', plain, promote]), 'promotion applies per-file even when config dir is second'
		);
		CliFixture.removeDir(promote);
		CliFixture.removeDir(plain);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testFixHonorsPerFileEnablement(): Void {
		#if (sys || nodejs)
		final off: String = dirWith('Foo.hx', UNUSED, '{"rules":{"unused-import":{"enabled":false}}}');
		final on: String = dirWith('Bar.hx', UNUSED, null);
		// Config dir FIRST so a paths[0]-only bug would disable the fix everywhere.
		Cli.run(['lint', '--fix', off, on]);
		final foo: String = File.getContent('$off/Foo.hx');
		final bar: String = File.getContent('$on/Bar.hx');
		Assert.isTrue(foo.indexOf('a.b.Unused') >= 0, 'disabled rule leaves Foo.hx unchanged');
		Assert.isTrue(bar.indexOf('a.b.Unused') == -1, 'enabled rule fixes Bar.hx (not blocked by the sibling OFF config)');
		CliFixture.removeDir(off);
		CliFixture.removeDir(on);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testOptionCheckPerFileInCombinedRun(): Void {
		#if (sys || nodejs)
		// Tightening complexity.max to 1 in
		// ONE directory flags it there; the sibling with no config keeps the built-in max
		// and stays silent — the option-reading `complexity` check must honour EACH file's
		// own apqlint.json in a combined run, now fed by the memoised resolver.
		final tight: String = dirWith('Foo.hx', SCORE_TWO, '{"rules":{"complexity":{"max":1}}}');
		final loose: String = dirWith('Bar.hx', SCORE_TWO, null);
		Assert.equals(1, Cli.run(['lint', '--fail-on', 'warning', tight]), 'max 1 flags the score-2 function');
		Assert.equals(0, Cli.run(['lint', '--fail-on', 'warning', loose]), 'default max leaves the score-2 function alone');
		// Combined either order: the tightened max applies to its own dir only, so the
		// paths[0]-config-for-all bug (loose first) would leave Foo unflagged and return 0.
		Assert.equals(1, Cli.run(['lint', '--fail-on', 'warning', tight, loose]), 'tight config applies (config dir first)');
		Assert.equals(1, Cli.run(['lint', '--fail-on', 'warning', loose, tight]), 'tight config applies even when config dir is second');
		CliFixture.removeDir(tight);
		CliFixture.removeDir(loose);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testDirectCheckRunDiscoversConfig(): Void {
		#if (sys || nodejs)
		// A check invoked directly (as unit callers do) gets no injected resolver and must
		// still discover the on-disk apqlint.json by walking up from the file path — the
		// fallback that keeps checks usable outside the CLI.
		final dir: String = dirWith('Foo.hx', SCORE_TWO, '{"rules":{"complexity":{"max":1}}}');
		final vs: Array<Violation> = new Complexity().run([{ file: '$dir/Foo.hx', source: SCORE_TWO }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length, 'direct run discovers the on-disk max:1 and flags the score-2 function');
		Assert.equals('complexity', vs[0].rule);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private function dirWith(name: String, source: String, config: Null<String>): String {
		// Declaring stub for the `a.b.Unused` the UNUSED fixture imports: an
		// out-of-scope named import is an unverifiable Info, so each dir must
		// carry the module for the import to stay a deletable Warning. Inert
		// for the complexity fixtures (no imports, no findings of its own).
		final files: Array<{ name: String, source: String }> = [
			{ name: name, source: source },
			{ name: 'Unused.hx', source: 'package a.b;\n\nclass Unused {}\n' }
		];
		if (config != null) files.push({ name: 'apqlint.json', source: config });
		return CliFixture.writeDir('perfilecfg', files);
	}
	#end

}
