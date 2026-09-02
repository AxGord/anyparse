package unit;

import anyparse.grammar.haxe.HaxeLexicalRegions;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions;
import utest.Assert;
import utest.Test;

using StringTools;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

/**
 * `GrammarPlugin.lexicalRegions` — the seam that moved one grammar's LEXER out of the engine.
 *
 * `anyparse.query.LexicalRegions` held a full Haxe lexer: single-quote interpolation, `${ … }`
 * holes, `~/ … /` literals, `//` and block comments. A grammar-agnostic package deciding what
 * a comment is for every language is invariant 4 in reverse — a second grammar could not answer
 * the question without editing core code — and the debt stayed invisible because the only
 * grammar that ever asked was Haxe.
 *
 * RED AT BASE, and by the seam itself: `plugin.lexicalRegions(source)` does not compile at
 * `3d5bf593`, so the whole class fails to build there rather than failing an assertion. The
 * behaviour half is a characterization pin — the answers must be byte-identical to what the
 * old `LexicalRegions.scan` gave, which `testForwarderAgreesWithTheSeam` states directly and
 * the corpus sweep confirms wholesale.
 */
class LexicalRegionsSeamTest extends Test {

	/** Comment, interpolating literal with a nested same-quote hole, and a regex holding an opener. */
	private static final SOURCE: String = "// note\nvar s = '${c ? '// inner' : x}';\nvar r = ~/[\\/*]/;\n";

	/** The package prefix no grammar-agnostic module may name outside the allow-list. */
	private static final GRAMMAR_PATH: String = 'anyparse.grammar.haxe.';

	/** The seam answers the Haxe regions — the scan that used to sit in the engine, asked of the grammar. */
	public function testPluginAnswersTheHaxeRegions(): Void {
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final regions: Array<LexRegion> = plugin.lexicalRegions(SOURCE);
		Assert.equals(3, regions.length, 'comment, literal and regex: ${dump(regions)}');
		Assert.equals('// note', SOURCE.substring(regions[0].from, regions[0].to));
		Assert.equals(LexRegionKind.LineComment, regions[0].kind);
		Assert.equals("'${c ? '// inner' : x}'", SOURCE.substring(regions[1].from, regions[1].to), 'the hole stays inside ONE region');
		Assert.equals(LexRegionKind.StringLit, regions[1].kind);
		Assert.equals('~/[\\/*]/', SOURCE.substring(regions[2].from, regions[2].to), 'and the regex opens no comment');
		Assert.equals(LexRegionKind.RegexLit, regions[2].kind);
	}

	/**
	 * The move is behaviour-preserving: the grammar implementation and the seam answer the same
	 * thing. The deprecated `LexicalRegions` forwarder this used to compare against as well is
	 * gone since S60 — every consumer now reaches the scan through the plugin — so what remains
	 * is the arm that would go red if `HaxeQueryPlugin.lexicalRegions` ever stopped delegating.
	 */
	public function testGrammarImplementationAgreesWithTheSeam(): Void {
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final seam: String = text(SOURCE, plugin.lexicalRegions(SOURCE));
		Assert.equals(text(SOURCE, HaxeLexicalRegions.scan(SOURCE)), seam, 'seam == grammar implementation');
	}

	/**
	 * The caching wrapper passes the seam STRAIGHT THROUGH and memoises nothing — two different
	 * sources through one wrapper each get their own answer, and a source asked twice is
	 * re-lexed rather than served from a map that would live as long as the run.
	 *
	 * Deliberate, not an omission: the scan is 2.7 % of a full `lint --all --fix` over 869 files
	 * (`--cpu-prof`), against a parse that is demanded once per CHECK. A cache added on
	 * speculation is exactly the process-lifetime state invariant 1 is about, even when it is
	 * instance-scoped.
	 */
	public function testCachingWrapperPassesThrough(): Void {
		final plain: String = "var t = 'plain';\n";
		final wrapper: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final first: String = text(SOURCE, wrapper.lexicalRegions(SOURCE));
		final other: String = text(plain, wrapper.lexicalRegions(plain));
		Assert.equals(text(SOURCE, new HaxeQueryPlugin().lexicalRegions(SOURCE)), first, 'the wrapper answers what the inner grammar does');
		Assert.equals("'plain'", other, 'a second, different source is not served the first answer');
		Assert.equals(first, text(SOURCE, wrapper.lexicalRegions(SOURCE)), 'and the first source still answers the same');
	}

