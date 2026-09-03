package unit.grammar.haxe;

import anyparse.format.WhitespacePolicy;
import anyparse.grammar.haxe.AstPreds;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxComprehension;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * Bracket-whitespace parity for array comprehensions vs plain array /
 * map literals. haxe-formatter couples a comprehension's bracket
 * padding to `sameLine.comprehensionFor`: `fitLine` pads the brackets
 * (`[ for (x in y) x ]`, overriding any `bracketConfig` policy) while
 * `same` (the fork default) leaves them tight (`[for (x in y) x]`).
 * Plain array (`[1, 2, 3]`) and map (`[k => v]`) literals stay tight
 * regardless — the three kinds share one grammar ctor
 * (`HxExpr.ArrayExpr`) and the writer dispatches on the first element.
 */
@:nullSafety(Strict)
class HxComprehensionBracketPolicyTest extends Test {

	/** Pads only `mapLiteralBrackets`, so a padded `[` reports kind 1 and a tight one reports 0 or 2. */
	private static inline final MAP_PAD: String =
		'{"whitespace":{"bracketConfig":{"mapLiteralBrackets":{"openingPolicy":"after","closingPolicy":"before"}}}}';

	/** The mirror of `MAP_PAD`: a padded `[` reports kind 2, a tight one 0 or 1. */
	private static inline final COMPREHENSION_PAD: String =
		'{"whitespace":{"bracketConfig":{"comprehensionBrackets":{"openingPolicy":"after","closingPolicy":"before"}}}}';

	public function new(): Void {
		super();
	}

	public function testDefaultComprehensionBracketsTight(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(WhitespacePolicy.None, opts.comprehensionBracketsOpen);
		Assert.equals(WhitespacePolicy.None, opts.comprehensionBracketsClose);
	}

	public function testDefaultComprehensionFormatsTight(): Void {
		final out: String = write('class M { static function f() { var a = [for (x in y) x]; } }', '{}');
		Assert.isTrue(out.indexOf('[for (x in y) x]') != -1, 'expected tight comprehension in: <$out>');
	}

	public function testComprehensionForFitLinePadsOptions(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine":{"comprehensionFor":"fitLine"}}');
		Assert.equals(WhitespacePolicy.After, opts.comprehensionBracketsOpen);
		Assert.equals(WhitespacePolicy.Before, opts.comprehensionBracketsClose);
	}

	public function testComprehensionForFitLineFormatsPadded(): Void {
		final json: String = '{"sameLine":{"comprehensionFor":"fitLine"}}';
		final out: String = write('class M { static function f() { var a = [for (x in y) x]; } }', json);
		Assert.isTrue(out.indexOf('[ for (x in y) x ]') != -1, 'expected padded comprehension in: <$out>');
	}

	public function testWhileComprehensionForFitLineFormatsPadded(): Void {
		final json: String = '{"sameLine":{"comprehensionFor":"fitLine"}}';
		final out: String = write('class M { static function f() { var a = [while (c) x]; } }', json);
		Assert.isTrue(out.indexOf('[ while (c) x ]') != -1, 'expected padded while-comprehension in: <$out>');
	}

	/**
	 * A loop head `HxForExpr` cannot model — here a `k => v.q` key-value binder
	 * over a field access — projects the reified twin `ForReifExpr`. It is a
	 * comprehension by every reading of the source, but until the ctor joined
	 * `GENERATOR_CTORS` the writer read the same bracket as a plain array literal
	 * and left it tight under a comprehension-padding config. The plain `ForExpr`
	 * line below is the control: it was already padded, so a failure here is about
	 * the reified twin alone.
	 */
	public function testReifiedForHeadIsComprehension(): Void {
		final out: String = write('class M { static function f() { var a = [for (k => v.q in m) k]; } }', COMPREHENSION_PAD);
		Assert.isTrue(out.indexOf('[ for (k => v.q in m) k ]') != -1, 'expected padded reified comprehension in: <$out>');
		final plain: String = write('class M { static function f() { var a = [for (x in y) x]; } }', COMPREHENSION_PAD);
		Assert.isTrue(plain.indexOf('[ for (x in y) x ]') != -1, 'expected padded plain comprehension in: <$plain>');
	}

