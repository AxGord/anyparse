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
 * Which grammars a process-level call runs on with no `--lang`: the registry's extension of its files, the content of
 * stdin for a command that reads its document there, the grammars of the files under a directory, the project config —
 * else a usage error: there is no default.
 */
@:nullSafety(Strict)
class LanguageChoiceTest extends Test {

	/** A file with a registered extension names its grammar, put first as `--lang`. */
	@:killer('M-LANG-OF-FILE-NONE')
	@:pin('control')
	public function testAFileExtensionNamesTheGrammar(): Void {
		Assert.same(['--lang', 'json', 'a.json', 'k'], one(choose(new GetCommand(), ['a.json', 'k'])));
		Assert.same(['--lang', 'haxe', 'src/A.hx', '--all'], one(choose(new LintCommand(), ['src/A.hx', '--all'])));
		Assert.same(['--lang', 'mermaid', 'F.MMD'], one(choose(new LintCommand(), ['F.MMD'])));
	}

	/** Every registered grammar's extensions route back to it, and `pickPlugin` builds the plugin that answers to its name. */
	public function testEveryRegistryRowRoutesToItself(): Void {
		for (entry in CliArgs.grammars()) {
			Assert.equals(entry.lang, CliArgs.pickPlugin(entry.lang).langName());
			for (extension in entry.extensions) Assert.equals(entry.lang, CliArgs.langOfFile('x$extension'));
		}
		Assert.isNull(CliArgs.langOfFile('notes.txt'));
	}

	/**
	 * Nothing names a grammar — an unknown extension, a path holding no file of any grammar — so the call is a usage error, not Haxe.
	 */
	public function testNoNamedGrammarIsAUsageError(): Void {
		Assert.raises(() -> choose(new LintCommand(), ['notes.txt']), UsageFailure);
		Assert.raises(() -> choose(new LintCommand(), ['no-such-dir']), UsageFailure);
	}

	/** A valued flag's value, as the command declares it, is no file and does not name the grammar. */
	@:killer('M-LANG-CHOICE-FLAG-VALUE-COUNTED')
	@:pin('control')
	public function testAFlagValueIsNotAFile(): Void {
		Assert.raises(() -> choose(new SweepCommand(), ['--save', 'base.json']), UsageFailure);
		Assert.same(
			['--lang', 'haxe', '--baseline', 'base.json', 'A.hx'], one(choose(new LintCommand(), ['--baseline', 'base.json', 'A.hx']))
		);
	}

	/** A switch takes no value, so the file after it names a grammar: `fmt --list A.hx b.json` names two. */
	@:killer('M-CLI-FLAGS-SWITCH-TAKES-VALUE')
	@:pin('control')
	public function testAFileAfterASwitchCounts(): Void {
		Assert.same(
			[['--lang', 'haxe', '--list', 'A.hx'], ['--lang', 'json', '--list', 'b.json']],
			choose(new FmtCommand(), ['--list', 'A.hx', 'b.json']).runs
		);
		Assert.same(
			['--lang', 'haxe', '--list', 'A.hx', 'b.json'],
			one(choose(new FmtCommand(), ['--lang-default', 'haxe', '--list', 'A.hx', 'b.json']))
		);
		Assert.same(['--lang', 'haxe', '--write', 'A.hx'], one(choose(new FmtCommand(), ['--write', 'A.hx'])));
	}

	/** Files of two grammars run the command once per grammar, in the order the files name them, each run over its own files. */
	@:killer('M-LANG-RUN-KEEPS-OTHER-FILES')
	@:pin('control')
	public function testFilesOfTwoGrammarsRunOncePerGrammar(): Void {
		Assert.same(
			[['--lang', 'json', 'a.json', '--all'], ['--lang', 'haxe', 'B.hx', '--all']],
			choose(new LintCommand(), ['a.json', 'B.hx', '--all']).runs
		);
	}

