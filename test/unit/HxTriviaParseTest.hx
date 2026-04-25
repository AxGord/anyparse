package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;

/**
 * ω₄d — end-to-end Trivia-mode parse tests. Exercises the generated
 * `HaxeModuleTriviaParser.parse` pipeline: comment-aware `skipWs`
 * (ω₃), `Trivial<T>`-wrapped Star elements (ω₄d), plus the
 * synth-module paired types (ω₄c) that tie the return shape
 * together.
 *
 * The six trivia-bearing Star sites in the Haxe grammar are
 * exercised through composed inputs: top-level decls (HxModule.decls),
 * class members (HxClassDecl.members), function bodies
 * (HxFnDecl.body), and block statements (HxStatement.BlockStmt's
 * stmts). HxInterfaceDecl.members and HxAbstractDecl.members share
 * the same structural path as HxClassDecl.members and are not
 * individually retested here — their contribution is covered by the
 * @:trivia propagation shape check.
 */
class HxTriviaParseTest extends Test {

	// Force the Trivia-mode parser's @:build to complete before this
	// test's method bodies reference the synth module types. The
	// pattern mirrors `HxTriviaTypesTest._forceBuild` — initialisation
	// order between a marker class's build phase and a consumer's
	// top-of-file type references is not guaranteed without this hook.
	//
	// Helpers cannot reference paired `*T` types in their signatures —
	// signature typing precedes static-init, so the synth module isn't
	// registered yet. Each method body that accesses `fn.body` does an
	// inline `switch fn.body { case BlockBody(b): b.stmts; case _: throw }`
	// to extract the Trivial-wrapped statement array (`b` is the
	// paired `HxFnBlockT` carrying the trivia + orphan slots).
	private static final _forceBuild:Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;

	public function testLeadingLineCommentOnDecl():Void {
		final source:String = '// hello world\nclass Foo {}';
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		Assert.equals(1, m.decls.length);
		Assert.equals(1, m.decls[0].leadingComments.length);
		Assert.equals('// hello world', m.decls[0].leadingComments[0]);
		Assert.isFalse(m.decls[0].blankBefore);
		Assert.isNull(m.decls[0].trailingComment);
	}

	public function testLeadingBlockCommentOnDecl():Void {
		final source:String = '/* a block comment */\nclass Foo {}';
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		Assert.equals(1, m.decls.length);
		Assert.equals(1, m.decls[0].leadingComments.length);
		Assert.equals('/* a block comment */', m.decls[0].leadingComments[0]);
	}

	public function testBlankLineBeforeSecondDecl():Void {
		final source:String = 'class A {}\n\nclass B {}';
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		Assert.equals(2, m.decls.length);
		Assert.isFalse(m.decls[0].blankBefore);
		Assert.isTrue(m.decls[1].blankBefore);
	}

	public function testNoBlankLineWithoutDoubleNewline():Void {
		final source:String = 'class A {}\nclass B {}';
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		Assert.equals(2, m.decls.length);
		Assert.isFalse(m.decls[0].blankBefore);
		Assert.isFalse(m.decls[1].blankBefore);
	}

	public function testLeadingCommentOnClassMember():Void {
		final source:String = 'class Foo {\n\t// member note\n\tvar x:Int;\n}';
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final cls:anyparse.grammar.haxe.trivia.Pairs.HxClassDeclT = switch m.decls[0].node.decl {
			case ClassDecl(decl): decl;
			case _: throw 'expected ClassDecl';
		};
		Assert.equals(1, cls.members.length);
		Assert.equals(1, cls.members[0].leadingComments.length);
		Assert.equals('// member note', cls.members[0].leadingComments[0]);
	}

