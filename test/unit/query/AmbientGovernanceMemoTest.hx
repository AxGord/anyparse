package unit.query;

import anyparse.query.CachingGrammarPlugin;
import anyparse.query.GrammarPlugin;
import unit.cli.CliFixture;

/**
 * What an ambient import source governs is read from disk once per run: the decorator holds the
 * answer per path, a fresh decorator is a fresh run, and the head of a `--fix` pass lets go of it
 * because that is where the run's own writes become visible.
 */
@:nullSafety(Strict)
class AmbientGovernanceMemoTest extends Test {

	/** A source and the two modules it governs. */
	private static final TREE: Array<{ name: String, source: String }> = [
		{ name: 'src/gqq/import.hx', source: 'import haxe.io.Path;\n' },
		{ name: 'src/gqq/Aqq.hx', source: 'package gqq;\n\nclass Aqq {}\n' },
		{ name: 'src/gqq/sub/Bqq.hx', source: 'package gqq.sub;\n\nclass Bqq {}\n' }
	];

	/** Two calls in one run read the subtree once: a module changed between them is not seen. */
	@:pin('guard')
	public function testTwoCallsInOneRunReadTheTreeOnce(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_govern_memo_once', TREE);
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final cached: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
			final first: String = governedText(cached, root);
			rewriteModule(root);
			out = '${first == governedText(cached, root)}';
		});
		Assert.equals('true', out);
		#else
		Assert.pass();
		#end
	}

	/** A second run, which is a second decorator, sees the module the first run's tree held differently. */
	@:pin('guard')
	public function testASecondRunSeesAFileChangedBetweenRuns(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_govern_memo_runs', TREE);
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final first: String = governedText(new CachingGrammarPlugin(new HaxeQueryPlugin()), root);
			rewriteModule(root);
			out = '${first != governedText(new CachingGrammarPlugin(new HaxeQueryPlugin()), root)}';
		});
		Assert.equals('true', out);
		#else
		Assert.pass();
		#end
	}

	/** The head of a pass lets go: a module a previous pass wrote is the one the next call reads. */
	@:pin('control')
	@:killer('M-AMBIENT-GOVERN-STALE')
	public function testAPassSeesTheModulesAPreviousPassWrote(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_govern_memo_pass', TREE);
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final cached: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
			final first: String = governedText(cached, root);
			rewriteModule(root);
			cached.invalidateAmbientChain();
			out = '${first != governedText(cached, root)}';
		});
		Assert.equals('true', out);
		#else
		Assert.pass();
		#end
	}

	/** Change the text of one governed module on disk, the way a pass of a `--fix` run does. */
	private static function rewriteModule(root: String): Void {
		#if (sys || nodejs)
		sys.io.File.saveContent('$root/src/gqq/Aqq.hx', 'package gqq;\n\nclass Aqq { var x: Int; }\n');
		#end
	}

	/** The governed modules of the source under `root`, each file name with its text, in a stable order. */
	private static function governedText(plugin: GrammarPlugin, root: String): String {
		final governance: Null<AmbientImportGovernance> = plugin.ambientImportGovernance('$root/src/gqq/import.hx');
		if (governance == null) return 'NONE';
		final entries: Array<String> = governance.governs.map(entry -> '${entry.file}:${entry.source}');
		entries.sort(Reflect.compare);
		return entries.join(';');
	}

}
