package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * Under the default array-literal cascade, object-literal elements of one shape are laid out alike: an array that fits stays on
 * one line, one that overflows where it starts moves whole to a continuation line where it fits, and one too wide for that breaks
 * by its own cascade with every element flat, never its first element alone through a `[{` hug.
 */
@:nullSafety(Strict)
class HxArrayObjectElementsAlikeTest extends Test {

	private static final HINT: String = 'final targets: Array<{ node: QueryNode, parent: Null<QueryNode> }> = ';
	private static final WIDE_CONFIG: String = '{"wrapping": {"maxLineLength": 120}}';
	private static final NARROW_CONFIG: String = '{"wrapping": {"maxLineLength": 80}}';
	private static final CALL_CONFIG: String = '{"wrapping": {"maxLineLength": 120, "callParameter": {"defaultWrap": '
		+ '"fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, '
		+ '{"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}}}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-ARRAY-OVERFLOW-BY-FIRST-LINE')
	@:killer('M-ARRAY-CONTAINER-ITEMS-FIT-GUARD')
	public function testOverflowingArrayMovesWholeAfterTheAssign(): Void {
		final out: String = write('$HINT[{ node: regionNN, parent: tree }, { node: memberNN, parent: regionNN }];');
		Assert.isTrue(
			out.indexOf(' =\n\t\t\t[{node: regionNN, parent: tree}, {node: memberNN, parent: regionNN}];') != -1,
			'expected the array whole on the line after `=` in:\n<$out>'
		);
	}

	@:pin('guard')
	public function testMovedWholeArrayIsAFixedPoint(): Void {
		final once: String = write('$HINT[{ node: regionNN, parent: tree }, { node: memberNN, parent: regionNN }];');
		Assert.equals(once, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(once), options()));
	}

	@:pin('control')
	@:killer('M-ARRAY-OVERFLOW-BY-FIRST-LINE')
	public function testSoleArgumentArrayMovesWholeInsideTheParens(): Void {
		final out: String = write(
			"final equivalence: KindEquivalence = new KindEquivalence([['ClassDecl', 'ClassForm'], ['FnMember', 'FinalModifiedMember']]);",
			CALL_CONFIG
		);
		Assert.isTrue(
			out.indexOf("new KindEquivalence(\n\t\t\t[['ClassDecl', 'ClassForm'], ['FnMember', 'FinalModifiedMember']]\n\t\t);") != -1,
			'expected the array whole on its own line inside the parens in:\n<$out>'
		);
	}

	@:pin('guard')
	public function testArrayTooWideForItsContinuationBreaksItselfNotItsFirstElement(): Void {
		final out: String = write(
			'$HINT[{node: regionNNNNNNNN, parent: treeeeeeeeeeeeee}, {node: memberNNNNNNNN, parent: regionNNNNN}];', NARROW_CONFIG
		);
		Assert.isTrue(
			out.indexOf(
				' = [\n\t\t\t{node: regionNNNNNNNN, parent: treeeeeeeeeeeeee},\n\t\t\t{node: memberNNNNNNNN, parent: regionNNNNN}\n\t\t];'
			) != -1,
			'expected the array broken with both elements flat in:\n<$out>'
		);
	}

	@:pin('guard')
	public function testFittingArrayStaysOnOneLine(): Void {
		final out: String = write('final t = [{ node: regionNN, parent: tree }, { node: memberNN, parent: regionNN }];');
		Assert.isTrue(
			out.indexOf('final t = [{node: regionNN, parent: tree}, {node: memberNN, parent: regionNN}];') != -1,
			'expected the array on one line in:\n<$out>'
		);
	}

	@:pin('control')
	@:killer('M-ARRAY-SINGLE-ITEM-HUG')
	public function testOverflowingSingleObjectElementKeepsTheHug(): Void {
		final out: String = write('$HINT[{node: regionNN, parent: treeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee}];');
		Assert.isTrue(out.indexOf(' = [{\n') != -1 && out.indexOf('\n\t\t}];') != -1, 'expected the `[{` hug kept in:\n<$out>');
	}

	@:pin('guard')
	public function testOverflowingArrayOfAtomsMovesWholeToTheNextLine(): Void {
		final out: String = write(
			'final statementBraceTerminalKinds: Array<String> = ['
			+ "'BlockExpr', 'ObjectLit', 'ArrayExpr', 'DollarBlockExpr', 'DollarReifExpr', 'Is'];"
		);
		Assert.isTrue(
			out.indexOf(" =\n\t\t\t['BlockExpr', 'ObjectLit', 'ArrayExpr', 'DollarBlockExpr', 'DollarReifExpr', 'Is'];") != -1,
			'expected the array flat on the line after `=` in:\n<$out>'
		);
	}

	private static function write(statement: String, ?config: String): String {
		return HaxeModuleTriviaWriter.write(
			HaxeModuleTriviaParser.parse('class C {\n\tfunction f():Void {\n\t\t$statement\n\t}\n}'), options(config)
		);
	}

	private static function options(?config: String): HxModuleWriteOptions {
		return HxWriteOptionsKit.strictJson(config ?? WIDE_CONFIG);
	}

}
