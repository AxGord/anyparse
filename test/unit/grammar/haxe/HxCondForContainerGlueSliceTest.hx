package unit.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrappingLocation;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * A for-loop whose iterable is a multi-line array (or object / call) keeps the
 * `for (` paren GLUED (`for (item in [\n\t...\n]) {`) instead of opening it onto
 * its own line (`for (\n\titem in [\n...\n]\n) {`). The container's own leading
 * break absorbs the wrap; the cond paren stays on the header line (fork parity).
 *
 * Regression guard for the `emitCondition` hardline branch, which used to open
 * the paren unconditionally whenever the cond carried a container-induced
 * hardline. The fix defers to the same `IfNaturalFirstLineFitsOpenDelim` natural
 * probe the non-hardline path uses: glue when the natural first line ends at an
 * open delimiter. Both a FLAT-source and an already-WRAPPED-source input
 * converge to the glued form (idempotent).
 */
@:nullSafety(Strict)
final class HxCondForContainerGlueSliceTest extends Test {

	private static final CONFIG: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
		edited.lineWidth = 140;
		edited.forBody = BodyPolicy.FitLine;
		edited.conditionWrap = {
			defaultAdditionalIndent: 0,
			defaultMode: WrapMode.FillLineWithLeadingBreak,
			rules: [
				{ conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }], mode: WrapMode.NoWrap }
			]
		};
		edited.comprehensionObjectLitGlue = true;
	});
	private static final GLUED: String = 'class C {\n\tfunction f() {\n\t\tfor (item in [\n\t\t\tfirstLongItemNameValue,\n'
		+ '\t\t\tsecondLongItemNameValue,\n\t\t\tthirdLongItemNameValue,\n\t\t\tfourthLongItemNameV\n\t\t]) {\n'
		+ '\t\t\tdoWork(item);\n\t\t}\n\t}\n}';

	public function new(): Void {
		super();
	}

	public function testFlatSourceForArrayKeepsParenGlued(): Void {
		final flat: String = 'class C {\n\tfunction f() {\n\t\tfor (item in [firstLongItemNameValue, secondLongItemNameValue, '
			+ 'thirdLongItemNameValue, fourthLongItemNameV]) {\n\t\t\tdoWork(item);\n\t\t}\n\t}\n}';
		Assert.equals(GLUED, triviaWrite(flat));
	}

	public function testWrappedSourceForArrayIsIdempotent(): Void {
		Assert.equals(GLUED, triviaWrite(GLUED));
	}

	/**
	 * A top-level `&&`/`||` chain condition whose LAST operand ends in a
	 * multi-line container still OPENS the paren (the chain wraps, not the
	 * paren) -- it must NOT be glued like a bare container cond. Regression
	 * guard for the `chainOpens` exclusion in the hardline branch. One-way:
	 * the opBoolChain fill-wrap of a broken-array operand is not idempotent
	 * (a separate, pre-existing writer trait), so only flat -> opened is asserted.
	 */
	public function testChainContainerCondOpensNotGlued(): Void {
		final config: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
			edited.lineWidth = 140;
			edited.ifBody = BodyPolicy.FitLine;
			edited.opBoolChainWrap = {
				defaultAdditionalIndent: 0,
				defaultMode: WrapMode.NoWrap,
				rules: [
					{
						conditions: [
							{ cond: WrapConditionType.ItemCountLessThan, value: 3 },
							{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }
						],
						mode: WrapMode.NoWrap
					},
					{
						conditions: [
							{ cond: WrapConditionType.TotalItemLengthLessThan, value: 120 },
							{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }
						],
						mode: WrapMode.NoWrap
					},
					{
						conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 1 }],
						location: WrappingLocation.BeforeLast,
						mode: WrapMode.FillLine
					}
				]
			};
			edited.conditionWrap = {
				defaultAdditionalIndent: 0,
				defaultMode: WrapMode.FillLineWithLeadingBreak,
				rules: [
					{ conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }], mode: WrapMode.NoWrap }
				]
			};
		});
		final flat: String = 'class C {\n\tfunction f() {\n\t\tif (aa == null || bb == null || [alphaItemNameHere, betaItemNameHere, '
			+ 'gammaItemNameHere, deltaItemNameHere, epsilonItemName].indexOf(k) < 0) {\n\t\t\tdoWork();\n\t\t}\n\t}\n}';
		final opened: String = 'class C {\n\tfunction f() {\n\t\tif (\n\t\t\taa == null || bb == null || [\n'
			+ '\t\t\t\talphaItemNameHere,\n\t\t\t\tbetaItemNameHere,\n\t\t\t\tgammaItemNameHere,\n\t\t\t\tdeltaItemNameHere,'
			+ '\n\t\t\t\tepsilonItemName\n\t\t\t].indexOf(k) < 0\n\t\t) {\n\t\t\tdoWork();\n\t\t}\n\t}\n}';
		final opts: HxModuleWriteOptions = config;
		opts.finalNewline = false;
		Assert.equals(opened, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(flat), opts));
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
