package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxStatement;

/**
 * Slice 42 — `stmtExprNoSemi` direct-returns true on `DollarBlockExpr`.
 *
 * `HxStatement.ExprStmt` carries `@:fmt(trailOptParseGate('stmtExprNoSemi'))`
 * — the trailing `;` is optional iff the parsed expression visually
 * ends with `}` (or `]`). Pre-slice the predicate already handled
 * `ObjectLit` (Slice 30) and `ArrayExpr` (Slice 39) but not the macro
 * block-reification `${expr}` ctor (`@:lead("${") @:trail("}")` on
 * `HxExpr.DollarBlockExpr`). The closing `}` is the statement's last
 * token, matching Haxe's elision rule for any `}`-closed stmt.
 *
 * Twin of Slice 30 / 39: direct ctor-name match in the gate, plus the
 * same `*Assign`-RHS carve-out so `x = ${expr}` keeps `;` strict.
 *
 * Corpus driver: `lineends/issue_215_macro_with_dollar_block`
 * (`macro { $e0; ${loop(el)} };` — `${…}` as last stmt of macro block).
 */
class HxDollarBlockExprStmtNoSemiSliceTest extends HxTestHelpers {

	// -- Isolated: bare ${expr} as sole statement, no `;` --

	public function testBareDollarBlockNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse("class C {\n\tfunction f() {\n\t\t${expr}\n\t}\n}");
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		final e: HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(DollarBlockExpr(_)));
	}

	// -- Multi-statement: ${expr} no `;` followed by next stmt --

	public function testDollarBlockFollowedByStmt(): Void {
		final cls: HxClassDecl = HaxeParser.parse("class C {\n\tfunction f() {\n\t\t${expr}\n\t\ty = 5;\n\t}\n}");
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(2, stmts.length);
		final e0: HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e0.match(DollarBlockExpr(_)));
	}

	// -- Regression: pre-slice path with `;` still parses --

	public function testDollarBlockWithSemiUnchanged(): Void {
		final cls: HxClassDecl = HaxeParser.parse("class C {\n\tfunction f() {\n\t\t${expr};\n\t}\n}");
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		final e: HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(DollarBlockExpr(_)));
	}

	// -- Post-Slice-44 (ω-slice-X3): Assign+DollarBlockExpr before `}`
	// now parses via the parse-time peek-`}` disjunct. The intrinsic
	// Assign-RHS carve-out in `stmtExprNoSemi` (`rhsCtor ==
	// 'DollarBlockExpr'`) remains load-bearing for the case where the
	// next byte is NOT `}` (see `HxAssignStmtNoSemiSliceTest.testAssignFollowedByIdentRegression`).

	public function testDollarBlockAssignBeforeCloseBraceNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse("class C {\n\tfunction f() {\n\t\tx = ${expr}\n\t}\n}");
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
	}

	// -- Corpus driver: issue_215 input verbatim --

	public function testCorpusIssue215MacroDollarBlock(): Void {
		final cls: HxClassDecl = HaxeParser.parse(
			"class Main {\n\tpublic static function main() {\n\t\tmacro { $e0; ${loop(el)}};\n\t\tmacro {\n\t\t\t$e0;\n\t\t\t${loop(el)}};\n\t}\n}"
		);
		Assert.equals(1, cls.members.length);
	}

	// -- Idempotency: issue_215 round-trip via the module pipeline --

	public function testCorpusIssue215RoundTrip(): Void {
		roundTrip(
			"class Main {\n\tpublic static function main() {\n\t\tmacro { $e0; ${loop(el)}};\n\t\tmacro {\n\t\t\t$e0;\n\t\t\t${loop(el)}};\n\t}\n}",
			"issue_215_macro_with_dollar_block"
		);
	}

}
