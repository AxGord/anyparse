package unit.grammar.haxe;

import anyparse.core.CollapsePass;
import anyparse.core.CollapseRun;
import anyparse.core.D;
import anyparse.core.Doc;
import anyparse.core.DocIdentityMap;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.trivia.Pairs.HxModuleT;
import anyparse.runtime.Parser;
import anyparse.runtime.StringInput;
import utest.Assert;
import utest.Test;

using Lambda;

private typedef Shape = { name: String, gen: Int -> String, cfg: Null<String> };

/** One measured mechanism: its shapes, what one of them costs at a depth, and the budget. */
private typedef Meter = { shapes: Array<Shape>, cost: (Shape, Int) -> Int, budget: Int -> Int };

/**
 * Formatting cost must stay linear in how deeply a construct nests. Each mechanism that made it
 * `2^depth` is pinned by an operation count rather than by a clock:
 *
 *  - the PARSER: sibling alternatives sharing a prefix (`(e : T)` then `(e)`, an arrow type
 *    then a parenthesised one) re-parsed the shared operand once per alternative. `@:memo` on
 *    `HxExpr` / `HxType` records each atom's outcome per position and pending-trivia content;
 *    `Parser.memoRuns` counts the runs that were not replays;
 *  - `CollapsePass`: the writer's Doc is a DAG — a two-branch ctor's branches share their
 *    operands — and the pass rewrote, committed and walked it as a tree.
 *    `CollapseRun.evaluations` counts what it computed;
 *  - the WRITER's Doc: regrouping a comprehension's items (`groupifyInlineBodies`) copied every
 *    shared node once per path to it. Counted as the distinct nodes of the Doc;
 *  - the WRITER itself: a `for` body was written once as an Allman probe and again for the
 *    layout. Counted by the reads of the `body` field the writer makes.
 *
 * Every meter is read at a small depth first, and the depth-40 round runs only once every
 * meter is linear there: one exponential mechanism makes every deep input unanswerable, so an
 * exponential engine answers RED instead of never answering.
 */
class HxNestingCostTest extends Test {

	private static inline final SMALL: Int = 6;
	private static inline final DEEP: Int = 40;

	/** A condition-chain setup under which a committed glue walks every nested paren (`commitOpens`). */
	private static final CHAIN_GLUE_CFG: String = '{"wrapping": {"expressionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", '
		+ '"rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}, "opBoolChain": {'
		+ '"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", '
		+ '"location": "beforeLast"}]}}}';

	/** The fit-driven array wrap under which a comprehension's items are regrouped (`groupifyInlineBodies`). */
	private static final ARRAY_WRAP_CFG: String = '{"wrapping": {"arrayWrap": {"defaultWrap": "ignore", "rules": [{"conditions": ['
		+ '{"cond": "complexItemCount >= n", "value": 2}, {"cond": "totalItemLength >= n", "value": 100}], "type": "onePerLine"}, '
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": ['
		+ '{"cond": "exceedsMaxLineLength", "value": 1}], "type": "packedOrOnePerLine"}]}}}';

	private static final COMPREHENSION: Shape = { name: 'comprehension', gen: n -> nest(n, '[for (i in a) ', ']', '0'), cfg: null };

	/** At most three atoms per level (a ternary's condition, branch and alternative), in each of two parsers. */
	private static final PARSER: Meter = {
		cost: parserRuns,
		budget: n -> 8 * n + 16,
		shapes: [
			{ name: 'paren', gen: n -> nest(n, '(', ')', '0'), cfg: null },
			{ name: 'ternary-paren', gen: n -> nest(n, '(a ? ', ' : 1)', '0'), cfg: null },
			{ name: 'neg-paren', gen: n -> nest(n, '-(', ')', '0'), cfg: null },
			{ name: 'macro-paren', gen: n -> nest(n, 'macro (', ')', '0'), cfg: null },
			{ name: 'meta-paren', gen: n -> nest(n, '@:m (', ')', '0'), cfg: null },
			{ name: 'lambda-paren', gen: n -> nest(n, '((a) -> ', ')', '0'), cfg: null },
			{ name: 'lambda-paren-broken', gen: n -> nest(n, '((a) ->\n', ')', '0'), cfg: null },
			{ name: 'ternary-paren-broken', gen: n -> nest(n, '(a\n? ', '\n: 1)', '0'), cfg: null },
			{ name: 'paren-type', gen: n -> '(0 : ${nest(n, '(', ')', 'Int')})', cfg: null },
			{ name: 'arrow-type', gen: n -> '(0 : ${nest(n, '(Int -> ', ')', 'Int')})', cfg: null }
		]
	};