	public function testComprehensionForSameKeepsTight(): Void {
		final json: String = '{"sameLine":{"comprehensionFor":"same"}}';
		final out: String = write('class M { static function f() { var a = [for (x in y) x]; } }', json);
		Assert.isTrue(out.indexOf('[for (x in y) x]') != -1, 'expected tight comprehension under comprehensionFor=same in: <$out>');
	}

	public function testArrayLiteralStaysTightUnderFitLine(): Void {
		final json: String = '{"sameLine":{"comprehensionFor":"fitLine"}}';
		final out: String = write('class M { static function f() { var a = [1, 2, 3]; } }', json);
		Assert.isTrue(out.indexOf('[1, 2, 3]') != -1, 'expected tight array literal in: <$out>');
	}

	public function testMapLiteralStaysTightUnderFitLine(): Void {
		final json: String = '{"sameLine":{"comprehensionFor":"fitLine"}}';
		final out: String = write('class M { static function f() { var a = [k => v, k2 => v2]; } }', json);
		Assert.isTrue(out.indexOf('[k => v, k2 => v2]') != -1, 'expected tight map literal in: <$out>');
	}

	public function testExplicitBracketConfigPadsComprehension(): Void {
		final json: String =
			'{"whitespace":{"bracketConfig":{"comprehensionBrackets":{"openingPolicy":"after","closingPolicy":"before"}}}}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(json);
		Assert.equals(WhitespacePolicy.After, opts.comprehensionBracketsOpen);
		Assert.equals(WhitespacePolicy.Before, opts.comprehensionBracketsClose);
	}

	/**
	 * `arrayBracketKind`'s kind-2 arm and `HaxeFormat.isComprehensionGenerator` classify
	 * ONE grammar fact — which `HxExpr` ctors can be a comprehension's generator — from two
	 * compilation contexts: a macro-generated typed predicate on `AstPreds`, and a runtime
	 * `Reflect` walk over the untyped elements the grammar-agnostic writer lowering holds.
	 * They cannot share a body, so they share the LIST, `HxComprehension.GENERATOR_CTORS`;
	 * before that they were two hand-kept spellings that happened to agree.
	 *
	 * The fixture is driven off that list rather than off a literal pair, and the count is
	 * asserted BOTH ways: a ctor added to the list fails here on a missing sample, and a
	 * ctor removed from it fails on the count rather than passing with a shorter loop.
	 *
	 * Two limits worth knowing before extending it. It exercises the PLAIN-mode `AstPreds`;
	 * the trivia writer calls the separately generated `AstPredsT.arrayBracketKind`, covered
	 * here only end-to-end by the formatting tests above. And `Type.createEnum` with `[null]`
	 * matches the arity every generator ctor happens to have today — a future one with a
	 * different arity needs its own payload, not a copied `[null]`, which on js would build a
	 * malformed value rather than throw.
	 */
	public function testBothComprehensionClassifiersAnswerFromOneList(): Void {
		final samples: Map<String, HxExpr> = [
			'ForExpr' => Type.createEnum(HxExpr, 'ForExpr', [null]),
			'ForReifExpr' => Type.createEnum(HxExpr, 'ForReifExpr', [null]),
			'WhileExpr' => Type.createEnum(HxExpr, 'WhileExpr', [null])
		];
		Assert.equals(HxComprehension.GENERATOR_CTORS.length, samples.count(), 'the sample set and GENERATOR_CTORS have diverged');
		for (ctor in HxComprehension.GENERATOR_CTORS) {
			final sample: Null<HxExpr> = samples[ctor];
			if (sample == null) {
				Assert.fail('no sample for generator ctor $ctor — add one, matching the ctor\'s arity');
				continue;
			}
			Assert.equals(2, AstPreds.arrayBracketKind(sample), 'arrayBracketKind($ctor)');
			Assert.isTrue(HaxeFormat.isComprehensionGenerator(sample), 'isComprehensionGenerator($ctor)');
			Assert.isTrue(HaxeFormat.isComprehensionGenerator({ node: sample }), 'trivia-wrapped $ctor');
		}
		final notAGenerator: HxExpr = Type.createEnum(HxExpr, 'NewExpr', [null]);
		Assert.equals(0, AstPreds.arrayBracketKind(notAGenerator));
		Assert.isFalse(HaxeFormat.isComprehensionGenerator(notAGenerator));
		Assert.equals(0, AstPreds.arrayBracketKind(null));
		Assert.isFalse(HaxeFormat.isComprehensionGenerator(null));
	}

