package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * Under the default object-literal cascade a literal of simple fields that overflows only because of what stands before it
 * breaks at its braces and fills its fields on one line inside; a literal the cascade measures as complex keeps one field per line.
 */
@:nullSafety(Strict)
class HxObjectLitSimpleFieldsFillTest extends Test {

	private static final HINT: String =
		'final found: { ids: Array<String>, chains: Map<String, Array<String>>, waivers: Array<String> } = ';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-OBJECT-LIT-SIMPLE-FILL')
	public function testSimpleFieldsFillOneLineInsideTheBrokenBraces(): Void {
		final out: String = write('$HINT{ ids: ids, chains: _chains, waivers: _waivers };');
		Assert.isTrue(
			out.indexOf(' = {\n\t\t\tids: ids, chains: _chains, waivers: _waivers\n\t\t};') != -1,
			'expected the simple fields on one line inside the braces in:\n<$out>'
		);
	}

	@:pin('control')
	@:killer('M-OBJECT-LIT-SIMPLE-FILL')
	public function testSimpleFieldsFillIsAFixedPoint(): Void {
		final once: String = write('$HINT{ ids: ids, chains: _chains, waivers: _waivers };');
		Assert.isTrue(
			once.indexOf('\t\t\tids: ids, chains: _chains, waivers: _waivers\n') != -1, 'expected the packed fields in:\n<$once>'
		);
		Assert.equals(once, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(once), options()));
	}

	@:pin('guard')
	public function testComplexFieldsStayOnePerLine(): Void {
		final out: String = write('$HINT{ ids: ids, chains: _chains, waivers: Math.round((Timer.stamp() - _phaseSince) * 10) / 10 };');
		Assert.isTrue(out.indexOf('\t\t\tids: ids,\n\t\t\tchains: _chains,\n') != -1, 'expected one field per line in:\n<$out>');
	}

	private static function write(statement: String): String {
		return HaxeModuleTriviaWriter.write(
			HaxeModuleTriviaParser.parse('class C {\n\tfunction f():Void {\n\t\t$statement\n\t}\n}'), options()
		);
	}

	private static function options(): HxModuleWriteOptions {
		return HxWriteOptionsKit.strictJson('{"wrapping": {"maxLineLength": 120}}');
	}

}
