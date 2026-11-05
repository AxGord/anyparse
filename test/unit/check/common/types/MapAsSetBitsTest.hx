package unit.check.common.types;

import anyparse.check.LintConfig;
import anyparse.check.common.types.MapAsSet;
import anyparse.query.CanonicalEdit;

using StringTools;

/**
 * The `map-as-set` advice under a project that names its bit-set type (the `bits` option): a set whose key is a fixed enum
 * domain is told to be that type, grown or not, and `--fix` respells it; every other key keeps the advice it had.
 */
class MapAsSetBitsTest extends Test {

	private static final CONFIG: String = '{"rules": {"map-as-set": {"enabled": true, "bits": "anyparse.ds.Bits"}}}';
	private static final BOTH: String =
		'{"rules": {"map-as-set": {"enabled": true, "bits": "anyparse.ds.Bits", "set": "anyparse.ds.Set"}}}';
	private static final DOMAINS: String = 'enum Color {\n\tRed;\n\tGreen;\n}\n\nenum Shape {\n\tDot;\n\tBox(size: Int);\n}\n\n'
		+ 'enum abstract Level(Int) {\n\tfinal Low = 0;\n\tfinal High = 5;\n}\n\n'
		+ 'enum abstract Computed(Int) {\n\tfinal One = 1;\n\tfinal Two = 1 << 1;\n}\n\n'
		+ 'enum abstract Ratio(Float) {\n\tfinal Half = 1;\n}\n\n'
		+ 'private enum Hidden {\n\tDim;\n\tLit;\n}\n\n';

	/** A set filled once is advised bits, not an array. */
	public function testEnumKeySetFilledOnceAdvisedBits(): Void {
		final run: FixRun = CheckFixture.fixRunUnder(new MapAsSet(), source(once('Color')), CONFIG);
		Assert.equals(1, run.violations.length);
		Assert.stringContains('Bits<Color>', run.violations[0].message);
	}

	/** A set that grows is advised bits too, with no `set` key configured. */
	public function testEnumKeyGrowingSetAdvisedBits(): Void {
		final run: FixRun = CheckFixture.fixRunUnder(new MapAsSet(), source(growing('Color')), CONFIG);
		Assert.equals(1, run.violations.length);
		Assert.stringContains('Bits<Color>', run.violations[0].message);
	}

	public function testFixRespellsToBits(): Void {
		final body: String = 'var seen: Map<Color, Bool> = [];\n\t\tfor (i in 0...3) {\n\t\t\tif (seen.exists(c)) continue;\n'
			+ '\t\t\tseen[c] = true;\n\t\t\tseen.set(Color.Red, true);\n\t\t\tseen.remove(c);\n\t\t}\n\t\treturn seen.exists(c);';
		final fixed: String = CheckFixture.fixedUnder(new MapAsSet(), source(body), CONFIG);
		Assert.stringContains('var seen: Bits<Color> = new Bits<Color>();', fixed);
		Assert.stringContains('if (seen.has(c)) continue;', fixed);
		Assert.stringContains('seen.add(c);', fixed);
		Assert.stringContains('seen.add(Color.Red);', fixed);
		Assert.stringContains('seen.remove(c);', fixed);
		Assert.stringContains('return seen.has(c);', fixed);
		Assert.stringContains('import anyparse.ds.Bits;', fixed);
	}

	/** A set filled once is respelled too: a bit set has no linear scan to trade the hash lookup for. */
	public function testFixRespellsSetFilledOnce(): Void {
		final fixed: String = CheckFixture.fixedUnder(new MapAsSet(), source(once('Color')), CONFIG);
		Assert.stringContains('var seen: Bits<Color> = new Bits<Color>();', fixed);
		Assert.stringContains('seen.add(c);', fixed);
	}

	public function testIntEnumAbstractKeyAdvisedBits(): Void {
		final run: FixRun = CheckFixture.fixRunUnder(new MapAsSet(), source(once('Level')), CONFIG);
		Assert.equals(1, run.violations.length);
		Assert.stringContains('Bits<Level>', run.violations[0].message);
	}

	/** An enum constructor with parameters has no bit to give: the set is advised an array as before. */
	@:pin('control')
	@:killer('M-MAS-BITS-PARAMS')
	public function testEnumWithParametersNotAdvisedBits(): Void {
		final run: FixRun = CheckFixture.fixRunUnder(new MapAsSet(), source(once('Shape')), CONFIG);
		Assert.equals(1, run.violations.length);
		Assert.stringContains('Array<Shape>', run.violations[0].message);
		Assert.equals(source(once('Shape')), CheckFixture.fixedUnder(new MapAsSet(), source(once('Shape')), CONFIG));
	}

	/** An enum abstract value that is no integer literal has no fixed bit. */
	@:pin('control')
	@:killer('M-MAS-BITS-LITERAL')
	public function testEnumAbstractWithComputedValueNotAdvisedBits(): Void {
		final run: FixRun = CheckFixture.fixRunUnder(new MapAsSet(), source(once('Computed')), CONFIG);
		Assert.equals(1, run.violations.length);
		Assert.stringContains('Array<Computed>', run.violations[0].message);
	}

