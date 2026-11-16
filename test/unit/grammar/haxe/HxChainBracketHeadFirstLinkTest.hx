package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A chain that breaks per link treats the dot after an array-literal or comprehension head as a seam like the others: the head
 * keeps its own line and the first link breaks below it, instead of gluing to `]` and paren-breaking its argument once the glued
 * line overflows. A path head (`xs.concat(a)`) keeps its first link glued — its dot is not a chain item.
 */
@:nullSafety(Strict)
final class HxChainBracketHeadFirstLinkTest extends Test {

	/** Tab indent, 140 columns, the `callParameter` cascade whose overflow answer is a leading break inside the parens. */
	private static final CONFIG: String = '{"indentation":{"character":"tab","tabWidth":4},"wrapping":{"maxLineLength":140,'
		+ '"methodChainCuddledLinks":true,"comprehensionCuddledOpen":true,"callParameter":{"defaultWrap":"fillLineWithLeadingBreak",'
		+ '"rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},'
		+ '{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],"type":"noWrap"}]}}}';

	/** Four comprehension links; head + first link fit one line, the whole chain does not. */
	private static final COMPREHENSION_SRC: String = 'class A {\n\tfunction f() {\n'
		+ '\t\treturn [for (col in 0...lastCol) new P(0, col)].concat([for (row in 0...lastRow) new P(row, lastCol)]).concat([for ('
		+ 'col in 0...lastCol) new P(lastRow, lastCol - col)]).concat([for (row in 0...lastRow) new P(lastRow - row, 0)]);\n\t}\n}';

	private static final COMPREHENSION_EXP: String = 'class A {\n\tfunction f() {\n\t\treturn [for (col in 0...lastCol) new P(0, col)]\n'
		+ '\t\t\t.concat([for (row in 0...lastRow) new P(row, lastCol)])\n\t\t\t.concat([for (col in 0...lastCol) '
		+ 'new P(lastRow, lastCol - col)])\n\t\t\t.concat([for (row in 0...lastRow) new P(lastRow - row, 0)]);\n\t}\n}';

	/** The first link's argument is wide enough that head + link overflow the line: the link breaks away, the argument stays whole. */
	private static final OVERWIDE_SRC: String = 'class A {\n\tfunction f() {\n\t\treturn [for (col in 0...lastCol) '
		+ 'new P(0, col)].concat([for (row in 0...lastRow) new P(row, '
		+ 'lastColxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx)]).concat([for (col in 0...lastCol) new P(lastRow, '
		+ 'lastCol - col)]).concat([for (row in 0...lastRow) new P(lastRow - row, 0)]);\n\t}\n}';

	private static final OVERWIDE_EXP: String = 'class A {\n\tfunction f() {\n\t\treturn [for (col in 0...lastCol) new P(0, col)]\n'
		+ '\t\t\t.concat([for (row in 0...lastRow) new P(row, lastColxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx)])\n\t\t\t.concat([for ('
		+ 'col in 0...lastCol) new P(lastRow, lastCol - col)])\n\t\t\t.concat([for (row in 0...lastRow) new P(lastRow - row, 0)]);\n\t}\n}';

	/** A plain array literal head breaks the same way. */
	private static final LITERAL_SRC: String = 'class A {\n\tfunction f() {\n'
		+ '\t\treturn [alphaElementValue, betaElementValue].concat(gammaListValueNameLong).concat(deltaListValueNameLong)'
		+ '.concat(epsilonListValueNameLong).concat(zetaListValueNameLong).concat(etaListValueNameLongest);\n\t}\n}';

	private static final LITERAL_EXP: String = 'class A {\n\tfunction f() {\n\t\treturn [alphaElementValue, betaElementValue]\n'
		+ '\t\t\t.concat(gammaListValueNameLong)\n\t\t\t.concat(deltaListValueNameLong)\n'
		+ '\t\t\t.concat(epsilonListValueNameLong)\n\t\t\t.concat(zetaListValueNameLong)\n'
		+ '\t\t\t.concat(etaListValueNameLongest);\n\t}\n}';

	/** CONTROL: an identifier head keeps its first link glued (its dot follows no `)`), only the later links break. */
	private static final IDENT_SRC: String = 'class A {\n\tfunction f() {\n'
		+ '\t\treturn alphaCollection.concat(gammaListValueNameLong).concat(deltaListValueNameLong).concat(epsilonListValueNameLong)'
		+ '.concat(zetaListValueNameLong).concat(etaListValueNameLongest).concat(thetaListValueNameLongest);\n\t}\n}';

