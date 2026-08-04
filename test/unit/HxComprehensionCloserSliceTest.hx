package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-comprehension-closer: a comprehension body is a BLOCK body — the shape
 * whose `}` the closing `]` may ride (`[ for (…) {` … `} ]`) — only when the
 * `{` is GLUED to the generator head. Before this slice the test was the
 * item's last token alone (`lastVisibleText == '}'`), so every EXPRESSION body
 * that merely ENDS in a curly read as a block: a macro reification
 * (`macro if (…) $p{['sourceObject', f.slot]}`), a ternary whose else-branch
 * is an object literal, a trailing `switch`. Those took the head-hug shape and
 * got their `]` glued to a BODY line at body indent — while the sibling
 * comprehension one screen up, whose body happened to end in `)`, dropped its
 * `]` to container indent. Two canonical closers for one construct.
 *
 * Width does not enter the decision on either side of the fix (both shapes fit
 * `maxLineLength` comfortably), and neither does the body's line COUNT — a
 * two-continuation-line body with a curly tail glued exactly like a one-line
 * one (`testTwoLineReifiedBodyAlsoDropsCloser` pins that direction).
 *
 * Byte-inert for genuine block bodies (`HxComprehensionBlockHugSliceTest`,
 * `HxComprehensionCuddledOpenTest.testBlockBodyComprehensionKeepsBlockHug`)
 * and for comprehensions that fit one line
 * (`…CuddledOpenTest.testFittingComprehensionStaysFlat`, plus the curly-tailed
 * variant pinned here).
 *
 * Every fixture literal here is DOUBLE-quoted: the reified bodies carry `$p{`
 * / `$v{`, which a single-quoted Haxe literal would try to interpolate.
 */
@:nullSafety(Strict)
final class HxComprehensionCloserSliceTest extends Test {

	/** TM-shaped config with `wrapping.comprehensionCuddledOpen` ON — the regime TM formats under. */
	private static final ON: String = '{"indentation": {"character": "tab", "tabWidth": 4},'
		+ ' "wrapping": {"maxLineLength": 140, "comprehensionCuddledOpen": true},'
		+ ' "sameLine": {"ifBody": "fitLine", "expressionIf": "next", "comprehensionFor": "fitLine"}}';

