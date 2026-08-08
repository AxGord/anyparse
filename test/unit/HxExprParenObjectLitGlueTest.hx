package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * omega-ternary-paren-glue follow-up: an expression paren whose inner is an OBJECT LITERAL keeps its delimiters GLUED
 * (`({` ... `})`) instead of exploding into `(\n\t{...}\n)`.
 *
 * `WrapList.isTopLevelTernary` used to accept a depth-1 `?` OR `:`, so an object literal - whose field separator IS `:` -
 * was misread as a ternary and routed to the ternary arm of the expr-paren cascade. That arm opens the paren as soon as
 * `expressionWrapping` carries a fillLine-family mode, so the very same literal rendered glued on the universal default
 * and exploded under a TM-shaped config. Requiring BOTH separators sends a `:`-only inner to the generic
 * `IfFullLineExceeds(open, glued)` arm, where `Renderer.collapseParenCommitsOpen` keeps the paren glued because the
 * literal cannot be made a single fitting line.
 *
 * Every object-literal fixture is asserted on BOTH configs: the glue is config-independent, matching the sibling
 * array-literal inner (no depth-1 `:`) that glued on every config already. A real ternary - `?` AND `:` at depth 1 -
 * still opens the paren under the fillLine config, which is what fails first if the predicate is over-broadened.
 */
@:nullSafety(Strict)
final class HxExprParenObjectLitGlueTest extends Test {

	/** TM-shaped config: tab indent, `maxLineLength` 140, packed-or-one-per-line collections, fillLine `expressionWrapping`. */
	private static final FILL_LINE: String = '{"indentation": {"character": "tab", "tabWidth": 4},'
		+ ' "wrapping": {"maxLineLength": 140, "comprehensionCuddledOpen": true,'
		+ ' "objectLiteral": {"defaultWrap": "ignore", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "packedOrOnePerLine"}]},'
		+ ' "arrayWrap": {"defaultWrap": "ignore", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "packedOrOnePerLine"}]},'
		+ ' "expressionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}},'
		+ ' "sameLine": {"ifBody": "fitLine", "expressionIf": "next", "comprehensionFor": "fitLine"}}';

	/** Same config with `wrapping.expressionWrapping` absent - the universal default (`NoWrap`) cascade. */
	private static final DEFAULT_WRAP: String = '{"indentation": {"character": "tab", "tabWidth": 4},'
		+ ' "wrapping": {"maxLineLength": 140, "comprehensionCuddledOpen": true,'
		+ ' "objectLiteral": {"defaultWrap": "ignore", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "packedOrOnePerLine"}]},'
		+ ' "arrayWrap": {"defaultWrap": "ignore", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "packedOrOnePerLine"}]}},'
		+ ' "sameLine": {"ifBody": "fitLine", "expressionIf": "next", "comprehensionFor": "fitLine"}}';

	/** Exploded `(\n\t{...}\n)` parens in the three positions a paren-wrapped literal reaches: decl init, call arg, `return`. */
	private static final POSITIONS_EXPLODED: String = 'class C {\n' + '\tfunction test() {\n' + '\t\tfinal declValue = (\n' + '\t\t\t{\n'
		+ '\t\t\t\tcaptionValue: elementValue.captionValue,\n' + '\t\t\t\tdetailValue: elementValue.detailValue,\n'
		+ '\t\t\t\tidentityValue: elementValue.identityValue,\n' + '\t\t\t\taddressValue: elementValue.addressValue,\n'
		+ '\t\t\t\taccessValue: VIEWVALUE,\n' + '\t\t\t\tpictureValue: elementValue.pictureValue\n' + '\t\t\t}\n' + '\t\t);\n'
		+ '\t\tconsumeCollectedValue((\n' + '\t\t\t{\n' + '\t\t\t\tcaptionValue: elementValue.captionValue,\n'
		+ '\t\t\t\tdetailValue: elementValue.detailValue,\n' + '\t\t\t\tidentityValue: elementValue.identityValue,\n'
		+ '\t\t\t\taddressValue: elementValue.addressValue,\n' + '\t\t\t\taccessValue: VIEWVALUE,\n'
		+ '\t\t\t\tpictureValue: elementValue.pictureValue\n' + '\t\t\t}\n' + '\t\t));\n' + '\t\treturn (\n' + '\t\t\t{\n'
		+ '\t\t\t\tcaptionValue: elementValue.captionValue,\n' + '\t\t\t\tdetailValue: elementValue.detailValue,\n'
		+ '\t\t\t\tidentityValue: elementValue.identityValue,\n' + '\t\t\t\taddressValue: elementValue.addressValue,\n'
		+ '\t\t\t\taccessValue: VIEWVALUE,\n' + '\t\t\t\tpictureValue: elementValue.pictureValue\n' + '\t\t\t}\n' + '\t\t);\n' + '\t}\n'
		+ '}';

