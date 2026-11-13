package unit.grammar.haxe;

import anyparse.format.ConditionalIndentationPolicy;
import anyparse.format.SiblingPolicy;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * A `#if` region body is written in one layout by both writers: the plain writer and the trivia writer put each
 * statement, member, declaration, case and enum constructor of a body on its own line, a body of two or more opens and
 * closes on lines of its own, and the branches of one region break together. Each fixture goes through both modes.
 */
final class HxCondBodyBothModesTest extends Test {

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-PLAIN-COND-BODY-JOIN')
	@:killer('M-PLAIN-COND-BODY-PAD')
	@:killer('M-PLAIN-COND-BODY-SEMI')
	public function testStatementBodies(): Void {
		bothModes(
			'class C {\n\tfunction f() {\n\t\t#if js\n\t\ta();\n\t\tb();\n\t\t#else\n\t\tc();\n\t\td();\n\t\t#end\n\t}\n}',
			'class C {\n\tfunction f() {\n\t\t#if js a(); b(); #else c(); d(); #end\n\t}\n}', defaults()
		);
	}

	@:pin('control')
	@:killer('M-PLAIN-COND-BODY-JOIN')
	@:killer('M-PLAIN-COND-BODY-PAD')
	public function testMemberAndEnumBodies(): Void {
		bothModes(
			'class C {\n\t#if js\n\tvar x:Int;\n\tvar y:Int;\n\t#end\n}\n\nenum E {\n\t#if js\n\tA;\n\tB;\n\t#end\n}',
			'class C {\n\t#if js var x:Int; var y:Int; #end\n}\n\nenum E {\n\t#if js A; B; #end\n}', defaults()
		);
	}

	/** The plain writer glues a case body to its label inside a region and outside it alike, so only the cases' lines are compared. */
	@:pin('control')
	@:killer('M-PLAIN-COND-BODY-JOIN')
	@:killer('M-PLAIN-COND-BODY-PAD')
	public function testDeclarationAndCaseBodies(): Void {
		bothModes('#if js\nimport a.B;\nimport a.C;\n#end', '#if js import a.B; import a.C; #end', defaults());
		final src: String = 'class C {\n\tfunction f() {\n\t\tswitch (v) {\n\t\t\t#if js case 1: a(); case 2: b(); #end\n\t\t}\n\t}\n}';
		final head: String = 'class C {\n\tfunction f() {\n\t\tswitch (v) {\n\t\t\t#if js\n';
		final tail: String = '\t\t\t#end\n\t\t}\n\t}\n}';
		Assert.equals('$head\t\t\tcase 1:\n\t\t\t\ta();\n\t\t\tcase 2:\n\t\t\t\tb();\n$tail', HxWriteFixture.triviaWrite(src, defaults()));
		Assert.equals('$head\t\t\tcase 1:a();\n\t\t\tcase 2:b();\n$tail', HxWriteFixture.plainWrite(src, defaults()));
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\tswitch (v) {\n\t\t\tcase 1:a();\n\t\t\tcase 2:b();\n\t\t}\n\t}\n}',
			HxWriteFixture.plainWrite(
				'class C {\n\tfunction f() {\n\t\tswitch (v) {\n\t\t\tcase 1: a(); case 2: b();\n\t\t}\n\t}\n}', defaults()
			)
		);
	}

	@:pin('control')
	@:killer('M-PLAIN-COND-PAD-UNSHARED')
	@:killer('M-COND-REGION-UNSHARED')
	public function testTheBranchesOfARegionShareTheirLines(): Void {
		bothModes(
			'class C {\n\tfunction f() {\n\t\t#if a\n\t\tfoo();\n\t\t#else\n\t\tbar();\n\t\tbaz();\n\t\t#end\n\t}\n}',
			'class C {\n\tfunction f() {\n\t\t#if a foo(); #else bar(); baz(); #end\n\t}\n}', defaults()
		);
	}

	@:pin('guard')
	public function testOffDecidesEachBranchAlone(): Void {
		final opts: HxModuleWriteOptions = defaults();
		opts.conditionalSiblings = SiblingPolicy.Off;
		bothModes(
			'class C {\n\t#if a var r:Int; #else\n\tvar s:Int;\n\tvar t:Int;\n\t#end\n}',
			'class C {\n\t#if a var r:Int; #else var s:Int; var t:Int; #end\n}', opts
		);
	}

	@:pin('guard')
	public function testAOneElementBodyKeepsTheMarkerLine(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\t#if js a(); #else b(); #end\n\t}\n}';
		bothModes(src, src, defaults());
	}

	@:pin('control')
	@:killer('M-PLAIN-COND-BODY-INDENT')
	public function testAnIncreasingPolicyNestsTheBody(): Void {
		final opts: HxModuleWriteOptions = defaults();
		opts.conditionalPolicy = ConditionalIndentationPolicy.AlignedIncrease;
		bothModes(
			'class C {\n\tfunction f() {\n\t\t#if js\n\t\t\ta();\n\t\t\tb();\n\t\t#end\n\t}\n}',
			'class C {\n\tfunction f() {\n\t\t#if js a(); b(); #end\n\t}\n}', opts
		);
	}

	@:pin('control')
	@:killer('M-PLAIN-COND-INDENT-GLUED')
	public function testAnIncreasingPolicyLeavesAGluedBodyAsWritten(): Void {
		final opts: HxModuleWriteOptions = defaults();
		opts.conditionalPolicy = ConditionalIndentationPolicy.AlignedIncrease;
		final src: String = 'class C {\n\tfunction f() {\n\t\tg(#if js function() {\n\t\t\ta();\n\t\t}, b #end);\n\t}\n}';
		bothModes(src, src, opts);
	}

	private function defaults(): HxModuleWriteOptions {
		return HaxeFormatConfigLoader.loadHxFormatJson('{}');
	}

	private function bothModes(expected: String, src: String, opts: HxModuleWriteOptions): Void {
		final trivia: String = HxWriteFixture.triviaWrite(src, opts);
		final plain: String = HxWriteFixture.plainWrite(src, opts);
		Assert.equals(expected, trivia, 'trivia wrote:\n$trivia');
		Assert.equals(expected, plain, 'plain wrote:\n$plain');
	}

}
