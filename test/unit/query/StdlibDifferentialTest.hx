package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.StdlibDifferential;
import anyparse.query.StdlibDupScan;
import utest.Assert;
import utest.Test;

/**
 * `StdlibDifferential` -- the mapping enumeration and probe generation behind `apq stdlib-dup`.
 * Everything asserted here is PURE: the candidate comes from a real scan, the mappings and the
 * generated program are built without a compiler, and the verdict parser is driven with a
 * transcript. The spawn half is exercised end to end by the CLI, not by the unit suite.
 *
 * Fixture sources are written in DOUBLE quotes so a `$` inside a fixture's own single-quoted
 * string stays literal rather than becoming an interpolation of the test file.
 */
class StdlibDifferentialTest extends Test {

	/**
	 * The mapping the motivating case needs exists, and it carries BOTH things the two cheaper
	 * detection channels could not supply: the `Int -> String` interpolation adapter that makes
	 * `padDigit(Int, Int)` reach `lpad(String, String, Int)` at all, and the `'0'` lifted out of
	 * the candidate's own body. Asserted as ONE string so neither half can pass alone.
	 */
	public function testInterpolationAdapterAndBodyLiteralReachTheSameCall(): Void {
		final maps: Array<Mapping> = StdlibDifferential.mappings(padDigit());
		Assert.isTrue(displays(maps).contains("StringTools.lpad('$i', '0', digits)"), 'displays: ${displays(maps)}');
	}

	/** Every enumerated stdlib mapping consumes every candidate parameter -- one that drops one is a different function. */
	public function testEveryMappingUsesEveryParameter(): Void {
		final candidate: StdlibCandidate = padDigit();
		final maps: Array<Mapping> = StdlibDifferential.mappings(candidate);
		Assert.isTrue(maps.length > 0);
		for (map in maps)
			if (!StdlibDifferential.isTrivial(map))
				for (param in candidate.params) Assert.isTrue(map.display.indexOf(param.name) >= 0, '${map.display} drops ${param.name}');
	}

	/**
	 * A candidate that returns one of its own arguments unchanged is measured against that
	 * baseline alongside the pool, and the baseline is flagged as trivial. Without it a
	 * pass-through setter agrees with every identity-shaped stdlib call at once -- five such
	 * functions produced 55 of 161 findings on a real 806-file tree before this gate existed.
	 */
	public function testTrivialBaselineAccompaniesEveryEnumeration(): Void {
		final candidate: StdlibCandidate = one('class C {\n\tfunction set_value(value:String):String return value;\n}');
		final maps: Array<Mapping> = StdlibDifferential.mappings(candidate);
		final trivial: Array<Mapping> = maps.filter(StdlibDifferential.isTrivial);
		Assert.equals(1, trivial.length, 'the sole String parameter is the sole baseline');
		Assert.equals('value', trivial[0].display);
		Assert.isTrue(maps.length > trivial.length, 'the pool mappings are still enumerated beside it');
		Assert.isFalse(StdlibDifferential.isTrivial(maps[trivial.length]), 'baselines lead, pool entries follow');
	}

	/**
	 * A body written as a static EXTENSION is already calling the pooled member, so that member is
	 * disqualified for it. `path.endsWith('.drl')` and `StringTools.endsWith(path, '.drl')` are one
	 * call written two ways, and only the qualified spelling used to be recognised -- which made
	 * the most convincing false positive of all: a finding that is literally true and useless.
	 */
	public function testStaticExtensionSpellingDisqualifiesItsEntry(): Void {
		final candidate: StdlibCandidate = one("class C {\n\tfunction isDrl(path:String):Bool return path.endsWith('.drl');\n}");
		for (map in StdlibDifferential.mappings(candidate))
			Assert.isTrue(map.display.indexOf('endsWith') < 0, 'the extension call came back as a finding: ${map.display}');
	}

	/**
	 * The input grid is SEEDED with the candidate's own string literals, each also affixed on both
	 * sides. Without the affixes an equality against a literal and a `startsWith` / `endsWith` /
	 * `contains` of the same literal agree on every value the grid holds.
	 */
	public function testGridIsSeededFromTheBody(): Void {
		final candidate: StdlibCandidate = one("class C {\n\tfunction isJaZh(code:String):Bool return code == 'JA';\n}");
		final program: String = StdlibDifferential.program(candidate, StdlibDifferential.mappings(candidate));
		Assert.isTrue(program.indexOf("'JA'") >= 0, 'the body literal itself');
		Assert.isTrue(program.indexOf("'~' + 'JA'") >= 0, 'the literal with a leading affix');
		Assert.isTrue(program.indexOf("'JA' + '~'") >= 0, 'the literal with a trailing affix');
	}

	/**
	 * A probe that reports `CONSTANT` is a refusal, not a finding: a candidate returning the same
	 * answer for every input has not been discriminated by the grid, so every call it "agrees"
	 * with agrees with the constant instead.
	 */
	public function testConstantCollapseIsRefused(): Void {
		final maps: Array<Mapping> = StdlibDifferential.mappings(padDigit());
		switch (StdlibDifferential.verdict('INPUTS 24\nCONSTANT\nMATCH 0\n', maps)) {
			case Skipped(reason):
				Assert.isTrue(reason.indexOf('constant') >= 0, reason);
			case _:
				Assert.fail('a CONSTANT line must refuse the candidate, MATCH lines notwithstanding');
		}
	}

