package unit.grammar.haxe;

import anyparse.core.BreakToken;
import anyparse.core.D;
import anyparse.core.Doc;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * An object literal that a branch of an expression-scope `#if` holds on the keyword's line, and that its own wrap rule
 * breaks, is laid out in one write as the next write reads it back.
 *
 * The literal breaks GLUED, by a width decision the renderer makes, so a list around the `#if` — a comprehension's
 * brackets, a call's arguments — used to lay itself out from the flat item: the next write read the literal it broke as
 * a source-multi-line literal, the item as multi-line, and laid the list out by those rules instead (a comprehension
 * cuddled `[for`, a call kept its arguments on the call's line). The literal's decision is now named
 * (`BreakCommits.named`), and the list offers the read-back layout for the measure render to pick.
 */
@:nullSafety(Strict)
final class HxCondExprBodyBreakFixedPointTest extends Test {

	/** Columns a tab occupies under every config here. */
	private static inline final TAB_WIDTH: Int = 4;

	/** `maxLineLength` of the compiled defaults. */
	private static inline final LIMIT_DEFAULT: Int = 160;

	/** `maxLineLength` of `CFG_CUDDLED`. */
	private static inline final LIMIT_CUDDLED: Int = 140;

	/** The widest `k` the sweeps write: past it the literal's last field alone no longer fits its line. */
	private static inline final MAX_K: Int = 120;

	/** The compiled defaults, 160 columns. */
	private static final CFG_DEFAULT: String = '{}';

	/** A comprehension's open bracket cuddles its `for`, at 140 columns. */
	private static final CFG_CUDDLED: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": '
		+ '{"maxLineLength": 140, "comprehensionCuddledOpen": true}}';

	/**
	 * `CFG_CUDDLED` with an object-literal rule that keeps a literal flat up to 140 columns of fields, whatever column it
	 * starts at: a flat literal then runs past the limit on main as well (`k` 17-20 and 52-56 of `callOfComprehension`),
	 * so only the one-write fixed point is asserted under it.
	 */
	private static final CFG_OBJECT_RULE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": '
		+ '{"maxLineLength": 140, "comprehensionCuddledOpen": true, "objectLiteral": {"defaultWrap": "onePerLine", '
		+ '"rules": [{"conditions": [{"cond": "totalItemLength <= n", "value": 140}], "type": "noWrap"}]}}}';

	/** `CFG_CUDDLED` with the `#if` region its own fit group (`sameLine.conditionalExprFit`) and a fit-line `for` body. */
	private static final CFG_FIT: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": '
		+ '{"maxLineLength": 140, "comprehensionCuddledOpen": true}, "sameLine": {"conditionalExprFit": true, '
		+ '"comprehensionFor": "fitLine"}}';

	/** The comprehension at `k = 30`, laid out in one write. */
	private static final COMPREHENSION_30: String = 'class M {\n\tfunction f() {\n\t\tvar y = [for (x in xs) #if debug {\n'
		+ '\t\t\talpha: x.aaaaaaaaaaaaaaaaaaaaaa,\n\t\t\tbeta: \'' + ''.lpad('k', 30) + '\'\n'
		+ '\t\t} #else {alpha: x.aaaaaaaaaaaaaaaaaaaaaa} #end\n\t\t];\n\t}\n}';

	/** The call at `k = 60`, laid out in one write. */
	private static final CALL_60: String = 'class M {\n\tfunction f() {\n\t\tvar y = foo(aaaa, #if debug {\n'
		+ '\t\t\talpha: x.aaaaaaaaaaaaaaaaaaaaaa,\n\t\t\tbeta: \'' + ''.lpad('k', 60) + '\'\n'
		+ '\t\t} #else {alpha: x.aaaaaaaaaaaaaaaaaaaaaa} #end);\n\t}\n}';

	/** The comprehension at `k = 85` under `CFG_FIT`: the region's own group breaks its directive seams. */
	private static final FIT_85: String = 'class M {\n\tfunction f() {\n\t\tvar y = [ for (x in xs)\n\t\t\t#if debug\n'
		+ '\t\t\t\t{\n\t\t\t\t\talpha: x.aaaaaaaaaaaaaaaaaaaaaa,\n\t\t\t\t\tbeta: \'' + ''.lpad('k', 85) + '\'\n'
		+ '\t\t\t\t}\n\t\t\t#else\n\t\t\t\t{alpha: x.aaaaaaaaaaaaaaaaaaaaaa}\n\t\t\t#end\n\t\t];\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** A comprehension whose `#if` literal breaks cuddles its open bracket in the first write, as the next reads it. */
	@:pin('control')
	@:killer('M-BREAKMARK-SITE-OFF')
	public function testAComprehensionCuddlesInOneWrite(): Void {
		Assert.equals(COMPREHENSION_30, HxWriteFixture.triviaWrite(comprehension(30), CFG_CUDDLED));
		Assert.equals(COMPREHENSION_30, HxWriteFixture.triviaWrite(COMPREHENSION_30, CFG_CUDDLED));
	}

	/** A call whose `#if` argument breaks keeps that argument on the call's line in the first write. */
	@:pin('control')
	@:killer('M-BREAKMARK-UNRECORDED')
	public function testACallKeepsTheArgumentGluedInOneWrite(): Void {
		Assert.equals(CALL_60, HxWriteFixture.triviaWrite(call(60), CFG_DEFAULT));
		Assert.equals(CALL_60, HxWriteFixture.triviaWrite(CALL_60, CFG_DEFAULT));
	}

	/** One write is a fixed point within the limit at every width of the comprehension and of the call. */
	@:pin('control')
	@:killer('M-BREAKMARK-UNREAD')
	public function testOneWriteIsAFixedPointAtEveryWidth(): Void {
		for (k in 1...MAX_K + 1) {
			assertOneWriteWithinLimit(comprehension(k), CFG_CUDDLED, LIMIT_CUDDLED, k);
			assertOneWriteWithinLimit(call(k), CFG_CUDDLED, LIMIT_CUDDLED, k);
			assertOneWriteWithinLimit(call(k), CFG_DEFAULT, LIMIT_DEFAULT, k);
		}
	}

	/**
	 * A comprehension nested in a call: where the call opening is what pushes the second literal past the limit, the
	 * measure follows the layout it committed and reads that literal back too (`CFG_OBJECT_RULE`, `k` 55-58).
	 */
	@:pin('control')
	@:killer('M-BREAKMARK-ONE-ROUND')
	public function testANestedListFollowsTheLayoutItCommitted(): Void {
		for (k in 1...MAX_K + 1) {
			assertOneWriteWithinLimit(callOfComprehension(k), CFG_CUDDLED, LIMIT_CUDDLED, k);
			assertOneWrite(callOfComprehension(k), CFG_OBJECT_RULE, k);
		}
	}

	/** A `BreakMark` rebuilt by a Doc walk keeps its token, so a copy still names the break its `BreakCommit` waits for. */
	@:pin('control')
	@:killer('M-BREAKMARK-REBUILD-FRESH-TOKEN')
	public function testARebuiltMarkKeepsItsToken(): Void {
		final token: BreakToken = new BreakToken();
		switch D.mapChildren(Doc.BreakMark(Doc.Text('a'), token), d -> d) {
			case Doc.BreakMark(_, kept):
				Assert.isTrue(kept == token);
			case _:
				Assert.fail('a BreakMark rebuilt as another node');
		}
	}

	/** Under `conditionalExprFit` the region keeps the directive-seam ladder its own group gives it. */
	@:pin('control')
	@:killer('M-BREAKMARK-FIT-NAMED')
	public function testAFitRegionKeepsItsLadder(): Void {
		Assert.equals(FIT_85, HxWriteFixture.triviaWrite(comprehension(85), CFG_FIT));
		Assert.equals(FIT_85, HxWriteFixture.triviaWrite(FIT_85, CFG_FIT));
	}

	private static function assertOneWrite(src: String, config: String, k: Int): String {
		final once: String = HxWriteFixture.triviaWrite(src, config);
		Assert.equals(once, HxWriteFixture.triviaWrite(once, config), 'k=$k config=$config\n$src');
		return once;
	}

	private static function assertOneWriteWithinLimit(src: String, config: String, limit: Int, k: Int): Void {
		final once: String = assertOneWrite(src, config, k);
		var widest: Int = 0;
		for (line in once.split('\n')) {
			final width: Int = line.replace('\t', ''.lpad(' ', TAB_WIDTH)).length;
			if (width > widest) widest = width;
		}
		Assert.isTrue(widest <= limit, 'k=$k config=$config: a $widest-column line\n$once');
	}

	private static function comprehension(k: Int): String {
		return statement('var y = [for (x in xs) ' + conditional(k) + '];');
	}

	private static function call(k: Int): String {
		return statement('var y = foo(aaaa, ' + conditional(k) + ');');
	}

	private static function callOfComprehension(k: Int): String {
		return statement('var y = foo(aaaa, [for (x in xs) ' + conditional(k) + ']);');
	}

	private static function conditional(k: Int): String {
		return
			'#if debug {alpha: x.aaaaaaaaaaaaaaaaaaaaaa, beta: \'' + ''.lpad('k', k) + '\'} #else {alpha: x.aaaaaaaaaaaaaaaaaaaaaa} #end';
	}

	private static function statement(s: String): String {
		return 'class M {\n\tfunction f() {\n\t\t' + s + '\n\t}\n}';
	}

}
