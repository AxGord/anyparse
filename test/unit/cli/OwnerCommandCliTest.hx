package unit.cli;

import anyparse.query.Cli;

/** `apq owner`: the ranked rows, the `--list` table of owned questions, and the usage refusals. */
class OwnerCommandCliTest extends Test {

	/** A ranked row is `Type[.member]`, `file:line` and the doc's first sentence, tab-separated, best first. */
	public function testARankedRowNamesTheDeclarationItsLineAndItsFirstSentence(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		var code: Int = -1;
		final out: String = CliFixture.captureStdout(() -> code = Cli.run(['owner', 'which file is this path', dir, '--limit', '1']));
		CliFixture.removeDir(dir);
		Assert.equals(0, code);
		Assert.equals('Paths\t$dir/Paths.hx:4\tThe one answer to "which file is this path?": every caller asks here.\n', out);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `--list` prints each owned question with its declaration, and nothing for a doc that names none. */
	public function testListPrintsEachOwnedQuestion(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		var code: Int = -1;
		final out: String = CliFixture.captureStdout(() -> code = Cli.run(['owner', '--list', dir]));
		CliFixture.removeDir(dir);
		Assert.equals(0, code);
		Assert.equals('which file is this path?\tPaths\t$dir/Paths.hx:4\n', out);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A question with no scope, or nothing at all, is a usage error. */
	public function testAMissingScopeIsAUsageError(): Void {
		#if (sys || nodejs)
		CliFixture.captureStdout(() -> {
			Assert.equals(2, Cli.run(['owner', 'which file']));
			Assert.equals(2, Cli.run(['owner', '--list']));
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	private static function fixture(): String {
		return CliFixture.writeDir('owner', [
			{
				name: 'Paths.hx',
				source: 'package;\n\n/** The one answer to "which file is this path?": every caller asks here. */\nclass Paths {}\n'
			},
			{ name: 'Other.hx', source: 'package;\n\n/** Counts nodes. */\nclass Other {}\n' }
		]);
	}

}
