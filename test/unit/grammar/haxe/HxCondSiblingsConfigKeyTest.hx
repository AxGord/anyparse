package unit.grammar.haxe;

import anyparse.format.SiblingPolicy;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * `sameLine.conditionalSiblings` in `hxformat.json` sets `HxModuleWriteOptions.conditionalSiblings`, with the same
 * values as `sameLine.caseSiblings`: `anyBreak` (the default) shares one break decision across the branches of a
 * `#if` region, `off` lets each branch decide alone.
 */
final class HxCondSiblingsConfigKeyTest extends Test {

	private static final SRC: String = 'class C {\n\t#if a var r:Int; #else var s:Int; var t:Int; #end\n}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-COND-SIBLINGS-KEY-IGNORED')
	public function testOffKeyLoadsAsOff(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"conditionalSiblings": "off"}}');
		Assert.equals(SiblingPolicy.Off, opts.conditionalSiblings);
	}

	@:pin('control')
	@:killer('M-COND-SIBLINGS-KEY-IGNORED')
	public function testOffKeyLetsEachBranchDecideAlone(): Void {
		Assert.equals(
			'class C {\n\t#if a var r:Int; #else\n\tvar s:Int;\n\tvar t:Int;\n\t#end\n}\n',
			write('{"sameLine": {"conditionalSiblings": "off"}}')
		);
	}

	@:pin('guard')
	public function testAnyBreakKeyAndTheDefaultShareTheBranches(): Void {
		final shared: String = 'class C {\n\t#if a\n\tvar r:Int;\n\t#else\n\tvar s:Int;\n\tvar t:Int;\n\t#end\n}\n';
		Assert.equals(shared, write('{"sameLine": {"conditionalSiblings": "anyBreak"}}'));
		Assert.equals(shared, write('{}'));
		Assert.equals(
			SiblingPolicy.AnyBreak,
			HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"conditionalSiblings": "anyBreak"}}').conditionalSiblings
		);
	}

	private static function write(json: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(SRC), HaxeFormatConfigLoader.loadHxFormatJson(json));
	}

}
