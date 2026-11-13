package unit.format;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * A value-`if` whose `expressionIf: next` branch is an object literal holding an
 * array of a literal, under an object cascade with a `totalItemLength` `noWrap`
 * shadow and an `arrayWrap` cascade whose pivot sits under the array's item. One
 * writer round trip must land on the fixed point — the inner literal one-per-line.
 */
@:nullSafety(Strict)
class ValueIfBranchObjectFixedPointTest extends Test {

	private static final CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, '
		+ '"sameLine": {"ifBody": "fitLine", "expressionIf": "next"}, "wrapping": {"maxLineLength": 140, '
		+ '"objectLiteral": {"defaultWrap": "onePerLine", "rules": [{"conditions": [{"cond": "totalItemLength <= n", '
		+ '"value": 140}], "type": "noWrap"}]}, "arrayWrap": {"defaultWrap": "noWrap", "rules": [{"conditions": '
		+ '[{"cond": "hasMultilineItems", "value": 1}], "type": "onePerLine"}, {"conditions": [{"cond": '
		+ '"totalItemLength <= n", "value": 80}], "type": "noWrap"}, {"conditions": [{"cond": "anyItemLength >= n", '
		+ '"value": 30}], "type": "onePerLine"}]}}}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-REDECIDED-LITERAL-OFFER-OFF')
	public function testValueIfBranchLiteralSettlesInOneWrite(): Void {
		final src: String = 'class C {\n\tfunction f(): Void {\n\t\tfinal v = if (staticDIVar != null)\n\t\t\t{ expr: EVars([\n'
			+ '\t\t\t\t{ name: staticDIVar.varName, type: TPath({ pack: [], name: \'Null\', params: [TPType(t)] }), expr: macro null, '
			+ 'isFinal: false }\n\t\t\t]), pos: Context.currentPos() }\n\t\telse\n\t\t\tcheckExpr(x);\n\t}\n}';
		final once: String = write(src);
		final twice: String = write(once);
		Assert.isTrue(
			twice.indexOf('\t\t\t{expr: EVars([\n\t\t\t\t{\n\t\t\t\t\tname: staticDIVar.varName,\n') != -1,
			'the settled shape must break the inner literal one-per-line, got:\n<$twice>'
		);
		Assert.equals(twice, once, 'one round trip must land on the fixed point');
	}

	private static function write(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
