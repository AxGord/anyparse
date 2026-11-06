package unit.cli;

import anyparse.query.Cli;
import anyparse.query.cli.CliArgs;
import anyparse.query.cli.CliCommand;
import anyparse.query.cli.LanguageChoice;
import anyparse.query.cli.UsageFailure;
import anyparse.query.cli.command.BlastCommand;
import anyparse.query.cli.command.CalleesCommand;
import anyparse.query.cli.command.CallersCommand;
import anyparse.query.cli.command.CasesCommand;
import anyparse.query.cli.command.ChangedCommand;
import anyparse.query.cli.command.CommentRewriteCommand;
import anyparse.query.cli.command.CondCommand;
import anyparse.query.cli.command.DeclaresCommand;
import anyparse.query.cli.command.FmtCommand;
import anyparse.query.cli.command.GetCommand;
import anyparse.query.cli.command.ImportersCommand;
import anyparse.query.cli.command.LintCommand;
import anyparse.query.cli.command.LitCommand;
import anyparse.query.cli.command.MentionsCommand;
import anyparse.query.cli.command.MetaCommand;
import anyparse.query.cli.command.OwnerCommand;
import anyparse.query.cli.command.RefsCommand;
import anyparse.query.cli.command.ResolveDefineCommand;
import anyparse.query.cli.command.SearchCommand;
import anyparse.query.cli.command.SweepCommand;
import anyparse.query.cli.command.TestSummaryCommand;
import anyparse.query.cli.command.UsesCommand;
import sys.FileSystem;

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

	/** A valued flag's value, as the command declares it, is no file and does not name the grammar. */
	@:killer('M-LANG-CHOICE-FLAG-VALUE-COUNTED')
	@:pin('control')
	public function testAFlagValueIsNotAFile(): Void {
		Assert.raises(() -> choose(new SweepCommand(), ['--save', 'base.json']), UsageFailure);
		Assert.same(
			['--lang', 'haxe', '--baseline', 'base.json', 'A.hx'], choose(new LintCommand(), ['--baseline', 'base.json', 'A.hx']).args
		);
	}

	/** A switch takes no value, so the file after it names a grammar: `fmt --list A.hx b.json` names two. */
	@:killer('M-CLI-FLAGS-SWITCH-TAKES-VALUE')
	@:pin('control')
	public function testAFileAfterASwitchCounts(): Void {
		Assert.raises(() -> choose(new FmtCommand(), ['--list', 'A.hx', 'b.json']), UsageFailure);
		Assert.same(
			['--lang', 'haxe', '--list', 'A.hx', 'b.json'],
			choose(new FmtCommand(), ['--lang-default', 'haxe', '--list', 'A.hx', 'b.json']).args
		);
		Assert.same(['--lang', 'haxe', '--write', 'A.hx'], choose(new FmtCommand(), ['--write', 'A.hx']).args);
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

	/**
	 * `hxq`'s `--lang-default` is a default, not an override: a file another grammar's extension names is read by that
	 * grammar. Files of two grammars read as the preset's, as they did before it yielded.
	 */
	@:killer('M-LANG-PRESET-OVERRIDES')
	@:pin('control')
	public function testAPresetYieldsToAFileExtension(): Void {
		Assert.same(['--lang', 'json', 'a.json'], choose(new LintCommand(), ['--lang-default', 'haxe', 'a.json']).args);
		Assert.same(['--lang', 'haxe', 'A.hx', '--all'], choose(new LintCommand(), ['--lang-default', 'haxe', 'A.hx', '--all']).args);
		Assert.same(['--lang', 'haxe', 'a.json', 'B.hx'], choose(new LintCommand(), ['--lang-default', 'haxe', 'a.json', 'B.hx']).args);
	}

	/** With no file naming a grammar the preset names it — a directory, an unknown extension, stdin — and stdin is not read for it. */
	@:killer('M-LANG-PRESET-IGNORED')
	@:pin('control')
	public function testAPresetNamesTheGrammarNoFileNames(): Void {
		Assert.same(['--lang', 'haxe', 'src'], choose(new LintCommand(), ['--lang-default', 'haxe', 'src']).args);
		Assert.same(['--lang', 'haxe', 'notes.txt'], choose(new LintCommand(), ['notes.txt', '--lang-default', 'haxe']).args);
		Assert.same(['--lang', 'haxe', '-', 'a'], choose(new GetCommand(), ['--lang-default', 'haxe', '-', 'a']).args);
		Assert.same(['--lang', 'haxe', 'log.txt'], choose(new TestSummaryCommand(), ['--lang-default', 'haxe', 'log.txt']).args);
	}

	/** An explicit `--lang` beats the preset, and a preset with no name is a usage error. */
	public function testAnExplicitLangBeatsThePreset(): Void {
		Assert.same(['--lang', 'json', 'x'], choose(new LintCommand(), ['--lang-default', 'haxe', '--lang', 'json', 'x']).args);
		Assert.raises(() -> choose(new LintCommand(), ['A.hx', '--lang-default']), UsageFailure);
	}

	/** The argv `bin/hxq` builds formats a `.json` file as `apq` does, and a `.hx` file as Haxe — never a parse error. */
	public function testHxqFormatsJsonAsApqDoes(): Void {
		final json: String = CliFixture.writeAs('hxqlang', 'json', '{"a": [1, 2]}\n');
		final hx: String = CliFixture.write('hxqlang', 'class A {}\n');
		CliFixture.always(() -> {
			FileSystem.deleteFile(json);
			FileSystem.deleteFile(hx);
		}, () -> {
			var code: Int = -1;
			final viaHxq: String = CliFixture.captureStdout(() -> code = Cli.run(['fmt', '--lang-default', 'haxe', json], true));
			Assert.equals(0, code);
			Assert.equals(CliFixture.captureStdout(() -> Cli.run(['fmt', json], true)), viaHxq);
			Assert.stringContains('"a"', viaHxq);
			final hxOut: String = CliFixture.captureStdout(() -> code = Cli.run(['fmt', '--lang-default', 'haxe', hx], true));
			Assert.equals(0, code);
			Assert.stringContains('class A', hxOut);
		});
	}

	/** A preset reads files of two grammars as its own; without one they stay a usage error. */
	@:killer('M-LANG-PRESET-MIXED-REFUSED')
	@:pin('control')
	public function testAPresetReadsMixedFilesAsItsOwn(): Void {
		Assert.same(['--lang', 'haxe', 'A.hx', 'apq.json'], choose(new LintCommand(), ['A.hx', 'apq.json', '--lang-default', 'haxe']).args);
		Assert.raises(() -> choose(new LintCommand(), ['A.hx', 'apq.json']), UsageFailure);
	}

	/** `--` is no flag and takes no value, so the path after it is a file. */
	@:killer('M-LANG-END-OF-OPTIONS-VALUE')
	@:pin('control')
	public function testAPathAfterEndOfOptionsCounts(): Void {
		Assert.same(['--lang', 'haxe', 'x', '--', 'A.hx'], choose(new LintCommand(), ['--lang-default', 'haxe', 'x', '--', 'A.hx']).args);
		Assert.same(['--lang', 'json', 'x', '--', 'a.json'], choose(new LintCommand(), ['x', '--', 'a.json']).args);
	}

	/**
	 * A command that routes each file by its own extension needs no
	 * argument naming a grammar: the file `--diff` names is no positional.
	 */
	public function testChangedNeedsNoPositionalFile(): Void {
		Assert.same(['HEAD', '--diff', 'A.hx'], choose(new ChangedCommand(), ['HEAD', '--diff', 'A.hx']).args);
		Assert.same(['HEAD'], choose(new ChangedCommand(), ['HEAD']).args);
		Assert.same(['--lang', 'haxe', 'HEAD'], choose(new ChangedCommand(), ['--lang-default', 'haxe', 'HEAD']).args);
	}

	/**
	 * The text a walker searches for is no file: `lit '.last-sweep.json' src` names Haxe, not JSON, however its query is
	 * spelled — one query, a batch before `--`, or a scope that is itself a JSON file.
	 */
	@:killer('M-LANG-QUERY-COUNTED-AS-FILE')
	@:pin('control')
	public function testTheQueryOfAWalkerIsNoFile(): Void {
		Assert.same(['--lang', 'haxe', '.last-sweep.json', 'A.hx'], choose(new LitCommand(), ['.last-sweep.json', 'A.hx']).args);
		Assert.same(
			['--lang', 'haxe', '.last-sweep.json', 'src'],
			choose(new LitCommand(), ['--lang-default', 'haxe', '.last-sweep.json', 'src']).args
		);
		Assert.same(
			['--lang', 'haxe', 'a.json', 'b.json', '--', 'A.hx'], choose(new LitCommand(), ['a.json', 'b.json', '--', 'A.hx']).args
		);
		Assert.same(['--lang', 'json', 'k', 'a.json'], choose(new LitCommand(), ['k', 'a.json']).args);
		Assert.raises(() -> choose(new LitCommand(), ['a.json']), UsageFailure);
		Assert.same(['--lang', 'haxe', 'haxe.Json', 'A.hx'], choose(new ImportersCommand(), ['haxe.Json', 'A.hx']).args);
	}

	/** Every command whose first positional is the text it searches for carries the marker, so none reads that text as a file. */
	public function testEveryTextFirstCommandIsMarked(): Void {
		final commands: Array<CliCommand> = [
			new SearchCommand(),
			new RefsCommand(),
			new UsesCommand(),
			new BlastCommand(),
			new LitCommand(),
			new MentionsCommand(),
			new DeclaresCommand(),
			new CasesCommand(),
			new CondCommand(),
			new CallersCommand(),
			new CalleesCommand(),
			new ResolveDefineCommand(),
			new ImportersCommand()
		];
		for (command in commands)
			Assert.same(['--lang', 'haxe', 'q.json', 'A.hx'], choose(command, ['q.json', 'A.hx']).args, command.name());
	}

	/** `owner` reads its question as text, so a question ending in `.json` names no grammar; `--list` has none. */
	@:killer('M-LANG-OWNER-QUESTION-READ-AS-FILE')
	@:pin('control')
	public function testTheQuestionOfOwnerIsNoFile(): Void {
		final owner: CliCommand = new OwnerCommand();
		Assert.same(['--lang', 'haxe', 'who reads apqlint.json', 'A.hx'], choose(owner, ['who reads apqlint.json', 'A.hx']).args);
		Assert.same(['--lang', 'haxe', '--limit', '3', 'q.json', 'A.hx'], choose(owner, ['--limit', '3', 'q.json', 'A.hx']).args);
		Assert.same(['--lang', 'json', '--list', 'a.json'], choose(owner, ['--list', 'a.json']).args);
	}

	/** `comment-rewrite` reads TWO texts, the find and the replace, before the files. */
	@:killer('M-LANG-REWRITE-TEXTS-READ-AS-FILES')
	@:pin('control')
	public function testTheTwoTextsOfCommentRewriteAreNoFiles(): Void {
		final rewrite: CliCommand = new CommentRewriteCommand();
		Assert.same(['--lang', 'haxe', 'a.json', 'b.json', 'A.hx'], choose(rewrite, ['a.json', 'b.json', 'A.hx']).args);
		Assert.same(
			['--lang', 'haxe', '--write', 'a.json', 'b.json', 'A.hx'], choose(rewrite, ['--write', 'a.json', 'b.json', 'A.hx']).args
		);
		Assert.raises(() -> choose(rewrite, ['a.json', 'b.json']), UsageFailure);
	}

	/** `meta` reads its leading positional as text only when it is an annotation: `--on` may leave the annotation out. */
	@:killer('M-LANG-META-ANNOTATION-READ-AS-FILE')
	@:pin('control')
	public function testTheAnnotationOfMetaIsNoFile(): Void {
		final meta: CliCommand = new MetaCommand();
		Assert.same(['--lang', 'haxe', '@:keep.json', 'A.hx'], choose(meta, ['@:keep.json', 'A.hx']).args);
		Assert.same(['--lang', 'json', '--on', 'ClassDecl', 'a.json'], choose(meta, ['--on', 'ClassDecl', 'a.json']).args);
		Assert.same(['--lang', 'haxe', '@:fmt(a.json)', 'A.hx'], choose(meta, ['@:fmt(a.json)', 'A.hx']).args);
		Assert.raises(() -> choose(meta, ['@:keep.json']), UsageFailure);
	}

	private static function choose(command: CliCommand, args: Array<String>): LanguageChoiceResult {
		return LanguageChoice.choose(args, command, () -> throw 'stdin must not be read');
	}

}