	public function testTrailingLineCommentOnMember():Void {
		final source:String = 'class Foo {\n\tvar x:Int; // inline\n}';
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final cls:anyparse.grammar.haxe.trivia.Pairs.HxClassDeclT = switch m.decls[0].node.decl {
			case ClassDecl(decl): decl;
			case _: throw 'expected ClassDecl';
		};
		Assert.equals(1, cls.members.length);
		Assert.equals(0, cls.members[0].leadingComments.length);
		Assert.equals(' inline', cls.members[0].trailingComment);
	}

	public function testLeadingCommentInsideFunctionBody():Void {
		final source:String = 'class Foo {\n\tfunction bar() {\n\t\t// inner\n\t\tx;\n\t}\n}';
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final cls:anyparse.grammar.haxe.trivia.Pairs.HxClassDeclT = switch m.decls[0].node.decl {
			case ClassDecl(decl): decl;
			case _: throw 'expected ClassDecl';
		};
		final fn:anyparse.grammar.haxe.trivia.Pairs.HxFnDeclT = switch cls.members[0].node.member {
			case FnMember(decl): decl;
			case _: throw 'expected FnMember';
		};
		final stmts:Array<anyparse.runtime.Trivial<anyparse.grammar.haxe.trivia.Pairs.HxStatementT>>
			= switch fn.body {
				case BlockBody(b): b.stmts;
				case _: throw 'expected BlockBody';
			};
		Assert.equals(1, stmts.length);
		Assert.equals(1, stmts[0].leadingComments.length);
		Assert.equals('// inner', stmts[0].leadingComments[0]);
	}

	public function testBlockStmtStatementsCapturedAsTrivial():Void {
		// Nested BlockStmt inside a function body — exercises the
		// @:trivia branch of HxStatement's BlockStmt enum ctor.
		final source:String = 'class Foo {\n\tfunction bar() {\n\t\t{\n\t\t\t// inner block note\n\t\t\tx;\n\t\t}\n\t}\n}';
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final cls:anyparse.grammar.haxe.trivia.Pairs.HxClassDeclT = switch m.decls[0].node.decl {
			case ClassDecl(decl): decl;
			case _: throw 'expected ClassDecl';
		};
		final fn:anyparse.grammar.haxe.trivia.Pairs.HxFnDeclT = switch cls.members[0].node.member {
			case FnMember(decl): decl;
			case _: throw 'expected FnMember';
		};
		final outerStmts:Array<anyparse.runtime.Trivial<anyparse.grammar.haxe.trivia.Pairs.HxStatementT>>
			= switch fn.body {
				case BlockBody(b): b.stmts;
				case _: throw 'expected BlockBody';
			};
		Assert.equals(1, outerStmts.length);
		final inner:anyparse.grammar.haxe.trivia.Pairs.HxStatementT = outerStmts[0].node;
		final stmts:Array<anyparse.runtime.Trivial<anyparse.grammar.haxe.trivia.Pairs.HxStatementT>> = switch inner {
			case BlockStmt(stmts, _): stmts;
			case _: throw 'expected BlockStmt';
		};
		Assert.equals(1, stmts.length);
		Assert.equals(1, stmts[0].leadingComments.length);
		Assert.equals('// inner block note', stmts[0].leadingComments[0]);
	}

	public function testMultipleLeadingComments():Void {
		final source:String = '// first\n// second\nclass Foo {}';
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		Assert.equals(1, m.decls.length);
		Assert.equals(2, m.decls[0].leadingComments.length);
		Assert.equals('// first', m.decls[0].leadingComments[0]);
		Assert.equals('// second', m.decls[0].leadingComments[1]);
	}

	public function testEmptyModuleYieldsEmptyDecls():Void {
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse('');
		Assert.equals(0, m.decls.length);
	}

	public function testCommentOnlyModuleDropsOrphanTrivia():Void {
		// Comments without a following element are consumed by the
		// trailing collectTrivia and discarded — ω₄d explicitly does
		// not preserve orphan end-of-block leading-of-nothing trivia.
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse('// just a comment\n');
		Assert.equals(0, m.decls.length);
	}

