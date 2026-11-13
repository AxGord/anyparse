package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * omega-fill-literal-run — a run of consecutive collection arguments is ONE
 * unit of a call's argument fill: it joins the arguments before it when it
 * fits there, else starts its own line, and in both cases ends its line; a
 * run wider than a line keeps one collection per line.
 */
@:nullSafety(Strict)
final class HxFillLiteralRunTest extends Test {

	private static final CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, '
		+ '"callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}, '
		+ '"whitespace": {"bracesConfig": {"objectLiteralBraces": {"openingPolicy": "after", "closingPolicy": "before"}}}}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-RUN-MEMBERS-SPLIT')
	public function testARunThatFitsJoinsTheArgumentsBeforeIt(): Void {
		Assert.equals(
			'\t\tregister(\n\t\t\tfirstArgumentValue, { x: make(1) }, { y: make(2) }, { z: make(3) },\n'
			+ '\t\t\tsecondArgumentValue, thirdArgumentValue, fourth, fifthArgumentValueX\n\t\t);',
			call(
				'firstArgumentValue, {x: make(1)}, {y: make(2)}, {'
				+ 'z: make(3)}, secondArgumentValue, thirdArgumentValue, fourth, fifthArgumentValueX'
			)
		);
	}

	@:pin('control')
	@:killer('M-RUN-HEAD-GREEDY')
	@:killer('M-RUN-NO-LINE-END')
	public function testARunThatDoesNotFitAfterThemStartsAndEndsItsOwnLine(): Void {
		final first: String = 'firstArgumentValueLongLongLongLongLongLongLongLongLongLongLongLongLongLongLongLongLongLongLong';
		Assert.equals(
			'\t\tregister(\n\t\t\t$first,\n\t\t\t{ x: make(1) }, { y: make(2) }, { z: make(3) },\n'
			+ '\t\t\tsecondArgumentValue, thirdArgumentValue, fourth, fifthArgumentValueX\n\t\t);',
			call('$first, {x: make(1)}, {y: make(2)}, {z: make(3)}, secondArgumentValue, thirdArgumentValue, fourth, fifthArgumentValueX')
		);
	}

	@:pin('control')
	@:killer('M-RUN-NO-PER-LINE')
	public function testARunWiderThanALineKeepsOneCollectionPerLine(): Void {
		Assert.equals(
			'\t\tregister(\n\t\t\tfirstArgumentValue, { xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx: make(1) },\n'
			+ '\t\t\t{ yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy: make(2) },\n'
			+ '\t\t\t{ zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz: make(3) }, secondArgumentValue, third\n\t\t);',
			call(
				'firstArgumentValue, {xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx: make(1)}, {yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy: make(2)}, '
				+ '{zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz: make(3)}, secondArgumentValue, third'
			)
		);
	}

	@:pin('guard')
	public function testASingleLiteralKeepsTheAfterCollectionRule(): Void {
		Assert.equals(
			'\t\tregister(\n\t\t\tfirstArgumentValue, { x: make(1) },\n\t\t\tsecondArgumentValue, thirdArgumentValue, '
			+ 'fourthArgumentValue, fifthArgumentValue, sixthArgument, seventh, eighth\n\t\t);',
			call(
				'firstArgumentValue, {x: make(1)}, secondArgumentValue, thirdArgumentValue, fourthArgumentValue, fifthArgumentValue, '
				+ 'sixthArgument, seventh, eighth'
			)
		);
	}

	@:pin('guard')
	public function testALiteralLastArgumentTakesTheNextLine(): Void {
		Assert.equals(
			'\t\tregister(\n\t\t\tfirstArgumentValue, secondArgumentValue, thirdArgumentValue, '
			+ 'fourthArgumentValueXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX, fifth,\n\t\t\t{ x: make(1) }\n\t\t);',
			call(
				'firstArgumentValue, secondArgumentValue, thirdArgumentValue, fourthArgumentValueXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX, '
				+ 'fifth, {x: make(1)}'
			)
		);
	}

	@:pin('guard')
	public function testAPlainRunThatFitsTheCallStaysFlat(): Void {
		Assert.equals(
			'\t\tregister(firstArgumentValue, { x: 1 }, { y: 2 }, {'
			+ ' z: 3 }, secondArgumentValue, thirdArgumentValue, fourthArgumentValue, fifthArg);',
			call('firstArgumentValue, {x: 1}, {y: 2}, {z: 3}, secondArgumentValue, thirdArgumentValue, fourthArgumentValue, fifthArg')
		);
	}

	/** The written `register(<args>);` statement, its line(s) only. */
	private static function call(args: String): String {
		final opts: HxModuleWriteOptions = HxWriteOptionsKit.strictJson(CONFIG);
		final out: String = HaxeModuleTriviaWriter.write(
			HaxeModuleTriviaParser.parse('class C {\n\tfunction f() {\n\t\tregister($args);\n\t}\n}'), opts
		);
		final from: Int = out.indexOf('\t\tregister(');
		return out.substring(from, out.indexOf(');', from) + 2);
	}

}
