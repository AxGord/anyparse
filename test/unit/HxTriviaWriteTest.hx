package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

/**
 * ω₅ — end-to-end Trivia-mode write tests. Validates that the writer
 * consumes `Trivial<T>` wrappers produced by the ω₄d parser and emits
 * captured leading/trailing comments plus blank-line separators
 * preserving round-trip fidelity for single-line-comment inputs.
 *
 * Block-style comment round-trip is intentionally lossy until ω₆ adds
 * style/placement policy knobs — a multi-line block stays block, but a
 * single-line block (`/* x *\/`) gets written as a line comment (`//
 * x`) by the auto-style heuristic in `leadingCommentDoc`. Tests that
 * cover this explicitly document the expected output shape.
 */
class HxTriviaWriteTest extends Test {

	private static final _forceBuild:Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	public function testLeadingLineCommentRoundTrip():Void {
		final source:String = '// hello world\nclass Foo {}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('// hello world\nclass Foo {}\n', out);
	}

	public function testMultipleLeadingLineComments():Void {
		final source:String = '// first\n// second\nclass Foo {}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('// first\n// second\nclass Foo {}\n', out);
	}

	public function testTrailingLineCommentOnClassMember():Void {
		final source:String = 'class Foo {\n\tvar x:Int; // inline\n}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('class Foo {\n\tvar x:Int; // inline\n}\n', out);
	}

	public function testLeadingCommentOnClassMember():Void {
		final source:String = 'class Foo {\n\t// member note\n\tvar x:Int;\n}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('class Foo {\n\t// member note\n\tvar x:Int;\n}\n', out);
	}

	public function testBlankLineBetweenDecls():Void {
		final source:String = 'class A {}\n\nclass B {}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('class A {}\n\nclass B {}\n', out);
	}

	public function testAdjacentDeclsWithoutBlankLine():Void {
		final source:String = 'class A {}\nclass B {}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('class A {}\nclass B {}\n', out);
	}

	public function testLeadingCommentInsideFunctionBody():Void {
		final source:String = 'class Foo {\n\tfunction bar() {\n\t\t// inner\n\t\tx;\n\t}\n}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('class Foo {\n\tfunction bar() {\n\t\t// inner\n\t\tx;\n\t}\n}\n', out);
	}

	public function testCleanSourceUnchanged():Void {
		final source:String = 'class Foo {\n\tvar x:Int;\n}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('class Foo {\n\tvar x:Int;\n}\n', out);
	}

	public function testMultiLineBlockCommentStaysBlock():Void {
		// Multi-line block comment content contains a newline, so the
		// auto-style heuristic renders it back as a block comment.
		final source:String = '/*\n * doc\n */\nclass Foo {}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('/*\n * doc\n */\nclass Foo {}\n', out);
	}

	public function testTwoDeclsEachWithLeadingComment():Void {
		final source:String = '// first decl\nclass A {}\n\n// second decl\nclass B {}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('// first decl\nclass A {}\n\n// second decl\nclass B {}\n', out);
	}

	/**
	 * ω-issue-316a — same-line trailing comment after `else` kw is
	 * preserved on the output. The comment lands adjacent to `else`, not
	 * inside the block.
	 */
	public function testSameLineCommentAfterElseRoundTrip():Void {
		final source:String =
			'class Foo {\n'
			+ '\tfunction bar() {\n'
			+ '\t\tif (cond) {\n'
			+ '\t\t\ta;\n'
			+ '\t\t} else // after else\n'
			+ '\t\t{\n'
			+ '\t\t\tb;\n'
			+ '\t\t}\n'
			+ '\t}\n'
			+ '}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out);
	}

	/**
	 * ω-issue-316b — own-line comment between `else` and the block's
	 * `{` is preserved at the body's interior indent on output, while
	 * the `{` drops back to the outer (body's exterior) indent.
	 */
	public function testOwnLineCommentBetweenElseAndBlockRoundTrip():Void {
		final source:String =
			'class Foo {\n'
			+ '\tfunction bar() {\n'
			+ '\t\tif (cond) {\n'
			+ '\t\t\ta;\n'
			+ '\t\t} else\n'
			+ '\t\t\t// between else and block\n'
			+ '\t\t{\n'
			+ '\t\t\tb;\n'
			+ '\t\t}\n'
			+ '\t}\n'
			+ '}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out);
	}
}
