package unit.query;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import anyparse.query.Engine;
import anyparse.query.QueryNode;
import anyparse.query.Selector;
import anyparse.query.format.Json;
import anyparse.query.format.Text;
import anyparse.runtime.ParseError;
import haxe.Exception;
import utest.Assert;
import utest.Test;

/**
 * Phase 1 integration test for the `apq ast` engine.
 *
 * Walks `src/anyparse/`, parses each `.hx` through `HaxeQueryPlugin`, renders it as an
 * S-expr and applies `Engine.truncate` and a sample selector; the two JSON paths
 * (`Json.renderTree`, and `Json.renderMatches` with the `Cli.sourceWindows` that feeds it)
 * run on one file in `JSON_SAMPLE_STRIDE` — see that constant for the measurement behind
 * the split. The test passes when no file triggers a non-`ParseError` exception in the
 * engine path. Parse failures on individual files are reported but do not fail the test —
 * Phase 3 grammar coverage is an independent concern.
 *
 * Skipped when `src/anyparse` is not reachable from the runner's cwd.
 */
class ApqAstIntegrationTest extends Test {

	/**
	 * One file in this many gets the two JSON render paths.
	 *
	 * Every other engine path in the walk is cheap — parse + `Text.render` + `truncate`
	 * + `select` over all 764 files under `src/anyparse` measured 4.9s. The two JSON
	 * paths over the same set measured 438s of the 443s total (anyparse's JSON writer
	 * emits 3.8 MB of pretty-printed output for a 127 KB source, ~2 MB/s), which is
	 * twenty times the whole suite. The stride keeps them exercised on a deterministic
	 * spread of the sorted list instead; the JSON writer's throughput is a separate
	 * concern, and `jsonRendered` is asserted against `walked / stride` so the sample
	 * cannot silently shrink. `Cli.sourceWindows` rides the same stride — it lexes the
	 * whole file per match, and `ApqSourceSelectTest` covers it directly.
	 */
	private static inline final JSON_SAMPLE_STRIDE: Int = 64;

	private static final SRC_ROOT: String = 'src/anyparse';

	@:access(anyparse.query.Cli)
	public function testParseEveryAnyparseFileWithoutCrash(): Void {
		#if (sys || nodejs)
		if (!FileSystem.exists(SRC_ROOT) || !FileSystem.isDirectory(SRC_ROOT)) {
			// Loud, not a silent pass: the runner always starts at the repo root, so an unreachable
			// root means the walk covered nothing — the same green-while-asserting-nothing shape
			// `DeadTestGuardTest` exists to catch, and the verdict its own probe already uses.
			Assert.fail('$SRC_ROOT is not reachable from the runner cwd — this walk cannot run');
			return;
		}
		final paths: Array<String> = SourceTree.collect(SRC_ROOT);
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final probeSelector: Selector = Selector.parse('ClassDecl');
		var parsedOk: Int = 0;
		var parseFailed: Int = 0;
		var jsonRendered: Int = 0;
		var walked: Int = 0;
		final engineCrashes: Array<String> = [];

		for (path in paths) {
			final source: String = File.getContent(path);
			final tree: Null<QueryNode> = try plugin.parseFile(source) catch (e: ParseError) {
				parseFailed++;
				null;
			} catch (e: Exception) {
				engineCrashes.push('$path: ${e.message}');
				continue;
			}
			if (tree == null) continue;
			final jsonSampled: Bool = walked++ % JSON_SAMPLE_STRIDE == 0;
			try {
				Text.render(tree);
				if (jsonSampled) Json.renderTree(path, source, tree);
				final truncated: QueryNode = Engine.truncate(tree, 2);
				Text.render(truncated);
				final matches: Array<QueryNode> = Engine.select(tree, probeSelector, plugin.selectKindEquivalence());
				if (matches.length > 0 && jsonSampled)
					Json.renderMatches(
						path, source, matches, Cli.sourceWindows(tree, matches, source, plugin.lexicalRegions.bind(source)), false, false,
						plugin.lexicalRegions(source)
					);
				if (jsonSampled) jsonRendered++;
				parsedOk++;
			} catch (e: Exception) {
				engineCrashes.push('$path (post-parse): ${e.message}');
			}
		}

		if (engineCrashes.length > 0) {
			Assert.fail('engine crashed on ${engineCrashes.length} files:\n  ${engineCrashes.join('\n  ')}');
			return;
		}
		Assert.isTrue(paths.length > 0, '$SRC_ROOT must contain .hx files');
		Assert.isTrue(
			jsonRendered >= Std.int(walked / JSON_SAMPLE_STRIDE),
			'the JSON-render sample must track the stride, not just be non-empty ($jsonRendered of $walked walked)'
		);
		Assert.pass(
			'engine clean on $parsedOk/${paths.length} files ($parseFailed parse-failed, $jsonRendered JSON-rendered, 0 engine crashes)'
		);
		#else
		Assert.pass('integration: non-sys target, fs unavailable — skipped');
		#end
	}

}
