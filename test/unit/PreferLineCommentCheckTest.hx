package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Linter;
import anyparse.check.PreferLineComment;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `prefer-line-comment` check: a `/* … *\/` block comment sitting in a STATEMENT
 * position inside a function body is rewritten to `//` line comments. The hard gate is
 * that `*\/` be the last non-whitespace on its line — so a mid-expression comment
 * (`foo(a /* x *\/, b)`) and a comment with code after it never convert. A multi-line
 * block additionally needs `/*` first on its line. Doc comments attached to a
 * declaration are out of scope — a member's, a type's, and a LOCAL FUNCTION's; any other
 * statement-level `/**` block converts like a plain one. A content-free comment is ceded
 * to `empty-comment`.
 */
class PreferLineCommentCheckTest extends Test {

	public function testStandaloneWholeLineBlockFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\t/* note */\n\t\tg();\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('prefer-line-comment', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('block comment in a statement position; use a line comment', vs[0].message);
	}

	public function testStandaloneWholeLineBlockFixed(): Void {
		Assert.equals(
			'class C {\n\tfunction f():Void {\n\t\t// note\n\t\tg();\n\t}\n}',
			applyFix('class C {\n\tfunction f():Void {\n\t\t/* note */\n\t\tg();\n\t}\n}')
		);
	}

	/** The confirmed target shape: a leading star is CONTENT in a plain block, not a gutter. */
	public function testStarBodyKeptAsContent(): Void {
		Assert.equals(
			'class C {\n\tfunction f():Void {\n\t\tvar h:Int = w;\n\t\t// * 2\n\t}\n}',
			applyFix('class C {\n\tfunction f():Void {\n\t\tvar h:Int = w;\n\t\t/* * 2 */\n\t}\n}')
		);
	}

	public function testTrailingBlockAfterStatementFixed(): Void {
		Assert.equals(
			'class C {\n\tfunction f():Void {\n\t\tg(); // why\n\t}\n}',
			applyFix('class C {\n\tfunction f():Void {\n\t\tg(); /* why */\n\t}\n}')
		);
	}

	public function testTrailingBlockTrailingSpaceRemoved(): Void {
		Assert.equals(
			'class C {\n\tfunction f():Void {\n\t\tg(); // why\n\t}\n}',
			applyFix('class C {\n\tfunction f():Void {\n\t\tg(); /* why */  \n\t}\n}')
		);
	}

	/** Prose diagram: `/*` alone on its line, the body dedented by its own common indent. */
	public function testMultilineProseDiagramFixed(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t/*\n\t\t\ta -> b\n\t\t\tb -> c\n\t\t */\n\t\tg();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\t// a -> b\n\t\t// b -> c\n\t\tg();\n\t}\n}', applyFix(src));
	}

	/** Prose header over commented-out code: text on the `/*` line, code lines below. */
	public function testMultilineProseHeaderFixed(): Void {
		final src: String =
			'class C {\n\tfunction f():Void {\n\t\t/* square at the tip\n\t\t\tp.x = q;\n\t\t\tp.y = r;\n\t\t*/\n\t\tg();\n\t}\n}';
		Assert.equals(
			'class C {\n\tfunction f():Void {\n\t\t// square at the tip\n\t\t// p.x = q;\n\t\t// p.y = r;\n\t\tg();\n\t}\n}', applyFix(src)
		);
	}

	/** Relative indentation among the body lines survives the common-indent strip. */
	public function testMultilineRelativeIndentKept(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t/*\n\t\t\touter\n\t\t\t\tinner\n\t\t*/\n\t\tg();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\t// outer\n\t\t// \tinner\n\t\tg();\n\t}\n}', applyFix(src));
	}

	/** A statement-level `/**` block is not a real doc — it converts, gutter stripped. */
	public function testStatementLevelDocBlockConverts(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t/**\n\t\t * a\n\t\t * b\n\t\t */\n\t\tg();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\t// a\n\t\t// b\n\t\tg();\n\t}\n}', applyFix(src));
	}

	public function testNestedBlockStatementScopeFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tif (b) {\n\t\t\t/* note */\n\t\t\tg();\n\t\t}\n\t}\n}').length);
	}

	public function testMidExpressionCommentKept(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tfoo(a /* x */, b);\n\t}\n}').length);
	}

	/** `*\/` last on its line is not enough: a call argument is still mid-expression. */
	public function testMidExpressionLineTerminalCommentKept(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tfoo(a, /* x */\n\t\t\tb);\n\t}\n}').length);
	}

	public function testCodeAfterCloseKept(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\t/* x */ g();\n\t}\n}').length);
	}

	public function testDocOnMemberKept(): Void {
		Assert.equals(0, violations('class C {\n\t/** Returns x. */\n\tfunction f():Void {}\n}').length);
	}

	public function testDocOnTypeKept(): Void {
		Assert.equals(0, violations('/** A type. */\nclass C {\n\tfunction f():Void {}\n}').length);
	}

	public function testBlockBeforeFirstMemberKept(): Void {
		Assert.equals(0, violations('class C {\n\t/* section */\n\tfunction f():Void {}\n}').length);
	}

	public function testMultilineOpenNotFirstOnLineKept(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg(); /* a\n\t\t\tb */\n\t}\n}').length);
	}

	public function testEmptyBlockLeftToEmptyComment(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\t/*  */\n\t\tg();\n\t}\n}').length);
	}

	/** A star-only body is `empty-comment`'s shape; converting it would strand an un-deletable `// *`. */
	public function testStarOnlyBlockLeftToEmptyComment(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\t/* * */\n\t\tg();\n\t}\n}').length);
	}

	/** Guards the `substring` argument-swap hazard of the degenerate delimiters-only forms. */
	public function testDegenerateBlocksKept(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\t/**/\n\t\tg();\n\t}\n}').length);
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\t/***/\n\t\tg();\n\t}\n}').length);
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\t/****/\n\t\tg();\n\t}\n}').length);
	}

	/** An unclosed block in an otherwise-parseable file has no closing delimiter to gate on. */
	public function testUnclosedBlockKept(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg();\n\t}\n}\n/* trailing').length);
	}

	/** A `**\/` close is delimiter, not body: no star leaks in and the close line skews no indent. */
	public function testDoubleStarCloseFixed(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t/**\n\t\t\ta hack\n\t\t**/\n\t\tg();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\t// a hack\n\t\tg();\n\t}\n}', applyFix(src));
	}

	/** A `/***` open is delimiter too. */
	public function testTripleStarOpenFixed(): Void {
		Assert.equals(
			'class C {\n\tfunction f():Void {\n\t\t// three\n\t\tg();\n\t}\n}',
			applyFix('class C {\n\tfunction f():Void {\n\t\t/*** three */\n\t\tg();\n\t}\n}')
		);
	}

	/** A gutter block loses its star column whether it opens `/*` or `/**` — the SHAPE decides. */
	public function testPlainGutterBlockStripsStars(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t/*\n\t\t * a\n\t\t * b\n\t\t */\n\t\tg();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\t// a\n\t\t// b\n\t\tg();\n\t}\n}', applyFix(src));
	}

	/** A BARE `*\/` closing line is the wrap's structural indent, not body, and must not skew the dedent. */
	public function testBareCloseLineDoesNotSkewDedent(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (b) {\n\t\t\t/*\n\t\t\t\tone\n\t\t\t*/\n\t\t\tg();\n\t\t}\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tif (b) {\n\t\t\t// one\n\t\t\tg();\n\t\t}\n\t}\n}', applyFix(src));
	}

	/** A close that carries CONTENT (`}*\/`) is body — it participates in the dedent and keeps its line. */
	public function testContentBearingCloseLineKept(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t/*if (b) {\n\t\t\tg();\n\t\t}*/\n\t\th();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\t// if (b) {\n\t\t// \tg();\n\t\t// }\n\t\th();\n\t}\n}', applyFix(src));
	}

	/** A `/**` above a LOCAL FUNCTION is a real doc for it — the in-body analogue of a member doc. */
	public function testDocOnLocalFunctionKept(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f():Void {\n\t\t/** Helper. */\n\t\tfunction h():Void {}\n\t\th();\n\t}\n}').length
		);
	}

	public function testDocOnInlineLocalFunctionKept(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f():Void {\n\t\t/** Helper. */\n\t\tinline function h():Void {}\n\t\th();\n\t}\n}').length
		);
	}

	/** Only the DOC form is spared: plain prose above a local function is still prose. */
	public function testPlainBlockOnLocalFunctionConverts(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t/* helper */\n\t\tfunction h():Void {}\n\t\th();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\t// helper\n\t\tfunction h():Void {}\n\t\th();\n\t}\n}', applyFix(src));
	}

	/** A CRLF file keeps its terminator: the edit stops before the CR and the join re-emits it. */
	public function testCrlfTerminatorPreserved(): Void {
		final src: String = 'class C {\r\n\tfunction f():Void {\r\n\t\t/*\r\n\t\t\ta\r\n\t\t\tb\r\n\t\t*/\r\n\t\tg();\r\n\t}\r\n}';
		Assert.equals('class C {\r\n\tfunction f():Void {\r\n\t\t// a\r\n\t\t// b\r\n\t\tg();\r\n\t}\r\n}', applyFix(src));
	}

	public function testLineCommentKept(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\t// note\n\t\tg();\n\t}\n}').length);
	}

	public function testBlockInStringLiteralKept(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar s:String = "/* x */";\n\t}\n}').length);
	}

	public function testDefaultOff(): Void {
		Assert.isTrue(new PreferLineComment() is DefaultOff);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-line-comment'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-line-comment'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { /* ').length);
		Assert.equals(0, violations('class Bad { function f() { /* note */').length);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferLineComment().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		return CheckFixture.fixedSource(new PreferLineComment(), src);
	}

}
