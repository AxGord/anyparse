package unit.query;

import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.Matcher;
import anyparse.query.Pattern;

/**
 * Where a pattern's `$X` / `...` stays text: the grammar's lexical regions decide, not a scanner of the pattern's own.
 */
class MetavarRegionsTest extends Test {

	@:pin('control') @:killer('M-METAVAR-REGIONS-OFF')
	public function testAMetavarInsideAStringLiteralStaysText(): Void {
		Assert.equals('y', onlyBound("f('$x', $y)"));
		Assert.equals('y', onlyBound('f("$$x", $$y)'));
		Assert.equals('y', onlyBound("f('${$x}', $y)"));
	}

	@:pin('guard')
	public function testAMetavarInsideACommentStaysText(): Void {
		Assert.equals('y', onlyBound("f(/* $x */ $y)"));
		Assert.equals('y', onlyBound("f(\n$y // $x\n)"));
	}

	@:pin('control') @:killer('M-METAVAR-REGIONS-OFF')
	public function testAMetavarInsideARegexLiteralStaysText(): Void {
		Assert.equals(1, matches('~/a$$x/', 'class X { function f() { var r = ~/a$$x/; } }').length);
		final quoted: Array<Match> = matches("~/'/.match($y)", "class X { function f(y) { ~/'/.match(y); } }");
		Assert.equals(1, quoted.length);
		Assert.equals('y', quoted[0].bindings.get('y')?.name);
	}

	public function testTheSubstitutionLeavesATextRegionAsWritten(): Void {
		final source: String = "f('$x ...', /* $x ... */ ~/$x/, $y, ...)";
		final regions: Array<LexRegion> = new HaxeQueryPlugin().lexicalRegions(source);
		Assert.equals(
			'f(\'$$x ...\', /* $$x ... */ ~/$$x/, __APQ_MV_y_END__, ${PatternStar.PLACEHOLDER})',
			Metavar.substituteMetavarsHaxe(source, regions)
		);
	}

	private static function matches(pattern: String, source: String): Array<Match> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return Matcher.search(plugin.parsePattern(pattern), plugin.parseFile(source));
	}

	private static function onlyBound(source: String): String {
		final counts: Map<String, Int> = Metavar.treeCounts(new HaxeQueryPlugin().parsePattern(source).root);
		return [for (name => _ in counts) name].join(',');
	}

}
