package unit;

import anyparse.grammar.haxe.HaxeLexicalRegions;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions;
import utest.Assert;
import utest.Test;

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
	 * The move is behaviour-preserving: the grammar implementation, the seam and the deprecated
	 * forwarder in `anyparse.query` all answer the same thing. The forwarder is what keeps the
	 * plugin-less callers compiling — 69 `collectCommentTokens` call sites among them — and this
	 * is the arm that would go red if the split ever let the two drift.
	 */
	public function testForwarderAgreesWithTheSeam(): Void {
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final seam: String = text(SOURCE, plugin.lexicalRegions(SOURCE));
		Assert.equals(text(SOURCE, HaxeLexicalRegions.scan(SOURCE)), seam, 'seam == grammar implementation');
		Assert.equals(text(SOURCE, LexicalRegions.scan(SOURCE)), seam, 'deprecated forwarder == seam');
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

}
