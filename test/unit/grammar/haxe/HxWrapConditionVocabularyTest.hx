package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * The `wrapping.*.rules[].cond` vocabulary, exercised through the WRITER
 * rather than through the loader.
 *
 * `HxWrapRulesIngestTest` pins that each spelling reaches a
 * `WrapConditionType`; every test here pins that the resulting cascade
 * DECIDES something — which is the half a mapping alone cannot prove,
 * since an unevaluated condition and an unmapped one look identical from
 * outside (the rule simply never selects a mode).
 *
 * Each test formats ONE source holding two lists that differ only in the
 * axis under test. A single-list fixture would pass on a cascade that
 * answered the same way for every input; the pair cannot. Each asserts the whole output, so a shape that moves anywhere else in the file fails too.
 */
@:nullSafety(Strict)
class HxWrapConditionVocabularyTest extends Test {

	public function new(): Void {
		super();
	}

	/**
	 * `equalItemLengths` is a predicate over the whole item set, not a
	 * threshold — the fork ships it in its own `arrayWrap` / `mapWrap`
	 * defaults, and Pony's config uses it twice. Equal-width items keep the
	 * `noWrap` rule; one odd width sends the list to `defaultWrap`.
	 */
	public function testEqualItemLengthsIsASetPredicate(): Void {
		final config: String = cascade('arrayWrap', 'onePerLine', '{"cond": "equalItemLengths", "value": 1}');
		Assert.equals(
			'class P {\n\tstatic var eq = [11, 22, 33, 44, 55];\n\n\tstatic var ne = [\n\t\t1,\n\t\t222,\n\t\t33,'
			+ '\n\t\t4444,\n\t\t55\n\t];\n}',
			format('class P {\n\tstatic var eq = [11, 22, 33, 44, 55];\n\n\tstatic var ne = [1, 222, 33, 4444, 55];\n}', config)
		);
	}

	/**
	 * `allItemLengths <= n` is the FORK's spelling of the max-width
	 * predicate; hxq mapped only its own older `allItemLengths < n`, so a
	 * config copied from haxe-formatter lost the rule whole.
	 */
	public function testAllItemLengthsLessThanReadsTheForkSpelling(): Void {
		final config: String = cascade('arrayWrap', 'onePerLine', '{"cond": "allItemLengths <= n", "value": 6}');
		Assert.equals(
			'class P {\n\tstatic var narrow = [1, 22, 333, 4];\n\n\tstatic var wide = [\n\t\t1,\n\t\t22,\n\t\t33333,\n\t\t4\n\t];\n}',
			format('class P {\n\tstatic var narrow = [1, 22, 333, 4];\n\n\tstatic var wide = [1, 22, 33333, 4];\n}', config)
		);
	}

	/**
	 * `anyItemLength <= n` is the fork's MINIMUM-width predicate, not a
	 * respelling of `anyItemLength >= n` (the maximum). Both fixtures here
	 * hold an item at or above the threshold, so a cascade that read the
	 * maximum would leave BOTH lists flat and this test would not move.
	 */
	public function testAnyItemLengthLessThanReadsTheMinimum(): Void {
		final config: String = cascade('arrayWrap', 'onePerLine', '{"cond": "anyItemLength <= n", "value": 3}');
		Assert.equals(
			'class P {\n\tstatic var hasNarrow = [1, 2222, 3333, 4444];\n\n\tstatic var allWide = [\n\t\t1111,\n\t\t2222,\n\t\t3333,'
			+ '\n\t\t4444\n\t];\n}',
			format(
				'class P {\n\tstatic var hasNarrow = [1, 2222, 3333, 4444];\n\n\tstatic var allWide = [1111, 2222, 3333, 4444];\n}', config
			)
		);
	}

	/**
	 * `allItemLengths >= n` is the fork's other minimum-width predicate.
	 * No config this project has met uses it, but it drops a rule exactly
	 * as silently as its three neighbours did, which is the defect.
	 */
	public function testAllItemLengthsLargerThanReadsTheMinimum(): Void {
		final config: String = cascade('arrayWrap', 'onePerLine', '{"cond": "allItemLengths >= n", "value": 5}');
		Assert.equals(
			'class P {\n\tstatic var allWide = [1111, 2222, 3333, 44444];\n\n\tstatic var hasNarrow = [\n\t\t1,\n\t\t2222,\n\t\t3333,'
			+ '\n\t\t44444\n\t];\n}',
			format(
				'class P {\n\tstatic var allWide = [1111, 2222, 3333, 44444];\n\n\tstatic var hasNarrow = [1, 2222, 3333, 44444];\n}',
				config
			)
		);
	}

