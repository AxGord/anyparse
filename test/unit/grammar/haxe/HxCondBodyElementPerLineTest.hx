package unit.grammar.haxe;

import anyparse.format.SiblingPolicy;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * A `#if` region body separates its elements as its host list does outside the region: statements, members,
 * declarations, cases and enum constructors each take a line of their own, so a body of two or more opens and
 * closes on lines of its own whatever the source layout, and so does every branch of that region
 * (`conditionalSiblings`). A one-element body of a region no branch breaks keeps its source line.
 */
final class HxCondBodyElementPerLineTest extends Test {

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-COND-BODY-SOURCE-SEP')
	public function testStatementBodiesPutEachStatementOnItsLine(): Void {
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\t#if js\n\t\ta();\n\t\tb();\n\t\t#else\n\t\tc();\n\t\td();\n\t\t#end\n\t}\n}',
			HxWriteFixture.triviaWrite('class C {\n\tfunction f() {\n\t\t#if js a(); b(); #else c(); d(); #end\n\t}\n}', '{}')
		);
	}

	@:pin('control')
	@:killer('M-COND-BODY-SOURCE-SEP')
	public function testMemberAndEnumBodiesPutEachElementOnItsLine(): Void {
		Assert.equals(
			'class C {\n\t#if js\n\tvar x:Int;\n\tvar y:Int;\n\t#end\n}\n\nenum E {\n\t#if js\n\tA;\n\tB;\n\t#end\n}',
			HxWriteFixture.triviaWrite('class C {\n\t#if js var x:Int; var y:Int; #end\n}\n\nenum E {\n\t#if js A; B; #end\n}', '{}')
		);
	}

	@:pin('control')
	@:killer('M-COND-BODY-SOURCE-SEP')
	public function testDeclarationAndCaseBodiesPutEachElementOnItsLine(): Void {
		Assert.equals('#if js\nimport a.B;\nimport a.C;\n#end', HxWriteFixture.triviaWrite('#if js import a.B; import a.C; #end', '{}'));
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\tswitch (v) {\n\t\t\t#if js\n\t\t\tcase 1:\n\t\t\t\ta();\n\t\t\tcase 2:\n\t\t\t\tb();\n'
			+ '\t\t\t#end\n\t\t}\n\t}\n}',
			HxWriteFixture.triviaWrite(
				'class C {\n\tfunction f() {\n\t\tswitch (v) {\n\t\t\t#if js case 1: a(); case 2: b(); #end\n\t\t}\n\t}\n}', '{}'
			)
		);
	}

	@:pin('control')
	@:killer('M-COND-BODY-PAD-SOURCE')
	public function testABodyOfSeveralOpensAndClosesOnItsOwnLines(): Void {
		Assert.equals(
			'class C {\n\t#if js\n\tvar x:Int;\n\tvar y:Int;\n\t#end\n}',
			HxWriteFixture.triviaWrite('class C {\n\t#if js var x:Int;\n\tvar y:Int; #end\n}', '{}')
		);
	}

	@:pin('guard')
	public function testAOneElementBodyKeepsItsLine(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\t#if js a(); #end\n\t}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, '{}'));
	}

	@:pin('control')
	@:killer('M-COND-REGION-UNSHARED')
	public function testTheBranchesOfARegionShareTheirLines(): Void {
		Assert.equals(
			'class C {\n\t#if a\n\tvar r:Int;\n\t#else\n\tvar s:Int;\n\tvar t:Int;\n\t#end\n\n\tfunction f() {\n\t\t#if a\n\t\tfoo();\n'
			+ '\t\t#elseif b\n\t\tbar();\n\t\tbaz();\n\t\t#else\n\t\tqux();\n\t\t#end\n\t}\n}',
			HxWriteFixture.triviaWrite(
				'class C {\n\t#if a var r:Int; #else var s:Int; var t:Int; #end\n\n\tfunction f() {\n'
				+ '\t\t#if a foo(); #elseif b bar(); baz(); #else qux(); #end\n\t}\n}',
				'{}'
			)
		);
	}

	@:pin('control')
	@:killer('M-PAD-SLOT-NEVER-LEADS')
	public function testABranchBrokenByShapeMovesItsSiblings(): Void {
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\t#if a\n\t\tfoo();\n\t\t#else\n\t\tbar();\n\t\tbaz();\n\t\t#end\n\t}\n}',
			HxWriteFixture.triviaWrite('class C {\n\tfunction f() {\n\t\t#if a foo(); #else bar(); baz(); #end\n\t}\n}', '{}')
		);
	}

	@:pin('guard')
	public function testOffDecidesEachBranchAlone(): Void {
		final opts: HxModuleWriteOptions = HxWriteOptionsKit.strictJson('{}');
		opts.conditionalSiblings = SiblingPolicy.Off;
		Assert.equals(
			'class C {\n\t#if a var r:Int; #else\n\tvar s:Int;\n\tvar t:Int;\n\t#end\n}\n',
			HaxeModuleTriviaWriter.write(
				HaxeModuleTriviaParser.parse('class C {\n\t#if a var r:Int; #else var s:Int; var t:Int; #end\n}'), opts
			)
		);
	}

	@:pin('control')
	@:killer('M-SEMI-ELSEIF-PER-LINE')
	public function testAValueRegionElseifKeepsItsLine(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tx = #if a false; #elseif b log(); true; #else true; #end\n\t}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, '{}'));
	}

	@:pin('guard')
	public function testACommentLedFirstElementTakesOneBreak(): Void {
		final broken: String = '\t\t#else\n\t\tbar();\n\t\tbaz();\n\t\t#end\n\t}\n}';
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\t#if a\n\t\t// c\n\t\tfoo();\n$broken',
			HxWriteFixture.triviaWrite(
				'class C {\n\tfunction f() {\n\t\t#if a\n\t\t// c\n\t\tfoo();\n\t\t#else bar(); baz(); #end\n\t}\n}', '{}'
			)
		);
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\t#if a\n\t\t/* c */\n\t\tfoo();\n$broken',
			HxWriteFixture.triviaWrite('class C {\n\tfunction f() {\n\t\t#if a /* c */ foo(); #else bar(); baz(); #end\n\t}\n}', '{}')
		);
	}

	@:pin('guard')
	public function testATrailingLineCommentDoesNotVote(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\t#if a foo(); // t\n\t\t#else bar(); #end\n\t}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, '{}'));
	}

}