	public function testTrailingBlockCommentOnSameLine():Void {
		final source:String = 'class Foo {\n\tvar x:Int; /* inline block */\n}';
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final cls:anyparse.grammar.haxe.trivia.Pairs.HxClassDeclT = switch m.decls[0].node.decl {
			case ClassDecl(decl): decl;
			case _: throw 'expected ClassDecl';
		};
		Assert.equals(1, cls.members.length);
		Assert.equals(' inline block ', cls.members[0].trailingComment);
	}

	public function testMultilineBlockIsLeadingNotTrailing():Void {
		// A block comment containing a newline is never a trailing
		// comment — it attaches as leading of the next element.
		final source:String = 'class A {}\n/* multi\nline */\nclass B {}';
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		Assert.equals(2, m.decls.length);
		Assert.isNull(m.decls[0].trailingComment);
		Assert.equals(1, m.decls[1].leadingComments.length);
		Assert.equals('/* multi\nline */', m.decls[1].leadingComments[0]);
	}

	/**
	 * ω₆a — speculative skipWs rewind on optional-kw miss. Previously the
	 * `@:optional @:kw('else')` check's pre-skipWs unconditionally ate any
	 * comment sitting between the if-stmt's body terminator and the next
	 * statement; after the kw missed, that trivia was already gone, so
	 * the enclosing function-body Star's `collectTrivia` saw nothing and
	 * the comment vanished.
	 *
	 * With rewind, the miss restores pos to pre-skipWs — the outer Star
	 * loop's `collectTrivia` then captures the comment as a leading of
	 * the next statement, which is where it semantically belongs.
	 */
	public function testCommentBetweenStmtsAfterIfWithoutElsePreserved():Void {
		final source:String =
			'class Foo {\n'
			+ '\tfunction bar() {\n'
			+ '\t\tif (cond) doFirst();\n'
			+ '\t\t// between stmts\n'
			+ '\t\tdoSecond();\n'
			+ '\t}\n'
			+ '}';
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final cls:anyparse.grammar.haxe.trivia.Pairs.HxClassDeclT = switch m.decls[0].node.decl {
			case ClassDecl(decl): decl;
			case _: throw 'expected ClassDecl';
		};
		final fn:anyparse.grammar.haxe.trivia.Pairs.HxFnDeclT = switch cls.members[0].node.member {
			case FnMember(decl): decl;
			case _: throw 'expected FnMember';
		};
		final stmts:Array<anyparse.runtime.Trivial<anyparse.grammar.haxe.trivia.Pairs.HxStatementT>>
			= switch fn.body {
				case BlockBody(b): b.stmts;
				case _: throw 'expected BlockBody';
			};
		Assert.equals(2, stmts.length);
		Assert.equals(0, stmts[0].leadingComments.length);
		Assert.equals(1, stmts[1].leadingComments.length);
		Assert.equals('// between stmts', stmts[1].leadingComments[0]);
	}

	/**
	 * ω₆a — trailing comment after an if-stmt without else. The if's
	 * optional-kw `else` skipWs used to consume the trailing, now it
	 * rewinds on the miss and the enclosing Star's `collectTrailing`
	 * captures it on the if-stmt's Trivial wrapper.
	 */
	public function testTrailingCommentAfterIfWithoutElsePreserved():Void {
		final source:String =
			'class Foo {\n'
			+ '\tfunction bar() {\n'
			+ '\t\tif (cond) doIt(); // trailing\n'
			+ '\t}\n'
			+ '}';
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final cls:anyparse.grammar.haxe.trivia.Pairs.HxClassDeclT = switch m.decls[0].node.decl {
			case ClassDecl(decl): decl;
			case _: throw 'expected ClassDecl';
		};
		final fn:anyparse.grammar.haxe.trivia.Pairs.HxFnDeclT = switch cls.members[0].node.member {
			case FnMember(decl): decl;
			case _: throw 'expected FnMember';
		};
		final stmts:Array<anyparse.runtime.Trivial<anyparse.grammar.haxe.trivia.Pairs.HxStatementT>>
			= switch fn.body {
				case BlockBody(b): b.stmts;
				case _: throw 'expected BlockBody';
			};
		Assert.equals(1, stmts.length);
		Assert.equals(' trailing', stmts[0].trailingComment);
	}