	/** The same three positions with the paren glued to the literal's braces. */
	private static final POSITIONS_GLUED: String = 'class C {\n' + '\tfunction test() {\n' + '\t\tfinal declValue = ({\n'
		+ '\t\t\tcaptionValue: elementValue.captionValue,\n' + '\t\t\tdetailValue: elementValue.detailValue,\n'
		+ '\t\t\tidentityValue: elementValue.identityValue,\n' + '\t\t\taddressValue: elementValue.addressValue,\n'
		+ '\t\t\taccessValue: VIEWVALUE,\n' + '\t\t\tpictureValue: elementValue.pictureValue\n' + '\t\t});\n'
		+ '\t\tconsumeCollectedValue(({\n' + '\t\t\tcaptionValue: elementValue.captionValue,\n'
		+ '\t\t\tdetailValue: elementValue.detailValue,\n' + '\t\t\tidentityValue: elementValue.identityValue,\n'
		+ '\t\t\taddressValue: elementValue.addressValue,\n' + '\t\t\taccessValue: VIEWVALUE,\n'
		+ '\t\t\tpictureValue: elementValue.pictureValue\n' + '\t\t}));\n' + '\t\treturn ({\n'
		+ '\t\t\tcaptionValue: elementValue.captionValue,\n' + '\t\t\tdetailValue: elementValue.detailValue,\n'
		+ '\t\t\tidentityValue: elementValue.identityValue,\n' + '\t\t\taddressValue: elementValue.addressValue,\n'
		+ '\t\t\taccessValue: VIEWVALUE,\n' + '\t\t\tpictureValue: elementValue.pictureValue\n' + '\t\t});\n' + '\t}\n' + '}';

	/** The reported TM shape: a comprehension filter body wrapping its object literal in parens, exploded. */
	private static final COMPREHENSION_EXPLODED: String = 'class SharePanelStore {\n'
		+ '\tpublic function getNotAddedItems(addedItems:SharePanelUserList):SharePanelUserList {\n' + '\t\treturn {\n'
		+ '\t\t\tfirst: [ for (user in _store.ActiveUnits)\n'
		+ '\t\t\t\tif (!addedItems.first.exists((u:SharePanelCoachEntries) -> u.email == user.Email))\n' + '\t\t\t\t\t(\n'
		+ '\t\t\t\t\t\t{\n' + '\t\t\t\t\t\t\tfirstname: user.Firstname,\n' + '\t\t\t\t\t\t\tlastname: user.Lastname,\n'
		+ '\t\t\t\t\t\t\tid: user.UserId,\n' + '\t\t\t\t\t\t\temail: user.Email,\n' + '\t\t\t\t\t\t\taccess: VIEW,\n'
		+ '\t\t\t\t\t\t\timage: user.Image\n' + '\t\t\t\t\t\t}\n' + '\t\t\t\t\t)\n' + '\t\t\t]\n' + '\t\t};\n' + '\t}\n' + '}';

	/** The same comprehension with the filter body's paren glued. */
	private static final COMPREHENSION_GLUED: String = 'class SharePanelStore {\n'
		+ '\tpublic function getNotAddedItems(addedItems:SharePanelUserList):SharePanelUserList {\n' + '\t\treturn {\n'
		+ '\t\t\tfirst: [ for (user in _store.ActiveUnits)\n'
		+ '\t\t\t\tif (!addedItems.first.exists((u:SharePanelCoachEntries) -> u.email == user.Email))\n' + '\t\t\t\t\t({\n'
		+ '\t\t\t\t\t\tfirstname: user.Firstname,\n' + '\t\t\t\t\t\tlastname: user.Lastname,\n' + '\t\t\t\t\t\tid: user.UserId,\n'
		+ '\t\t\t\t\t\temail: user.Email,\n' + '\t\t\t\t\t\taccess: VIEW,\n' + '\t\t\t\t\t\timage: user.Image\n' + '\t\t\t\t\t})\n'
		+ '\t\t\t]\n' + '\t\t};\n' + '\t}\n' + '}';