	private static final IDENT_EXP: String = 'class A {\n\tfunction f() {\n\t\treturn alphaCollection.concat(gammaListValueNameLong)\n'
		+ '\t\t\t.concat(deltaListValueNameLong)\n\t\t\t.concat(epsilonListValueNameLong)\n'
		+ '\t\t\t.concat(zetaListValueNameLong)\n\t\t\t.concat(etaListValueNameLongest)\n'
		+ '\t\t\t.concat(thetaListValueNameLongest);\n\t}\n}';

	/** CONTROL: a chain that fits one line is untouched. */
	private static final FITS: String = 'class A {\n\tfunction f() {\n'
		+ '\t\treturn [for (col in 0...lastCol) new P(0, col)].concat([for (row in 0...lastRow) new P(row, 0)]).concat(tail);\n\t}\n}';

	/** A bare field access leads the first link (`].length.toString()`): the head still stands alone and the field belongs to that link. */
	private static final FIELD_SRC: String = 'class A {\n\tfunction f() {\n\t\treturn [for (col in 0...lastCol) '
		+ 'new P(0, col)].length.toString().concat([for (row in 0...lastRow) new P(row, lastCol)].join(\',\'))'
		+ '.concat([for (col in 0...lastCol) new P(lastRow, lastCol - col)].join(\',\')).concat(zzzzzzzzzzzzz);\n\t}\n}';

	private static final FIELD_EXP: String = 'class A {\n\tfunction f() {\n\t\treturn [for (col in 0...lastCol) new P(0, col)]\n'
		+ '\t\t\t.length.toString()\n\t\t\t.concat([for (row in 0...lastRow) new P(row, lastCol)].join(\',\'))\n'
		+ '\t\t\t.concat([for (col in 0...lastCol) new P(lastRow, lastCol - col)].join(\',\'))\n'
		+ '\t\t\t.concat(zzzzzzzzzzzzz);\n\t}\n}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-CHAIN-ARRAY-HEAD-GLUED')
	public function testComprehensionHeadFirstLinkIsASeam(): Void {
		Assert.equals(COMPREHENSION_EXP, write(COMPREHENSION_SRC));
	}

	@:pin('control')
	@:killer('M-CHAIN-ARRAY-HEAD-GLUED')
	public function testOverwideFirstLinkBreaksAwayWithItsArgumentWhole(): Void {
		Assert.equals(OVERWIDE_EXP, write(OVERWIDE_SRC));
	}

	@:pin('control')
	@:killer('M-CHAIN-ARRAY-HEAD-GLUED')
	public function testArrayLiteralHeadFirstLinkIsASeam(): Void {
		Assert.equals(LITERAL_EXP, write(LITERAL_SRC));
	}

	@:pin('control')
	@:killer('M-CHAIN-PATH-HEAD-SEAM')
	public function testIdentHeadKeepsFirstLinkGlued(): Void {
		Assert.equals(IDENT_EXP, write(IDENT_SRC));
	}

	@:pin('guard')
	public function testFittingChainStaysOnOneLine(): Void {
		Assert.equals(FITS, write(FITS));
	}

	@:pin('control')
	@:killer('M-CHAIN-ARRAY-HEAD-GLUED')
	public function testSeamLayoutsAreFixedPoints(): Void {
		Assert.equals(COMPREHENSION_EXP, write(COMPREHENSION_EXP));
		Assert.equals(OVERWIDE_EXP, write(OVERWIDE_EXP));
		Assert.equals(LITERAL_EXP, write(LITERAL_EXP));
		Assert.equals(IDENT_EXP, write(IDENT_EXP));
	}

	/** The plain writer reaches the same chain walk without trivia slots; both twins must agree. */
	@:pin('control')
	@:killer('M-CHAIN-ARRAY-HEAD-GLUED-PLAIN')
	public function testPlainWriterAgrees(): Void {
		Assert.equals(COMPREHENSION_EXP, HxWriteFixture.plainWrite(COMPREHENSION_SRC, CONFIG));
	}

	@:pin('control')
	@:killer('M-CHAIN-ARRAY-FIELD-HEAD-GLUED')
	public function testBareFieldLedFirstLinkIsASeam(): Void {
		Assert.equals(FIELD_EXP, write(FIELD_SRC));
		Assert.equals(FIELD_EXP, write(FIELD_EXP));
	}

	@:pin('control')
	@:killer('M-CHAIN-ARRAY-FIELD-HEAD-GLUED-PLAIN')
	public function testBareFieldLedFirstLinkIsASeamInThePlainWriter(): Void {
		Assert.equals(FIELD_EXP, HxWriteFixture.plainWrite(FIELD_SRC, CONFIG));
	}

	private inline function write(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