	/** An explicit `--lang`, `--help`, or a command that parses no grammar passes through untouched. */
	public function testExplicitOrLanguageFreePassesThrough(): Void {
		Assert.same(['--lang', 'haxe', 'src'], one(choose(new LintCommand(), ['--lang', 'haxe', 'src'])));
		Assert.same(['--help'], one(choose(new LintCommand(), ['--help'])));
		Assert.same(['log.txt'], one(choose(new TestSummaryCommand(), ['log.txt'])));
	}

	/** A `-` document on stdin is told by its content, and the text read is handed on so the command does not read twice. */
	@:killer('M-LANG-OF-CONTENT-NONE')
	@:pin('control')
	public function testStdinIsToldByItsContent(): Void {
		final chosen: LanguageChoiceResult = LanguageChoice.choose(['-', 'a'], new GetCommand(), () -> ' [1, 2]');
		Assert.same(['--lang', 'json', '-', 'a'], one(chosen));
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
		Assert.same(['--lang', 'json', 'a.json'], one(choose(new LintCommand(), ['--lang-default', 'haxe', 'a.json'])));
		Assert.same(['--lang', 'haxe', 'A.hx', '--all'], one(choose(new LintCommand(), ['--lang-default', 'haxe', 'A.hx', '--all'])));
		Assert.same(['--lang', 'haxe', 'a.json', 'B.hx'], one(choose(new LintCommand(), ['--lang-default', 'haxe', 'a.json', 'B.hx'])));
	}

	/** With no file naming a grammar the preset names it — a directory, an unknown extension, stdin — and stdin is not read for it. */
	@:killer('M-LANG-PRESET-IGNORED')
	@:pin('control')
	public function testAPresetNamesTheGrammarNoFileNames(): Void {
		Assert.same(['--lang', 'haxe', 'src'], one(choose(new LintCommand(), ['--lang-default', 'haxe', 'src'])));
		Assert.same(['--lang', 'haxe', 'notes.txt'], one(choose(new LintCommand(), ['notes.txt', '--lang-default', 'haxe'])));
		Assert.same(['--lang', 'haxe', '-', 'a'], one(choose(new GetCommand(), ['--lang-default', 'haxe', '-', 'a'])));
		Assert.same(['--lang', 'haxe', 'log.txt'], one(choose(new TestSummaryCommand(), ['--lang-default', 'haxe', 'log.txt'])));
	}