	/**
	 * ω-issue-316a — same-line trailing comment after an `@:optional
	 * @:kw('else')` commit is captured into the parent paired type's
	 * `elseBodyAfterKw` slot instead of being folded into the block's
	 * first statement (which was the ω₆b behavior).
	 */
	public function testSameLineCommentAfterElseKwCapturedOnHxIfStmt():Void {
		final source:String =
			'class Foo {\n'
			+ '\tfunction bar() {\n'
			+ '\t\tif (cond) { a; } else // after else\n'
			+ '\t\t{\n'
			+ '\t\t\tb;\n'
			+ '\t\t}\n'
			+ '\t}\n'
			+ '}';
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final cls:anyparse.grammar.haxe.trivia.Pairs.HxClassDeclT = switch m.decls[0].node.decl {
			case ClassDecl(decl): decl;
			case _: throw 'expected ClassDecl';
		};
		final fn:anyparse.grammar.haxe.trivia.Pairs.HxFnDeclT = switch cls.members[0].node.member {
			case FnMember(decl): decl;
			case _: throw 'expected FnMember';
		};
		final stmts:Array<anyparse.runtime.Trivial<anyparse.grammar.haxe.trivia.Pairs.HxStatementT>>
			= switch fn.body {
				case BlockBody(b): b.stmts;
				case _: throw 'expected BlockBody';
			};
		Assert.equals(1, stmts.length);
		final ifStmt:anyparse.grammar.haxe.trivia.Pairs.HxIfStmtT = switch stmts[0].node {
			case IfStmt(s): s;
			case _: throw 'expected IfStmt';
		};
		Assert.equals(' after else', ifStmt.elseBodyAfterKw);
		Assert.equals(0, ifStmt.elseBodyKwLeading.length);
		final elseStmt:Null<anyparse.grammar.haxe.trivia.Pairs.HxStatementT> = ifStmt.elseBody;
		Assert.notNull(elseStmt);
		final elseStmts:Array<anyparse.runtime.Trivial<anyparse.grammar.haxe.trivia.Pairs.HxStatementT>>
			= switch elseStmt {
				case BlockStmt(stmts, _): stmts;
				case _: throw 'expected BlockStmt';
			};
		Assert.equals(1, elseStmts.length);
		Assert.equals(0, elseStmts[0].leadingComments.length);
	}

	/**
	 * ω-issue-316b — own-line comments between `else` and the body's
	 * `{` are captured into `elseBodyKwLeading` instead of leaking into
	 * the block's first statement as leading.
	 */
	public function testOwnLineCommentBetweenElseAndBlockCapturedOnHxIfStmt():Void {
		final source:String =
			'class Foo {\n'
			+ '\tfunction bar() {\n'
			+ '\t\tif (cond) { a; } else\n'
			+ '\t\t\t// between else and block\n'
			+ '\t\t{\n'
			+ '\t\t\tb;\n'
			+ '\t\t}\n'
			+ '\t}\n'
			+ '}';
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final cls:anyparse.grammar.haxe.trivia.Pairs.HxClassDeclT = switch m.decls[0].node.decl {
			case ClassDecl(decl): decl;
			case _: throw 'expected ClassDecl';
		};
		final fn:anyparse.grammar.haxe.trivia.Pairs.HxFnDeclT = switch cls.members[0].node.member {
			case FnMember(decl): decl;
			case _: throw 'expected FnMember';
		};
		final stmts:Array<anyparse.runtime.Trivial<anyparse.grammar.haxe.trivia.Pairs.HxStatementT>>
			= switch fn.body {
				case BlockBody(b): b.stmts;
				case _: throw 'expected BlockBody';
			};
		final ifStmt:anyparse.grammar.haxe.trivia.Pairs.HxIfStmtT = switch stmts[0].node {
			case IfStmt(s): s;
			case _: throw 'expected IfStmt';
		};
		Assert.isNull(ifStmt.elseBodyAfterKw);
		Assert.equals(1, ifStmt.elseBodyKwLeading.length);
		Assert.equals('// between else and block', ifStmt.elseBodyKwLeading[0]);
		final elseStmt:Null<anyparse.grammar.haxe.trivia.Pairs.HxStatementT> = ifStmt.elseBody;
		Assert.notNull(elseStmt);
		final elseStmts:Array<anyparse.runtime.Trivial<anyparse.grammar.haxe.trivia.Pairs.HxStatementT>>
			= switch elseStmt {
				case BlockStmt(stmts, _): stmts;
				case _: throw 'expected BlockStmt';
			};
		Assert.equals(1, elseStmts.length);
		Assert.equals(0, elseStmts[0].leadingComments.length);
	}

