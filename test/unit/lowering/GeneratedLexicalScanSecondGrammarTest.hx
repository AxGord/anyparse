package unit.lowering;

import anyparse.grammar.haxe.HaxeLexicalRegions;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.LexicalRegions.LexRegionKind;
import unit.minilex.MiniLexScan;
import utest.Assert;
import utest.Test;

/**
 * The generated lexical pass asked the one question no Haxe-only pin can ask: does it KNOW
 * what a comment or a string is, or does it only know what it was DECLARED?
 *
 * `MiniLexScan` is built by the same `Build.buildLexicalScan` from `unit.minilex.MiniLexDoc`,
 * a second grammar whose format spells a line comment `#`, a block comment `<# … #>` and a
 * string `@ … @` — not one byte shared with Haxe. So every assertion here is two-sided: the
 * second grammar's delimiters ARE regions, and Haxe's delimiters are NOT, in the same source.
 *
 * This is the killer for the arm the Haxe pins cannot see. `LexicalLowering` could read its
 * comment delimiters from a literal instead of from the format and every Haxe test would stay
 * green, because the literal and the declaration say the same thing there; here they do not.
 * It is also the standing evidence for invariant 4 — a second grammar answers the same
 * question without a core change, which is the whole claim `LexicalCodegen`'s doc makes.
 */
@:nullSafety(Strict)
class GeneratedLexicalScanSecondGrammarTest extends Test {

	/** `#` opens a comment in `MiniLex` and `//` does not — in ONE source, both directions. */
	public function testTheLineCommentIsTheOneTheFormatDeclares(): Void {
		final source: String = 'word # note\n';
		assertOnly(MiniLexScan.scan(source), source, '# note', LexRegionKind.LineComment);
		Assert.equals(0, MiniLexScan.scan('word // note\n').length, 'Haxe\'s line comment is not MiniLex\'s');
	}

	/** `<# … #>` is the block comment; Haxe's `/* … *' + '/` is ordinary text here. */
	public function testTheBlockCommentIsTheOneTheFormatDeclares(): Void {
		final source: String = 'word <# note #> word';
		assertOnly(MiniLexScan.scan(source), source, '<# note #>', LexRegionKind.BlockComment);
		Assert.equals(0, MiniLexScan.scan('word /* note */ word').length, 'Haxe\'s block comment is not MiniLex\'s');
	}

	/** `@ … @` is the string literal, from the terminal's own `@:re`, and neither quote is. */
	public function testTheStringDelimiterIsTheOneTheTerminalDeclares(): Void {
		final source: String = 'word @text@ word';
		assertOnly(MiniLexScan.scan(source), source, '@text@', LexRegionKind.StringLit);
		Assert.equals(0, MiniLexScan.scan('word \'text\' word').length, 'a Haxe single-quoted string is not MiniLex\'s');
		Assert.equals(0, MiniLexScan.scan('word "text" word').length, 'a Haxe double-quoted string is not MiniLex\'s');
	}

	/** The escape the `@:re` spells suspends the closer, exactly as it does for Haxe. */
	public function testTheEscapeComesOffTheSamePattern(): Void {
		final source: String = 'word @a\\@b@ word';
		assertOnly(MiniLexScan.scan(source), source, '@a\\@b@', LexRegionKind.StringLit);
	}

	/** `scanComments` filters the same walk, so the second grammar gets it for free. */
	public function testScanCommentsFollowsTheSecondGrammarToo(): Void {
		final spans: Array<String> = [];
		MiniLexScan.scanComments('word # note\nword <# two #>', (start: Int, end: Int) -> spans.push('$start:$end'));
		Assert.equals('5:11 17:26', spans.join(' '), 'both of MiniLex\'s comment shapes, neither of Haxe\'s');
	}

	/**
	 * The two generated passes disagree on the SAME source, and exactly where their
	 * declarations do — which is what "generated from the grammar" has to mean.
	 */
	public function testTheTwoPassesDisagreeExactlyWhereTheirDeclarationsDo(): Void {
		final haxeShaped: String = 'var a = \'text\'; // note';
		Assert.equals(2, HaxeLexicalRegions.scan(haxeShaped).length, 'Haxe reads its own literal and comment');
		Assert.equals(0, MiniLexScan.scan(haxeShaped).length, 'MiniLex reads neither');
		final miniShaped: String = 'word @text@ # note';
		Assert.equals(0, HaxeLexicalRegions.scan(miniShaped).length, 'Haxe reads neither');
		Assert.equals(2, MiniLexScan.scan(miniShaped).length, 'MiniLex reads its own literal and comment');
	}

	/** One region, spanning exactly `text`, carrying `kind`. */
	private function assertOnly(regions: Array<LexRegion>, source: String, text: String, kind: LexRegionKind): Void {
		Assert.equals(1, regions.length, 'one region in `$source`');
		if (regions.length != 1) return;
		final region: LexRegion = regions[0];
		Assert.equals(text, source.substring(region.from, region.to));
		Assert.equals(kind, region.kind);
	}

}
