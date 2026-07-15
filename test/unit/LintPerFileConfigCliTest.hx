package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
import anyparse.check.Complexity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.check.Check.Violation;
#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

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

	// Content producing exactly one finding: an unused-import Warning. Written
	// in writer-canonical form so the `--fix` delete re-canonicalises cleanly.
	private static final UNUSED: String = 'package p;\n\nimport a.b.Unused;\n\nclass C {}\n';

	// A function of cyclomatic score 2 (one `&&`) — flagged only when complexity.max is tightened to 1.
	private static final SCORE_TWO: String = 'package p;\n\nclass C {\n\tpublic function f(a:Bool, b:Bool):Bool {\n\t\treturn a && b;\n\t}\n}\n';

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