	/**
	 * ω-trivia-before-kw — own-line line comment between `}` and `else`
	 * is captured into `elseBodyBeforeKwLeading` instead of being
	 * discarded by the pre-commit `skipWs`.
	 */
	public function testOwnLineCommentBetweenBraceAndElseKwCapturedOnHxIfStmt():Void {
		final source:String =
			'class Foo {\n'
			+ '\tfunction bar() {\n'
			+ '\t\tif (cond) { a; }\n'
			+ '\t\t// before else\n'
			+ '\t\telse { b; }\n'
			+ '\t}\n'
			+ '}';
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final cls:anyparse.grammar.haxe.trivia.Pairs.HxClassDeclT = switch m.decls[0].node.decl {
			case ClassDecl(decl): decl;
			case _: throw 'expected ClassDecl';
		};
		final fn:anyparse.grammar.haxe.trivia.Pairs.HxFnDeclT = switch cls.members[0].node.member {
			case FnMember(decl): decl;
			case _: throw 'expected FnMember';
		};
		final stmts:Array<anyparse.runtime.Trivial<anyparse.grammar.haxe.trivia.Pairs.HxStatementT>>
			= switch fn.body {
				case BlockBody(b): b.stmts;
				case _: throw 'expected BlockBody';
			};
		final ifStmt:anyparse.grammar.haxe.trivia.Pairs.HxIfStmtT = switch stmts[0].node {
			case IfStmt(s): s;
			case _: throw 'expected IfStmt';
		};
		Assert.equals(1, ifStmt.elseBodyBeforeKwLeading.length);
		Assert.equals('// before else', ifStmt.elseBodyBeforeKwLeading[0]);
		Assert.isNull(ifStmt.elseBodyAfterKw);
		Assert.equals(0, ifStmt.elseBodyKwLeading.length);
	}

	/**
	 * ω-trivia-before-kw — own-line block comment between `}` and `else`
	 * is captured into `elseBodyBeforeKwLeading`. (A same-line block on
	 * the `}` line itself goes into the BlockStmt's `closeTrailing`
	 * slot via `collectTrailingFull`, not here.)
	 */
	public function testOwnLineBlockCommentBetweenBraceAndElseKwCapturedOnHxIfStmt():Void {
		final source:String =
			'class Foo {\n'
			+ '\tfunction bar() {\n'
			+ '\t\tif (cond) { a; }\n'
			+ '\t\t/* before else */\n'
			+ '\t\telse { b; }\n'
			+ '\t}\n'
			+ '}';
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final cls:anyparse.grammar.haxe.trivia.Pairs.HxClassDeclT = switch m.decls[0].node.decl {
			case ClassDecl(decl): decl;
			case _: throw 'expected ClassDecl';
		};
		final fn:anyparse.grammar.haxe.trivia.Pairs.HxFnDeclT = switch cls.members[0].node.member {
			case FnMember(decl): decl;
			case _: throw 'expected FnMember';
		};
		final stmts:Array<anyparse.runtime.Trivial<anyparse.grammar.haxe.trivia.Pairs.HxStatementT>>
			= switch fn.body {
				case BlockBody(b): b.stmts;
				case _: throw 'expected BlockBody';
			};
		final ifStmt:anyparse.grammar.haxe.trivia.Pairs.HxIfStmtT = switch stmts[0].node {
			case IfStmt(s): s;
			case _: throw 'expected IfStmt';
		};
		Assert.equals(1, ifStmt.elseBodyBeforeKwLeading.length);
		Assert.equals('/* before else */', ifStmt.elseBodyBeforeKwLeading[0]);
	}

