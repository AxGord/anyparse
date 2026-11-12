package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * `enumAbstractEmptyLines.abstractRulesUnlessValueList` reads a `#if` region of an `enum abstract` body through the
 * members it holds, in any branch: a member beyond a value makes the body live by the `abstractEmptyLines` rules, a
 * region of plain values does not.
 */
@:nullSafety(Strict)
class HxEnumAbstractCondMemberTest extends Test {

	private static inline final ON: String = '{"emptyLines":{'
		+ '"enumAbstractEmptyLines":{"beginType":0,"betweenVars":0,"existingBetweenFields":"remove","abstractRulesUnlessValueList":true},'
		+ '"abstractEmptyLines":{"beginType":1,"endType":1}}}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-COND-MEMBER-THEN-UNREAD')
	public function testAMethodInTheThenBranchTriggers(): Void {
		Assert.equals(
			'enum abstract T(Int) {\n\n\tvar A = 1;\n\t#if x\n\tvar B = 2;\n\n\tfunction f() {}\n\t#end\n\n}\n',
			write('enum abstract T(Int) {\n\tvar A = 1;\n\t#if x\n\tvar B = 2;\n\n\tfunction f() {}\n\t#end\n}\n')
		);
	}

	@:pin('control')
	@:killer('M-COND-MEMBER-ELSE-UNREAD')
	public function testAMethodInTheElseBranchTriggers(): Void {
		Assert.equals(
			'enum abstract T(Int) {\n\n\tvar A = 1;\n\t#if x\n\tvar B = 2;\n\t#else\n\tfunction f() {}\n\t#end\n\n}\n',
			write('enum abstract T(Int) {\n\tvar A = 1;\n\t#if x\n\tvar B = 2;\n\t#else\n\tfunction f() {}\n\t#end\n}\n')
		);
	}

	@:pin('control')
	@:killer('M-COND-MEMBER-ELSEIF-UNREAD')
	public function testAMethodInAnElseifBranchTriggers(): Void {
		Assert.equals(
			'enum abstract T(Int) {\n\n\tvar A = 1;\n\t#if x\n\tvar B = 2;\n\t#elseif y\n\tfunction f() {}\n\t#end\n\n}\n',
			write('enum abstract T(Int) {\n\tvar A = 1;\n\t#if x\n\tvar B = 2;\n\t#elseif y\n\tfunction f() {}\n\t#end\n}\n')
		);
	}

	@:pin('control')
	@:killer('M-COND-REGION-ALWAYS-BEYOND')
	public function testARegionOfValuesIsNoTrigger(): Void {
		Assert.equals(
			'enum abstract T(Int) {\n\tvar A = 1;\n\t#if x\n\tvar B = 2;\n\t#else\n\tvar C = 3;\n\t#end\n}\n',
			write('enum abstract T(Int) {\n\tvar A = 1;\n\n\t#if x\n\tvar B = 2;\n\t#else\n\tvar C = 3;\n\t#end\n}\n')
		);
	}

	private function write(src: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HxWriteOptionsKit.strictJson(ON));
	}

}
