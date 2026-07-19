package unit;

import utest.Assert;
import utest.Test;
import haxe.Exception;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Engine;
import anyparse.query.QueryNode;
import anyparse.query.Selector;
import anyparse.query.format.Json;
import anyparse.query.format.Text;
import anyparse.runtime.ParseError;
#if sys
import sys.FileSystem;
import sys.io.File;
#end

/**
 * Phase 1 integration test for the `apq ast` engine.
 *
 * Walks `src/anyparse/`, parses each `.hx` through `HaxeQueryPlugin`,
 * renders S-expr + JSON + applies `Engine.truncate` and a sample
 * selector. The test passes when no file triggers a non-`ParseError`
 * exception in the engine path. Parse failures on individual files
 * are reported but do not fail the test — Phase 3 grammar coverage is
 * an independent concern.
 *
 * Skipped on non-sys targets (no filesystem).
 */
class ApqAstIntegrationTest extends Test {

	private static final SRC_ROOT: String = 'src/anyparse';

	public function testParseEveryAnyparseFileWithoutCrash(): Void {
		#if sys
		if (!FileSystem.exists(SRC_ROOT) || !FileSystem.isDirectory(SRC_ROOT)) {
			Assert.pass('integration: $SRC_ROOT not present (different cwd?) — skipped');
			return;
		}
		final paths: Array<String> = [];
		collectHxFiles(SRC_ROOT, paths);
		paths.sort((a: String, b: String) -> a < b ? -1 : (a > b ? 1 : 0));

		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final probeSelector: Selector = Selector.parse('ClassDecl');
		var parsedOk: Int = 0;
		var parseFailed: Int = 0;
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
			try {
				Text.render(tree);
				Json.renderTree(path, source, tree);
				final truncated: QueryNode = Engine.truncate(tree, 2);
				Text.render(truncated);
				final matches: Array<QueryNode> = Engine.select(tree, probeSelector, plugin.selectKindEquivalence());
				if (matches.length > 0) Json.renderMatches(path, source, matches, false, false);
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
		Assert.pass('engine clean on $parsedOk/${paths.length} files ($parseFailed parse-failed, 0 engine crashes)');
		#else
		Assert.pass('integration: non-sys target, fs unavailable — skipped');
		#end
	}

	#if sys
	private static function collectHxFiles(dir: String, into: Array<String>): Void {
		for (name in FileSystem.readDirectory(dir)) {
			final path: String = '$dir/$name';
			if (FileSystem.isDirectory(path)) {
				collectHxFiles(path, into);
			} else if (StringTools.endsWith(name, '.hx')) {
				into.push(path);
			}
		}
	}
	#end

}
