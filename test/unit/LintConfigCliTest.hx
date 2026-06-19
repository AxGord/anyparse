package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if (sys || nodejs)
import sys.FileSystem;
#end

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
		final foo: String = "package p;\nclass C {\n\tpublic function f():String return 'a' + 'b';\n}";
		final off: String = dirWith('{"rules":{"fold-adjacent-string-literals":{"enabled":false}}}', foo);
		Assert.equals(0, Cli.run(['lint', '--all', '--fail-on', 'info', '$off/Foo.hx']), 'disabled fold cannot trip --fail-on info');
		cleanup(off);

		final on: String = dirWith(null, foo);
		Assert.equals(1, Cli.run(['lint', '--all', '--fail-on', 'info', '$on/Foo.hx']), 'without config the fold Info fires');
		cleanup(on);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSeverityPromotionTripsFailOn(): Void {
		#if (sys || nodejs)
		final foo: String = 'package p;\nimport a.b.Unused;\nclass C {}';
		final promoted: String = dirWith('{"rules":{"unused-import":{"severity":"error"}}}', foo);
		Assert.equals(1, Cli.run(['lint', '--fail-on', 'error', '$promoted/Foo.hx']), 'promoted unused-import trips --fail-on error');
		cleanup(promoted);

		final plain: String = dirWith(null, foo);
		Assert.equals(0, Cli.run(['lint', '--fail-on', 'error', '$plain/Foo.hx']), 'default Warning does not trip --fail-on error');
		cleanup(plain);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testComplexityMaxOverride(): Void {
		#if (sys || nodejs)
		final foo: String = 'package p;\nclass C {\n\tpublic function f(a:Bool, b:Bool):Bool { return a && b; }\n}';
		final tight: String = dirWith('{"rules":{"complexity":{"max":1}}}', foo);
		Assert.equals(1, Cli.run(['lint', '--fail-on', 'warning', '$tight/Foo.hx']), 'max 1 flags the score-2 function');
		cleanup(tight);

		final loose: String = dirWith(null, foo);
		Assert.equals(0, Cli.run(['lint', '--fail-on', 'warning', '$loose/Foo.hx']), 'default max 20 leaves score 2 alone');
		cleanup(loose);
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

	private function cleanup(dir: String): Void {
		for (name in ['Foo.hx', 'apqlint.json']) {
			final p: String = '$dir/$name';
			if (FileSystem.exists(p)) FileSystem.deleteFile(p);
		}
		if (FileSystem.exists(dir)) FileSystem.deleteDirectory(dir);
	}
	#end

}
