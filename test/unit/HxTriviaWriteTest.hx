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
		// Max-dry capture strips leading ws and `*` markers, so the
		// interior line reduces to `doc` (content only). Writer re-
		// emits per `HaxeFormat.defaultWriteOptions.commentStyle` —
		// `JavadocNoStars` by default — yielding `/**…**/` wrap and
		// plain indent-unit content.
		final source:String = '/*\n * doc\n */\nclass Foo {}';
		final expected:String = '/**\n\tdoc\n**/\nclass Foo {}\n';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(expected, out);
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

	/**
	 * ω-orphan-trivia — repro for `issue_159_unstable_comment.hxtest`
	 * (and its block-style sibling `issue_134_comments.hxtest`): a
	 * class body that contains ONLY a comment (no members) used to
	 * drop the comment because no member element existed to hang it
	 * on. Trailing-trivia slots on the Star field now carry these
	 * orphans through parse → write.
	 */
	public function testOrphanLineCommentInEmptyClassBody():Void {
		final source:String = 'class Main {\n\t// only a comment\n}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out);
	}

	public function testOrphanMultiLineBlockCommentInEmptyClassBody():Void {
		// Max-dry: source's leading-ws on interior lines + trailing-ws
		// before `*/` are stripped at parse time. Writer re-emits at
		// the default `commentStyle: JavadocNoStars`.
		final source:String = 'class Main {\n\t/*\n\t\tTODO:\n\t*/\n}';
		final expected:String = 'class Main {\n\t/**\n\t\tTODO:\n\t**/\n}\n';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(expected, out);
	}

	public function testOrphanCommentAfterLastMemberBlankLine():Void {
		final source:String = 'class Main {\n\tvar x:Int;\n\n\t// trailing\n}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out);
	}

	public function testOrphanCommentAtEndOfFile():Void {
		final source:String = 'class Main {}\n\n// trailing file comment';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out);
	}

	/**
	 * ω-issue-48-v2 — `@:allow(...)\n\tvar x` round-trips with the
	 * newline intact even when the member's `modifiers` Star is empty.
	 * The trivia `newlineBefore` marker sits on the member element
	 * itself; the writer must consult it at the meta→member boundary
	 * when modifiers contributes nothing. Mirrors upstream
	 * `test/testcases/sameline/issue_48_metadata_max_length.hxtest`.
	 */
	public function testMetadataNewlineBeforeBareVar():Void {
		final source:String = 'class Main {\n\t@:allow(Foo.Bar)\n\tvar x:Int;\n}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out);
	}


	/**
	 * ω-C-commentStyle — default `JavadocNoStars`: `/**…**\/` wrap
	 * with plain indent-unit content (no ` * ` markers). Mixed-indent
	 * source re-emits at writer's `indentChar=Tab`. Content lines
	 * relative-offset past the common leading prefix is preserved
	 * (bullets indented one space under a paragraph round-trip as
	 * one-space-past-the-indent-unit in the output — same contract
	 * as the `issue_51_adjust_comment_indentation` corpus fixture).
	 */
	public function testMultiLineBlockCommentJavadocNoStarsDefault():Void {
		final source:String = 'class Main {\n'
			+ '    /**\n'
			+ '        Description\n'
			+ '         - point A\n'
			+ '         - point B\n'
			+ '    **/\n'
			+ '    static public function main() {}\n'
			+ '}';
		final expected:String = 'class Main {\n'
			+ '\t/**\n'
			+ '\t\tDescription\n'
			+ '\t\t - point A\n'
			+ '\t\t - point B\n'
			+ '\t**/\n'
			+ '\tstatic public function main() {}\n'
			+ '}\n';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(expected, out);
	}

	/**
	 * ω-C-commentStyle — source-javadoc (` * foo`) also collapses
	 * into content-only on capture. Default `JavadocNoStars` re-
	 * emits as `/**…**\/` wrap with plain indent-unit content — the
	 * source ` * ` markers are not round-tripped.
	 */
	public function testMultiLineBlockCommentSourceJavadocCollapses():Void {
		final source:String = 'class Main {\n'
			+ '\t/**\n'
			+ '\t * first\n'
			+ '\t * second\n'
			+ '\t */\n'
			+ '\tvar x:Int;\n'
			+ '}';
		final expected:String = 'class Main {\n'
			+ '\t/**\n'
			+ '\t\tfirst\n'
			+ '\t\tsecond\n'
			+ '\t**/\n'
			+ '\tvar x:Int;\n'
			+ '}\n';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(expected, out);
	}

	/**
	 * ω-C-commentStyle — inline content on the opening line wraps
	 * through the same default `JavadocNoStars` path as separate-
	 * line content. The `/** one, two,` opening collapses to a
	 * regular first interior line after capture.
	 */
	public function testMultiLineBlockCommentInlineFirstLine():Void {
		final source:String = 'class Main {\n'
			+ '\t/** one, two,\n'
			+ '\tthree. */\n'
			+ '\tvar x:Int;\n'
			+ '}';
		final expected:String = 'class Main {\n'
			+ '\t/**\n'
			+ '\t\tone, two,\n'
			+ '\t\tthree.\n'
			+ '\t**/\n'
			+ '\tvar x:Int;\n'
			+ '}\n';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(expected, out);
	}

	/**
	 * ω-C-commentStyle — explicit `commentStyle: Javadoc` emits
	 * `/**…**\/` wrap with ` * ` markers on each content line,
	 * canonical Java / Haxe doc-block appearance. Exercises the
	 * non-default path.
	 */
	public function testMultiLineBlockCommentJavadocStarsExplicit():Void {
		final source:String = 'class Main {\n'
			+ '\t/**\n'
			+ '\t first\n'
			+ '\t second\n'
			+ '\t**/\n'
			+ '\tvar x:Int;\n'
			+ '}';
		final expected:String = 'class Main {\n'
			+ '\t/**\n'
			+ '\t * first\n'
			+ '\t * second\n'
			+ '\t**/\n'
			+ '\tvar x:Int;\n'
			+ '}\n';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final opts:anyparse.grammar.haxe.HxModuleWriteOptions =
			withCommentStyle(anyparse.format.CommentStyle.Javadoc);
		final out:String = HaxeModuleTriviaWriter.write(ast, opts);
		Assert.equals(expected, out);
	}

	/**
	 * ω-C-commentStyle — explicit `commentStyle: Plain` strips the
	 * javadoc `*` markers and wraps with plain `/*…*\/` + one
	 * indent-unit per interior line. Exercises the non-default
	 * path of the knob.
	 */
	public function testMultiLineBlockCommentPlainStyle():Void {
		final source:String = 'class Main {\n'
			+ '\t/** first\n'
			+ '\t    second */\n'
			+ '\tvar x:Int;\n'
			+ '}';
		final expected:String = 'class Main {\n'
			+ '\t/*\n'
			+ '\t\tfirst\n'
			+ '\t\tsecond\n'
			+ '\t*/\n'
			+ '\tvar x:Int;\n'
			+ '}\n';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final opts:anyparse.grammar.haxe.HxModuleWriteOptions =
			withCommentStyle(anyparse.format.CommentStyle.Plain);
		final out:String = HaxeModuleTriviaWriter.write(ast, opts);
		Assert.equals(expected, out);
	}

	private static function withCommentStyle(style:anyparse.format.CommentStyle):anyparse.grammar.haxe.HxModuleWriteOptions {
		final base:anyparse.grammar.haxe.HxModuleWriteOptions =
			anyparse.grammar.haxe.HaxeFormat.instance.defaultWriteOptions;
		return {
			indentChar: base.indentChar,
			indentSize: base.indentSize,
			tabWidth: base.tabWidth,
			lineWidth: base.lineWidth,
			lineEnd: base.lineEnd,
			finalNewline: base.finalNewline,
			trailingWhitespace: base.trailingWhitespace,
			commentStyle: style,
			sameLineElse: base.sameLineElse,
			sameLineCatch: base.sameLineCatch,
			sameLineDoWhile: base.sameLineDoWhile,
			trailingCommaArrays: base.trailingCommaArrays,
			trailingCommaArgs: base.trailingCommaArgs,
			trailingCommaParams: base.trailingCommaParams,
			ifBody: base.ifBody,
			elseBody: base.elseBody,
			forBody: base.forBody,
			whileBody: base.whileBody,
			doBody: base.doBody,
			leftCurly: base.leftCurly,
			objectFieldColon: base.objectFieldColon,
			typeHintColon: base.typeHintColon,
			funcParamParens: base.funcParamParens,
			callParens: base.callParens,
			elseIf: base.elseIf,
			fitLineIfWithElse: base.fitLineIfWithElse,
			afterFieldsWithDocComments: base.afterFieldsWithDocComments,
			existingBetweenFields: base.existingBetweenFields,
			beforeDocCommentEmptyLines: base.beforeDocCommentEmptyLines,
			betweenVars: base.betweenVars,
			betweenFunctions: base.betweenFunctions,
			afterVars: base.afterVars,
			interfaceBetweenVars: base.interfaceBetweenVars,
			interfaceBetweenFunctions: base.interfaceBetweenFunctions,
			interfaceAfterVars: base.interfaceAfterVars,
			typedefAssign: base.typedefAssign,
			typeParamOpen: base.typeParamOpen,
			typeParamClose: base.typeParamClose,
			anonTypeBracesOpen: base.anonTypeBracesOpen,
			anonTypeBracesClose: base.anonTypeBracesClose,
			objectLiteralBracesOpen: base.objectLiteralBracesOpen,
			objectLiteralBracesClose: base.objectLiteralBracesClose,
		};
	}
}
