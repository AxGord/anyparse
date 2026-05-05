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
		// Default `commentStyle: Verbatim` round-trips block-comment
		// content byte-identical between `/*` and `*/`. Per-line
		// markers, blank lines, leading whitespace — all preserved.
		final source:String = '/*\n * doc\n */\nclass Foo {}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out);
	}

	/**
	 * ω-orphan-trivia-alt — orphan line comments inside a BlockStmt /
	 * BlockExpr / ArrayExpr (Alt-branch close-peek `@:trivia` Stars) must
	 * survive round-trip. Pre-slice these were dropped because the
	 * Lowering Case 4 trivia loop discarded `_lead` on close-peek break;
	 * the synth ctor had no positional slots to carry the captured
	 * `blankBefore` / `leadingComments` and the writer passed null through
	 * to the helper. issue_360 sameline fixture's primary 88-byte diff was
	 * exactly this mechanism — comments inside `try { … } catch (e:T)
	 * { /* dropped *\/ }` block bodies.
	 */
	public function testOrphanCommentInsideBlockBodyRoundTrip():Void {
		final source:String =
			'class Foo {\n'
			+ '\tfunction bar() {\n'
			+ '\t\ttry {\n'
			+ '\t\t\t// inside try\n'
			+ '\t\t} catch (e:Err) {\n'
			+ '\t\t\t// inside catch\n'
			+ '\t\t}\n'
			+ '\t\t{\n'
			+ '\t\t\t// inside plain block\n'
			+ '\t\t}\n'
			+ '\t}\n'
			+ '}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out);
	}

	/**
	 * ω-orphan-trivia-alt — trailing line comment after the LAST stmt
	 * inside a block (between `;` and `}`) must survive. Variant of
	 * the orphan-comment fix that exercises the `_arr.length > 0`
	 * code path in `triviaBlockStarExpr` (`_trailBB` triggers `_dhl()`
	 * before the captured trail comments).
	 */
	public function testTrailingCommentAfterLastStmtInBlockRoundTrip():Void {
		final source:String =
			'class Foo {\n'
			+ '\tfunction bar() {\n'
			+ '\t\t{\n'
			+ '\t\t\tx;\n'
			+ '\t\t\t// after last\n'
			+ '\t\t}\n'
			+ '\t}\n'
			+ '}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out);
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
	 * ω-trivia-before-kw-trailing — same-line `// comment` after a
	 * non-block then-body's terminating `;`, immediately before the
	 * `else` keyword, must be preserved cuddled to the `;`. Reproduces
	 * `issue_45_comment_breaks_indentation.hxtest`'s first byte-diff
	 * mechanism: pre-slice the comment was bucketed as `BeforeKwLeading`
	 * (own-line leading of `else`) and emitted on its own line, breaking
	 * the source's `;-trailing-comment+else` shape.
	 */
	public function testSameLineCommentBeforeElseAfterStmtRoundTrip():Void {
		final source:String =
			'class Foo {\n'
			+ '\tfunction bar() {\n'
			+ '\t\tif (cond)\n'
			+ '\t\t\ta(); // first\n'
			+ '\t\telse\n'
			+ '\t\t\tb(); // second\n'
			+ '\t}\n'
			+ '}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out);
	}

	/**
	 * ω-trivia-after-trail — same-line `// comment` after `if (cond)`'s
	 * trailing `)` (a Ref field's `@:trail` literal) must be preserved
	 * cuddled to the `)` ahead of the `Next`-layout body. Reproduces
	 * `issue_45_comment_breaks_indentation.hxtest`'s second byte-diff
	 * mechanism: pre-slice the comment was silently dropped because
	 * `parseHxStatement` swallowed it as leading trivia of the bare-Ref
	 * `thenBody` and the writer had no slot to re-emit it from.
	 */
	public function testSameLineCommentAfterIfCondRoundTrip():Void {
		final source:String =
			'class Foo {\n'
			+ '\tfunction bar() {\n'
			+ '\t\tif (cond) // afterCond\n'
			+ '\t\t\tresize(1);\n'
			+ '\t}\n'
			+ '}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out);
	}

	/**
	 * ω-trivia-after-kw-next-layout — same-line `// comment` after `else`
	 * (the optional-kw commit point) must be preserved cuddled to the
	 * keyword when the body's `bodyPolicy` resolves to `Next` (haxe-
	 * formatter default for `elseBody`). Reproduces
	 * `issue_45_comment_breaks_indentation.hxtest`'s third byte-diff
	 * mechanism: pre-slice the captured `_afterKw_elseBody` slot only fed
	 * the Same-layout's `kwGapDoc`, so the Next-layout `_dn(_cols, [_dhl,
	 * body])` silently dropped the comment.
	 */
	public function testSameLineCommentAfterElseNonBlockRoundTrip():Void {
		final source:String =
			'class Foo {\n'
			+ '\tfunction bar() {\n'
			+ '\t\tif (cond)\n'
			+ '\t\t\ta();\n'
			+ '\t\telse // afterElse\n'
			+ '\t\t\tb();\n'
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
		// Default `commentStyle: Verbatim` runs the indent-canonicalize
		// path on multi-line block comments whose first line has no
		// inline content; the close-on-own-line is padded with a single
		// space (haxe-formatter convention `<indent> */`), interior
		// content keeps its source depth via per-line ws fields.
		final source:String = 'class Main {\n\t/*\n\t\tTODO:\n\t*/\n}';
		final expected:String = 'class Main {\n\t/*\n\t\tTODO:\n\t */\n}\n';
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
	 * ω-block-comment-verbatim — default `commentStyle: Verbatim` with
	 * indent-canonicalization on context change. Source 4-space indent
	 * for the wrap maps to `\t` at target; interior lines reduce the
	 * source common prefix and re-emit one indent unit deeper than the
	 * wrap. Per-line residual ws (the single space before `- point A`)
	 * survives untouched. Wrap stars (`/**` open, `**\/` close) stay
	 * verbatim because line 0 / last decoration carry the source `*`s.
	 *
	 * Mirrors AxGord/haxe-formatter
	 * `test/testcases/indentation/issue_51_adjust_comment_indentation.hxtest`.
	 */
	public function testMultiLineBlockCommentDefaultVerbatim():Void {
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
	 * ω-block-comment-verbatim — javadoc body with ` * ` per-line
	 * markers round-trips byte-identical under default `Verbatim`.
	 */
	public function testMultiLineBlockCommentJavadocBodyVerbatim():Void {
		final source:String = 'class Main {\n'
			+ '\t/**\n'
			+ '\t * first\n'
			+ '\t * second\n'
			+ '\t */\n'
			+ '\tvar x:Int;\n'
			+ '}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out);
	}

	/**
	 * ω-javadoc-byte-preserve-nest — javadoc-bodied verbatim comment
	 * authored at file column 0 lands at the surrounding context's
	 * indent (one tab here for class-member depth). Source's per-line
	 * structure (per-line ` * [Description]`, close-pad before delimiter) survives intact;
	 * only the leading column shifts to follow target nest. Mirrors
	 * AxGord/haxe-formatter
	 * `whitespace/final_space_removed_from_javadoc_comments_2.hxtest`.
	 */
	public function testMultiLineBlockCommentJavadocColZeroIndentsToTarget():Void {
		final source:String = 'class Main{\n'
			+ '/**\n'
			+ ' * [Description]\n'
			+ ' */\n'
			+ 'static function main(){}\n'
			+ '}';
		final expected:String = 'class Main {\n'
			+ '\t/**\n'
			+ '\t * [Description]\n'
			+ '\t */\n'
			+ '\tstatic function main() {}\n'
			+ '}\n';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(expected, out);
	}

	/**
	 * ω-block-comment-verbatim — inline content on the opening line
	 * stays inline (no `\n` injected after `/*`) under default
	 * `Verbatim`. Continuation lines without a leading `*` marker
	 * gain `+1 indent over surrounding nest` per haxe-formatter's
	 * `MarkTokenText.printComment` rule (issue_208 / issue_139).
	 */
	public function testMultiLineBlockCommentInlineFirstLine():Void {
		final source:String = 'class Main {\n'
			+ '\t/** one, two,\n'
			+ '\tthree. */\n'
			+ '\tvar x:Int;\n'
			+ '}';
		final expected:String = 'class Main {\n'
			+ '\t/** one, two,\n'
			+ '\t\tthree. */\n'
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

	/**
	 * ω-block-comment-verbatim — asymmetric `/** … *\/` under default
	 * `Verbatim` keeps the extra `*` after `/*` as a body byte (not a
	 * marker) and pads the close-on-own-line with the canonical
	 * single space (`<indent> *\/`).
	 */
	public function testMultiLineBlockCommentAsymmetricVerbatim():Void {
		final source:String = 'class Main {\n'
			+ '\t/**\n'
			+ '\tfoo\n'
			+ '\t*/\n'
			+ '\tvar x:Int;\n'
			+ '}';
		final expected:String = 'class Main {\n'
			+ '\t/**\n'
			+ '\tfoo\n'
			+ '\t */\n'
			+ '\tvar x:Int;\n'
			+ '}\n';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(expected, out);
	}

	private static function withCommentStyle(style:anyparse.format.CommentStyle):anyparse.grammar.haxe.HxModuleWriteOptions {
		final opts:anyparse.grammar.haxe.HxModuleWriteOptions =
			anyparse.grammar.haxe.HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.commentStyle = style;
		return opts;
	}

	/**
	 * ω-trivia-before-kw — own-line line comment between `}` and `else`
	 * round-trips at the parent's indent level. Without the slice the
	 * comment is dropped and the writer emits `} else { b; }` only.
	 */
	public function testOwnLineCommentBetweenBraceAndElseRoundTrip():Void {
		final source:String = 'class Foo {\n'
			+ '\tfunction bar() {\n'
			+ '\t\tif (cond) {\n'
			+ '\t\t\ta;\n'
			+ '\t\t}\n'
			+ '\t\t// before else\n'
			+ '\t\telse {\n'
			+ '\t\t\tb;\n'
			+ '\t\t}\n'
			+ '\t}\n'
			+ '}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out);
	}

	/**
	 * ω-trivia-before-kw — multiple own-line line comments between `}`
	 * and `else` each render on their own indented line.
	 */
	public function testMultipleOwnLineCommentsBetweenBraceAndElseRoundTrip():Void {
		final source:String = 'class Foo {\n'
			+ '\tfunction bar() {\n'
			+ '\t\tif (cond) {\n'
			+ '\t\t\ta;\n'
			+ '\t\t}\n'
			+ '\t\t// first\n'
			+ '\t\t// second\n'
			+ '\t\telse {\n'
			+ '\t\t\tb;\n'
			+ '\t\t}\n'
			+ '\t}\n'
			+ '}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out);
	}

	/**
	 * ω-trivia-before-kw — when no comments precede `else`, the slice
	 * is byte-identical to pre-slice output (sameLine `} else`).
	 */
	public function testNoCommentBetweenBraceAndElseStaysSameLine():Void {
		final source:String = 'class Foo {\n'
			+ '\tfunction bar() {\n'
			+ '\t\tif (cond) {\n'
			+ '\t\t\ta;\n'
			+ '\t\t} else {\n'
			+ '\t\t\tb;\n'
			+ '\t\t}\n'
			+ '\t}\n'
			+ '}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out);
	}

	/**
	 * ω-line-comment-space — leading `//foo` (no space after `//`)
	 * gets rewritten to `// foo` on emission. Mirrors haxe-formatter's
	 * `whitespace.addLineCommentSpace: @:default(true)` behaviour and
	 * unblocks the corpus's `single_line_comments.hxtest` /
	 * `issue_162_space_at_start_of_single_line_comment.hxtest`.
	 */
	public function testLeadingLineCommentInsertsSpace():Void {
		final source:String = '//foo\nclass Main {}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('// foo\nclass Main {}\n', out);
	}

	/**
	 * ω-line-comment-space — decoration prefixes (body starts with
	 * `*`, `-`, `/`, or whitespace) survive tight; the space-insert
	 * pass is gated by the haxe-formatter `^[/\*\-\s]+` regex.
	 */
	public function testLeadingLineCommentDecorationKeepsTight():Void {
		final source:String = 'class Main {\n'
			+ '\t//*******\n'
			+ '\t//---------\n'
			+ '\t////////////\n'
			+ '\t// already-spaced\n'
			+ '\tvar x:Int;\n'
			+ '}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out);
	}

	/**
	 * ω-line-comment-space — `addLineCommentSpace: false` skips the
	 * space-insert pass; bodies are still trimmed but no padding is
	 * synthesised. Knob lives on the base `WriteOptions` so every
	 * text writer can read it from the unconditionally-emitted
	 * `leadingCommentDoc` helper.
	 */
	public function testLeadingLineCommentSpaceCanBeDisabled():Void {
		final source:String = '//foo\nclass Main {}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final opts:anyparse.grammar.haxe.HxModuleWriteOptions =
			anyparse.grammar.haxe.HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"addLineCommentSpace": false}}');
		final out:String = HaxeModuleTriviaWriter.write(ast, opts);
		Assert.equals('//foo\nclass Main {}\n', out);
	}

	/**
	 * ω-line-comment-space — trailing same-line `//foo` (no space)
	 * routed through `trailingCommentDoc`, the body-only helper, also
	 * picks up the leading-space rewrite. Body is rebuilt as `'//' +
	 * body` before normalisation so the same rule applies as for
	 * leading and verbatim variants.
	 */
	public function testTrailingLineCommentInsertsSpace():Void {
		final source:String = 'class Foo {\n\tvar x:Int; //inline\n}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('class Foo {\n\tvar x:Int; // inline\n}\n', out);
	}

	/**
	 * ω-trivia-sep — `HxObjectLit.fields` flat single-line layout:
	 * source has all fields on one line with no comments / no blanks /
	 * no `newlineBefore`. `triviaSepStarExpr` collapses to `{a: 1, b:
	 * 2}` and skips the multi-line wrap.
	 */
	public function testObjectLitFlatRoundTrip():Void {
		final source:String = 'class Main {\n\tstatic function main() {\n\t\tvar o = {a: 1, b: 2};\n\t}\n}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('${source}\n', out);
	}

	/**
	 * ω-trivia-sep — `HxObjectLit.fields` multi-line layout: source
	 * had `newlineBefore` on each element, so the writer breaks the
	 * literal across lines and indents the body one level.
	 *
	 * Disables `indentObjectLiteral` (slice ω-indent-objectliteral
	 * default-true) so this round-trip stays focused on the trivia-sep
	 * preservation axis — the new default would otherwise add one extra
	 * indent step to every internal hardline.
	 */
	public function testObjectLitMultiLineRoundTrip():Void {
		final source:String = 'class Main {\n\tstatic function main() {\n\t\tvar o = {\n\t\t\ta: 1,\n\t\t\tb: 2\n\t\t};\n\t}\n}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final opts:anyparse.grammar.haxe.HxModuleWriteOptions =
			anyparse.grammar.haxe.HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.indentObjectLiteral = false;
		final out:String = HaxeModuleTriviaWriter.write(ast, opts);
		Assert.equals('${source}\n', out);
	}

	/**
	 * ω-trivia-sep — trailing comment after the last value of
	 * `HxObjectLit.fields` is captured by `collectTrailing` AFTER the
	 * optional `,` (none here). Pratt loop's pre-skipWs comment-rewind
	 * keeps the comment available for the sibling capture path.
	 *
	 * `indentObjectLiteral=false` keeps the focus on trailing-comment
	 * capture, see `testObjectLitMultiLineRoundTrip` for context.
	 */
	public function testObjectLitTrailingComment():Void {
		final source:String = 'class Main {\n\tstatic function main() {\n\t\tvar o = {\n\t\t\ta: 1 // tag\n\t\t};\n\t}\n}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final opts:anyparse.grammar.haxe.HxModuleWriteOptions =
			anyparse.grammar.haxe.HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.indentObjectLiteral = false;
		final out:String = HaxeModuleTriviaWriter.write(ast, opts);
		Assert.equals('${source}\n', out);
	}

	/**
	 * ω-trivia-sep — `HxExpr.ArrayExpr` multi-line layout: array
	 * elements parsed via the Alt-branch trivia+sep path round-trip
	 * across lines.
	 */
	public function testArrayExprMultiLineRoundTrip():Void {
		final source:String = 'class Main {\n\tstatic function main() {\n\t\tvar a = [\n\t\t\t1,\n\t\t\t2\n\t\t];\n\t}\n}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('${source}\n', out);
	}

	/**
	 * ω-open-trailing — same-line `// comment` after an object literal's
	 * `{` open delim attaches as the open's trailing comment, not as
	 * own-line leading of the first field. Covers `HxObjectLit.fields`'s
	 * trivia-sep Star path.
	 */
	public function testObjectLitOpenTrailingLineComment():Void {
		final source:String = 'class Main {\n\tstatic function main():Void {\n\t\tfunc({ // comment\n\t\t\tfoo: 1\n\t\t});\n\t}\n}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('${source}\n', out);
	}

	/**
	 * Empty case body whose only content is a trail comment followed by a
	 * blank line preserves the blank between trail and the next case label.
	 * Mirrors haxe-formatter `indentation/issue_392_case_indentation`
	 * second switch — `case A: // Case A` (own-line trail) + blank line +
	 * `case B:` round-trips with the gap intact.
	 */
	public function testCaseBodyEmptyTrailWithBlankAfter():Void {
		final source:String = 'class Main {\n\tstatic function main():Void {\n\t\tswitch v {\n\t\t\tcase A:\n\t\t\t\t// Case A\n\n\t\t\tcase B:\n\t\t\t\ttrace(\'b\');\n\t\t}\n\t}\n}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('${source}\n', out);
	}

	/**
	 * ω-postfix-starsuffix-trivia — inline `/* x *\/` block comments
	 * between Call args round-trip in flat layout. Pre-slice, comments
	 * inside `(args)` were dropped at parse: the postfix Star-suffix
	 * branch had no trivia path and `skipWs(ctx)` between args ate any
	 * trailing comment before any capture. Reproduces
	 * `whitespace/commented_out_parameter.hxtest`'s mechanism in a
	 * minimal shape.
	 */
	public function testCallArgFlatInlineBlockComments():Void {
		final source:String = 'class Main {\n\tstatic function main() {\n\t\tfoo(a, "" /* x */, "" /* y */);\n\t}\n}';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out);
	}

	/**
	 * ω-postfix-starsuffix-trivia — multi-line trail capture: a comment
	 * physically on the line AFTER an arg but BEFORE its trailing sep
	 * is treated as trailing-of-arg (mirror of fork's reformat). The
	 * writer renders the comment cuddled to the arg in the output
	 * regardless of source position.
	 */
	public function testCallArgMultiLineTrailingComment():Void {
		final source:String = 'class Main {\n\tstatic function main() {\n\t\tfoo(a, ""\n\t\t\t/* tag */, b);\n\t}\n}';
		final expected:String = 'class Main {\n\tstatic function main() {\n\t\tfoo(a, "" /* tag */, b);\n\t}\n}\n';
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(expected, out);
	}
}