	/**
	 * ω-trivia-before-kw — when no comments precede `else`, the
	 * `elseBodyBeforeKwLeading` slot is an empty array (rewind path
	 * never touches it; commit path copies an empty captured trivia).
	 */
	public function testNoCommentBetweenBraceAndElseLeavesBeforeKwLeadingEmpty():Void {
		final source:String =
			'class Foo {\n'
			+ '\tfunction bar() {\n'
			+ '\t\tif (cond) { a; } else { b; }\n'
			+ '\t}\n'
			+ '}';
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final cls:anyparse.grammar.haxe.trivia.Pairs.HxClassDeclT = switch m.decls[0].node.decl {
			case ClassDecl(decl): decl;
			case _: throw 'expected ClassDecl';
		};
		final fn:anyparse.grammar.haxe.trivia.Pairs.HxFnDeclT = switch cls.members[0].node.member {
			case FnMember(decl): decl;
			case _: throw 'expected FnMember';
		};
		final stmts:Array<anyparse.runtime.Trivial<anyparse.grammar.haxe.trivia.Pairs.HxStatementT>>
			= switch fn.body {
				case BlockBody(b): b.stmts;
				case _: throw 'expected BlockBody';
			};
		final ifStmt:anyparse.grammar.haxe.trivia.Pairs.HxIfStmtT = switch stmts[0].node {
			case IfStmt(s): s;
			case _: throw 'expected IfStmt';
		};
		Assert.equals(0, ifStmt.elseBodyBeforeKwLeading.length);
	}

	/**
	 * ω-trivia-before-kw — when an `if` has no `else` branch, the
	 * `elseBodyBeforeKwLeading` slot still defaults to `[]` (the
	 * commit-miss rewind path never populates it).
	 */
	public function testNoElseBranchLeavesBeforeKwLeadingEmpty():Void {
		final source:String =
			'class Foo {\n'
			+ '\tfunction bar() {\n'
			+ '\t\tif (cond) { a; }\n'
			+ '\t}\n'
			+ '}';
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final cls:anyparse.grammar.haxe.trivia.Pairs.HxClassDeclT = switch m.decls[0].node.decl {
			case ClassDecl(decl): decl;
			case _: throw 'expected ClassDecl';
		};
		final fn:anyparse.grammar.haxe.trivia.Pairs.HxFnDeclT = switch cls.members[0].node.member {
			case FnMember(decl): decl;
			case _: throw 'expected FnMember';
		};
		final stmts:Array<anyparse.runtime.Trivial<anyparse.grammar.haxe.trivia.Pairs.HxStatementT>>
			= switch fn.body {
				case BlockBody(b): b.stmts;
				case _: throw 'expected BlockBody';
			};
		final ifStmt:anyparse.grammar.haxe.trivia.Pairs.HxIfStmtT = switch stmts[0].node {
			case IfStmt(s): s;
			case _: throw 'expected IfStmt';
		};
		Assert.isNull(ifStmt.elseBody);
		Assert.equals(0, ifStmt.elseBodyBeforeKwLeading.length);
	}
}
