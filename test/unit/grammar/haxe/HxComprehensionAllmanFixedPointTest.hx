package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

using StringTools;

/**
 * A comprehension whose body is an object literal the SOURCE wrote flat and its wrap rule breaks by width reaches
 * its fixed point in ONE write: `HxForExpr.body`'s `@:fmt(bodyAllmanIndentForCtor('ObjectLit', …))` placement and
 * the `wrapping.comprehensionCuddledOpen` head both follow the literal's own break verdict (`BodyAllman`), instead of
 * the forced hardline that only a second write, reading the newlines the first one wrote, could see.
 *
 * The shape is the one `tools/battery.sh`'s cross-config arm carried in its baseline (`MemberReachTest.hx`,
 * `TriviaPairConverters.hx`) under the vendored Pony config; the configs here keep only the keys that reach it.
 */
@:nullSafety(Strict)
final class HxComprehensionAllmanFixedPointTest extends Test {

	/** `maxLineLength` of every config here. */
	private static inline final LIMIT: Int = 140;

	/** Columns a tab occupies under every config here. */
	private static inline final TAB_WIDTH: Int = 4;

	/** `comprehensionFor: same`, cuddled-open head, and a width-broken object literal — the Pony shape. */
	private static final CFG_SAME: String = cfg('same', true, true);

	/** The same without the cuddled-open head, so the list keeps its ladder. */
	private static final CFG_SAME_LADDER: String = cfg('same', false, true);

	/** `comprehensionFor: keep`, which glues a body the source wrote on the head line. */
	private static final CFG_KEEP: String = cfg('keep', true, true);

	/** No `objectLiteral` rules: the literal breaks through a rest-aware fit `Group` rather than a first-line probe. */
	private static final CFG_GROUP: String = cfg('keep', false, false);

	/** The rest-aware `Group` again, with a trailing comma the ladder line carries after the item. */
	private static final CFG_TRAILING_COMMA: String = cfg('same', true, false, true);

	/** Every config the sweeps run under. */
	private static final CONFIGS: Array<String> = [CFG_SAME, CFG_SAME_LADDER, CFG_KEEP, CFG_GROUP, CFG_TRAILING_COMMA];

	/**
	 * An iterable call the ladder wraps before the literal is asked, so the literal stays glued and flat behind
	 * `))`: a layout the writer already reached in one write, which a static verdict on the flat item's width
	 * would re-cuddle into `[for (entry in someFunction(…))` over an Allman literal.
	 */
	private static final WRAPPED_ITERABLE: String = 'class M {\n\tfunction f() {\n\t\tvar y = [\n\t\t\tfor (entry in someFunction(\n'
		+ '\t\t\t\targumentNumberOne, argumentNumberTwo, argumentNumberThree\n'
		+ '\t\t\t)) {alpha: entry.aaaaaaaa, beta: \'${kinds(20)}\'}\n\t\t];\n\t}\n}';

	/** The literal fits glued on the ladder line with no column to spare: the line is exactly 140 wide. */
	private static final AT_LIMIT: String = 'class M {\n\tfunction f() {\n\t\tfinal x = {\n\t\t\ttypes: [\n'
		+ '\t\t\t\tfor (t in [[\'C\', \'F0.hx\'], [\'Other\', \'F1.hx\']]) {'
		+ 'name: t[0], file: t[1], kind: \'${kinds(42)}\'}\n\t\t\t]\n\t\t};\n\t}\n}';

	/** One column more: the literal breaks, so `{` goes Allman and the `for` head cuddles its `[`. */
	private static final PAST_LIMIT: String = 'class M {\n\tfunction f() {\n\t\tfinal x = {\n\t\t\ttypes: [for (t in [[\'C\', \'F0.hx\'], ['
		+ "'Other', 'F1.hx']])\n\t\t\t\t{\n\t\t\t\t\tname: t[0],\n\t\t\t\t\tfile: t[1],\n"
		+ '\t\t\t\t\tkind: \'${kinds(43)}\'\n\t\t\t\t}\n\t\t\t]\n\t\t};\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** At the limit the flat source is already canonical: nothing moves. */
	public function testALiteralThatFitsStaysGlued(): Void {
		Assert.equals(AT_LIMIT, HxWriteFixture.triviaWrite(fieldShape(42), CFG_SAME));
	}

	/** Past it the FIRST write lands on the shape a source-multi-line literal gets, and that shape is a fixed point. */
	public function testALiteralBrokenByWidthLandsInAllmanInOneWrite(): Void {
		Assert.equals(PAST_LIMIT, HxWriteFixture.triviaWrite(fieldShape(43), CFG_SAME));
		Assert.equals(PAST_LIMIT, HxWriteFixture.triviaWrite(PAST_LIMIT, CFG_SAME));
	}

	/** The wrapped iterable keeps its layout: its first write already was the fixed point. */
	public function testAWrappedIterableKeepsItsGluedLiteral(): Void {
		Assert.equals(WRAPPED_ITERABLE, HxWriteFixture.triviaWrite(longIterableShape(20), CFG_SAME));
		Assert.equals(WRAPPED_ITERABLE, HxWriteFixture.triviaWrite(WRAPPED_ITERABLE, CFG_SAME));
	}