	/** A real ternary inner, written flat past `maxLineLength`. */
	private static final TERNARY_FLAT: String = 'class C {\n' + '\tfunction test() {\n'
		+ '\t\tfinal ternaryValue = (someConditionValueNameThatIsQuiteLong ? firstAlternativeValueNameLongEnough : secondAlternativeValueNameThatIsLongEnoughHere);\n'
		+ '\t}\n' + '}';

	/** The ternary inner opens its paren: content on its own line at +1, `)` back at statement indent. */
	private static final TERNARY_OPENED: String = 'class C {\n' + '\tfunction test() {\n' + '\t\tfinal ternaryValue = (\n'
		+ '\t\t\tsomeConditionValueNameThatIsQuiteLong ? firstAlternativeValueNameLongEnough : secondAlternativeValueNameThatIsLongEnoughHere\n'
		+ '\t\t);\n' + '\t}\n' + '}';

	/** An array-literal inner, written flat past `maxLineLength`. */
	private static final ARRAY_FLAT: String = 'class C {\n' + '\tfunction test() {\n'
		+ '\t\tfinal arrayValue = ([firstElementValueNameLonger, secondElementValueNameLonger, thirdElementValueNameLonger, fourthElementValueNameLonger, fifthElementValueNameLonger, sixthElementValueNameLonger]);\n'
		+ '\t}\n' + '}';

	/** The array-literal inner breaks INSIDE its own brackets, paren glued on both sides. */
	private static final ARRAY_GLUED: String = 'class C {\n' + '\tfunction test() {\n' + '\t\tfinal arrayValue = ([\n'
		+ '\t\t\tfirstElementValueNameLonger,\n' + '\t\t\tsecondElementValueNameLonger,\n' + '\t\t\tthirdElementValueNameLonger,\n'
		+ '\t\t\tfourthElementValueNameLonger,\n' + '\t\t\tfifthElementValueNameLonger,\n' + '\t\t\tsixthElementValueNameLonger\n'
		+ '\t\t]);\n' + '\t}\n' + '}';

	public function new(): Void {
		super();
	}

	/** All three positions collapse to the glued form under the fillLine config - the shape this slice restores. */
	public function testObjectLitGluesInEveryExprPosition(): Void {
		Assert.equals(POSITIONS_GLUED, triviaWrite(POSITIONS_EXPLODED, FILL_LINE));
	}

	/** The universal-default cascade produces the SAME glued form - the two configs no longer disagree on this shape. */
	public function testGlueIsConfigIndependent(): Void {
		Assert.equals(POSITIONS_GLUED, triviaWrite(POSITIONS_EXPLODED, DEFAULT_WRAP));
	}

	/** The glued layout is a fixed point (a second write does not re-explode it). */
	public function testGluedLayoutIsIdempotent(): Void {
		Assert.equals(POSITIONS_GLUED, triviaWrite(POSITIONS_GLUED, FILL_LINE));
	}

	/** The reported comprehension-filter-body shape glues, keeping the literal's fields one level below the `if`. */
	public function testComprehensionFilterBodyGlues(): Void {
		Assert.equals(COMPREHENSION_GLUED, triviaWrite(COMPREHENSION_EXPLODED, FILL_LINE));
	}

	/** Same comprehension on the universal-default cascade - identical output. */
	public function testComprehensionFilterBodyGluesOnDefaultCascade(): Void {
		Assert.equals(COMPREHENSION_GLUED, triviaWrite(COMPREHENSION_EXPLODED, DEFAULT_WRAP));
	}

	/**
	 * A REAL ternary inner (`?` AND `:` at depth 1) still OPENS the paren under the fillLine config - fork parity. This is
	 * the discriminator against over-broadening: dropping the `?` requirement collapses it to the glued form.
	 */
	public function testTernaryInnerStillOpensParen(): Void {
		Assert.equals(TERNARY_OPENED, triviaWrite(TERNARY_FLAT, FILL_LINE));
	}

	/** An array-literal inner (no depth-1 `:`) glues on both configs, as it always did - the fix must not disturb it. */
	public function testArrayLitInnerGluesOnBothConfigs(): Void {
		Assert.equals(ARRAY_GLUED, triviaWrite(ARRAY_FLAT, FILL_LINE));
		Assert.equals(ARRAY_GLUED, triviaWrite(ARRAY_FLAT, DEFAULT_WRAP));
	}

	private inline function triviaWrite(src: String, config: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(config);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