	/** Linear in the depth, with room for the widest per-level shape (a call chain). */
	private static final COLLAPSE: Meter = {
		cost: collapseEvaluations,
		budget: n -> 120 * n + 500,
		shapes: [
			{ name: 'add-paren', gen: n -> nest(n, '(a + ', ')', '0'), cfg: null },
			{ name: 'paren', gen: n -> nest(n, '(', ')', '0'), cfg: null },
			{ name: 'ternary-paren', gen: n -> nest(n, '(a ? ', ' : 1)', '0'), cfg: null },
			{ name: 'lambda-paren', gen: n -> nest(n, '((a) -> ', ')', '0'), cfg: null },
			{ name: 'bool-paren', gen: n -> nest(n, '(a && ', ')', 'b'), cfg: null },
			{ name: 'call-chain', gen: n -> nest(n, 'f(a + ', ').g()', '0'), cfg: null },
			{
				name: 'glued-bool-chain',
				gen: n -> '${StringTools.rpad('', 'a', 39)} && (${StringTools.rpad('', 'b', 82)} || ${nest(n, '(a ? ', ' : 1)', '0')})',
				cfg: CHAIN_GLUE_CFG
			}
		]
	};

	private static final DOC_NODES: Meter = {
		cost: docNodes,
		budget: n -> 40 * n + 100,
		shapes: [
			{ name: 'comprehension-array-wrap', gen: COMPREHENSION.gen, cfg: ARRAY_WRAP_CFG }
		]
	};

	/** A constant number of reads of a `for` body or a call's arguments per level. */
	private static final BODY_WRITES: Meter = {
		cost: bodyReads,
		budget: n -> 3 * n + 8,
		shapes: [
			COMPREHENSION,
			{ name: 'method-call-nest', gen: n -> nest(n, 'a.m(', ')', '1'), cfg: null }
		]
	};

	@:pin('control')
	@:killer('M-PARSE-MEMO-REPLAY-OFF')
	@:killer('M-PARSE-MEMO-STASHED-SKIP')
	public function testParserRunsEachNestedAtomOnce(): Void {
		check(PARSER);
	}

	@:pin('control')
	@:killer('M-COLLAPSE-REWRITE-MEMO-OFF')
	@:killer('M-COLLAPSE-SUBTREE-MEMO-OFF')
	@:killer('M-COLLAPSE-COMMIT-MEMO-OFF')
	public function testCollapsePassComputesEachSharedNodeOnce(): Void {
		check(COLLAPSE);
	}

	@:pin('control')
	@:killer('M-GROUPIFY-SHARED-OFF')
	public function testWriterDocKeepsItsSharing(): Void {
		check(DOC_NODES);
	}

	@:pin('control')
	@:killer('M-FOR-BODY-PROBE-EAGER')
	@:killer('M-CHAIN-WALK-EAGER')
	public function testEachBodyIsWrittenOnce(): Void {
		check(BODY_WRITES);
	}

	private static inline function wrapExpr(e: String): String {
		return 'class M {\n\tstatic function main() {\n\t\tvar x = $e;\n\t}\n}\n';
	}

	/**
	 * Every shape of `meter` within budget at `SMALL`, then at `DEEP` — but the deep round
	 * runs only once EVERY meter is linear at `SMALL`, since one exponential mechanism makes
	 * every other meter's deep input unanswerable too.
	 */
	private static function check(meter: Meter): Void {
		for (shape in meter.shapes) {
			final cost: Int = meter.cost(shape, SMALL);
			Assert.isTrue(cost <= meter.budget(SMALL), '${shape.name} x$SMALL: cost $cost');
		}
		if (!linearAtSmall()) return;
		for (shape in meter.shapes) {
			final cost: Int = meter.cost(shape, DEEP);
			Assert.isTrue(cost <= meter.budget(DEEP), '${shape.name} x$DEEP: cost $cost');
		}
	}