	/**
	 * Control for the whole `MAP_PAD` family: a BARE `Arrow` first element was
	 * already kind 1 before the wrapper recursion existed, so this one is green
	 * at base by construction and only fails if the map arm itself is lost.
	 */
	public function testBareMapEntryPadsUnderMapBracketConfig(): Void {
		final out: String = write('class M { static function f() { var a = [k => v]; } }', MAP_PAD);
		Assert.isTrue(out.indexOf('[ k => v ]') != -1, 'expected padded map literal in: <$out>');
	}

	/** Control: a list with no arrow anywhere must not be dragged into the map policy. */
	public function testPlainArrayStaysArrayLiteralUnderMapBracketConfig(): Void {
		final out: String = write('class M { static function f() { var a = [1, 2, 3]; } }', MAP_PAD);
		Assert.isTrue(out.indexOf('[1, 2, 3]') != -1, 'expected tight array literal in: <$out>');
	}

	public function testParenWrappedMapEntryIsMapLiteral(): Void {
		final out: String = write('class M { static function f() { var a = [(k => v)]; } }', MAP_PAD);
		Assert.isTrue(out.indexOf('[ (k => v) ]') != -1, 'expected padded map literal in: <$out>');
	}

	public function testMetaWrappedMapEntryIsMapLiteral(): Void {
		final out: String = write('class M { static function f() { var a = [@:foo k => v]; } }', MAP_PAD);
		Assert.isTrue(out.indexOf('[ @:foo k => v ]') != -1, 'expected padded map literal in: <$out>');
	}

	public function testBalancedConditionalMapEntryIsMapLiteral(): Void {
		final out: String = write('class M { static function f() { var a = [#if flag k => v #else k2 => v2 #end]; } }', MAP_PAD);
		Assert.isTrue(out.indexOf('[ #if flag k => v #else k2 => v2 #end ]') != -1, 'expected padded map literal in: <$out>');
	}

	/** Only the `#else` branch carries the entry — the `#if` branch answers 0 and must not end the search. */
	public function testBalancedConditionalElseBranchMapEntryIsMapLiteral(): Void {
		final out: String = write('class M { static function f() { var a = [#if flag x #else k => v #end]; } }', MAP_PAD);
		Assert.isTrue(out.indexOf('[ #if flag x #else k => v #end ]') != -1, 'expected padded map literal in: <$out>');
	}

	public function testConditionalArgsMapEntryIsMapLiteral(): Void {
		final out: String = write('class M { static function f() { var a = [#if flag k => v, #end k2 => v2]; } }', MAP_PAD);
		Assert.isTrue(out.indexOf('[ #if flag k => v, #end k2 => v2 ]') != -1, 'expected padded map literal in: <$out>');
	}

	/** `body[0]` is not an entry here; the answer lives in `elseBody`. */
	public function testConditionalArgsElseBranchMapEntryIsMapLiteral(): Void {
		final out: String = write('class M { static function f() { var a = [#if flag x, #else k => v, #end k2 => v2]; } }', MAP_PAD);
		Assert.isTrue(out.indexOf('[ #if flag x, #else k => v, #end k2 => v2 ]') != -1, 'expected padded map literal in: <$out>');
	}

