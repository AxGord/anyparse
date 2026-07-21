package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxStatement;

/**
 * Semi-elision slice -- `stmtExprNoSemi` recurses through NON-assign
 * binary operators, ternaries, lambdas, and the inner
 * `@:trailOpt(';')` slots of `HxIfExpr` / `HxForExpr` / `HxFnBody`.
 *
 * Haxe's `;`-elision rule is purely lexical: `Parser.semicolon` makes
 * the trailing `;` optional whenever the previously consumed token was
 * `}`, with no regard for which operator produced it. anyparse only
 * walked the `*Assign` family (`HxAssignStmtNoSemiSliceTest`), so
 * every other operator whose right operand happened to be
 * brace-terminated was rejected:
 *
 *   a =  function () { b(); } x();   parsed
 *   a << function () { b(); } x();   FAILED at `x`
 *
 * A second, distinct defect sat behind it: the `;` was PRESENT in the
 * source and still swallowed, because `HxIfExpr.thenBranch`,
 * `HxForExpr.body` and `HxFnBody.ExprBody` each own a
 * `@:trailOpt(';')` that claims the statement's terminator before the
 * `ExprStmt` gate ever runs. `a << if (e) f(m); x();` failed at `x`
 * while `a << if (e) f(m);; x();` parsed -- the doubled `;` proves the
 * swallow. `HxWhileExpr.body` owns no such slot, which is exactly why
 * `a << while (e) f(m); x();` always parsed.
 *
 * Real sources unblocked: Pony `pony/pixi/nape/NapeGroupView.hx`,
 * `NapeSpaceView.hx`, `pony/ui/gui/ButtonCore.hx`; openfl
 * `openfl/text/_internal/TextEngine.hx`; std
 * `cs|java|jvm|python/_std/Std.hx`, `haxe/macro/Printer.hx`,
 * `python/_std/sys/thread/Thread.hx`.
 *
 * The relaxation is position-scoped: it fires only for an operand
 * reached by walking INTO an `ExprStmt`, never for the expression at
 * its top. A statement that starts with `if` / `for` / `function` is
 * dispatched to `HxStatement.IfStmt` / `ForStmt` / `LocalFnStmt` first
 * and only fail-rewinds into the `ExprStmt` catch-all when the
 * statement-position branch could NOT parse it -- for `if (c) g() h();`
 * precisely because the `;` is missing. The negative tests below pin
 * that boundary.
 */
class HxBinopStmtNoSemiSliceTest extends HxTestHelpers {

	// -- A1: non-assign binop RHS ends with `}` --

