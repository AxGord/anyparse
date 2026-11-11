package unit.cli;

import anyparse.query.cli.CliCommand;
import anyparse.query.cli.LanguageChoice;
import anyparse.query.cli.UsageFailure;
import anyparse.query.cli.command.GetCommand;

/** An unknown `--lang` is refused before any document is read, with one file or several. */
@:nullSafety(Strict)
class UnknownLangRefusedEarlyTest extends Test {

	@:killer('M-LANG-UNKNOWN-NOT-REFUSED')
	@:pin('control')
	public function testAnUnknownLangIsRefusedWithOneFile(): Void {
		Assert.raises(() -> choose(['--lang', 'bogus', 'one.json']), UsageFailure);
	}

	@:killer('M-LANG-UNKNOWN-NOT-REFUSED')
	@:pin('control')
	public function testAnUnknownLangIsRefusedWithSeveralFiles(): Void {
		Assert.raises(() -> choose(['--lang', 'bogus', '--where', 'n=1', 'one.json', 'note.txt']), UsageFailure);
	}

	private static function choose(args: Array<String>): Void {
		final command: CliCommand = new GetCommand();
		LanguageChoice.choose(args, command, () -> '');
	}

}
