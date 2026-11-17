package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * `wrapping.comprehensionFit` decouples a comprehension's layout from its bracket padding. Absent, it follows
 * `whitespace.bracketConfig.comprehensionBrackets` (the fork's `comprehensionFor: fitLine` coupling): padded
 * brackets take the fit cascade and hug a sole block body. `false` keeps the padding as whitespace only, so a
 * multi-line comprehension keeps `[` / `for` / `]` on their own lines; this repository formats under that.
 */
@:nullSafety(Strict)
final class HxComprehensionFitKeyTest extends Test {

	private static final PADDING: String =
		'"whitespace": {"bracketConfig": {"comprehensionBrackets": {"openingPolicy": "onlyAfter", "closingPolicy": "onlyBefore"}}}';
	private static final ABSENT: String =
		'{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}, $PADDING}';
	private static final OFF: String =
		'{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, "comprehensionFit": false}, $PADDING}';
	private static final OFF_FITLINE: String = '{"indentation": {"character": "tab", "tabWidth": 4},'
		+ ' "wrapping": {"maxLineLength": 140, "comprehensionFit": false}, "sameLine": {"comprehensionFor": "fitLine"}}';

	/** A block-body comprehension with the brackets on their own lines. */
	private static final BLOCK: String = 'class C {\n\tfunction f(xs:Array<Int>):Array<Int> {\n\t\tfinal a = [\n\t\t\tfor (x in xs) {\n'
		+ '\t\t\t\tfinal y = x + 1;\n\t\t\t\ty * 2;\n\t\t\t}\n\t\t];\n\t\treturn a;\n\t}\n}';

	/** The same comprehension hugging its brackets. */
	private static final HUGGED: String = 'class C {\n\tfunction f(xs:Array<Int>):Array<Int> {\n\t\tfinal a = [ for (x in xs) {\n'
		+ '\t\t\tfinal y = x + 1;\n\t\t\ty * 2;\n\t\t} ];\n\t\treturn a;\n\t}\n}';

	/** A comprehension whose item passes the generic array thresholds while its line fits `maxLineLength`. */
	private static final WIDE: String = 'class C {\n\tfunction f():Array<Int> {\n'
		+ '\t\treturn [for (elementValue in sourceCollectionValueName) computeEntryValueFrom(elementValue, extraArgument)];\n\t}\n}';

	private static final WIDE_FLAT: String = 'class C {\n\tfunction f():Array<Int> {\n'
		+ '\t\treturn [ for (elementValue in sourceCollectionValueName) computeEntryValueFrom(elementValue, extraArgument) ];\n\t}\n}';

	/** Tight comprehension, array literal and index access side by side. */
	private static final KINDS: String =
		'class C {\n\tfunction f(xs:Array<Int>):Array<Int> {\n\t\tfinal a = [1, 2];\n\t\treturn [for (x in xs) x + a[0]];\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** Absent, padded brackets hug a sole block body: the layout every config without the key had. */
	@:pin('control')
	@:killer('M-COMPR-HUG-ABSENT-NEVER')
	public function testPaddingWithKeyAbsentHugsTheBlockBody(): Void {
		Assert.equals(HUGGED, HxWriteFixture.triviaWrite(BLOCK, ABSENT));
	}

	/** `false`: the padding stays whitespace and the brackets keep their own lines. */
	@:pin('control')
	@:killer('M-COMPR-FIT-KEY-IGNORED')
	public function testPaddingWithKeyFalseKeepsTheBracketLines(): Void {
		Assert.equals(BLOCK, HxWriteFixture.triviaWrite(BLOCK, OFF));
		Assert.equals(BLOCK, HxWriteFixture.triviaWrite(HUGGED, OFF));
	}

	/** Absent, padded brackets take the fit cascade; `false` leaves the comprehension on the generic array cascade. */
	@:pin('control')
	@:killer('M-COMPR-FIT-CASCADE-PADDING-ONLY')
	public function testKeyFalseLeavesTheFitCascade(): Void {
		Assert.equals(WIDE_FLAT, HxWriteFixture.triviaWrite(WIDE, ABSENT));
		final off: String = HxWriteFixture.triviaWrite(WIDE, OFF);
		Assert.isTrue(off.indexOf('return [\n') != -1, 'expected the bracket to open in: <$off>');
	}

	/** Under `false` a flat comprehension is still padded, and the other bracket kinds stay tight. */
	@:pin('control')
	@:killer('M-COMPR-PAD-OPEN-DROPPED')
	public function testKeyFalsePadsOnlyTheComprehension(): Void {
		final out: String = HxWriteFixture.triviaWrite(KINDS, OFF);
		Assert.isTrue(out.indexOf('return [ for (x in xs) x + a[0] ];') != -1, 'expected a padded comprehension in: <$out>');
		Assert.isTrue(out.indexOf('final a = [1, 2];') != -1, 'expected a tight array literal in: <$out>');
	}

	/** An explicit `false` wins over `sameLine.comprehensionFor: fitLine`, which still pads the brackets. */
	@:pin('control')
	@:killer('M-COMPR-FIT-FITLINE-OVERRIDES')
	public function testKeyFalseWinsOverComprehensionForFitLine(): Void {
		Assert.equals(BLOCK, HxWriteFixture.triviaWrite(BLOCK, OFF_FITLINE));
		final out: String = HxWriteFixture.triviaWrite(KINDS, OFF_FITLINE);
		Assert.isTrue(out.indexOf('return [ for (x in xs) x + a[0] ];') != -1, 'expected a padded comprehension in: <$out>');
	}

}