	/**
	 * One write is a fixed point for every literal width across the break boundary, and never spends a line past
	 * the limit, in every host the cuddled head answers differently in: a field value, a nested list item (whose
	 * ladder column lies RIGHT of its cuddled column), a declaration, a call argument with two generators, and an
	 * iterable call that wraps before the literal.
	 */
	public function testOneWriteIsAFixedPointAcrossTheBoundary(): Void {
		for (config in CONFIGS) for (k in 20...100) {
			for (src in [
				fieldShape(k),
				nestedShape(k),
				declShape(k),
				callShape(k),
				longIterableShape(k - 20)
			]) assertOneWriteWithinLimit(src, config, k);
		}
	}

	/**
	 * A declaration whose `=` breaks for a comprehension too wide to follow it, in a NoWrap array that force-flattens
	 * its item: the `=` still breaks, and the literal stays flat on the continuation line rather than the whole
	 * declaration running on past the limit. The widths between the two ranges belong to other families — the
	 * array's `hasMultilineItems` rule reading the break the literal made, and the `=` probe's pending-space skew.
	 */
	public function testADeclarationStillBreaksAfterItsEquals(): Void {
		for (config in CONFIGS) for (k in [for (k in 70...80) k].concat([for (k in 93...110) k]))
			assertOneWriteWithinLimit(shortDeclShape(k), config, k);
	}

	private static function assertOneWriteWithinLimit(src: String, config: String, k: Int): Void {
		final once: String = HxWriteFixture.triviaWrite(src, config);
		Assert.equals(once, HxWriteFixture.triviaWrite(once, config), 'k=$k config=$config\n$src');
		var widest: Int = 0;
		for (line in once.split('\n')) {
			final width: Int = line.replace('\t', ''.lpad(' ', TAB_WIDTH)).length;
			if (width > widest) widest = width;
		}
		Assert.isTrue(widest <= LIMIT, 'k=$k config=$config: a $widest-column line\n$once');
	}

	private static function fieldShape(k: Int): String {
		return 'class M {\n\tfunction f() {\n\t\tfinal x = {\n\t\t\ttypes: [for (t in [[\'C\', \'F0.hx\'], [\'Other\', \'F1.hx\']]) {'
			+ 'name: t[0], file: t[1], kind: \'${kinds(k)}\'}]\n\t\t};\n\t}\n}';
	}

	private static function nestedShape(k: Int): String {
		return 'class M {\n\tfunction f() {\n\t\tfinal x = [\n\t\t\t[for (t in [[\'C\', \'F0.hx\'], [\'Other\', \'F1.hx\']]) {'
			+ 'name: t[0], file: t[1], kind: \'${kinds(k)}\'}],\n\t\t\t[]\n\t\t];\n\t}\n}';
	}

	private static function declShape(k: Int): String {
		return 'class M {\n\tfunction f() {\n\t\tvar y = [for (t in xs) {'
			+ 'alpha: t.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, beta: t.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, kind: \'${kinds(k)}\'}];\n\t}\n}';
	}

	private static function callShape(k: Int): String {
		return 'class M {\n\tfunction f() {\n\t\tfoo(aaaaaaaa, [for (a in xs) for (b in ys) {'
			+ 'alpha: a.aaaaaaaaaaaaaaaaaaaa, beta: b.bbbbbbbbbbbbbbbbbbbbbbbbb, kind: \'${kinds(k)}\'}]);\n\t}\n}';
	}

	private static function longIterableShape(k: Int): String {
		return 'class M {\n\tfunction f() {\n\t\tvar y = [for (entry in someFunction(argumentNumberOne, argumentNumberTwo, '
			+ 'argumentNumberThree)) {alpha: entry.aaaaaaaa, beta: \'${kinds(k)}\'}];\n\t}\n}';
	}

	private static function shortDeclShape(k: Int): String {
		return 'class M {\n\tfunction f() {\n\t\tfinal ${''.lpad('n', k)}: Array<Dynamic> = [for (x in xs) {a: x, b: 2}];\n\t}\n}';
	}

	private static function kinds(k: Int): String {
		return ''.lpad('k', k);
	}

	private static function cfg(
		comprehensionFor: String, cuddledOpen: Bool, objectLiteralRules: Bool, trailingCommas: Bool = false
	): String {
		final objectLiteral: String = objectLiteralRules
			? ', "objectLiteral": {"defaultWrap": "onePerLine", "rules": [{"conditions": [{"cond": "totalItemLength <= n", "value": 140}],'
				+ ' "type": "noWrap"}]}'
			: '';
		final commas: String = trailingCommas ? ', "trailingCommas": {"arrayLiteralDefault": "yes"}' : '';
		return '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, "comprehensionCuddledOpen": '
			+ '$cuddledOpen, "arrayWrap": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "hasMultilineItems", "value": 1}], '
			+ '"type": "onePerLine"}, {"conditions": [{"cond": "anyItemLength >= n", "value": 30}], "type": "onePerLine"}]}, '
			+ '"callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", '
			+ '"value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", '
			+ '"value": 100}], "type": "noWrap"}]}$objectLiteral}, "sameLine": {"comprehensionFor": "$comprehensionFor"}$commas}';
	}

}