	/**
	 * A map literal reads `wrapping.mapWrap`, an array literal
	 * `wrapping.arrayWrap` — the fork's split between `mapLiteralWrapping`
	 * and `arrayLiteralWrapping`. Only `mapWrap` is set here, so an engine
	 * that still routed both through `arrayWrap` would leave the map broken
	 * like the array.
	 *
	 * The comprehension and the empty list are in the fixture because they
	 * are the two shapes the classifier must NOT call a map. The
	 * comprehension goes to `arrayWrap` — upstream routes `Comprehension`
	 * to `arrayLiteralWrapping` alongside plain arrays — and here that is
	 * VISIBLE: it breaks with the array rather than staying flat with the
	 * map. The empty list has no first element to ask about, and the guard
	 * around that read is what keeps a `[]` carrying a trailing comment from
	 * indexing out of bounds.
	 */
	public function testMapLiteralReadsMapWrap(): Void {
		final config: String = '{"wrapping": {"maxLineLength": 60, "arrayWrap": {"defaultWrap": "onePerLine", "rules": []},'
			+ ' "mapWrap": {"defaultWrap": "noWrap", "rules": []}}}';
		Assert.equals(
			'class P {\n\tstatic var m = [1 => 11, 2 => 22, 3 => 33];\n\n\tstatic var a = [\n\t\t11,\n\t\t22,\n\t\t33\n\t];'
			+ '\n\n\tstatic var c = [\n\t\tfor (i in 0...3) i\n\t];\n\n\tstatic var e = [];\n\n\tstatic var t = [ // trailing\n\t];\n}',
			format(
				'class P {\n\tstatic var m = [1 => 11, 2 => 22, 3 => 33];\n\n\tstatic var a = [11, 22, 33];'
				+ '\n\n\tstatic var c = [for (i in 0...3) i];\n\n\tstatic var e = [];\n\n\tstatic var t = [ // trailing\n\t];\n}',
				config
			)
		);
	}

	/**
	 * A binary chain measures `equalItemLengths` on the BARE operands. Its
	 * operator is a LEADING `op ` on every continuation, so the first operand
	 * is short by construction and a rendered-width comparison answers "not
	 * equal" for every chain that exists — the predicate could never match,
	 * and its `value: 0` twin could never fail. Upstream has the mirror-image arrangement (a trailing operator, so
	 * its LAST item is the short one) and forgives it with a hard-coded 2 —
	 * which a two-character operator never satisfies, so upstream answers "not
	 * equal" here too. Measuring bare operands is the predicate's named
	 * semantic, not a port of that number.
	 *
	 * The two chains here differ only in the width of their last operand, so a
	 * measure that charges the operator to either end gets this fixture wrong
	 * in a visible direction.
	 */
	public function testChainEqualItemLengthsMeasuresBareOperands(): Void {
		final config: String = cascade('opBoolChain', 'onePerLineAfterFirst', '{"cond": "equalItemLengths", "value": 1}');
		final decls: String = [for (n in ['aaaa', 'bbbb', 'cccc', 'dddd', 'e']) '\tstatic var $n:Bool;'].join('\n\n');
		final eq: String = 'var eq = aaaa || bbbb || cccc || dddd;';
		final flatNe: String = 'var ne = aaaa || bbbb || cccc || e;';
		final brokenNe: String = 'var ne = aaaa ||\n\t\t\tbbbb ||\n\t\t\tcccc ||\n\t\t\te;';
		Assert.equals(
			'class C {\n$decls\n\n\tstatic function f():Void {\n\t\t$eq\n\t\t$brokenNe\n\t}\n}',
			format('class C {\n$decls\n\n\tstatic function f():Void {\n\t\t$eq\n\t\t$flatNe\n\t}\n}', config)
		);
	}

	/**
	 * `emitZeroThresholdAgree` reaches for `rules.defaultMode` when both
	 * cascade states resolve to `NoWrap` and the default is a break mode.
	 * Taking it RAW skipped the `breakAsOnePerLine` collapse, so the
	 * emitted `fillLineWithLeadingBreak` put newlines in a list the next
	 * pass then re-read as author intent and force-one-per-lined: the same
	 * file needed two writer passes, and `writeRoundTrip(s) == s` — the
	 * gate under every writer-emit mutation op — failed after one.
	 *
	 * Asserting the SECOND round trip is what discriminates: the two passes
	 * agree on the final bytes either way, so an output-only assertion
	 * passes with the fix reverted.
	 */
	public function testDefaultBreakModeTakesTheOnePerLineAxis(): Void {
		final config: String = '{"wrapping": {"maxLineLength": 60, "objectLiteral": {"defaultWrap": "fillLineWithLeadingBreak",'
			+ ' "rules": [{"type": "noWrap", "conditions": [{"cond": "hasMultilineItems", "value": 0}]}]}}}';
		final src: String =
			'class P {\n\tstatic function f() {\n\t\tg({alpha: 1, bravo: 2, charlie: 3, delta: 4, echo: 5, foxtrot: 6});\n\t}\n}';
		final once: String = format(src, config);
		Assert.equals(once, format(once, config));
	}

	/** A one-rule cascade over `<knob>`: the rule selects `noWrap`, everything else falls to `fallback`. */
	private static function cascade(knob: String, fallback: String, condition: String): String {
		return '{"wrapping": {"maxLineLength": 60, "$knob": {"defaultWrap": "$fallback",'
			+ ' "rules": [{"type": "noWrap", "conditions": [$condition]}]}}}';
	}

	private static function format(source: String, config: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(config);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts);
	}

}