	/** An explicit `--lang` beats the preset, and a preset with no name is a usage error. */
	public function testAnExplicitLangBeatsThePreset(): Void {
		Assert.same(['--lang', 'json', 'x'], one(choose(new LintCommand(), ['--lang-default', 'haxe', '--lang', 'json', 'x'])));
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

	/**
	 * A preset reads files of two grammars as its own; without one they run once per grammar.
	 */
	@:killer('M-LANG-PRESET-MIXED-REFUSED')
	@:pin('control')
	public function testAPresetReadsMixedFilesAsItsOwn(): Void {
		Assert.same(['--lang', 'haxe', 'A.hx', 'apq.json'], one(choose(new LintCommand(), ['A.hx', 'apq.json', '--lang-default', 'haxe'])));
		Assert.equals(2, choose(new LintCommand(), ['A.hx', 'apq.json']).runs.length);
	}

	/** `--` is no flag and takes no value, so the path after it is a file. */
	@:killer('M-LANG-END-OF-OPTIONS-VALUE')
	@:pin('control')
	public function testAPathAfterEndOfOptionsCounts(): Void {
		Assert.same(['--lang', 'haxe', 'x', '--', 'A.hx'], one(choose(new LintCommand(), ['--lang-default', 'haxe', 'x', '--', 'A.hx'])));
		Assert.same(['--lang', 'json', 'x', '--', 'a.json'], one(choose(new LintCommand(), ['x', '--', 'a.json'])));
	}

	/**
	 * A command that routes each file by its own extension needs no
	 * argument naming a grammar: the file `--diff` names is no positional.
	 */
	public function testChangedNeedsNoPositionalFile(): Void {
		Assert.same(['HEAD', '--diff', 'A.hx'], one(choose(new ChangedCommand(), ['HEAD', '--diff', 'A.hx'])));
		Assert.same(['HEAD'], one(choose(new ChangedCommand(), ['HEAD'])));
		Assert.same(['--lang', 'haxe', 'HEAD'], one(choose(new ChangedCommand(), ['--lang-default', 'haxe', 'HEAD'])));
	}

	/**
	 * The text a walker searches for is no file: `lit '.last-sweep.json' src` names Haxe, not JSON, however its query is
	 * spelled — one query, a batch before `--`, or a scope that is itself a JSON file.
	 */
	@:killer('M-LANG-QUERY-COUNTED-AS-FILE')
	@:pin('control')
	public function testTheQueryOfAWalkerIsNoFile(): Void {
		Assert.same(['--lang', 'haxe', '.last-sweep.json', 'A.hx'], one(choose(new LitCommand(), ['.last-sweep.json', 'A.hx'])));
		Assert.same(
			['--lang', 'haxe', '.last-sweep.json', 'src'],
			one(choose(new LitCommand(), ['--lang-default', 'haxe', '.last-sweep.json', 'src']))
		);
		Assert.same(
			['--lang', 'haxe', 'a.json', 'b.json', '--', 'A.hx'], one(choose(new LitCommand(), ['a.json', 'b.json', '--', 'A.hx']))
		);
		Assert.same(['--lang', 'json', 'k', 'a.json'], one(choose(new LitCommand(), ['k', 'a.json'])));
		Assert.raises(() -> choose(new LitCommand(), ['a.json']), UsageFailure);
		Assert.same(['--lang', 'haxe', 'haxe.Json', 'A.hx'], one(choose(new ImportersCommand(), ['haxe.Json', 'A.hx'])));
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
			Assert.same(['--lang', 'haxe', 'q.json', 'A.hx'], one(choose(command, ['q.json', 'A.hx'])), command.name());
	}

	/** `owner` reads its question as text, so a question ending in `.json` names no grammar; `--list` has none. */
	@:killer('M-LANG-OWNER-QUESTION-READ-AS-FILE')
	@:pin('control')
	public function testTheQuestionOfOwnerIsNoFile(): Void {
		final owner: CliCommand = new OwnerCommand();
		Assert.same(['--lang', 'haxe', 'who reads apqlint.json', 'A.hx'], one(choose(owner, ['who reads apqlint.json', 'A.hx'])));
		Assert.same(['--lang', 'haxe', '--limit', '3', 'q.json', 'A.hx'], one(choose(owner, ['--limit', '3', 'q.json', 'A.hx'])));
		Assert.same(['--lang', 'json', '--list', 'a.json'], one(choose(owner, ['--list', 'a.json'])));
	}

	/** `comment-rewrite` reads TWO texts, the find and the replace, before the files. */
	@:killer('M-LANG-REWRITE-TEXTS-READ-AS-FILES')
	@:pin('control')
	public function testTheTwoTextsOfCommentRewriteAreNoFiles(): Void {
		final rewrite: CliCommand = new CommentRewriteCommand();
		Assert.same(['--lang', 'haxe', 'a.json', 'b.json', 'A.hx'], one(choose(rewrite, ['a.json', 'b.json', 'A.hx'])));
		Assert.same(
			['--lang', 'haxe', '--write', 'a.json', 'b.json', 'A.hx'], one(choose(rewrite, ['--write', 'a.json', 'b.json', 'A.hx']))
		);
		Assert.raises(() -> choose(rewrite, ['a.json', 'b.json']), UsageFailure);
	}

	/** `meta` reads its leading positional as text only when it is an annotation: `--on` may leave the annotation out. */
	@:killer('M-LANG-META-ANNOTATION-READ-AS-FILE')
	@:pin('control')
	public function testTheAnnotationOfMetaIsNoFile(): Void {
		final meta: CliCommand = new MetaCommand();
		Assert.same(['--lang', 'haxe', '@:keep.json', 'A.hx'], one(choose(meta, ['@:keep.json', 'A.hx'])));
		Assert.same(['--lang', 'json', '--on', 'ClassDecl', 'a.json'], one(choose(meta, ['--on', 'ClassDecl', 'a.json'])));
		Assert.same(['--lang', 'haxe', '@:fmt(a.json)', 'A.hx'], one(choose(meta, ['@:fmt(a.json)', 'A.hx'])));
		Assert.raises(() -> choose(meta, ['@:keep.json']), UsageFailure);
	}

	/** A directory names the grammars of the files under it: `apq lint src` here is `hxq lint src`, one Haxe run. */
	@:killer('M-LANG-DIRECTORY-UNWALKED')
	@:killer('M-LANG-DIRECTORY-EVERY-GRAMMAR')
	@:pin('control')
	public function testADirectoryNamesTheGrammarsOfItsFiles(): Void {
		Assert.same([['--lang', 'haxe', 'src', '--all']], choose(new LintCommand(), ['src', '--all']).runs);
		Assert.same(choose(new LintCommand(), ['--lang-default', 'haxe', 'src']).runs, choose(new LintCommand(), ['src']).runs);
	}

	/** A directory holding the files of two grammars runs once per grammar, and each run reads only its own grammar's files. */
	@:killer('M-CLI-RUNS-FIRST-ONLY')
	@:killer('M-WALK-FOLLOWS-NO-GRAMMAR')
	@:pin('control')
	public function testAMixedDirectoryReadsEachFileByItsOwnGrammar(): Void {
		final dir: String = mixedTree([]);
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			Assert.same([['--lang', 'haxe', dir], ['--lang', 'json', dir]], choose(new FmtCommand(), [dir]).runs);
			var code: Int = -1;
			final hits: String = CliFixture.captureStdout(() -> code = Cli.run(['lit', 'zz', dir, '--flat'], true));
			Assert.equals(0, code);
			Assert.same(
				['$dir/A.hx:2:17: DoubleStringExpr \'"zz"\'', '$dir/b.json:1:7: JString \'zz\''],
				hits.split('\n').filter(line -> line != '')
			);
		});
	}

	/** The project config names the grammars a directory walk takes (`languages`) and the grammar of a call no file names (`lang`). */
	@:killer('M-LANG-PROJECT-LANGUAGES-IGNORED')
	@:killer('M-LANG-PROJECT-LANG-IGNORED')
	@:pin('control')
	public function testTheProjectConfigNamesItsLanguages(): Void {
		final dir: String = mixedTree([{ name: 'apq.json', source: '{"languages": ["json"], "lang": "json"}\n' }]);
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			Assert.same([['--lang', 'json', dir]], choose(new FmtCommand(), [dir]).runs);
			final stdin: LanguageChoiceResult = LanguageChoice.choose(['-', 'a'], new GetCommand(), () -> 'class C {}', dir);
			Assert.same([['--lang', 'json', '-', 'a']], stdin.runs);
			Assert.equals('class C {}', stdin.stdin);
			Assert.same([['--lang', 'json', 'notes.txt']], LanguageChoice.choose(['notes.txt'], new LintCommand(), () -> '', dir).runs);
		});
	}

	/** A project config naming a grammar no plugin registers is a usage error, not a silent default. */
	public function testAnUnknownProjectLanguageIsAUsageError(): Void {
		final dir: String = mixedTree([{ name: 'apq.json', source: '{"languages": ["cobol"]}\n' }]);
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> Assert.raises(() -> choose(new FmtCommand(), [dir]), UsageFailure));
	}

	/** A pattern over a mixed directory runs only for the grammars it parses in; one parsing in none is a usage error naming them. */
	@:killer('M-LANG-PATTERN-EVERY-GRAMMAR')
	@:pin('control')
	public function testAPatternRunsWhereItParses(): Void {
		final dir: String = mixedTree([]);
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			Assert.same([['--lang', 'haxe', 'foo($$x)', dir]], choose(new SearchCommand(), ['foo($$x)', dir]).runs);
			Assert.raises(() -> choose(new SearchCommand(), [')(', dir]), UsageFailure);
		});
	}

	/** Several runs print several documents, so a JSON report over files of two grammars is refused. */
	@:killer('M-LANG-JSON-REPORT-SPLIT')
	@:pin('control')
	public function testAJsonReportOverTwoGrammarsIsRefused(): Void {
		Assert.raises(() -> choose(new LintCommand(), ['a.json', 'B.hx', '--format', 'json']), UsageFailure);
		Assert.raises(() -> choose(new RefsCommand(), ['x', 'a.json', 'B.hx', '--json']), UsageFailure);
	}

	/** `--exit-on-empty` over several runs judges the call: a hit in one grammar's run is a hit, and only every run empty fails. */
	@:killer('M-CLI-EXIT-ON-EMPTY-PER-RUN')
	@:killer('M-CLI-EXIT-ON-EMPTY-DROPPED')
	@:pin('control')
	public function testExitOnEmptyJudgesTheWholeCall(): Void {
		final dir: String = mixedTree([]);
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			Assert.equals(0, quietRun(['lit', 's', dir, '--flat', '--exit-on-empty']));
			Assert.equals(1, quietRun(['lit', 'nowhere', dir, '--flat', '--exit-on-empty']));
		});
	}

	/** A walked run reads the scopes holding its grammar's files, and a scope holding no file of any grammar walked stays in every run. */
	@:killer('M-LANG-WALK-KEEPS-FOREIGN-SCOPE')
	@:pin('control')
	public function testAWalkedRunReadsOnlyTheScopesHoldingItsFiles(): Void {
		final mixed: String = mixedTree([]);
		final haxeOnly: String = CliFixture.writeTree('langchoice', [{ name: 'C.hx', source: 'class C {}\n' }]);
		final none: String = '$haxeOnly/missing';
		CliFixture.always(() -> {
			CliFixture.removeDir(mixed);
			CliFixture.removeDir(haxeOnly);
		}, () -> Assert.same([
			['--lang', 'haxe', 'x', haxeOnly, mixed, none],
			['--lang', 'json', 'x', mixed, none]
		], choose(new RefsCommand(), ['x', haxeOnly, mixed, none]).runs));
	}

	/** The status of several runs is the worst (highest) of them, whichever run answered it. */
	@:killer('M-CLI-RUNS-LAST-STATUS')
	@:pin('control')
	public function testTheStatusOfSeveralRunsIsTheWorst(): Void {
		final dir: String = CliFixture.writeTree('langchoice', [
			{ name: 'A.hx', source: 'class A {\n' },
			{ name: 'b.json', source: '{"k": "zz"}\n' }
		]);
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> Assert.equals(1, quietRun(['fmt', '--list', dir])));
	}

	private static function choose(command: CliCommand, args: Array<String>): LanguageChoiceResult {
		return LanguageChoice.choose(args, command, () -> throw 'stdin must not be read');
	}

	/** The process entry's status for `args`, its output streams swallowed. */
	private static function quietRun(args: Array<String>): Int {
		var code: Int = -1;
		CliFixture.captureStderr(() -> CliFixture.captureStdout(() -> code = Cli.run(args, true)));
		return code;
	}

	/**
	 * A scratch directory holding `A.hx` and `b.json`, each with the string `zz`, and `extra`.
	 */
	private static function mixedTree(extra: Array<{ name: String, source: String }>): String {
		return CliFixture.writeTree('langchoice', [
			{ name: 'A.hx', source: 'class A {\n\tstatic var s = "zz";\n}\n' },
			{ name: 'b.json', source: '{"k": "zz"}\n' }
		].concat(extra));
	}

	/** The one run `chosen` holds. */
	private static function one(chosen: LanguageChoiceResult): Array<String> {
		Assert.equals(1, chosen.runs.length, 'runs: ${chosen.runs}');
		return chosen.runs[0];
	}

}
