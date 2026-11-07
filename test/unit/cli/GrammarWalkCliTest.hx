package unit.cli;

import anyparse.query.CachingGrammarPlugin.ResolutionScope;
import anyparse.query.Cli;
import anyparse.query.cli.CliArgs;
import anyparse.query.cli.CliCallGraph;
import anyparse.query.cli.CliRegistry;
import anyparse.query.cli.command.LintCommand;
import anyparse.query.cli.command.NewCommand;

using StringTools;

/**
 * Every file walk of a command reads the files of the grammar it parses them by (`CliArgs.expandFor`), never the
 * `.hx` ones whatever the grammar; what a run prints names that grammar, not Haxe.
 */
@:nullSafety(Strict)
class GrammarWalkCliTest extends Test {

	/** A refactor's `--scope` reads the files of the op's grammar: a JSON scope over a mixed directory is its `.json` file. */
	@:killer('M-SCOPE-FILES-WALK-HX')
	@:pin('control')
	public function testScopeFilesFollowTheGrammar(): Void {
		final dir: String = mixedTree();
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			Assert.same(['b.json'], names(CliArgs.collectScopeFiles('x', CliArgs.JSON_LANG, dir, []) ?? []));
			Assert.same(['A.hx'], names(CliArgs.collectScopeFiles('x', 'haxe', dir, []) ?? []));
		});
	}

	/** The declared `resolutionRoots` are read as files of the lint's grammar. */
	@:killer('M-RESOLUTION-ROOTS-WALK-HX')
	@:pin('control')
	public function testResolutionRootsFollowTheGrammar(): Void {
		final dir: String = mixedTree();
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			final scope: Null<ResolutionScope> = LintCommand.resolutionThunk(CliArgs.JSON_LANG, [], [dir], [], false);
			Assert.same(['b.json'], names(scope?.sources().projectRoots ?? []));
		});
	}

	/** A graph command's scope is the files of its grammar. */
	@:killer('M-GRAPH-SCOPE-WALK-HX')
	@:pin('control')
	public function testAGraphScopeFollowsTheGrammar(): Void {
		final dir: String = mixedTree();
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			Assert.same(['b.json'], names(CliCallGraph.readScope('callers', [dir], CliArgs.JSON_LANG)?.files ?? []));
		});
	}

	/** A scope holding no file of the run's grammar is named by that grammar's extension, not by `.hx`. */
	@:killer('M-FILES-OF-HX')
	@:pin('control')
	public function testNoFilesMatchedNamesTheGrammar(): Void {
		#if nodejs
		final dir: String = CliFixture.writeTree('grammarwalk', [{ name: 'C.hx', source: 'class C {}\n' }]);
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			var code: Int = -1;
			final err: String = CliFixture.captureStderr(() ->
				CliFixture.captureStdout(() -> code = Cli.run(['lint', '--lang', 'json', dir]))
			);
			Assert.equals(1, code);
			Assert.isTrue(err.contains('matched no .json files'), err);
		});
		#else
		Assert.pass('non-nodejs target');
		#end
	}

	/** No command's usage page claims Haxe as the default grammar: a process call takes the one its files' extensions name. */
	@:killer('M-LANG-HELP-DEFAULT-HAXE')
	@:pin('control')
	public function testNoUsageClaimsAHaxeDefault(): Void {
		#if nodejs
		for (command in CliRegistry.commands()) {
			final page: String = CliFixture.captureStdout(() -> CliFixture.captureStderr(() -> command.usage()));
			Assert.isFalse(page.contains('(default: haxe)') || page.contains('(default haxe)'), '${command.name()} --help');
		}
		#else
		Assert.pass('non-nodejs target');
		#end
	}

	/** Each run of a call over the files of two grammars is labelled with its grammar; a call of one grammar is not. */
	@:killer('M-RUNS-UNLABELLED')
	@:pin('control')
	public function testEachRunOfSeveralIsLabelled(): Void {
		#if nodejs
		final dir: String = mixedTree();
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			final several: String = CliFixture.captureStderr(() ->
				CliFixture.captureStdout(() -> Cli.run(['lit', 'zz', dir, '--flat'], true))
			);
			Assert.isTrue(several.contains('apq lit: --lang haxe (run 1 of 2)'), several);
			Assert.isTrue(several.contains('apq lit: --lang json (run 2 of 2)'), several);
			final one: String = CliFixture.captureStderr(() -> CliFixture.captureStdout(() -> Cli.run(['lit', 'zz', '$dir/b.json'], true)));
			Assert.isFalse(one.contains('(run 1 of'), one);
		});
		#else
		Assert.pass('non-nodejs target');
		#end
	}

	/** `new` scaffolds a type, so in a grammar declaring none it refuses and names `--raw -`. */
	@:killer('M-NEW-DATA-SCAFFOLD')
	@:pin('control')
	public function testANewScaffoldInADataGrammarIsRefused(): Void {
		#if nodejs
		var code: Int = -1;
		final err: String = CliFixture.captureStderr(() ->
			CliFixture.captureStdout(() -> code = Cli.run(['new', '--lang', 'json', 'X.json', '--class']))
		);
		Assert.equals(2, code);
		Assert.isTrue(err.contains('declares no types to scaffold'), err);
		#else
		Assert.pass('non-nodejs target');
		#end
	}

	/** A new module's type is named by its basename without the extension its grammar registers. */
	@:killer('M-NEW-CLASS-NAME-KEEPS-EXT')
	@:pin('control')
	public function testANewModuleIsNamedWithoutItsExtension(): Void {
		Assert.equals('C', NewCommand.newFileClassName('src/C.hx'));
		Assert.equals('B', NewCommand.newFileClassName('a/B.json'));
	}

	/** A probe is staged under its grammar's extension, so a chained `recon --probe` reads it by that grammar. */
	@:killer('M-PROBE-STAGE-HX')
	@:pin('control')
	public function testAProbeIsStagedUnderItsGrammarsExtension(): Void {
		#if nodejs
		final err: String = CliFixture.captureStderr(() ->
			CliFixture.captureStdout(() -> Cli.run(['probe', '--lang', 'json', '{"a": 1}']))
		);
		final marker: String = 'staged source -> ';
		final at: Int = err.indexOf(marker);
		Assert.isTrue(at >= 0, err);
		Assert.isTrue(err.substr(at + marker.length).split(' ')[0].endsWith('.json'), err);
		#else
		Assert.pass('non-nodejs target');
		#end
	}

	/**
	 * `gates --lang json` reads the JSON grammar's DEFINITIONS, and parses each by the grammar its extension names (a
	 * definition is Haxe), never by the JSON plugin `--lang` names.
	 */
	@:killer('M-GATES-PARSED-BY-LANG')
	@:killer('M-GATES-WALKS-LANG-FILES')
	@:pin('control')
	public function testGatesParsesDefinitionsByTheirOwnGrammar(): Void {
		#if nodejs
		final dir: String = CliFixture.writeTree('grammarwalk', [
			{ name: 'JKw.hx', source: 'package anyparse.grammar.json;\n\nenum JKw {\n\t@:kw("call") Call(name: String);\n}\n' }
		]);
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			var code: Int = -1;
			final out: String = CliFixture.captureStdout(
				() -> CliFixture.captureStderr(() -> code = Cli.run(['gates', '--lang', 'json', '--mechanism', 'kw-lead', '--flat', dir]))
			);
			Assert.equals(0, code);
			Assert.isTrue(out.contains('JKw.hx:4:15: ParamCtor Call → @:kw("call")'), out);
		});
		#else
		Assert.pass('non-nodejs target');
		#end
	}

	/** A scratch directory holding `A.hx` and `b.json`, each with the string `zz`. */
	private static function mixedTree(): String {
		return CliFixture.writeTree('grammarwalk', [
			{ name: 'A.hx', source: 'class A {\n\tstatic var s = "zz";\n}\n' },
			{ name: 'b.json', source: '{"k": "zz"}\n' }
		]);
	}

	/** The base names of `files`, in order. */
	private static function names(files: Array<{ file: String, source: String }>): Array<String> {
		return files.map(f -> haxe.io.Path.withoutDirectory(f.file));
	}

}
