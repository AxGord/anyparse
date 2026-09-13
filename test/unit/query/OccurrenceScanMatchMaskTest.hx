package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.OccurrenceScan;
import anyparse.query.SourceComments;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * `OccurrenceScan.referencedInRange` / `referencedUnqualifiedInRange` masked against
 * `OccurrenceScan.inertMask`: a name spelled inside a comment, a non-interpolating string
 * literal, or a regex literal no longer reads as a reference to the identifier it merely
 * spells, while a real reference — including one reached only through string interpolation —
 * still counts, and the existing comment-qualifier test stays independent of the new mask.
 */
class OccurrenceScanMatchMaskTest extends Test {

	public function testStringLiteralIsNotAReference(): Void {
		final src: String = 'class C {\n\tfunction m() {\n\t\tvar msg = "keep foo safe";\n\t}\n}';
		Assert.isFalse(referenced(src, 'foo'));
	}

	public function testLineCommentIsNotAReference(): Void {
		final src: String = 'class C {\n\tfunction m() {\n\t\t// keep foo safe\n\t}\n}';
		Assert.isFalse(referenced(src, 'foo'));
	}

	public function testBlockCommentIsNotAReference(): Void {
		final src: String = 'class C {\n\t/* keep foo safe */\n\tfunction m() {}\n}';
		Assert.isFalse(referenced(src, 'foo'));
	}

	public function testRegexLiteralIsNotAReference(): Void {
		final src: String = 'class C {\n\tfunction m() {\n\t\tvar r = ~/foo/;\n\t}\n}';
		Assert.isFalse(referenced(src, 'foo'));
	}

	public function testRealReferenceAdjacentToAMatchingStringIsStillFound(): Void {
		final src: String = 'class C {\n\tfunction m() {\n\t\tvar msg = "keep foo safe";\n\t\ttrace(foo);\n\t}\n}';
		Assert.isTrue(referenced(src, 'foo'));
	}

	/**
	 * `qualifiedBefore`'s backwards `.`-lookup takes COMMENTS ONLY, not the full match mask —
	 * a line comment ending in a sentence period must not read the next line's reference as
	 * dot-qualified. Pinned here because the two masks are separate parameters on
	 * `referencedUnqualifiedInRange`, and merging them would let a real reference inside a
	 * masked comment span silently change this answer.
	 */
	public function testCommentEndingInAFullStopDoesNotQualifyTheFollowingReference(): Void {
		final src: String = 'class C {\n\tfunction m() {\n\t\t// a sentence.\n\t\tfoo();\n\t}\n}';
		Assert.isTrue(referencedUnqualified(src, 'foo'));
	}

	public function testSimpleInterpolationSurvivesTheMask(): Void {
		Assert.isTrue(referenced("class C {\n\tfunction m() {\n\t\tvar s = '$name';\n\t}\n}", 'name'));
	}

	public function testBraceInterpolationSurvivesTheMask(): Void {
		Assert.isTrue(referenced("class C {\n\tfunction m() {\n\t\tvar s = '${name}';\n\t}\n}", 'name'));
	}

	private function referenced(src: String, name: String): Bool {
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		return OccurrenceScan.referencedInRange(src, name, 0, src.length, [], OccurrenceScan.inertMask(src, plugin));
	}

	private function referencedUnqualified(src: String, name: String): Bool {
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final regions: Array<LexRegion> = plugin.lexicalRegions(src);
		final comments: Array<Span> = SourceComments.collectCommentRegions(regions);
		return OccurrenceScan.referencedUnqualifiedInRange(src, name, 0, src.length, [], comments, OccurrenceScan.inertMask(src, plugin));
	}

}
