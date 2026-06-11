package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxStatement;

/**
 * Slice 43 — `stmtExprNoSemi` direct-returns true on `Is`.
 *
 * `HxStatement.ExprStmt` carries `@:fmt(trailOptParseGate('stmtExprNoSemi'))`
 * — the trailing `;` is optional iff the gate returns true. Pre-slice
 * the predicate stopped at brace-terminated ctors (`ObjectLit`,
 * `ArrayExpr`, `DollarBlockExpr`, plus the recursive Assign / If /
 * Meta / Return arms and the `endsWithCloseBrace` fallback); a bare
 * `Is` stmt — `x is Type` — required `;` even when followed by `}`.
 *
 * Departs from the brace-terminated rule of Slices 30 / 39 / 42 —
 * `Is`'s last token is a type-ref leaf (`String` ident in
 * `x is String`), not `}` / `]`. Permissive extension of
 * "last-stmt-in-block" semantics, consistent with the existing
 * permissive handling of `{a:1} {b:2}` (two ObjectLit stmts no `;`).
 *
 * Twin of Slice 30 / 39 / 42 mechanically: direct ctor-name match in
 * the gate, plus the same `*Assign`-RHS carve-out so `x = a is Int`
 * keeps `;` strict (Slice 19 carve-out path).
 *
 * Corpus driver: `whitespace/issue_605_operator_is`
 * (`{x is String}` as the sole content of an outer brace-block —
 * inner ExprStmt has no `;` before the closing `}`).
 */
class HxIsStmtNoSemiSliceTest extends HxTestHelpers {

	// -- Isolated: bare `x is Type` as sole statement, no `;` --

	public function testBareIsStmtNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx is String\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		final e: HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(Is(_, _)));
	}

	// -- Multi-statement: Is no `;` followed by next stmt --

	public function testIsFollowedByStmt(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx is String\n\t\ty = 5;\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(2, stmts.length);
		final e0: HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e0.match(Is(_, _)));
	}

	// -- Regression: pre-slice path with `;` still parses --

	public function testIsStmtWithSemiUnchanged(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx is String;\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		final e: HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(Is(_, _)));
	}

	// -- Post-Slice-44 (ω-slice-X3): Assign+Is RHS before `}` now parses
	// via the parse-time peek-`}` disjunct. The intrinsic Assign-RHS
	// carve-out in `stmtExprNoSemi` (`rhsCtor == 'Is'`) remains
	// load-bearing for the case where the next byte is NOT `}`.

	public function testIsAssignBeforeCloseBraceNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx = a is Int\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
	}

	// -- Regression: Assign+Is RHS with `;` parses --

	public function testIsAssignWithSemiUnchanged(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx = a is Int;\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
	}

	// -- Corpus driver shape: `{x is String}` brace-block with single
	// Is-stmt, no `;` before closing `}`. Outer `{...}` parses as
	// BlockStmt (greedy `{` at stmt position), inner Is-stmt is
	// ExprStmt inside the block body.

	public function testCorpusIssue605BraceBlockSingleIs(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\t{x is String}\n\t}\n}');
		Assert.equals(1, cls.members.length);
	}

	// -- Idempotency: issue_605 brace-block round-trip via the module
	// pipeline --

	public function testCorpusIssue605RoundTrip(): Void {
		roundTrip('class C {\n\tfunction f() {\n\t\t{x is String}\n\t}\n}', 'issue_605_operator_is');
	}

}
