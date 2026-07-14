package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
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
		cleanup(off);
		cleanup(on);
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
		cleanup(promote);
		cleanup(plain);
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
		cleanup(off);
		cleanup(on);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private function dirWith(name: String, source: String, config: Null<String>): String {
		final files: Array<{ name: String, source: String }> = [{ name: name, source: source }];
		if (config != null) files.push({ name: 'apqlint.json', source: config });
		return CliFixture.writeDir('perfilecfg', files);
	}

	private function cleanup(dir: String): Void {
		if (!FileSystem.exists(dir)) return;
		for (name in FileSystem.readDirectory(dir)) {
			final p: String = '$dir/$name';
			if (!FileSystem.isDirectory(p)) FileSystem.deleteFile(p);
		}
		FileSystem.deleteDirectory(dir);
	}
	#end

}
