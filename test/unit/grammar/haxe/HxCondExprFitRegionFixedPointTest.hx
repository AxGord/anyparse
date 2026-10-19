package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * A `sameLine.conditionalExprFit` region that breaks is laid out, in the first write, as the next write reads it back.
 *
 * Under `conditionalExprFit` a `#if … #end` value is one group whose directive seams break together. A list that holds
 * the region measured it as that undecided group — flat, too wide — so call arguments filling a line opened before the
 * `#if`; the group then broke by itself. The next write reads every seam newline it printed from the source as a
 * hardline, measures the region by its first line `#if cond` only, and glues it to the previous argument. The region is
 * now a named break (`BreakCommits.namedRegion`): when it breaks, the list is laid out with the seams as hardlines, the
 * read-back form. A list does not lay itself out for a region inside a fit body (a comprehension's `for` body): the next
 * write re-decides that body's own seam too, which the committed region alone does not say. And the
 * seams of one region break together inside a glued comprehension body too: the `#elseif` list kept
 * a force-flat boundary of its own, so the seams before it flattened and the ones after it broke.
 */
@:nullSafety(Strict)
final class HxCondExprFitRegionFixedPointTest extends Test {

	/** Columns a tab occupies under every config here. */
	private static inline final TAB_WIDTH: Int = 4;

	/** `maxLineLength` of every config here. */
	private static inline final LIMIT: Int = 140;

	/** The widest `k` the call sweep writes. */
	private static inline final MAX_K: Int = 100;

	/** Up to this width the call's region fits on its own line flat. */
	private static inline final MAX_K_FLAT_REGION: Int = 20;

	/** The widest `k` the `#elseif` sweep writes. */
	private static inline final MAX_K_ELSEIF: Int = 60;

	/** Past this width main's own fixed point of the lambda body drifts as well (a separate residue). */
	private static inline final MAX_K_LAMBDA: Int = 77;

	/**
	 * Past this width the literal in the region breaks as well, and a host reads that break, which no write names inside
	 * a fit region, as undecided (the lambda's residue above).
	 */
	private static inline final MAX_K_CHAIN: Int = 77;

	/** Call arguments fill their line; a fit region breaks its seams together. */
	private static final CFG_FILL: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, '
		+ '"callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": []}}, "sameLine": {"conditionalExprFit": true}}';

	/** A comprehension cuddles its `for` and fits its body to the line; a fit region breaks its seams together. */
	private static final CFG_COMPREHENSION: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": '
		+ '{"maxLineLength": 140, "comprehensionCuddledOpen": true}, "sameLine": {"conditionalExprFit": true, "comprehensionFor": '
		+ '"fitLine"}}';

	/** The comprehension config, with a chain link after a multi-line `)` cuddled onto it. */
	private static final CFG_CHAIN: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": '
		+ '{"maxLineLength": 140, "comprehensionCuddledOpen": true, "methodChainCuddledLinks": true}, "sameLine": '
		+ '{"conditionalExprFit": true, "comprehensionFor": "fitLine"}}';

	public function new(): Void {
		super();
	}

	/** A region that is a call argument settles in one write at every width, and stays on one line while it fits. */
	@:pin('control')
	@:killer('M-REGION-UNNAMED')
	@:killer('M-REGION-SEAMS-SOFT')
	@:killer('M-REGION-MARK-ALWAYS')
	public function testACallArgumentRegionSettlesInOneWrite(): Void {
		for (k in 1...MAX_K + 1) {
			final once: String = assertOneWriteWithinLimit(callArgument(k), CFG_FILL, k);
			if (k <= MAX_K_FLAT_REGION)
				Assert.isTrue(once.split('\n').exists(l -> l.contains('#if debug') && l.contains('#end')), 'k=$k: the region broke\n$once');
		}
	}

	/** A region that is a comprehension's body, under an arrow, settles in one write: no list lays itself out for it. */
	@:pin('control')
	@:killer('M-REGION-OFFER-THROUGH-BODIES')
	@:killer('M-NESTED-THROUGH-BODIES')
	public function testAComprehensionBodyRegionUnderAnArrowSettlesInOneWrite(): Void {
		for (k in 1...MAX_K_LAMBDA + 1) assertOneWriteWithinLimit(lambdaComprehension(k), CFG_COMPREHENSION, k);
	}

	/**
	 * A region with an `#elseif` that is a comprehension's body settles in one write: its seams break together, the one
	 * before the `#elseif` included.
	 */
	@:pin('control')
	@:killer('M-REGION-SEAMS-BOUNDED')
	public function testAnElseifRegionInAComprehensionSettlesInOneWrite(): Void {
		for (k in 1...MAX_K_ELSEIF + 1) assertOneWriteWithinLimit(elseifComprehension(k), CFG_COMPREHENSION, k);
	}

	/**
	 * A chain link after a call whose comprehension body is a region settles in one write: once the region breaks, the
	 * call closes on its own line, and the link after it is cuddled onto that line as the next write lays it out.
	 */
	public function testAChainLinkAfterARegionSettlesInOneWrite(): Void {
		for (k in 1...MAX_K_CHAIN + 1) assertOneWriteWithinLimit(chainComprehension(k), CFG_CHAIN, k);
	}

	private static function assertOneWriteWithinLimit(src: String, config: String, k: Int): String {
		final once: String = HxWriteFixture.triviaWrite(src, config);
		Assert.equals(once, HxWriteFixture.triviaWrite(once, config), 'k=$k\n$src');
		var widest: Int = 0;
		for (line in once.split('\n')) {
			final width: Int = line.replace('\t', ''.lpad(' ', TAB_WIDTH)).length;
			if (width > widest) widest = width;
		}
		Assert.isTrue(widest <= LIMIT, 'k=$k: a $widest-column line\n$once');
		return once;
	}

	private static function callArgument(k: Int): String {
		return statement(
			'var y = foo(aaaa, #if debug {alpha: x.aaaaaaaaaaaaaaaaaaaaaa, beta: \'' + ''.lpad('k', k)
			+ '\'} #else {alpha: x.aaaaaaaaaaaaaaaaaaaaaa} #end);'
		);
	}

	private static function lambdaComprehension(k: Int): String {
		return statement(
			'var f = () -> [for (x in xs) #if debug {alpha: x.aaaaaaaaaaaaaaaaaaaaaa, beta: \'' + ''.lpad('k', k)
			+ '\'} #else {alpha: x.aaaaaaaaaaaaaaaaaaaaaa} #end];'
		);
	}

	private static function chainComprehension(k: Int): String {
		return statement(
			'var y = builder.withName(nameValue).withItems([for (x in xs) #if debug {alpha: x.aaaaaaaaaaaaaaaaaaaaaa, beta: \''
			+ ''.lpad('k', k) + '\'} #else {alpha: x.aaaaaaaaaaaaaaaaaaaaaa} #end]).build();'
		);
	}

	private static function elseifComprehension(k: Int): String {
		return statement(
			'var y = [for (x in xs) #if debug {alpha: x.aaaaaaaaaaaaaaaaaaaaaa, beta: \'' + ''.lpad('k', k)
			+ '\'} #elseif foo {alpha: x.bbbbbbbbbbbbbbb} #end];'
		);
	}

	private static function statement(s: String): String {
		return 'class M {\n\tfunction f() {\n\t\t$s\n\t}\n}';
	}

}
