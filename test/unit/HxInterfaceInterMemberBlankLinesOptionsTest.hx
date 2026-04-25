package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-iface-interblank — interface-specific inter-member blank-line counts.
 *
 * Same Var/Fn/transition matrix as `HxInterMemberBlankLinesOptionsTest`
 * but routed through the dedicated `interfaceBetweenVars`,
 * `interfaceBetweenFunctions`, `interfaceAfterVars` knobs on
 * `HxModuleWriteOptions`. Defaults are all `0` (matching haxe-formatter's
 * `InterfaceFieldsEmptyLinesConfig`), so plain interface bodies stay
 * tight regardless of member kind.
 *
 * The interface knobs are independent of the class/abstract knobs —
 * tightening the interface body cannot bleed into class output, and
 * loosening the class body cannot bleed into interfaces. The
 * orthogonality assertion below codifies that boundary.
 */
@:nullSafety(Strict)
class HxInterfaceInterMemberBlankLinesOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testInterfaceDefaultsAreZero():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(0, defaults.interfaceBetweenVars);
		Assert.equals(0, defaults.interfaceBetweenFunctions);
		Assert.equals(0, defaults.interfaceAfterVars);
	}

	public function testInterfaceBetweenFunctionsZeroKeepsTight():Void {
		final out:String = writeWith(
			'interface I { public function a():Void; public function b():Void; }',
			0, 0, 0
		);
		Assert.isTrue(out.indexOf('a():Void;\n\tpublic function b') != -1,
			'expected no blank line between two interface functions with defaults in: <$out>');
	}

	public function testInterfaceBetweenFunctionsOneInsertsBlank():Void {
		final out:String = writeWith(
			'interface I { public function a():Void; public function b():Void; }',
			0, 1, 0
		);
		Assert.isTrue(out.indexOf('a():Void;\n\n\tpublic function b') != -1,
			'expected blank line between two interface functions with interfaceBetweenFunctions=1 in: <$out>');
	}

	public function testInterfaceBetweenVarsOneInsertsBlank():Void {
		final out:String = writeWith(
			'interface I { public var a:Int; public var b:Int; }',
			1, 0, 0
		);
		Assert.isTrue(out.indexOf('var a:Int;\n\n\tpublic var b') != -1,
			'expected blank line between two interface vars with interfaceBetweenVars=1 in: <$out>');
	}

	public function testInterfaceAfterVarsOneInsertsBlankOnVarToFunction():Void {
		final out:String = writeWith(
			'interface I { public var a:Int; public function b():Void; }',
			0, 0, 1
		);
		Assert.isTrue(out.indexOf('var a:Int;\n\n\tpublic function b') != -1,
			'expected blank line at interface var-to-function transition with interfaceAfterVars=1 in: <$out>');
	}

	public function testInterfaceAfterVarsOneInsertsBlankOnFunctionToVar():Void {
		final out:String = writeWith(
			'interface I { public function a():Void; public var b:Int; }',
			0, 0, 1
		);
		Assert.isTrue(out.indexOf('a():Void;\n\n\tpublic var b') != -1,
			'expected blank line at interface function-to-var transition with interfaceAfterVars=1 in: <$out>');
	}

	public function testClassKnobsDoNotAffectInterface():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.betweenFunctions = 5;
		opts.afterVars = 5;
		final out:String = HaxeModuleTriviaWriter.write(
			HaxeModuleTriviaParser.parse('interface I { public function a():Void; public function b():Void; }'),
			opts
		);
		Assert.isTrue(out.indexOf('a():Void;\n\tpublic function b') != -1,
			'expected interface body to stay tight when only class betweenFunctions/afterVars are set in: <$out>');
	}

	public function testInterfaceKnobsDoNotAffectClass():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.interfaceBetweenVars = 5;
		opts.interfaceBetweenFunctions = 5;
		opts.interfaceAfterVars = 5;
		final out:String = HaxeModuleTriviaWriter.write(
			HaxeModuleTriviaParser.parse('class M { public var a:Int; public var b:Int; }'),
			opts
		);
		Assert.isTrue(out.indexOf('var a:Int;\n\tpublic var b') != -1,
			'expected class body to stay tight when only interface knobs are set in: <$out>');
	}

	public function testConfigLoaderMapsInterfaceBetweenFunctionsInt():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"interfaceEmptyLines": {"betweenFunctions": 2}}}'
		);
		Assert.equals(2, opts.interfaceBetweenFunctions);
	}

	public function testConfigLoaderMapsInterfaceBetweenVarsInt():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"interfaceEmptyLines": {"betweenVars": 3}}}'
		);
		Assert.equals(3, opts.interfaceBetweenVars);
	}

	public function testConfigLoaderMapsInterfaceAfterVarsInt():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"interfaceEmptyLines": {"afterVars": 4}}}'
		);
		Assert.equals(4, opts.interfaceAfterVars);
	}

	public function testConfigLoaderMissingSectionKeepsInterfaceDefaults():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(0, opts.interfaceBetweenVars);
		Assert.equals(0, opts.interfaceBetweenFunctions);
		Assert.equals(0, opts.interfaceAfterVars);
	}

	public function testConfigLoaderInterfaceSectionLeavesClassUntouched():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"interfaceEmptyLines": {"betweenFunctions": 2, "afterVars": 4}}}'
		);
		Assert.equals(0, opts.betweenVars);
		Assert.equals(1, opts.betweenFunctions);
		Assert.equals(1, opts.afterVars);
	}

	public function testConfigLoaderClassSectionLeavesInterfaceUntouched():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"classEmptyLines": {"betweenFunctions": 5, "afterVars": 5, "betweenVars": 5}}}'
		);
		Assert.equals(0, opts.interfaceBetweenVars);
		Assert.equals(0, opts.interfaceBetweenFunctions);
		Assert.equals(0, opts.interfaceAfterVars);
	}

	private inline function writeWith(src:String, ifaceBetweenVars:Int, ifaceBetweenFunctions:Int, ifaceAfterVars:Int):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.interfaceBetweenVars = ifaceBetweenVars;
		opts.interfaceBetweenFunctions = ifaceBetweenFunctions;
		opts.interfaceAfterVars = ifaceAfterVars;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}
}