	/** Same config with the cuddled-open knob absent — the pre-knob leading-break regime. */
	private static final OFF: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140},'
		+ ' "sameLine": {"ifBody": "fitLine", "expressionIf": "next", "comprehensionFor": "fitLine"}}';

	/** The reported shape (anonymised from a macro-generating build macro): reified body, curly tail, `];` glued to the body line. */
	private static final REIFIED_GLUED: String = "class C {\n" + "\tfunction test() {\n"
		+ "\t\tfinal resultList = [ for (fieldEntry in fieldEntryCollection)\n"
		+ "\t\t\tmacro if ($p{['sourceObject', fieldEntry.slot]} != null) $p{[fieldEntry.slot]} = $p{['sourceObject', fieldEntry.slot]} ];\n"
		+ "\t}\n" + "}";

	/** Same comprehension with the closer on its own line at the declaration's indent — head-glue kept. */
	private static final REIFIED_OWN_LINE: String = "class C {\n" + "\tfunction test() {\n"
		+ "\t\tfinal resultList = [ for (fieldEntry in fieldEntryCollection)\n"
		+ "\t\t\tmacro if ($p{['sourceObject', fieldEntry.slot]} != null) $p{[fieldEntry.slot]} = $p{['sourceObject', fieldEntry.slot]}\n"
		+ "\t\t];\n" + "\t}\n" + "}";

	public function new(): Void {
		super();
	}

	/**
	 * The reported site: a reification-tailed body is an EXPRESSION body, so its `]` drops to the opener's indent. The head-glue
	 * `= [ for (…)` is untouched — only the closer moves.
	 */
	public function testReifiedBraceTailComprehensionDropsCloser(): Void {
		Assert.equals(REIFIED_OWN_LINE, triviaWrite(REIFIED_GLUED, ON));
	}

	/** The new layout is a fixed point — re-writing it does not pull the closer back up. */
	public function testReifiedCloserLayoutIsIdempotent(): Void {
		Assert.equals(REIFIED_OWN_LINE, triviaWrite(REIFIED_OWN_LINE, ON));
	}

	/**
	 * The rule is not macro-specific: a plain ternary whose else-branch is an object literal has the same curly tail and the same
	 * expression body, so it gets the same closer.
	 */
	public function testPlainExprBraceTailComprehensionDropsCloser(): Void {
		final src: String = "class C {\n" + "\tfunction test() {\n"
			+ "\t\tfinal resultList = [ for (elementValue in sourceCollectionValue)\n"
			+ "\t\t\tresolveCaption(elementValue) == null ? fallbackDescriptor : {caption: elementValue.caption, detail: elementValue.detail} ];\n"
			+ "\t}\n" + "}";
		final expected: String = "class C {\n" + "\tfunction test() {\n"
			+ "\t\tfinal resultList = [ for (elementValue in sourceCollectionValue)\n"
			+ "\t\t\tresolveCaption(elementValue) == null ? fallbackDescriptor : {caption: elementValue.caption, detail: elementValue.detail}\n"
			+ "\t\t];\n" + "\t}\n" + "}";
		Assert.equals(expected, triviaWrite(src, ON));
	}

	/**
	 * The body's line COUNT is not the gate. A curly-tailed body that renders across TWO continuation lines glued its closer exactly
	 * like the one-line body above — so the fix must move this one too, not just the single-line case.
	 */
	public function testTwoLineReifiedBodyAlsoDropsCloser(): Void {
		final src: String = "class C {\n" + "\tfunction test() {\n" + "\t\tfinal resultList = [ for (fieldEntry in fieldEntryCollection)\n"
			+ "\t\t\tmacro if (checkEntryIsAssignable(sourceObject, fieldEntry.slot, fallbackDescriptorValue, comparisonStrategyValue)) $p{[fieldEntry.slot]} = $p{['sourceObject', fieldEntry.slot]} ];\n"
			+ "\t}\n" + "}";
		final expected: String = "class C {\n" + "\tfunction test() {\n"
			+ "\t\tfinal resultList = [ for (fieldEntry in fieldEntryCollection)\n"
			+ "\t\t\tmacro if (checkEntryIsAssignable(sourceObject, fieldEntry.slot, fallbackDescriptorValue, comparisonStrategyValue))\n"
			+ "\t\t\t\t$p{[fieldEntry.slot]} = $p{['sourceObject', fieldEntry.slot]}\n" + "\t\t];\n" + "\t}\n" + "}";
		Assert.equals(expected, triviaWrite(src, ON));
	}

	/** The precedent this slice converges on: a body ending in `)` already dropped its closer and must stay byte-identical. */
	public function testNonBraceTailBodyCloserUnchanged(): Void {
		final src: String = "class C {\n" + "\tfunction test() {\n" + "\t\tfinal resultList = [ for (fieldEntry in fieldEntryCollection)\n"
			+ "\t\t\tmacro o.put($v{fieldEntry.tag}, resolveEntryValue(sourceObject, fieldEntry.slot, fallbackDescriptorValue, strategyValue))\n"
			+ "\t\t];\n" + "\t}\n" + "}";
		Assert.equals(src, triviaWrite(src, ON));
	}

	/** A curly-tailed comprehension that FITS one line never reaches either shape (no hardline) — byte-identical. */
	public function testFittingBraceTailComprehensionStaysFlat(): Void {
		final src: String = "class C {\n" + "\tfunction test() {\n"
			+ "\t\tfinal resultList = [ for (fieldEntry in fieldEntryCollection) macro $p{[fieldEntry.slot]} ];\n" + "\t}\n" + "}";
		Assert.equals(src, triviaWrite(src, ON));
	}

	/**
	 * Knob OFF, same misclassification: the curly tail used to buy a head-hug that the pre-knob regime grants no other expression
	 * body. It now leading-breaks like every one of them.
	 */
	public function testKnobOffBraceTailLeadingBreaks(): Void {
		final expected: String = "class C {\n" + "\tfunction test() {\n" + "\t\tfinal resultList = [\n"
			+ "\t\t\tfor (fieldEntry in fieldEntryCollection)\n"
			+ "\t\t\t\tmacro if ($p{['sourceObject', fieldEntry.slot]} != null) $p{[fieldEntry.slot]} = $p{['sourceObject', fieldEntry.slot]}\n"
			+ "\t\t];\n" + "\t}\n" + "}";
		Assert.equals(expected, triviaWrite(REIFIED_GLUED, OFF));
	}

	private inline function triviaWrite(src: String, config: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(config);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
