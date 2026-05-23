package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxStatement;

/**
 * Slice 44 (ω-slice-X3) — `ExprStmt` trail-`;` peek-`}` disjunct.
 *
 * `HxStatement.ExprStmt` carries `@:fmt(trailOptParseGate('stmtExprNoSemi'))`
 * — the trailing `;` is optional iff the gate returns true. Slices
 * 19/28/30/39/42/43 accumulated 6 INTRINSIC direct-return arms on
 * `stmtExprNoSemi` (BlockExpr / MetaExpr-ReturnExpr / ObjectLit /
 * ArrayExpr / DollarBlockExpr / Is) — each one made another
 * brace/bracket-terminated expr kind permissive at statement position.
 *
 * The principled invariant generalising those 6 ctors is EXTRINSIC, not
 * intrinsic: any `ExprStmt` whose next non-trivia byte is `}` may elide
 * its `;` because the enclosing block's closing brace itself is the
 * statement separator — regardless of the inner expr's kind. This slice
 * adds the `|| peekLit(ctx, "}")` disjunct to the parse-time gate in
 * `Lowering.hx` alongside the Slice-X2 `peekKw(ctx, "else")` disjunct.
 * Newly accepted shapes: bare `Call` / `IdentExpr` / non-assign binop /
 * ternary / etc. as the LAST stmt of any enclosing block (fn body,
 * switch arm, block-bodied for/while/if, top-level `{ … }` block).
 *
 * Cascade-safe: `f() g()` (no `;`, ident next) still throws — peek-`}`
 * only fires when `}` is GENUINELY the next non-trivia byte; `f(); g();`
 * boundary detection is unchanged.
 *
 * Corpus driver: `wrapping/issue_357_array_comprehension` (second class
 * — `[for (a in xs) { bar(a) }]` array comprehension with block-bodied
 * for-loop whose only stmt is a bare call).
 */
class HxStmtBlockEndNoSemiSliceTest extends HxTestHelpers {

	// -- Bare Call as last stmt of fn body, no `;` --

	public function testBareCallLastStmtNoSemi():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\tfoo()\n\t}\n}'
		);
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		final e:HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(Call(_, _)));
	}

	// -- Bare IdentExpr as last stmt of fn body, no `;` --

	public function testBareIdentLastStmtNoSemi():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\tx\n\t}\n}'
		);
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		final e:HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(IdentExpr(_)));
	}

	// -- Multi-stmt: `;`-separated leading stmts + bare final --

	public function testSemiSeparatedThenBareFinal():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\tx;\n\t\ty\n\t}\n}'
		);
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(2, stmts.length);
	}

	// -- Two consecutive fn decls, each with a bare last stmt --

	public function testTwoFnsEachWithBareLastStmt():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\tfoo()\n\t}\n\n\tfunction g() {\n\t\tbar()\n\t}\n}'
		);
		Assert.equals(2, cls.members.length);
	}

	// -- Non-assign binop as last stmt — pre-Slice-44 this required `;`. --

	public function testBinopLastStmtNoSemi():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\ta + b\n\t}\n}'
		);
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
	}

	// -- Corpus driver: issue_357 second class shape (array comprehension
	// with block-bodied for whose only stmt is a bare call). The first
	// class parses pre-slice; the second class was the sole blocker.

	public function testCorpusIssue357BlockBodyBareCall():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class Main {\n\tfunction foo() {\n\t\tcmd = [\n\t\t\tfor (a in xs) {\n\t\t\t\tbar(a)\n\t\t\t}\n\t\t].join(" ");\n\t}\n}'
		);
		Assert.equals(1, cls.members.length);
	}

	// -- Regression: peek-`}` is SPECIFIC to `}`. A bare expr followed
	// by an ident (next stmt) still throws on the missing `;`.

	public function testBareCallFollowedByIdentRegression():Void {
		Assert.raises(() -> HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\tfoo()\n\t\tbar()\n\t}\n}'
		));
	}
}
