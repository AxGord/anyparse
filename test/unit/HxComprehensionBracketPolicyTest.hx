package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.WhitespacePolicy;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.AstPreds;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HxComprehension;
import anyparse.grammar.haxe.HxExpr;

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
			'WhileExpr' => Type.createEnum(HxExpr, 'WhileExpr', [null])
		];
		Assert.equals(HxComprehension.GENERATOR_CTORS.length, Lambda.count(samples), 'the sample set and GENERATOR_CTORS have diverged');
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

	private inline function write(src: String, json: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(json));
	}

}
