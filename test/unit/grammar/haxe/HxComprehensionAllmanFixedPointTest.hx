package unit.grammar.haxe;

import anyparse.core.BreakCommits;
import anyparse.core.BreakToken;
import anyparse.core.Doc;
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

	/**
	 * How far past the limit a declaration's `=` probe lets its line run: the probe measures the comprehension one
	 * column before the renderer places it, a known skew outside this fixture's subject.
	 */
	private static inline final EQ_PROBE_SKEW: Int = 2;

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

	/** No wrap rules at all: the cascade's defaults under `comprehensionFor: keep`. */
	private static final CFG_PLAIN_KEEP: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {'
		+ '"maxLineLength": 140}, "sameLine": {"comprehensionFor": "keep"}}';

	/** An `expressionWrapping` rule: an expression paren opens by its own width probe, with no collapse gate. */
	private static final CFG_EXPRESSION: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, '
		+ '"expressionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", '
		+ '"value": 0}], "type": "noWrap"}]}}, "sameLine": {"comprehensionFor": "keep"}}';

	/** The ternary paren at the width where its literal breaks: it opens, as it does for every narrower literal. */
	private static final OPEN_TERNARY_PAREN: String = 'class M {\n\tfunction f() {\n\t\tvar y = (\n\t\t\tcond ? [\n\t\t\t\tfor (x in xs)\n'
		+ '\t\t\t\t\t{\n\t\t\t\t\t\talpha: x.aaaaaaaaaaaaaaaaaaaaa,\n\t\t\t\t\t\tk: \'${kinds(90)}\'\n\t\t\t\t\t}\n'
		+ '\t\t\t] : otherList\n\t\t).concat(tail);\n\t}\n}';

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
	 * ladder column lies RIGHT of its cuddled column), a declaration, a call argument with two
	 * generators, an iterable call that wraps before the literal, an assignment whose array stays
	 * NoWrap until the literal breaks, a call as the iterable, and a comprehension as the iterable.
	 */
	public function testOneWriteIsAFixedPointAcrossTheBoundary(): Void {
		for (config in CONFIGS) for (k in 20...100) {
			for (src in [
				fieldShape(k),
				nestedShape(k),
				declShape(k),
				callShape(k),
				longIterableShape(k - 20),
				assignShape(k),
				callIterableShape(k),
				comprehensionIterableShape(k)
			]) assertOneWriteWithinLimit(src, config, k);
		}
	}

	/**
	 * A declaration whose `=` breaks for a comprehension too wide to follow it, in a NoWrap array that force-flattens
	 * its item: the `=` still breaks, and the literal stays flat on the continuation line rather than the whole
	 * declaration running on past the limit. Where the `=` stays glued the literal's break reaches a NoWrap array,
	 * which the next rewrite lays out one item per line — the first one already does.
	 */
	public function testADeclarationStillBreaksAfterItsEquals(): Void {
		for (config in CONFIGS) for (k in 70...110)
			assertOneWriteWithinLimit(shortDeclShape(k), config, k, k == 80 || k == 81 ? EQ_PROBE_SKEW : 0);
	}

	/**
	 * A comprehension that is one argument of several, in a call that is itself one argument of several: the outer
	 * call's layout follows the literal's break as well. Laid out from the flat item, `foo(` stayed glued while
	 * the literal broke under it, and the next write, reading a multi-line argument, opened it one argument per line.
	 */
	@:pin('control')
	@:killer('M-BREAK-MULTI-ITEM-HOST-OFF')
	public function testAMultiArgumentHostFollowsTheBreak(): Void {
		for (config in CONFIGS) for (k in 20...101) assertOneWriteWithinLimit(nestedCallShape(k), config, k);
	}

	/**
	 * A comprehension in a field of an object literal that is itself a comprehension body: the literal's field list
	 * offers no alternative of its own, so the literal stays the width decision its Allman placement reads.
	 */
	@:pin('control')
	@:killer('M-BREAK-OBJECT-LITERAL-HOST')
	public function testALiteralHostKeepsItsAllmanDecision(): Void {
		for (config in CONFIGS.concat([CFG_PLAIN_KEEP])) for (k in 1...60) assertOneWriteWithinLimit(literalHostShape(k), config, k);
	}

	/** One alternative per break, from its outermost node: the alternatives do not multiply with the nesting depth. */
	@:pin('control')
	@:killer('M-BREAK-EVERY-NODE')
	public function testOneAlternativePerBreak(): Void {
		final token: BreakToken = new BreakToken();
		final inner: Doc = Doc.BreakCommit(Doc.Text('b'), Doc.Text('f'), token);
		final outer: Doc = Doc.BreakCommit(Doc.Text('B'), Doc.Concat([inner]), token);
		final other: Doc = Doc.BreakCommit(Doc.Text('o'), Doc.Text('f'), new BreakToken());
		final kept: Array<Doc> = BreakCommits.outermostPerToken(BreakCommits.nested(Doc.Concat([outer, other])));
		Assert.equals(2, kept.length);
		Assert.isTrue(kept.contains(outer));
		Assert.isTrue(kept.contains(other));
	}

	/**
	 * A comprehension argument of a method-chain link: the chain's glued tail is measured on the literal the next write
	 * reads, a multi-line literal whose `BodyGroup` the probe defers, so the first write already glues the chain where
	 * the second did.
	 */
	@:pin('control')
	@:killer('M-BREAK-COMMITTED-BARE')
	public function testAChainFollowsTheBreak(): Void {
		for (config in CONFIGS) for (k in 20...101) assertOneWriteWithinLimit(chainShape(k), config, k);
	}

	/** An arrow-lambda body: its residual line is measured on that literal too, so the body stays glued to `->`. */
	@:pin('control')
	@:killer('M-BREAK-COMMITTED-BARE')
	public function testALambdaBodyFollowsTheBreak(): Void {
		for (config in [CFG_GROUP, CFG_TRAILING_COMMA, CFG_PLAIN_KEEP]) for (k in 1...101)
			assertOneWriteWithinLimit(lambdaShape(k), config, k);
	}

	/**
	 * The same lambda body under the `objectLiteral` rule, which breaks the literal STATICALLY past its width: the
	 * forced Allman placement lays it out in the `BodyGroup` the next write reads it back in.
	 */
	@:pin('control')
	@:killer('M-BREAK-READBACK-BARE')
	public function testAStaticallyBrokenLambdaBodyStaysGlued(): Void {
		for (config in [CFG_SAME, CFG_SAME_LADDER, CFG_KEEP]) for (k in 1...101) assertOneWriteWithinLimit(lambdaShape(k), config, k);
	}

	/**
	 * An expression paren's next write keeps the open or glued layout its own source states, so its first write
	 * measures the literal bare: a paren that opens for every literal narrower than the break keeps opening past it,
	 * where measuring the deferred literal would glue it onto the other of its two fixed points.
	 */
	@:pin('control')
	@:killer('M-PAREN-MEASURES-COMMITTED')
	public function testAParenMeasuresTheBreakBare(): Void {
		Assert.equals(OPEN_TERNARY_PAREN, HxWriteFixture.triviaWrite(ternaryParenShape(90), CFG_EXPRESSION));
		for (k in 1...101) assertOneWriteWithinLimit(ternaryParenShape(k), CFG_EXPRESSION, k);
	}

	private static function assertOneWriteWithinLimit(src: String, config: String, k: Int, slack: Int = 0): Void {
		final once: String = HxWriteFixture.triviaWrite(src, config);
		Assert.equals(once, HxWriteFixture.triviaWrite(once, config), 'k=$k config=$config\n$src');
		var widest: Int = 0;
		for (line in once.split('\n')) {
			final width: Int = line.replace('\t', ''.lpad(' ', TAB_WIDTH)).length;
			if (width > widest) widest = width;
		}
		Assert.isTrue(widest <= LIMIT + slack, 'k=$k config=$config: a $widest-column line\n$once');
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

	/** An assignment whose short item leaves the array NoWrap until its literal breaks. */
	private static function assignShape(k: Int): String {
		return 'class M {\n\tfunction f() {\n\t\tthis.someFieldName${''.lpad('n', k)} = [for (t in xs) {'
			+ 'alpha: t.aaaaaaaaaaaaaaaa, beta: t.bbbbbbbbbbbbbbbbbbbbbbbbb}];\n\t}\n}';
	}

	/** An iterable call whose arguments the ladder would wrap before the literal is asked. */
	private static function callIterableShape(k: Int): String {
		return 'class M {\n\tfunction f() {\n\t\tvar y = [for (e in getThings(alpha, beta)) {'
			+ 'alpha: e.aaaaaaaaaaaaaaaaaaaaaaaaa, beta: e.bbbbbbbbbbbbbbbbbbbbbbbbbbbbb, k: \'${kinds(k)}\'}];\n\t}\n}';
	}

	/** A comprehension as the iterable, whose own literal breaks inside the head of the outer one. */
	private static function comprehensionIterableShape(k: Int): String {
		return 'class M {\n\tfunction f() {\n\t\tvar y = [for (x in [for (y in ys) {a: y, b: 2}]) {'
			+ 'alpha: x.aaaaaaaaaaaaaaaaaaaaaaa, beta: x.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, k: \'${kinds(k)}\'}];\n\t}\n}';
	}

	/** A comprehension as the last of two arguments, of a call that is the last of two arguments. */
	private static function nestedCallShape(k: Int): String {
		return 'class M {\n\tfunction f() {\n\t\tvar y = foo(aaaaaaaa, bar(bbbbbbbb, [for (x in xs) {'
			+ 'alpha: x.aaaaaaaaaaaaaaaaaaaaa, k: \'${kinds(k)}\'}]));\n\t}\n}';
	}

	/** A comprehension in a field of the object literal another comprehension carries as its body. */
	private static function literalHostShape(k: Int): String {
		return 'class M {\n\tfunction f() {\n\t\tvar y = [for (a in xs) {items: [for (b in a.children) {c: b.cccccccccccccccccccc, '
			+ 'd: \'${kinds(k)}\'}], name: a.nnnnnnnnnnnnnnnnnnnnnnnnnnn}];\n\t}\n}';
	}

	/** A comprehension argument of the middle link of a method chain. */
	private static function chainShape(k: Int): String {
		return 'class M {\n\tfunction f() {\n\t\treturn builder.withName(nameValue).withItems([for (x in xs) {'
			+ 'alpha: x.aaaaaaaaaaaaaaaaaaaaa, k: \'${kinds(k)}\'}]).build();\n\t}\n}';
	}

	/** A comprehension as an arrow-lambda body. */
	private static function lambdaShape(k: Int): String {
		return 'class M {\n\tfunction f() {\n\t\tvar f = () -> [for (x in xs) {'
			+ 'alpha: x.aaaaaaaaaaaaaaaaaaaaaa, beta: x.bbbbbbbbbbbbbbbbbbbbbb, k: \'${kinds(k)}\'}];\n\t}\n}';
	}

	/** A comprehension as a ternary branch inside an expression paren. */
	private static function ternaryParenShape(k: Int): String {
		return 'class M {\n\tfunction f() {\n\t\tvar y = (cond ? [for (x in xs) {'
			+ 'alpha: x.aaaaaaaaaaaaaaaaaaaaa, k: \'${kinds(k)}\'}] : otherList).concat(tail);\n\t}\n}';
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
