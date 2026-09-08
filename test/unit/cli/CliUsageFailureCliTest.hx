package unit.cli;

import anyparse.query.Cli;
#if (sys || nodejs)
import sys.FileSystem;
#end
import utest.Assert;
import utest.Test;

/**
 * `CliArgs.expectValue` / `parseLimit` / `pickPlugin` throw a plain-string
 * exception when a flag is missing its value, `--limit` is unparseable, or
 * `--lang` names an unknown plugin — a usage mistake, not a bug. Before this
 * pin `Cli.run` caught only `WriteFailure`, so the throw propagated past
 * `dispatch` uncaught: a raw Node stack trace and exit 1, for a mistake
 * most commands elsewhere report with a clean stderr line and
 * `EXIT_USAGE`. `UsageFailure` is now the common type all three helpers
 * throw, and `Cli.run` catches it next to `WriteFailure`.
 *
 * `apq cond … --max-body` is the reproduction the backlog named (its own
 * `--limit` already has a local try/catch; `--max-body`'s `expectValue`
 * call does not); `apq lit … --lang` exercises `pickPlugin` the same way.
 */
@:nullSafety(Strict)
class CliUsageFailureCliTest extends Test {

	private static final FIXTURE: String = 'class C {}';

	public function testMissingFlagValueIsUsageErrorNotAStackTrace(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('usage_missing_value', FIXTURE);
		var exit: Int = -1;
		final err: String = CliFixture.captureStderr(() -> exit = Cli.run(['cond', 'nodejs', f, '--max-body']));
		Assert.equals(2, exit, 'missing flag value is a usage error, not a runtime crash');
		Assert.isTrue(err.indexOf('--max-body requires a value') >= 0, 'stderr names the flag: $err');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testUnknownLangIsUsageError(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('usage_bad_lang', FIXTURE);
		var exit: Int = -1;
		final err: String = CliFixture.captureStderr(() -> exit = Cli.run(['lit', 'foo', f, '--lang', 'nosuchlang']));
		Assert.equals(2, exit, 'unknown --lang plugin is a usage error');
		Assert.isTrue(err.indexOf('no grammar plugin for --lang "nosuchlang"') >= 0, 'stderr names the plugin: $err');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testMissingLangValueIsUsageError(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('usage_missing_lang', FIXTURE);
		var exit: Int = -1;
		final err: String = CliFixture.captureStderr(() -> exit = Cli.run(['lit', 'foo', f, '--lang']));
		Assert.equals(2, exit, 'missing --lang value is a usage error');
		Assert.isTrue(err.indexOf('--lang requires a value') >= 0, 'stderr names the flag: $err');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
