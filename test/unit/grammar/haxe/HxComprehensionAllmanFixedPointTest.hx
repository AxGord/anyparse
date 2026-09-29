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

	/** `comprehensionFor: same`, cuddled-open head, and a width-broken object literal — the Pony shape. */
	private static final CFG_SAME: String = cfg('same', true, true);

	/** The same without the cuddled-open head, so the list keeps its ladder. */
	private static final CFG_SAME_LADDER: String = cfg('same', false, true);

	/** `comprehensionFor: keep`, which glues a body the source wrote on the head line. */
	private static final CFG_KEEP: String = cfg('keep', true, true);

	/** No `objectLiteral` rules: the literal breaks through a fit `Group` rather than a first-line probe. */
	private static final CFG_GROUP: String = cfg('keep', false, false);

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

	/**
	 * One write is a fixed point for every literal width across the break boundary, in every host the cuddled head
	 * answers differently in, under each config: a field value, a nested list item (whose ladder column lies RIGHT
	 * of its cuddled column), a declaration, and a call argument with two generators.
	 */
	public function testOneWriteIsAFixedPointAcrossTheBoundary(): Void {
		for (config in [CFG_SAME, CFG_SAME_LADDER, CFG_KEEP, CFG_GROUP]) for (k in 20...70) {
			for (src in [fieldShape(k), nestedShape(k), declShape(k), callShape(k)]) {
				final once: String = HxWriteFixture.triviaWrite(src, config);
				Assert.equals(once, HxWriteFixture.triviaWrite(once, config), 'k=$k config=$config\n$src');
			}
		}
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

	private static function kinds(k: Int): String {
		return ''.lpad('k', k);
	}

	private static function cfg(comprehensionFor: String, cuddledOpen: Bool, objectLiteralRules: Bool): String {
		final objectLiteral: String = objectLiteralRules
			? ', "objectLiteral": {"defaultWrap": "onePerLine", "rules": [{"conditions": [{"cond": "totalItemLength <= n", "value": 140}],'
				+ ' "type": "noWrap"}]}'
			: '';
		return '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, "comprehensionCuddledOpen": '
			+ '$cuddledOpen, "arrayWrap": {"defaultWrap": "noWrap", "rules": [{"conditions": ['
			+ '{"cond": "hasMultilineItems", "value": 1}], "type": "onePerLine"}, {"conditions": [{"cond": "anyItemLength >= n", "value": '
			+ '30}], "type": "onePerLine"}]}$objectLiteral}, "sameLine": {"comprehensionFor": "$comprehensionFor"}}';
	}

}