	/** Only an enum abstract over `Int` is a domain. */
	@:pin('control')
	@:killer('M-MAS-BITS-UNDERLYING')
	public function testEnumAbstractOverAnotherTypeNotAdvisedBits(): Void {
		final run: FixRun = CheckFixture.fixRunUnder(new MapAsSet(), source(once('Ratio')), CONFIG);
		Assert.equals(1, run.violations.length);
		Assert.stringContains('Array<Ratio>', run.violations[0].message);
	}

	@:pin('guard')
	public function testStringKeyKeepsItsAdvice(): Void {
		final src: String = source(once('String'));
		final run: FixRun = CheckFixture.fixRunUnder(new MapAsSet(), src, CONFIG);
		Assert.equals(1, run.violations.length);
		Assert.stringContains('Array<String>', run.violations[0].message);
		Assert.equals(src, CheckFixture.fixedUnder(new MapAsSet(), src, CONFIG));
	}

	/** Without the `bits` key an enum-keyed set is advised as it always was. */
	@:pin('guard')
	public function testNoBitsKeyKeepsTheAdvice(): Void {
		final plain: String = '{"rules": {"map-as-set": {"enabled": true}}}';
		final src: String = source(once('Color'));
		final run: FixRun = CheckFixture.fixRunUnder(new MapAsSet(), src, plain);
		Assert.equals(1, run.violations.length);
		Assert.stringContains('Array<Color>', run.violations[0].message);
		Assert.equals(src, CheckFixture.fixedUnder(new MapAsSet(), src, plain));
	}

	/** A `final` binding cannot take a bit set's `add`: it keeps the plain advice. */
	@:pin('control')
	@:killer('M-MAS-BITS-FINAL')
	public function testFinalBindingKeepsThePlainAdvice(): Void {
		final src: String = source(once('Color').replace('var seen', 'final seen'));
		final run: FixRun = CheckFixture.fixRunUnder(new MapAsSet(), src, BOTH);
		Assert.equals(1, run.violations.length);
		Assert.stringContains('Array<Color>', run.violations[0].message);
		Assert.equals(src, CheckFixture.fixedUnder(new MapAsSet(), src, BOTH));
	}

	/** A module-private enum cannot be named from the bit set's module, so its set keeps the plain advice. */
	@:pin('control')
	@:killer('M-MAS-BITS-PRIVATE')
	public function testPrivateEnumNotAdvisedBits(): Void {
		final src: String = source(once('Hidden'));
		final run: FixRun = CheckFixture.fixRunUnder(new MapAsSet(), src, CONFIG);
		Assert.equals(1, run.violations.length);
		Assert.stringContains('Array<Hidden>', run.violations[0].message);
		Assert.equals(src, CheckFixture.fixedUnder(new MapAsSet(), src, CONFIG));
	}

	/** A key enum declared in another file and imported is resolved through the index and respelled. */
	public function testImportedEnumKeyRespelledToBits(): Void {
		final enums: String = 'package dom;\n\nenum Tone {\n\tWarm;\n\tCold;\n}\n';
		final user: String = 'package use;\n\nimport dom.Tone;\n\nfinal class Local {\n\tpublic function new() {}\n\n'
			+ '\tpublic function f(t: Tone): Bool {\n\t\tvar seen: Map<Tone, Bool> = [];\n\t\tseen[t] = true;\n'
			+ '\t\treturn seen.exists(t);\n\t}\n}';
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'use/Local.hx',
				source: user
			},
			{ file: 'dom/Tone.hx', source: enums }
		];
		final config: LintConfig = LintConfig.parse(CONFIG);
		final run: FixRun = CheckFixture.fixRun(new MapAsSet(), files, 'use/Local.hx', null, _ -> config);
		Assert.equals(1, run.violations.length);
		Assert.stringContains('Bits<Tone>', run.violations[0].message);
		final fixed: String = CanonicalEdit.applyEdits(user, run.edits);
		Assert.stringContains('var seen: Bits<Tone> = new Bits<Tone>();', fixed);
		Assert.stringContains('seen.add(t);', fixed);
		Assert.stringContains('return seen.has(t);', fixed);
	}

	private static function once(key: String): String {
		return 'var seen: Map<$key, Bool> = [];\n\t\tseen[c] = true;\n\t\treturn seen.exists(c);';
	}

	private static function growing(key: String): String {
		return 'var seen: Map<$key, Bool> = [];\n\t\tfor (i in 0...3) seen[c] = true;\n\t\treturn seen.exists(c);';
	}

	private static function source(body: String): String {
		return '${DOMAINS}final class C {\n\tpublic function new() {}\n\n\tpublic function f(c: Color): Bool {\n\t\t$body\n\t}\n}';
	}

}