	private static function linearAtSmall(): Bool {
		return [PARSER, COLLAPSE, DOC_NODES, BODY_WRITES].foreach(meter ->
			meter.shapes.foreach(shape -> meter.cost(shape, SMALL) <= meter.budget(SMALL))
		);
	}

	/** `@:memo` atom runs that were not replays, in the trivia and the fast parser together. */
	private static function parserRuns(shape: Shape, n: Int): Int {
		final src: String = wrapExpr(shape.gen(n));
		final trivia: Parser = new Parser(new StringInput(src));
		HaxeModuleTriviaParser.parseWith(trivia);
		final fast: Parser = new Parser(new StringInput(src));
		HaxeModuleParser.parseWith(fast);
		return trivia.memoRuns + fast.memoRuns;
	}

	private static function collapseEvaluations(shape: Shape, n: Int): Int {
		final opt: HxModuleWriteOptions = options(shape.cfg);
		final doc: Doc = HaxeModuleTriviaWriter.writeDoc(HaxeModuleTriviaParser.parse(wrapExpr(shape.gen(n))), opt);
		final run: CollapseRun = new CollapseRun();
		CollapsePass.runWith(run, doc, opt.lineWidth, opt.indentChar, opt.tabWidth, opt.indentSize);
		return run.evaluations;
	}

	private static function docNodes(shape: Shape, n: Int): Int {
		return distinctNodes(HaxeModuleTriviaWriter.writeDoc(HaxeModuleTriviaParser.parse(wrapExpr(shape.gen(n))), options(shape.cfg)));
	}

	private static function bodyReads(shape: Shape, n: Int): Int {
		final ast: HxModuleT = HaxeModuleTriviaParser.parse(wrapExpr(shape.gen(n)));
		final reads: { count: Int } = { count: 0 };
		countBodyReads(ast, reads);
		HaxeModuleTriviaWriter.write(ast, options(shape.cfg));
		return reads.count;
	}

	/** How many distinct (by identity) nodes `d` holds. */
	private static function distinctNodes(d: Doc): Int {
		final seen: DocIdentityMap<Bool> = new DocIdentityMap();
		final stack: Array<Doc> = [d];
		var count: Int = 0;
		while (stack.length > 0) {
			final node: Doc = (cast stack.pop(): Doc);
			if (seen.exists(node)) continue;
			seen.set(node, true);
			count++;
			D.mapChildren(node, child -> {
				stack.push(child);
				return child;
			});
		}
		return count;
	}

	private static function options(cfg: Null<String>): HxModuleWriteOptions {
		return cfg == null ? HaxeFormat.instance.defaultWriteOptions : HaxeFormatConfigLoader.loadHxFormatJson(cfg);
	}

	/**
	 * Count the reads of every `for` payload's `body` and every call's `args` in `node` — the
	 * writer reads each a fixed number of times per write of it.
	 */
	private static function countBodyReads(node: Null<Dynamic>, reads: { count: Int }): Void {
		if (node == null) return;
		switch Type.typeof(node) {
			case TEnum(_):
				for (param in Type.enumParameters(node)) countBodyReads(param, reads);
				if (Type.enumConstructor(node) == 'Call') countFieldReads(node, 'args', reads);
			case TClass(Array):
				final items: Array<Dynamic> = node;
				for (item in items) countBodyReads(item, reads);
			case TObject, TClass(_) if (!(node is String)):
				for (field in Reflect.fields(node)) countBodyReads(Reflect.field(node, field), reads);
				if (Reflect.hasField(node, 'iterable') && Reflect.hasField(node, 'varName')) countFieldReads(node, 'body', reads);
			case _:
		}
	}

	/** Replace `node.field` with a getter that counts its reads. */
	private static function countFieldReads(node: Dynamic, field: String, reads: { count: Int }): Void {
		final value: Dynamic = Reflect.field(node, field);
		js.lib.Object.defineProperty(node, field, {
			get: () -> {
				reads.count++;
				return value;
			},
			enumerable: true
		});
	}

	private static function nest(n: Int, open: String, close: String, core: String): String {
		final buf: StringBuf = new StringBuf();
		for (_ in 0...n) buf.add(open);
		buf.add(core);
		for (_ in 0...n) buf.add(close);
		return buf.toString();
	}

}