	/** The region texts joined, so a failure says what was actually scanned. */
	private function text(source: String, regions: Array<LexRegion>): String {
		return [for (region in regions) source.substring(region.from, region.to)].join(' | ');
	}

	/** Region bounds and kinds, for a length assertion that would otherwise say only a number. */
	private function dump(regions: Array<LexRegion>): String {
		return [for (region in regions) '[${region.from},${region.to})'].join(' ');
	}

	/**
	 * THE ACCEPTANCE PIN, in the "shrinkage IS the test" shape: the grammar-agnostic packages
	 * `anyparse.query` and `anyparse.check` may name `anyparse.grammar.haxe.*` in EXACTLY two
	 * modules, and this asserts the list rather than a count.
	 *
	 *  - `query/Cli.hx` — `pickPlugin` maps `--lang haxe` to `HaxeQueryPlugin`. Something has to
	 *    know one concrete grammar for the CLI to have a default, and this is the one place that
	 *    does; every other module receives the plugin it was handed.
	 *  - `query/FormatConfigDiscovery.hx` — `HaxeFormatConfigDiagnostics` names the `hxformat.json`
	 *    keys this engine does not implement, which is a fact about the HAXE formatter's config
	 *    schema and cannot be derived from a grammar-agnostic seam.
	 *
	 * Everything else must reach a grammar through `GrammarPlugin`. Before S60 the exception was
	 * `LexicalRegions.scan` / `skipStringLiteral`, a deprecated forwarder that hardcoded the Haxe
	 * lexer for 65 `collectCommentTokens` call sites — the path that gates every DELETE in the
	 * tool. Both are gone; this test is what stops the next one being added quietly.
	 *
	 * Occurrences inside a COMMENT or a STRING do not count, and the masking is done with the very
	 * seam under test (`plugin.lexicalRegions` + `LexicalRegions.regionAt`) — this file's own class
	 * doc names `anyparse.grammar.haxe` in prose, and so does `LexicalRegions`'s.
	 */
	#if (sys || nodejs)
	public function testNoQueryOrCheckModuleReachesTheHaxeGrammar(): Void {
		final allowed: Array<String> = ['src/anyparse/query/Cli.hx', 'src/anyparse/query/FormatConfigDiscovery.hx'];
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final found: Array<String> = [];
		for (dir in ['src/anyparse/query', 'src/anyparse/check']) for (path in hxFilesUnder(dir)) {
			final source: String = File.getContent(path);
			final regions: Array<LexRegion> = plugin.lexicalRegions(source);
			var at: Int = source.indexOf(GRAMMAR_PATH);
			while (at >= 0) {
				if (LexicalRegions.regionAt(at, regions) == null) {
					found.push(path);
					break;
				}
				at = source.indexOf(GRAMMAR_PATH, at + 1);
			}
		}
		found.sort(Reflect.compare);
		Assert.equals(allowed.join('\n'), found.join('\n'), 'the allow-list is the whole story — a new one is a forwarder');
	}

	/** Every `.hx` under `dir`, recursively, in a stable order. */
	private function hxFilesUnder(dir: String): Array<String> {
		final out: Array<String> = [];
		if (!FileSystem.exists(dir)) return out;
		for (entry in FileSystem.readDirectory(dir)) {
			final path: String = '$dir/$entry';
			if (FileSystem.isDirectory(path))
				for (nested in hxFilesUnder(path)) out.push(nested);
			else if (path.endsWith('.hx'))
				out.push(path);
		}
		out.sort(Reflect.compare);
		return out;
	}
	#end

}