	/** A conditional region with no arrow in either branch stays an array literal. */
	public function testConditionalWithoutMapEntryStaysArrayLiteral(): Void {
		final out: String = write('class M { static function f() { var a = [#if flag x #else y #end]; } }', MAP_PAD);
		Assert.isTrue(out.indexOf('[#if flag x #else y #end]') != -1, 'expected tight array literal in: <$out>');
	}

	/**
	 * The recursion clamp, one wrapper per assertion. A generator ctor behind a
	 * wrapper is a `for` EXPRESSION used as an element, not an array comprehension,
	 * so it must never reach the comprehension policy. Green at base by
	 * construction (no recursion there).
	 *
	 * Killer coverage measured, not assumed: dropping the clamp inside `mapOnly`
	 * flips the meta, paren and balanced-conditional assertions. The
	 * `ConditionalArgs` one does NOT flip there — that arm is guarded twice, since
	 * its `_k == 1` test re-clamps whatever `mapOnly` returns — and it takes both
	 * defects at once to leak a 2 through it, which is exactly what this assertion
	 * pins. Widening `_k == 1` to `_k != 0` on its own is an EQUIVALENT mutant
	 * (`mapOnly` has already reduced `_k` to 1-or-0), so no fixture can kill it.
	 *
	 * The bare comprehension is the counter-assertion: kind 2 must still get
	 * through when nothing wraps it.
	 */
	public function testWrappedComprehensionStaysArrayLiteral(): Void {
		final out: String = write('class M { static function f() { var a = [@:foo for (x in y) x]; } }', COMPREHENSION_PAD);
		Assert.isTrue(out.indexOf('[@:foo for (x in y) x]') != -1, 'expected tight array literal in: <$out>');
		final paren: String = write('class M { static function f() { var a = [(for (x in y) x)]; } }', COMPREHENSION_PAD);
		Assert.isTrue(paren.indexOf('[(for (x in y) x)]') != -1, 'expected tight array literal in: <$paren>');
		final condArgs: String = write('class M { static function f() { var a = [#if flag for (x in y) x, #end z]; } }', COMPREHENSION_PAD);
		Assert.isTrue(condArgs.indexOf('[#if flag for (x in y) x, #end z]') != -1, 'expected tight array literal in: <$condArgs>');
		final condExpr: String = write(
			'class M { static function f() { var a = [#if flag for (x in y) x #else z #end]; } }', COMPREHENSION_PAD
		);
		Assert.isTrue(condExpr.indexOf('[#if flag for (x in y) x #else z #end]') != -1, 'expected tight array literal in: <$condExpr>');
		final bare: String = write('class M { static function f() { var a = [for (x in y) x]; } }', COMPREHENSION_PAD);
		Assert.isTrue(bare.indexOf('[ for (x in y) x ]') != -1, 'expected padded comprehension in: <$bare>');
	}

	/**
	 * Plain-mode `AstPreds` cover for the recursion — the formatting tests above
	 * all run the trivia writer, so they exercise `AstPredsT` only. `ParenExpr`
	 * is the one wrapper whose payload is a bare `HxExpr`, so it can be built
	 * here without standing in a struct operand.
	 */
	public function testPlainAstPredsSeesThroughParenWrapper(): Void {
		final arrow: HxExpr = Type.createEnum(HxExpr, 'Arrow', [null, null]);
		Assert.equals(1, AstPreds.arrayBracketKind(Type.createEnum(HxExpr, 'ParenExpr', [arrow])));
		final generator: HxExpr = Type.createEnum(HxExpr, 'ForExpr', [null]);
		Assert.equals(2, AstPreds.arrayBracketKind(generator));
		Assert.equals(0, AstPreds.arrayBracketKind(Type.createEnum(HxExpr, 'ParenExpr', [generator])));
		Assert.equals(0, AstPreds.arrayBracketKind(Type.createEnum(HxExpr, 'ParenExpr', [null])));
	}

	private inline function write(src: String, json: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(json));
	}

}