	public function testShlFnExprNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\ta << function() { b(); }\n\t\tx();\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(2, stmts.length);
		final e: HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(Shl(_, FnExpr(_))));
	}

	public function testLtFnExprNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\ta.b < function() { c(); }\n\t\treturn d;\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(2, stmts.length);
	}

	public function testOrFnExprNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\ta || function() { b(); }\n\t\tx();\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(2, stmts.length);
	}

	public function testShlSwitchExprNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\ta << switch (e) { case _: 1; }\n\t\tx();\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(2, stmts.length);
	}

	// -- A1: assignment whose RHS is an ADD CHAIN ending in a switch
	// (openfl `TextEngine.hx:540` `font += "" + switch (fontName) {...}`).
	// The enclosing op IS an assignment, but the brace-terminated
	// operand sits one binop deeper, so the pre-slice assign-only walk
	// stopped at `Add` and demanded the `;`.

	public function testAddAssignChainSwitchNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\tfont += "" + switch (n) { case A: "x"; }\n\t\ty();\n\t}\n}'
		);
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(2, stmts.length);
	}

	// -- A1: `var`/`final` init whose value ends with `}` through a
	// binop / ternary / lambda. Gated by the BlockBody Star sep
	// (`blockEnded('stmtNoSemi')` -> `varInitEndsWithBrace`), not by
	// the `ExprStmt` trail gate.

	public function testFinalInitAndBlockNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tfinal a = g() && { h(); i; }\n\t\tvar b = 1;\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(2, stmts.length);
	}

	public function testVarInitTernaryChainSwitchNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\tvar s = t == null ? "N" : (a) + switch (k) { case A: "x"; }\n\t\ttabs = old;\n\t}\n}'
		);
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(2, stmts.length);
	}

	public function testVarInitArrowLambdaBlockNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tvar a = () -> { g(); }\n\t\tb();\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(2, stmts.length);
	}

	// -- A2: the `;` IS in the source and was swallowed by an inner
	// `@:trailOpt(';')` slot. Doubling it was the pre-slice workaround.

	public function testShlIfExprExplicitSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\ta << if (e) f(m);\n\t\tx();\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(2, stmts.length);
		final e: HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(Shl(_, IfExpr(_))));
	}

	public function testAssignIfExprExplicitSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\ta = if (e) f(m);\n\t\tx();\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(2, stmts.length);
	}

	public function testShlForExprExplicitSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\ta << for (i in e) f(m);\n\t\tx();\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(2, stmts.length);
	}

	public function testShlFnExprBodyExplicitSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\tt.onClick << function() if (e) d.dispatch(m);\n\t\tx();\n\t}\n}'
		);
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(2, stmts.length);
	}

	// -- `$b{exprs}` reification splice as a bare statement: `}`-terminated
	// by its own trail literal, exactly like `${expr}`, but absent from
	// `STMT_BRACE_TERMINAL_CTORS` (Pony `pony/magic/builder/DIBuilder.hx`).

	public function testDollarReifSpliceStmtNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse(
			"class C {\n\tfunction f() {\n\t\ttasks.add();\n\t\t$b{loadBody}\n\t\ttasks.end();\n\t}\n}"
		);
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(3, stmts.length);
		final e: HxExpr = expectExprStmt(stmts[1]);
		Assert.isTrue(e.match(DollarReifExpr(_)));
	}

	// -- Boundary: statement-position `if` / `for` / anonymous
	// `function` still needs its `;`. These reach `ExprStmt` only by
	// fail-rewind from the keyword-dispatched statement branch, so the
	// nested-operand relaxation must not apply.

	public function testStmtPositionIfMissingSemiStillFatal(): Void {
		Assert.raises(() -> HaxeParser.parse('class C {\n\tfunction f() {\n\t\tif (c) g() h();\n\t}\n}'));
	}

	public function testStmtPositionForMissingSemiStillFatal(): Void {
		Assert.raises(() -> HaxeParser.parse('class C {\n\tfunction f() {\n\t\tfor (i in e) g() h();\n\t}\n}'));
	}

	public function testStmtPositionAnonFnMissingSemiStillFatal(): Void {
		Assert.raises(() -> HaxeParser.parse('class C {\n\tfunction f() {\n\t\tfunction() g() h();\n\t}\n}'));
	}

	public function testBareCallMissingSemiStillFatal(): Void {
		Assert.raises(() -> HaxeParser.parse('class C {\n\tfunction f() {\n\t\tf() g();\n\t}\n}'));
	}

	// -- `while` has no body trail slot, so its `;` always reached the
	// statement gate; pinned so a future `WhileExpr` arm cannot be
	// added by symmetry without noticing the asymmetry is deliberate.

	public function testShlWhileExprExplicitSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\ta << while (e) f(m);\n\t\tx();\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(2, stmts.length);
	}

	// -- Writer fidelity: a swallowed-then-restored `;` must round-trip
	// byte-identically, and the newly-parseable no-`;` forms must be
	// idempotent.

	public function testIfExprSwallowedSemiRoundTrip(): Void {
		roundTrip('class C {\n\tfunction f() {\n\t\ta << if (e) f(m);\n\t\tx();\n\t}\n}', 'shl-if-explicit-semi');
	}

	public function testBinopBraceTailRoundTrip(): Void {
		roundTrip('class C {\n\tfunction f() {\n\t\ta << function() {\n\t\t\tb();\n\t\t}\n\t\tx();\n\t}\n}', 'shl-fn-no-semi');
	}

	public function testVarInitLambdaRoundTrip(): Void {
		roundTrip('class C {\n\tfunction f() {\n\t\tvar a = () -> {\n\t\t\tg();\n\t\t}\n\t\tb();\n\t}\n}', 'var-lambda-no-semi');
	}

}
