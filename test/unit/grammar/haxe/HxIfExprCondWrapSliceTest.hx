package unit.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.format.SameLinePolicy;
import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrappingLocation;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * An expression-position `if` (arrow-function body) whose condition is a
 * top-level boolean chain that overflows `maxLineLength` EXPLODES the
 * condition paren (`if (\n\toperands\n) {`), identically to a statement `if`.
 *
 * Before the fix `HxIfExpr.cond` lacked `@:fmt(condWrap('conditionWrap'))`
 * (which `HxIfStmt` / `HxWhileStmt` / `HxForStmt` all carry), so an
 * overflowing expression-if condition fill-wrapped the `&&` chain at the
 * `if` indent with the paren GLUED. Config mirrors the divergent
 * `ifBody:fitLine` + `expressionIf:next` shape under which the bug manifests.
 *
 * The arrow itself now breaks BEFORE the condition does
 * (omega-arrowif-blockbody-width): a body whose construct head cannot render flat where it
 * would glue moves to the continuation line, so the exploded condition renders one level
 * deeper than it did when this fixture was written. The property under test is unchanged —
 * the condition paren still explodes rather than fill-wrapping with the paren glued — and
 * the fork corpus does not move either way.
 */
@:nullSafety(Strict)
final class HxIfExprCondWrapSliceTest extends Test {

	private static final CONFIG: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
		edited.lineWidth = 140;
		edited.sameLineExpressionElse = SameLinePolicy.SameOnBlock;
		edited.ifBody = BodyPolicy.FitLine;
		edited.expressionIfBody = BodyPolicy.Next;
		edited.expressionElseBody = BodyPolicy.Next;
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
	private static final EXPLODED: String = 'class C {\n\tfunction f() {\n\t\trunWith((alphaArg:AlphaType, betaArg:BetaType) ->\n'
		+ '\t\t\tif (\n\t\t\t\tfoundId == -1 && (excludeId == -1 || betaArg.id != excludeId)\n'
		+ '\t\t\t\t&& (betaArg.title == nameNoExt || alphaArg.file + alphaArg.ext == fileName)\n'
		+ '\t\t\t) {\n\t\t\t\tfoundId = betaArg.id;\n\t\t\t}\n\t\t);\n\t}\n}';

	public function new(): Void {
		super();
	}

	@:pin('guard')
	public function testArrowBodyIfOverflowChainExplodesCond(): Void {
		final flat: String = 'class C {\n\tfunction f() {\n'
			+ '\t\trunWith((alphaArg:AlphaType, betaArg:BetaType) -> if (foundId == -1 && (excludeId == -1 || betaArg.id != excludeId) && ('
			+ 'betaArg.title == nameNoExt || alphaArg.file + alphaArg.ext == fileName)) {\n\t\t\tfoundId = betaArg.id;\n\t\t});\n\t}\n}';
		Assert.equals(EXPLODED, triviaWrite(flat));
	}

	@:pin('guard')
	public function testExplodedSourceIsIdempotent(): Void {
		Assert.equals(EXPLODED, triviaWrite(EXPLODED));
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
