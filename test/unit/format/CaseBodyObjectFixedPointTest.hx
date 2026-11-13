package unit.format;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * A `caseBody: fitLine` branch whose body is a call holding a source-flat object
 * literal under a cascade with a `totalItemLength` `noWrap` shadow: the literal
 * fits the rule, the glued case line does not fit the width. One writer round trip
 * must land on the fixed point — the literal broken one-per-line, glued after `case`.
 */
@:nullSafety(Strict)
class CaseBodyObjectFixedPointTest extends Test {

	private static final CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4, '
		+ '"alignInlineSwitchCaseBody": true}, "sameLine": {"caseBody": "fitLine", "expressionCase": "fitLine"}, '
		+ '"wrapping": {"maxLineLength": 140, "objectLiteral": {"defaultWrap": "onePerLine", "rules": [{"conditions": '
		+ '[{"cond": "totalItemLength <= n", "value": 140}], "type": "noWrap"}]}}}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-CASE-BODY-LITERAL-OFFER-OFF')
	public function testTryItemLiteralSettlesInOneWrite(): Void {
		assertOneWrite(
			'cfg.zips.push({ path: try StringTools.trim(xml.innerData) catch (_: Any) \'\', file: xml.att.file, '
			+ 'rm: xml.isTrue(\'rm\'), log: !xml.isFalse(\'log\') });',
			'case \'zip\': cfg.zips.push({\n\t\t\t\tpath: try StringTools.trim(xml.innerData) catch (_:Any) \'\',\n'
		);
	}

	@:pin('control')
	@:killer('M-CASE-BODY-LITERAL-OFFER-OFF')
	public function testPlainItemLiteralSettlesInOneWrite(): Void {
		final longName: String = [for (_ in 0...47) 'x'].join('');
		assertOneWrite(
			'cfg.zips.push({path: xml.innerData$longName, file: xml.att.file, rm: xml.isTrue(\'rm\'), log: !xml.isFalse(\'log\')});',
			'case \'zip\': cfg.zips.push({\n\t\t\t\tpath: xml.innerData$longName,\n'
		);
	}

	private static function assertOneWrite(body: String, glued: String): Void {
		final src: String = 'class C {\n\tfunction readNode(xml: Fast): Void {\n\t\tswitch xml.name {\n\t\t\tcase \'zip\':\n\t\t\t\t$body\n'
			+ '\t\t\tcase _:\n\t\t\t\tsuper.readNode(xml);\n\t\t}\n\t}\n}';
		final once: String = write(src);
		final twice: String = write(once);
		Assert.isTrue(twice.indexOf(glued) != -1, 'the settled shape must break the literal glued after `case`, got:\n<$twice>');
		Assert.equals(twice, once, 'one round trip must land on the fixed point');
	}

	private static function write(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
