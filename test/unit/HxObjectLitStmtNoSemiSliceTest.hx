package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxStatement;

/**
 * Slice 30 — `stmtExprNoSemi` direct-returns true on `ObjectLit`.
 *
 * `HxStatement.ExprStmt` carries `@:fmt(trailOptParseGate('stmtExprNoSemi'))`
 * — the trailing `;` is optional iff the parsed expression visually
 * ends with `}`. Pre-slice the predicate stopped at `BlockExpr` and
 * `endsWithCloseBrace` (`SwitchExpr` / `FnExpr` block-body / `TryExpr`),
 * so a bare `{ foo: 1 }` object literal at statement position required
 * `;` even though the closing `}` is the statement's last token.
 *
 * Order of dispatch in `HxStatement`: `BlockStmt` precedes `ExprStmt`,
 * so `{` greedy-tries `BlockStmt` first. A `{ IDENT: value }` shape
 * (`foo: 1` is not a valid statement) makes `BlockStmt` backtrack, then
 * `ExprStmt` succeeds with `ObjectLit`. With the gate true, the
 * trailing `;` is optional.
 *
 * Corpus drivers: `whitespace/whitespace_after_object_literal`
 * (`{f: macro ${a},}` as last stmt of function body) and
 * `sameline/issue_161_if_body_in_object_literal`
 * (`{ foo: { if (foo) bar; ""; } }` as last stmt).
 */
class HxObjectLitStmtNoSemiSliceTest extends HxTestHelpers {

	// -- Isolated: bare object literal as sole statement, no `;` --

	public function testBareObjectLitNoSemi():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\t{foo: 1}\n\t}\n}'
		);
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		final e:HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(ObjectLit(_)));
	}

	// -- Trailing-comma single-field object literal, no `;` --

	public function testObjectLitTrailingCommaNoSemi():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\t{foo: 1,}\n\t}\n}'
		);
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		final e:HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(ObjectLit(_)));
	}

	// -- Multi-statement: object literal no `;` followed by next stmt.
	// The gate must terminate the first statement at the brace so the
	// next one parses cleanly.

	public function testObjectLitFollowedByStmt():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\t{foo: 1}\n\t\ty = 5;\n\t}\n}'
		);
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(2, stmts.length);
		final e0:HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e0.match(ObjectLit(_)));
	}

	// -- Regression: empty `{}` still parses as `BlockStmt`, not
	// `ExprStmt(ObjectLit)`. BlockStmt precedes ExprStmt in the
	// `HxStatement` order and there is no `IDENT:` field shape to
	// trigger backtracking, so the empty-brace stays a block.

	public function testEmptyBraceStillBlockStmt():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\t{}\n\t}\n}'
		);
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		Assert.isTrue(stmts[0].match(BlockStmt(_)));
	}

	// -- Regression: `{var x = 1;}` is a `BlockStmt` containing a
	// `VarStmt`. The first inner token is `var`, not `IDENT:`, so
	// BlockStmt succeeds without backtracking.

	public function testBlockWithVarStmtStillBlockStmt():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\t{var x = 1;}\n\t}\n}'
		);
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		Assert.isTrue(stmts[0].match(BlockStmt(_)));
	}

	// -- Regression: pre-slice path with `;` still parses --

	public function testObjectLitWithSemiUnchanged():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\t{foo: 1};\n\t}\n}'
		);
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		final e:HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(ObjectLit(_)));
	}

	// -- Post-Slice-44 (ω-slice-X3): a bare Call as the last stmt of a
	// block now elides `;` via the parse-time peek-`}` disjunct. The
	// intrinsic gate stays false on `Call` (this predicate's catch-all
	// `endsWithCloseBrace` returns false for non-brace exprs) — peek-`}`
	// supplies the elision because the enclosing block's `}` is the
	// next non-trivia byte. Multi-stmt boundary detection still works
	// (see the `testCallFollowedByIdentRegression` below).

	public function testCallExprBeforeCloseBraceNoSemi():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\tfoo()\n\t}\n}'
		);
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
	}

	// -- Regression: Call followed by another ident-led stmt (no `;`
	// between them) MUST still throw. Pins multi-stmt boundary
	// detection — peek-`}` is the ONLY new disjunct; ident lookahead
	// stays strict.

	public function testCallFollowedByIdentRegression():Void {
		Assert.raises(() -> HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\tfoo()\n\t\tbar()\n\t}\n}'
		));
	}

	// -- Corpus driver: whitespace_after_object_literal input verbatim,
	// trimmed to the failing tail (full file parses too).

	public function testCorpusObjectLitAfterSwitch():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			"class Main {\n\tstatic function main() {\n\t\tswitch (foo) {\n\t\t\tcase {kind: TkIdent, text: \"error\"}:\n\t\t\t\tdoSomething();\n\t\t}\n\t\t{f: macro ${a},}\n\t}\n}"
		);
		Assert.equals(1, cls.members.length);
	}

	// -- Corpus driver: issue_161 input verbatim. Outer object literal
	// at stmt position whose field value is itself a block.

	public function testCorpusIssue161IfBodyInObjectLiteral():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class Main {\n\tpublic static function main() {\n\t\t{\n\t\t\tfoo: {\n\t\t\t\tif (foo)\n\t\t\t\t\tbar;\n\t\t\t\t"";\n\t\t\t}\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, cls.members.length);
	}

	// -- Idempotency: corpus issue_161 round-trip via the module
	// pipeline (parse + write + parse + write must converge).

	public function testCorpusIssue161RoundTrip():Void {
		roundTrip(
			'class Main {\n\tpublic static function main() {\n\t\t{\n\t\t\tfoo: {\n\t\t\t\tif (foo)\n\t\t\t\t\tbar;\n\t\t\t\t"";\n\t\t\t}\n\t\t}\n\t}\n}',
			'issue_161_if_body_in_object_literal'
		);
	}

	public function testCorpusWhitespaceAfterObjectLiteralRoundTrip():Void {
		roundTrip(
			"class Main {\n\tstatic function main() {\n\t\tswitch (foo) {\n\t\t\tcase {kind: TkIdent, text: \"error\"}:\n\t\t\t\tdoSomething();\n\t\t}\n\t\t{f: macro ${a},}\n\t}\n}",
			'whitespace_after_object_literal'
		);
	}
}