	/** A body constant of the return type is a baseline too -- a constant function is no reimplementation. */
	public function testBodyConstantIsABaseline(): Void {
		final candidate: StdlibCandidate = one("class C {\n\tfunction f(n:Int):String return n > 0 ? '0' : '0';\n}");
		final displays: Array<String> = [for (map in StdlibDifferential.trivials(candidate)) map.display];
		Assert.isTrue(displays.contains("'0'"), 'baselines: $displays');
	}

	/**
	 * The enumeration is small because each slot is TYPE-FILTERED. A loose enumeration over the
	 * same pool would run to thousands; this bound is what makes one probe program per candidate
	 * a viable shape at all.
	 */
	public function testEnumerationStaysBounded(): Void {
		final maps: Array<Mapping> = StdlibDifferential.mappings(padDigit());
		Assert.isTrue(maps.length < 200, 'enumerated ${maps.length} mappings for a two-parameter candidate');
	}

	/**
	 * A function that already CALLS the pooled member is a thin wrapper, not a reimplementation --
	 * exactly the false positive the name channel produced on a real tree. Its own pool entry is
	 * dropped, while the rest of the pool stays available.
	 */
	public function testThinWrapperExcludesItsOwnPoolEntry(): Void {
		final candidate: StdlibCandidate = one('class C {\n\tfunction toInt(s:String):Int return Std.parseInt(s) + 0;\n}');
		for (map in StdlibDifferential.mappings(candidate))
			Assert.isTrue(map.display.indexOf('Std.parseInt') < 0, 'the wrapper\'s own call came back as a finding: ${map.display}');
	}

	/**
	 * The generated program carries the candidate VERBATIM as a static of a module holding nothing
	 * else, one input loop per parameter, and one live flag per mapping. That verbatim splice is
	 * why a compile failure is the terminal proof of self-containment.
	 */
	public function testProgramShape(): Void {
		final candidate: StdlibCandidate = padDigit();
		final maps: Array<Mapping> = StdlibDifferential.mappings(candidate);
		final program: String = StdlibDifferential.program(candidate, maps);

		Assert.isTrue(program.indexOf('class ${StdlibDifferential.PROBE_CLASS} {') >= 0);
		Assert.isTrue(program.indexOf('\tstatic ${candidate.source}') >= 0, 'the candidate must be spliced verbatim');
		Assert.equals(2, occurrences(program, 'for (a'), 'one input loop per parameter');
		Assert.equals(maps.length, occurrences(program, '] && __apqEval('), 'one comparison per mapping');
		Assert.isTrue(program.indexOf('__apqEval(() -> padDigit(a0, a1))') >= 0, 'the candidate is the baseline of every comparison');
	}

	/** The verdict parser reads the printed input count and the surviving indices, and ignores a bogus one. */
	public function testVerdictParsing(): Void {
		final maps: Array<Mapping> = StdlibDifferential.mappings(padDigit());
		switch (StdlibDifferential.verdict('INPUTS 256\nMATCH 0\nMATCH 99999\n', maps)) {
			case Matched(hits, inputs):
				Assert.equals(1, hits.length, 'an out-of-range index is not a hit');
				Assert.equals(256, inputs);
			case _:
				Assert.fail('a MATCH line must produce a Matched outcome');
		}
		switch (StdlibDifferential.verdict('INPUTS 256\n', maps)) {
			case NoMatch(inputs, tried):
				Assert.equals(256, inputs);
				Assert.equals(maps.length, tried);
			case _:
				Assert.fail('no MATCH line must produce a NoMatch outcome');
		}
	}

	/** A candidate whose name the probe module owns is refused before anything is staged. */
	public function testReservedNameRefused(): Void {
		final candidate: StdlibCandidate = one('class C {\n\tfunction main(i:Int):Int return i;\n}');
		Assert.notNull(StdlibDifferential.refusal(candidate, StdlibDifferential.mappings(candidate)));
	}

	/**
	 * An empty enumeration is refused rather than driven through a compiler, while a candidate the
	 * enumeration DID fill is not -- both directions, so the gate cannot pass by refusing everything.
	 */
	public function testEmptyEnumerationRefused(): Void {
		final candidate: StdlibCandidate = one('class C {\n\tfunction flip(b:Bool):Bool return !b;\n}');
		Assert.notNull(StdlibDifferential.refusal(candidate, []));
		Assert.isNull(StdlibDifferential.refusal(candidate, StdlibDifferential.mappings(candidate)));
	}

	/** The motivating case, scanned into a candidate the way the CLI does. */
	private static function padDigit(): StdlibCandidate {
		return one(
			"class C {\n\tprivate function padDigit(i:Int, digits:Int):String {\n\t\tvar str:String = '$i';\n"
			+ "\t\twhile (str.length < digits) str = '0$str';\n\t\treturn str;\n\t}\n}"
		);
	}

	/** The single candidate a fixture is expected to yield. */
	private static function one(source: String): StdlibCandidate {
		final candidates: Array<StdlibCandidate> = StdlibDupScan.scan('src/C.hx', source, new HaxeQueryPlugin()).candidates;
		if (candidates.length != 1) throw 'the fixture yielded ${candidates.length} candidates, expected exactly one';
		return candidates[0];
	}

	/** The human-facing spelling of every enumerated mapping. */
	private static function displays(maps: Array<Mapping>): Array<String> {
		return [for (map in maps) map.display];
	}

	/** How many times `needle` occurs in `text`. */
	private static function occurrences(text: String, needle: String): Int {
		var count: Int = 0;
		var at: Int = text.indexOf(needle);
		while (at >= 0) {
			count++;
			at = text.indexOf(needle, at + needle.length);
		}
		return count;
	}

}
