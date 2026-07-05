package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-ternary-collection-hug: a ternary whose SOLE multi-line branch is a bare
 * collection literal (`{…}` / `[…]`) or a block expression — while the
 * condition and the OTHER branch render flat — HUGS: `cond ? A : {` rides the
 * head/assignment line and the collection self-breaks, rather than leading-
 * breaking the whole ternary. The hug fires only when that head FITS the line;
 * an overflowing head keeps the leading-break-all shape.
 *
 * Positives: a multi-line ELSE object, a multi-line THEN object, a multi-line
 * ELSE array, and a block-expression ELSE all hug. Negatives (held at the
 * leading-break-all shape): a head that overflows the line, BOTH branches
 * multi-line, and a branch that is an opAdd CHAIN built around a collection
 * (`{…} + tail`). Control: a short all-flat ternary stays inline.
 */
@:nullSafety(Strict)
final class HxTernaryCollectionHugSliceTest extends Test {

	private static final CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}}';

	public function new(): Void {
		super();
	}

	public function testElseObjectHeadFitsHugs(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tresult = flag ? {name: \'alpha\', ok: true} : {\n\t\t\tname: \'bravo\',\n\t\t\tok: false\n\t\t};\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testThenObjectHugs(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tresult = flag ? {\n\t\t\tname: \'alpha\',\n\t\t\tok: true\n\t\t} : {name: \'bravo\', ok: false};\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testElseArrayHugs(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tresult = flag ? shortValue : [\n\t\t\talphaVeryLongItemNameHereToForceBreak,\n\t\t\tbravoVeryLongItemNameHereToForceBreak,\n\t\t\tcharlieVeryLongItemNameHereToForceBreak,\n\t\t\tdeltaVeryLongItemNameHereToForceBreak\n\t\t];\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testElseBlockExprHugs(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tvar present = gateCond ? matchLit(ctx, trailText) : {\n\t\t\texpectLit(ctx, trailText);\n\t\t\ttrue;\n\t\t};\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testHeadExceedsLeadingBreaks(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tresultVariableWithAnExtremelyLongDescriptiveName = someConditionFlagWithAnEquallyLongDescriptiveIdentifierNameHere\n\t\t\t? scalarThenBranchValue\n\t\t\t: {\n\t\t\t\tname: \'bravo\',\n\t\t\t\tok: false\n\t\t\t};\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testBothBranchesMultilineLeadingBreak(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tresult = flag\n\t\t\t? {\n\t\t\t\talpha: \'one\',\n\t\t\t\tbeta: \'two\'\n\t\t\t}\n\t\t\t: {\n\t\t\t\tname: \'bravo\',\n\t\t\t\tok: false\n\t\t\t};\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testOpAddChainBranchLeadingBreaks(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tresult = flag\n\t\t\t? shortValue\n\t\t\t: {\n\t\t\t\tname: \'bravo\',\n\t\t\t\tok: false\n\t\t\t}\n\t\t\t\t+ tail;\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testShortFlatTernaryInline(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tresult = flag ? shortThen : shortElse;\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
