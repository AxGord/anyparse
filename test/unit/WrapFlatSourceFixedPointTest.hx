package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-flat-source-fixed-point — ONE writer round trip must land where every
 * further round trip leaves the file.
 *
 * A sep-Star without `@:fmt(reflowSourceMultiline)` force-one-per-lines any
 * list whose SOURCE carried a newline, without consulting the wrap cascade.
 * For a source-FLAT list the cascade IS consulted, and when it answers a
 * break mode other than `OnePerLine` the newline pass 1 writes is read by
 * pass 2 as author intent and overridden. `fmt` then needs two rewrites, and
 * `writeRoundTrip(s) == s` — the canonical gate every writer-emit mutation op
 * is built on — fails after one pass.
 *
 * Measured on the Pony tree under its own `hxformat.json`: three files
 * (`HasAssetBuilder.hx`, `NinjaBuilder.hx`, `UTools.hx`) took two rewrites,
 * all three on the inline anon type hint of `testAnonTypeFillLineOnOverflow`.
 * haxe-formatter 1.18.0 reproduces both passes byte-for-byte on the same
 * config, so the shape is inherited from the fork's
 * `MarkWrapping.anonTypeWrapping` (`!isOriginalSameLine` →
 * `wrapChildOneLineEach`) rather than an anyparse regression — but the fork
 * ships no canonical gate, and anyparse does.
 *
 * Each fixture pins the SHAPE as well as the convergence: `once == twice`
 * alone would also hold for a writer that reflowed nothing.
 */
@:nullSafety(Strict)
class WrapFlatSourceFixedPointTest extends Test {

	/**
	 * Pony's own `anonType` cascade, reduced: everything short stays flat, an
	 * overflowing hint takes `fillLine`. `fillLine` breaks BETWEEN fields
	 * without breaking after `{`, which is not a shape the force-multi path
	 * can reproduce — hence the second rewrite.
	 */
	private static final ANON_FILL_LINE: String = '{"wrapping": {"maxLineLength": 40, "anonType": {"defaultWrap": "noWrap", "rules": ['
		+ '{"conditions": [{"cond": "itemCount <= n", "value": 3}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, '
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine"}]}}}';

	/**
	 * The widest measured instance — 163 of 854 Pony files under this one
	 * value. `fillLineWithLeadingBreak` breaks after `{` and then PACKS, so
	 * pass 1 writes `x: 1, y: 2` on one continuation line and pass 2 splits
	 * it.
	 */
	private static final OBJECT_LEADING_BREAK: String =
		'{"wrapping": {"objectLiteral": {"defaultWrap": "fillLineWithLeadingBreak", "rules": []}}}';

	/**
	 * A bare `fillLine` cascade with no rules: the mode is the cascade's
	 * answer in BOTH the fits and the overflows state. Guards the half of the
	 * fix that must NOT fire — see `testShortListUnderFillLineStaysFlat`.
	 */
	private static final ANON_BARE_FILL_LINE: String =
		'{"wrapping": {"maxLineLength": 100, "anonType": {"defaultWrap": "fillLine", "rules": []}}}';

	/**
	 * Pony's own `objectLiteral` cascade paired with its `callParameter` one.
	 * The literal is short enough for the `noWrap` rule, which SHADOWS a
	 * breaking `defaultWrap` — so the cascade agree-path hands the host an
	 * `IfFirstLineExceeds` pivot instead of a committed mode, and the pivot's
	 * flat arm carries no hardline for the host to measure.
	 */
	private static final CALL_ARG_OBJECT: String = '{"wrapping": {"maxLineLength": 140, "objectLiteral": {"defaultWrap": '
		+ '"onePerLine", "rules": [{"conditions": [{"cond": "totalItemLength <= n", "value": 140}], "type": "noWrap"}]}, '
		+ '"callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": '
		+ '"exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}}';

	/**
	 * The same literal cascade under a `callParameter` one whose BREAK mode is
	 * also its FITS answer — a rules-free `fillLine`, so nothing above the glue
	 * intercept ever refused the flat line.
	 */
	private static final CALL_ARG_FILL_LINE: String = '{"wrapping": {"maxLineLength": 140, "objectLiteral": {"defaultWrap": '
		+ '"onePerLine", "rules": [{"conditions": [{"cond": "totalItemLength <= n", "value": 140}], "type": "noWrap"}]}, '
		+ '"callParameter": {"defaultWrap": "fillLine", "rules": []}}}';

	/** The same literal cascade under a ternary host instead of a call host. */
	private static final TERNARY_ARG_OBJECT: String = '{"wrapping": {"maxLineLength": 140, "objectLiteral": {"defaultWrap": '
		+ '"onePerLine", "rules": [{"conditions": [{"cond": "totalItemLength <= n", "value": 140}], "type": "noWrap"}]}, '
		+ '"ternaryExpression": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", '
		+ '"value": 1}], "type": "onePerLineAfterFirst", "location": "beforeLast"}]}}}';

	public function new(): Void {
		super();
	}

	/** The Pony repro: an inline anon type hint whose line overflows. */
	public function testAnonTypeFillLineOnOverflow(): Void {
		final once: String = write(
			'class C {\n\tfunction f(): Void {\n\t\tfinal e: { pos: Int, expr: String } = null;\n\t}\n}', ANON_FILL_LINE
		);
		Assert.isTrue(
			once.indexOf('final e:{\n\t\t\tpos:Int,\n\t\t\texpr:String\n\t\t} = null;') != -1,
			'expected the one-per-line shape the next pass would force, got:\n<$once>'
		);
		Assert.equals(once, write(once, ANON_FILL_LINE), 'one round trip must land on the fixed point');
	}

