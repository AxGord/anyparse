package unit.cli;

import anyparse.query.cli.CliArgs;
import anyparse.query.cli.CliCommand;
import anyparse.query.cli.LanguageChoice;
import anyparse.query.cli.UsageFailure;
import anyparse.query.cli.command.GetCommand;
import anyparse.query.cli.command.LintCommand;
import anyparse.query.cli.command.SweepCommand;
import anyparse.query.cli.command.TestSummaryCommand;

/**
 * Which grammar a process-level call names with no `--lang`: the registry's extension of its files, else the
 * content of stdin for a command that reads its document there, else a usage error — there is no default.
 */
@:nullSafety(Strict)
class LanguageChoiceTest extends Test {

	/** A file with a registered extension names its grammar, put first as `--lang`. */
	@:killer('M-LANG-OF-FILE-NONE')
	@:pin('control')
	public function testAFileExtensionNamesTheGrammar(): Void {
		Assert.same(['--lang', 'json', 'a.json', 'k'], choose(new GetCommand(), ['a.json', 'k']).args);
		Assert.same(['--lang', 'haxe', 'src/A.hx', '--all'], choose(new LintCommand(), ['src/A.hx', '--all']).args);
		Assert.same(['--lang', 'mermaid', 'F.MMD'], choose(new LintCommand(), ['F.MMD']).args);
	}

	/** Every registered grammar's extensions route back to it, and `pickPlugin` builds the plugin that answers to its name. */
	public function testEveryRegistryRowRoutesToItself(): Void {
		for (entry in CliArgs.grammars()) {
			Assert.equals(entry.lang, CliArgs.pickPlugin(entry.lang).langName());
			for (extension in entry.extensions) Assert.equals(entry.lang, CliArgs.langOfFile('x$extension'));
		}
		Assert.isNull(CliArgs.langOfFile('notes.txt'));
	}

	/** Nothing names a grammar — a directory, an unknown extension — so the call is a usage error, not Haxe. */
	public function testNoNamedGrammarIsAUsageError(): Void {
		Assert.raises(() -> choose(new LintCommand(), ['src']), UsageFailure);
		Assert.raises(() -> choose(new LintCommand(), ['notes.txt']), UsageFailure);
	}

	/** A file right after a `--flag` may be its value, so it does not name the grammar. */
	@:killer('M-LANG-CHOICE-FLAG-VALUE-COUNTED')
	@:pin('control')
	public function testAFlagValueIsNotAFile(): Void {
		Assert.raises(() -> choose(new SweepCommand(), ['--save', 'base.json']), UsageFailure);
	}

	/** Files of two grammars are a usage error. */
	public function testTwoGrammarsAreAUsageError(): Void {
		Assert.raises(() -> choose(new LintCommand(), ['a.json', 'B.hx']), UsageFailure);
	}

	/** An explicit `--lang`, `--help`, or a command that parses no grammar passes through untouched. */
	public function testExplicitOrLanguageFreePassesThrough(): Void {
		Assert.same(['--lang', 'haxe', 'src'], choose(new LintCommand(), ['--lang', 'haxe', 'src']).args);
		Assert.same(['--help'], choose(new LintCommand(), ['--help']).args);
		Assert.same(['log.txt'], choose(new TestSummaryCommand(), ['log.txt']).args);
	}

	/** A `-` document on stdin is told by its content, and the text read is handed on so the command does not read twice. */
	@:killer('M-LANG-OF-CONTENT-NONE')
	@:pin('control')
	public function testStdinIsToldByItsContent(): Void {
		final chosen: LanguageChoiceResult = LanguageChoice.choose(['-', 'a'], new GetCommand(), () -> ' [1, 2]');
		Assert.same(['--lang', 'json', '-', 'a'], chosen.args);
		Assert.equals(' [1, 2]', chosen.stdin);
		Assert.raises(() -> LanguageChoice.choose(['-', 'a'], new GetCommand(), () -> 'class C {}'), UsageFailure);
	}

	/** A command that does not read its document from stdin never has stdin read for it. */
	public function testStdinIsReadOnlyForAStdinDocumentCommand(): Void {
		var read: Bool = false;
		Assert.raises(
			() -> LanguageChoice.choose(['-'], new LintCommand(), () -> {
				read = true;
				return '{}';
			}),
			UsageFailure
		);
		Assert.isFalse(read);
	}

	private static function choose(command: CliCommand, args: Array<String>): LanguageChoiceResult {
		return LanguageChoice.choose(args, command, () -> throw 'stdin must not be read');
	}

}
