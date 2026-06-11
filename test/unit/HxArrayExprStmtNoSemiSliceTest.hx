package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxStatement;

/**
 * Slice 39 — `stmtExprNoSemi` direct-returns true on `ArrayExpr`.
 *
 * `HxStatement.ExprStmt` carries `@:fmt(trailOptParseGate('stmtExprNoSemi'))`
 * — the trailing `;` is optional iff the parsed expression visually
 * ends with `}` (or `]`, by extension). Pre-slice the predicate stopped
 * at `ObjectLit` and `endsWithCloseBrace`; a bare `[…]` at statement
 * position required `;` even though the closing `]` is the statement's
 * last token, matching Haxe's elision rule for any `}`/`]`-closed stmt.
 *
 * Twin of Slice 30 (`ObjectLit`): direct ctor-name match in the gate,
 * plus the same `*Assign`-RHS carve-out so `x = [1, 2, 3]` keeps `;`
 * strict (Slice 19 carve-out path).
 *
 * Corpus driver: `sameline/issue_365_array_comprehension`
 * (`[if (foo) bar else foo, …]` as sole stmt of fn body).
 */
class HxArrayExprStmtNoSemiSliceTest extends HxTestHelpers {

	// -- Isolated: bare array literal as sole statement, no `;` --

	public function testBareArrayExprNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\t[1, 2, 3]\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		final e: HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(ArrayExpr(_)));
	}

	// -- Isolated: array of if-else expressions, no `;` (corpus shape) --

	public function testArrayOfIfElseNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\t[if (foo) bar else foo, if (foo) bar else foo]\n\t}\n}'
		);
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		final e: HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(ArrayExpr(_)));
	}

	// -- Multi-statement: array literal no `;` followed by next stmt.
	// The gate must terminate the first statement at `]` so the next
	// one parses cleanly.

	public function testArrayExprFollowedByStmt(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\t[1, 2, 3]\n\t\ty = 5;\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(2, stmts.length);
		final e0: HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e0.match(ArrayExpr(_)));
	}

	// -- Regression: pre-slice path with `;` still parses --

	public function testArrayExprWithSemiUnchanged(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\t[1, 2, 3];\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		final e: HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(ArrayExpr(_)));
	}

	// -- Corpus driver: issue_365 input verbatim (second function — the
	// blocker; the first parses pre-slice via `return [...].sum();`).

	public function testCorpusIssue365ArrayComprehension(): Void {
		final cls: HxClassDecl = HaxeParser.parse(
			'class Main {\n\tstatic function main() {\n\t\treturn [\n\t\t\tfor (meta in node.metadata) {\n\t\t\t\tvar child = node.children[meta - 1];\n\t\t\t\tif (child == null) 0 else value(child);\n\t\t\t}\n\t\t].sum();\n\t}\n\n\tstatic function main() {\n\t\t[\n\t\t\tif (foo) bar else foo,\n\t\t\tif (foo) bar else foo,\n\t\t\tif (foo) bar else foo,\n\t\t\tif (foo) bar else foo,\n\t\t\tif (foo) bar else foo\n\t\t]\n\t}\n}'
		);
		Assert.equals(2, cls.members.length);
	}

	// -- Idempotency: issue_365 round-trip via the module pipeline --

	public function testCorpusIssue365RoundTrip(): Void {
		roundTrip(
			'class Main {\n\tstatic function main() {\n\t\treturn [\n\t\t\tfor (meta in node.metadata) {\n\t\t\t\tvar child = node.children[meta - 1];\n\t\t\t\tif (child == null) 0 else value(child);\n\t\t\t}\n\t\t].sum();\n\t}\n\n\tstatic function main() {\n\t\t[\n\t\t\tif (foo) bar else foo,\n\t\t\tif (foo) bar else foo,\n\t\t\tif (foo) bar else foo,\n\t\t\tif (foo) bar else foo,\n\t\t\tif (foo) bar else foo\n\t\t]\n\t}\n}',
			'issue_365_array_comprehension'
		);
	}

}