	/** The same shape one Star over: an object literal under a leading-break cascade. */
	public function testObjectLiteralLeadingBreakOnOverflow(): Void {
		final once: String = write('class C {\n\tfunction f(): Void {\n\t\tvar p = { x: 1, y: 2 };\n\t}\n}', OBJECT_LEADING_BREAK);
		Assert.isTrue(
			once.indexOf('var p = {\n\t\t\tx: 1,\n\t\t\ty: 2\n\t\t};') != -1,
			'expected the one-per-line shape the next pass would force, got:\n<$once>'
		);
		Assert.equals(once, write(once, OBJECT_LEADING_BREAK), 'one round trip must land on the fixed point');
	}

	/**
	 * The other half: `fillLine` renders FLAT when the list fits, and a list
	 * that stays on one line grows no newline for the next pass to read — so
	 * it is already a fixed point and must be left alone. Collapsing every
	 * `fillLine` answer to `OnePerLine` regardless of the fit state would
	 * break this line for no convergence gain.
	 */
	public function testShortListUnderFillLineStaysFlat(): Void {
		final src: String = 'class C {\n\tfunction f(): Void {\n\t\tfinal e: { pos: Int, expr: String } = null;\n\t}\n}';
		final once: String = write(src, ANON_BARE_FILL_LINE);
		Assert.isTrue(
			once.indexOf('final e:{pos:Int, expr:String} = null;') != -1, 'expected the fitting hint left on one line, got:\n<$once>'
		);
		Assert.equals(once, write(once, ANON_BARE_FILL_LINE), 'a list that fits was already a fixed point');
	}

	/**
	 * A CALL whose sole collection argument breaks only at RENDER time. The
	 * literal's own cascade resolves `NoWrap` in both fit states, so
	 * `emitZeroThresholdAgree` hands back `IfFirstLineExceeds(break, flat)` —
	 * and `flatLength` reads the flat arm, so the call measures the argument as
	 * one-line and opens its own paren. The renderer then takes the literal's
	 * break arm anyway; pass 2 reads that newline as author intent, commits the
	 * literal to `OnePerLine`, and the call — now seeing a real hardline —
	 * glues instead.
	 */
	public function testCallArgObjectLiteralGluesOnFirstPass(): Void {
		final src: String = 'class C {\n\tstatic function g(): Void {\n\t\trecordResolution(verifiedClass, consumer.fieldName, '
			+ '{ ownerClass: levelClass, fieldName: producer.fieldName, scopeLevel: i, fromRootExport: exports != null '
			+ '&& !locals.contains(producer) });\n\t}\n}';
		final once: String = write(src, CALL_ARG_OBJECT);
		Assert.isTrue(
			once.indexOf('recordResolution(verifiedClass, consumer.fieldName, {\n\t\t\townerClass: levelClass,') != -1,
			'expected the glued shape the next pass produces, got:\n<$once>'
		);
		Assert.equals(once, write(once, CALL_ARG_OBJECT), 'one round trip must land on the fixed point');
	}

	/**
	 * The same render-time break under a TERNARY host: pass 1 breaks `?` / `:`
	 * onto their own lines because the branch measures flat, pass 2 hugs
	 * (`cond ? a : {`) because the branch now carries a hardline.
	 */
	public function testTernaryBranchObjectLiteralHugsOnFirstPass(): Void {
		final src: String = 'class C {\n\tstatic function f(p: Null<PosInfos>): Null<PosInfos> {\n\t\treturn p == null ? null : '
			+ '{ fileName: p.fileName, customParams: p.customParams, methodName: p.methodName, className: p.className, '
			+ 'lineNumber: p.lineNumber };\n\t}\n}';
		final once: String = write(src, TERNARY_ARG_OBJECT);
		Assert.isTrue(
			once.indexOf('return p == null ? null : {\n\t\t\tfileName: p.fileName,') != -1,
			'expected the hugged shape the next pass produces, got:\n<$once>'
		);
		Assert.equals(once, write(once, TERNARY_ARG_OBJECT), 'one round trip must land on the fixed point');
	}

	/**
	 * The other half of the call leg, and the reason the glue it adds is
	 * fit-gated. A cascade that answers a BREAK mode in the FITS state — a
	 * rules-free `fillLine` — reaches the same glue shape without anything
	 * above it having refused the flat line, and the resolved collection's
	 * first line always fits. Ungated, this call exploded a literal the line
	 * had room for.
	 */
	public function testShortCallArgObjectLiteralUnderFillLineStaysFlat(): Void {
		final src: String = 'class C {\n\tstatic function g(): Void {\n\t\tf(a, b, { x: 1, y: 2 });\n\t}\n}';
		final once: String = write(src, CALL_ARG_FILL_LINE);
		Assert.isTrue(once.indexOf('f(a, b, {x: 1, y: 2});') != -1, 'expected the fitting call left on one line, got:\n<$once>');
		Assert.equals(once, write(once, CALL_ARG_FILL_LINE), 'a call that fits was already a fixed point');
	}

	private static function write(src: String, config: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(config);
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
