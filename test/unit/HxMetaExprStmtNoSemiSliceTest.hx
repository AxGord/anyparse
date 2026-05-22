package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxStatement;

/**
 * Slice 28 — `stmtExprNoSemi` recurses through `MetaExpr` into its
 * inner expression, and through `ReturnExpr` into its value.
 *
 * `HxStatement.ExprStmt` carries `@:fmt(trailOptParseGate('stmtExprNoSemi'))`
 * — the trailing `;` is optional iff the parsed expression visually
 * ends with `}`. Pre-slice the predicate stopped at `MetaExpr` (the
 * `@:nullSafety(Off) …` shape) and at `ReturnExpr` (the
 * `return switch (…) { … }` shape reachable via meta-wrapped
 * expression position), so `@:meta return switch (…) { … }` and
 * `@:meta if (…) { … }` without trailing `;` hit the catch-all and
 * required `;` even though the inner expression was brace-terminated.
 *
 * This slice extends `stmtExprNoSemi` with two recursive arms:
 *  - `MetaExpr` — `params[0]` is the `HxMetaExpr` struct; read `.expr`
 *    via `Reflect.field` (same shape as `IfExpr`).
 *  - `ReturnExpr` — `params[0]` is the inner `HxExpr`; recurse via
 *    `stmtExprNoSemi`. Reachable only via `MetaExpr` because
 *    statement-position `return` routes through `HxStatement.ReturnStmt`.
 *
 * Corpus drivers: `lineends/issue_602_return_metadata`
 * (`@:nullSafety(Off) return switch thing { … }`) and
 * `indentation/issue_567_metadata_if_expression`
 * (`@:nullSafety(Off) if (foo) { … }`).
 */
class HxMetaExprStmtNoSemiSliceTest extends HxTestHelpers {

	// -- Isolated: @:meta return switch — single statement, no `;` --

	public function testMetaReturnSwitchNoSemi():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\t@:nullSafety(Off) return switch x { case _: 0; }\n\t}\n}'
		);
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		final e:HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(MetaExpr(_)));
	}

	// -- Isolated: @:meta if — single statement, no `;` --

	public function testMetaIfBlockNoSemi():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\t@:nullSafety(Off) if (foo) { 1; }\n\t}\n}'
		);
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		final e:HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(MetaExpr(_)));
	}

	// -- Nested meta — outer meta wraps another MetaExpr; recursion
	// must unwind through both layers to reach the brace-terminated
	// inner expression.

	public function testNestedMetaIfBlockNoSemi():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\t@:a @:b if (foo) { 1; }\n\t}\n}'
		);
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
	}

	// -- Multi-statement — @:meta-return-switch no `;` followed by a
	// next statement; the gate must terminate the first statement at
	// the brace so the next one parses cleanly.

	public function testMetaReturnSwitchFollowedByStmt():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\t@:nullSafety(Off) return switch x { case _: 0; }\n\t\ty = 5;\n\t}\n}'
		);
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(2, stmts.length);
	}

	// -- Regression: non-brace meta operand still requires `;`. The
	// gate must remain false for `@:meta x + 1` so the catch-all
	// throws and multi-statement boundary detection works.

	public function testMetaPlainExprRequiresSemi():Void {
		Assert.raises(() -> HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\t@:nullSafety(Off) x + 1\n\t}\n}'
		));
	}

	// -- Regression: pre-slice path with `;` still parses --

	public function testMetaReturnSwitchWithSemiUnchanged():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\t@:nullSafety(Off) return switch x { case _: 0; };\n\t}\n}'
		);
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
	}

	// -- Corpus driver: issue_602 input section verbatim --

	public function testCorpusIssue602ReturnMetadata():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class Main {\n\tstatic function foobar() {\n\t\tfunction foo() {\n\t\t\treturn bar;\n\t\t}\n\t\t@:nullSafety(Off) return switch thing {\n\t\t\tcase something: null;\n\t\t};\n\t\t@:nullSafety(Off) return switch thing {\n\t\t\tcase something: null;\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, cls.members.length);
	}

	// -- Corpus driver: issue_567 input section, first three variants
	// (the file's 4th case `@:m @:m if (…) {…}` is the nested-meta
	// shape already covered by testNestedMetaIfBlockNoSemi).

	public function testCorpusIssue567MetadataIfExpression():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class Main {\n\tstatic function main() {\n\t\t@:nullSafety(Off) if (foo) {\n\t\t\treturn;\n\t}\n\t\t@:nullSafety(Off)\n\t\tif (foo) {\n\t\t\treturn;\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, cls.members.length);
	}

	// -- Idempotency: corpus issue_602 round-trip via the module
	// pipeline (parse + write + parse + write must converge). Plain
	// mode emits `;` after the brace; the second write must agree
	// with the first.

	public function testCorpusIssue602RoundTrip():Void {
		roundTrip(
			'class Main {\n\tstatic function foobar() {\n\t\tfunction foo() {\n\t\t\treturn bar;\n\t\t}\n\t\t@:nullSafety(Off) return switch thing {\n\t\t\tcase something: null;\n\t\t};\n\t\t@:nullSafety(Off) return switch thing {\n\t\t\tcase something: null;\n\t\t}\n\t}\n}',
			'issue_602_return_metadata'
		);
	}

	public function testCorpusIssue567RoundTrip():Void {
		roundTrip(
			'class Main {\n\tstatic function main() {\n\t\t@:nullSafety(Off) if (foo) {\n\t\t\treturn;\n\t}\n\t\t@:nullSafety(Off)\n\t\tif (foo) {\n\t\t\treturn;\n\t\t}\n\t}\n}',
			'issue_567_metadata_if_expression'
		);
	}
}
