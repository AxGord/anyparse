package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

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
 * the fork corpus does not move either way (delta-pass 0 / delta-fail 0 over 946 cases).
 */
@:nullSafety(Strict)
final class HxIfExprCondWrapSliceTest extends Test {

	private static final CONFIG: String =
		'{"wrapping": {"maxLineLength": 140, "opBoolChain": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "itemCount <= n", "value": 3}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "totalItemLength <= n", "value": 120}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}]}, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}, "sameLine": {"ifBody": "fitLine", "expressionIf": "next"}}';
	private static final EXPLODED: String =
		'class C {\n\tfunction f() {\n\t\trunWith((alphaArg:AlphaType, betaArg:BetaType) ->\n\t\t\tif (\n\t\t\t\tfoundId == -1 && (excludeId == -1 || betaArg.id != excludeId)\n\t\t\t\t&& (betaArg.title == nameNoExt || alphaArg.file + alphaArg.ext == fileName)\n\t\t\t) {\n\t\t\t\tfoundId = betaArg.id;\n\t\t\t}\n\t\t);\n\t}\n}';

	public function new(): Void {
		super();
	}

	public function testArrowBodyIfOverflowChainExplodesCond(): Void {
		final flat: String =
			'class C {\n\tfunction f() {\n\t\trunWith((alphaArg:AlphaType, betaArg:BetaType) -> if (foundId == -1 && (excludeId == -1 || betaArg.id != excludeId) && (betaArg.title == nameNoExt || alphaArg.file + alphaArg.ext == fileName)) {\n\t\t\tfoundId = betaArg.id;\n\t\t});\n\t}\n}';
		Assert.equals(EXPLODED, triviaWrite(flat));
	}

	public function testExplodedSourceIsIdempotent(): Void {
		Assert.equals(EXPLODED, triviaWrite(EXPLODED));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
