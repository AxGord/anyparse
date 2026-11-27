package unit.cli;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.query.Cli;
import anyparse.query.ExitCode.EXIT_USAGE;

/**
 * `apq lint --fix --dry-run` runs the whole fix and shows its edits as a per-file diff, leaving every file as it found it.
 *
 * The fixture is the `else if` chain whose cascade `LintFixFixedPointCliTest` already pins, so a dry run has real edits to show.
 */
@:nullSafety(Strict)
class LintFixDryRunTest extends Test {

	private static final SOURCE: String = 'package p;\n\nclass C {\n\tpublic function f():Int {\n\t\tif (a)\n\t\t\treturn 1;\n'
		+ '\t\telse if (b)\n\t\t\treturn 2;\n\t\telse\n\t\t\treturn 3;\n\t}\n}\n';

	/** The file a dry run touched is byte-identical to what it was, and a real run afterwards still has its edits to make. */
	@:pin('control')
	@:killer('M-LINT-DRY-RUN-KEEPS-WRITES')
	public function testTheFileIsLeftAsItWas(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('fixdry', [{ name: 'Foo.hx', source: SOURCE }]);
		final path: String = '$dir/Foo.hx';
		final shown: String = CliFixture.captureStdout(
			() -> Assert.equals(0, Cli.run(['lint', '--fix', '--dry-run', '--no-oracle', path]), 'dry run exits ok')
		);
		Assert.notEquals('', shown, 'the preview was printed');
		Assert.equals(SOURCE, File.getContent(path), 'nothing is left written');
		Assert.equals(0, Cli.run(['lint', '--fix', '--no-oracle', path]), 'a real run exits ok');
		Assert.stringContains('return if (a) 1 else if (b) 2 else 3;', File.getContent(path), 'the edits were still waiting');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The diff names the file and carries the removed rows and the rows the fix would write. */
	@:pin('control')
	@:killer('M-LINT-DRY-RUN-SAYS-NOTHING')
	public function testTheEditsArePrintedAsADiff(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('fixdry', [{ name: 'Foo.hx', source: SOURCE }]);
		final path: String = '$dir/Foo.hx';
		final out: String = CliFixture.captureStdout(() -> Cli.run(['lint', '--fix', '--dry-run', '--no-oracle', path]));
		Assert.stringContains('--- $path\n+++ $path\n', out, 'the file the run would change');
		Assert.stringContains('- \t\tif (a)\n', out, 'a row the fix removes');
		Assert.stringContains('+ \t\treturn if (a) 1 else if (b) 2 else 3;\n', out, 'the row it writes');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A run that is not a fix has nothing to preview: the flag is refused, not ignored. */
	public function testTheFlagNeedsFix(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('fixdry', [{ name: 'Foo.hx', source: SOURCE }]);
		final err: String = CliFixture.captureStderr(() -> Assert.equals(EXIT_USAGE, Cli.run(['lint', '--dry-run', '$dir/Foo.hx'])));
		Assert.stringContains('--dry-run', err);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
