package unit.check.oracle;

import anyparse.check.oracle.DefineReads;

/**
 * `DefineReads`: a source reads a define when code names it — a conditional-compilation directive above all — when a
 * define reader takes its name as a whole literal, and whenever it calls `getDefines`; a comment, a literal's text, the
 * declaration of `getDefines` and a call that sets the define read nothing, and a source that cannot be parsed counts as
 * a reader.
 */
@:nullSafety(Strict)
final class DefineReadsTest extends Test {

	private static final NAMES: Array<String> = ['keep-inline-positions'];

	@:pin('control')
	@:killer('M-DEFINE-READS-NONE')
	public function testADirectiveNamingTheDefineReadsIt(): Void {
		Assert.isTrue(reads('class A {\n\tstatic function f() {\n\t\t#if keep_inline_positions\n\t\ttrace(1);\n\t\t#end\n\t}\n}\n'));
		Assert.isTrue(reads('class A {\n\t#if (js && keep_inline_positions)\n\tstatic var x = 1;\n\t#end\n}\n'));
	}

	@:pin('control')
	@:killer('M-DEFINE-READS-LITERAL-ANYWHERE')
	public function testAReaderTakingTheNameAsAWholeLiteralReadsIt(): Void {
		Assert.isTrue(
			reads('class A {\n\tstatic function f() {\n\t\treturn haxe.macro.Context.defined(\'keep-inline-positions\');\n\t}\n}\n')
		);
		Assert.isTrue(reads('class A {\n\tstatic function f() {\n\t\treturn Compiler.getDefine( "keep_inline_positions" );\n\t}\n}\n'));
		Assert.isFalse(reads('class A {\n\tstatic final DEFINES = [\'keep-inline-positions\'];\n}\n'), 'a list of names reads none');
		Assert.isFalse(
			reads('class A {\n\tstatic final S = \'getDefine( "keep_inline_positions" )\';\n}\n'),
			'a reader quoted inside a longer literal is that literal\'s text'
		);
		Assert.isFalse(
			reads('class A {\n\tstatic function f() {\n\t\thaxe.macro.Compiler.define(\'keep-inline-positions\');\n\t}\n}\n'),
			'setting the define reads nothing'
		);
	}

	@:pin('control')
	@:killer('M-DEFINE-READS-ALL-DEFINES-DECLARED')
	public function testACallOfGetDefinesReadsEveryName(): Void {
		Assert.isTrue(reads('class A {\n\tstatic function f() {\n\t\treturn [for (k in Context.getDefines().keys()) k];\n\t}\n}\n'));
		Assert.isTrue(
			reads('class A {\n\tstatic function f() {\n\t\treturn \'$${Context.getDefines()}\';\n\t}\n}\n'), 'an interpolation is code'
		);
		Assert.isFalse(reads('class Context {\n\tpublic static function getDefines():Map<String, String> {\n\t\treturn [];\n\t}\n}\n'));
		Assert.isFalse(reads('class A {\n\tstatic final S = \'Context.getDefines().keys()\';\n}\n'), 'a literal\'s text reads nothing');
	}

	public function testACommentReadsNothing(): Void {
		Assert.isFalse(reads('// #if keep_inline_positions\nclass A {\n\t/** see getDefines() */\n\tstatic var x = 1;\n}\n'));
		Assert.isFalse(reads('class A {\n\tstatic var keep_inline_positionsx = 1;\n}\n'), 'a longer name is another word');
	}

	public function testAnUnparsableSourceCountsAsAReader(): Void {
		Assert.isTrue(reads('class A {\n\tstatic var x = "keep-inline-positions"\n'));
		Assert.isFalse(reads('class A {\n\tstatic var x = 1\n'), 'a source naming nothing is never parsed');
	}

	public function testBothSpellingsNameOneDefine(): Void {
		Assert.same(['keep-inline-positions', 'keep_inline_positions'], DefineReads.spellings('keep_inline_positions'));
		Assert.same(['js'], DefineReads.spellings('js'));
	}

	private static function reads(source: String): Bool {
		return DefineReads.reads(source, NAMES, new HaxeQueryPlugin());
	}

}
