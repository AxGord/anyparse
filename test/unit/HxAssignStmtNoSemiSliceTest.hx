package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxStatement;

/**
 * Slice 19 — `stmtExprNoSemi` recurses through `*Assign` RHS and
 * `IfExpr` else/then branches.
 *
 * `HxStatement.ExprStmt` carries `@:fmt(trailOptParseGate('stmtExprNoSemi'))`
 * — the trailing `;` is optional iff the parsed expression visually
 * ends with `}`. The Slice-V predicate only walked `MacroClassExpr` /
 * `MacroExpr` / `SwitchExpr` / `FnExpr-block` / `TryExpr-block`; a
 * bare-statement `x = if (a) { 1; } else { 2; }` (assignment whose RHS
 * is a block-bodied if-expression) hit the catch-all and required `;`.
 *
 * This slice extends `stmtExprNoSemi` with three recursive arms:
 *  - `*Assign` (15 ctors: `Assign` + `+=`, `-=`, `*=`, `/=`, `%=`,
 *    `<<=`, `>>>=`, `>>=`, `|=`, `&=`, `^=`, `??=`, `&&=`, `||=`) —
 *    recurse into the right operand.
 *  - `IfExpr` — recurse into `elseBranch` (or `thenBranch` when there
 *    is no `else`).
 *  - `BlockExpr` — recursion target only; standalone `{ … }` at
 *    statement position is `HxStatement.BlockStmt`, never
 *    `ExprStmt(BlockExpr)`.
 *
 * Corpus drivers: `lineends/expression_if`,
 * `lineends/expression_if_indent_assignment_expr` (and the broader
 * `fun.expr = if (…) {…} else {…}` no-`;` pattern from
 * `other/issue_261` etc.). VarStmt's `endsWithCloseBrace` gate is
 * deliberately left unchanged — the writer-side `var x = …` rule
 * still keeps `;` for IfExpr/ObjectLit/BlockExpr RHS, matching
 * haxe-formatter's `var`-init-specific output policy.
 */
class HxAssignStmtNoSemiSliceTest extends HxTestHelpers {

	// -- Isolated: Assign + IfExpr (block then + block else) no `;` --

	public function testAssignIfBlockBothNoSemi():Void {
		final cls:HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx = if (a) { 1; } else { 2; }\n\t}\n}');
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		final e:HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(Assign(_, IfExpr(_))));
	}

	// -- Negative: Assign + IfExpr (block then + bare else) — bare
	// else's last token is NOT `}`, so the gate returns false and `;`
	// is required. Documents the discrimination boundary.

	public function testAssignIfBlockThenBareElseRequiresSemi():Void {
		Assert.raises(() -> HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx = if (a) { 1; } else 2\n\t}\n}'));
	}

	// -- Isolated: Assign + IfExpr no else — body is block --

	public function testAssignIfNoElseBlockNoSemi():Void {
		final cls:HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx = if (a) { 1; }\n\t}\n}');
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
	}

	// -- Isolated: Assign + SwitchExpr no `;` (exercises endsWithCloseBrace fallback through Assign) --

	public function testAssignSwitchNoSemi():Void {
		final cls:HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx = switch (a) { case 1: 2; case _: 3; }\n\t}\n}');
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		final e:HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(Assign(_, SwitchExpr(_))));
	}

	// -- Isolated: compound-assign `+=` with if-RHS no `;` --

	public function testCompoundAssignIfBlockNoSemi():Void {
		final cls:HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx += if (a) { 1; } else { 2; }\n\t}\n}');
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		final e:HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(AddAssign(_, IfExpr(_))));
	}

	// -- Isolated: multi-statement — Assign+IfExpr-no-semi followed by next stmt --

	public function testAssignIfFollowedByNextStmt():Void {
		final cls:HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx = if (a) { 1; } else { 2; }\n\t\ty = 5;\n\t}\n}');
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(2, stmts.length);
	}

	// -- Isolated: corpus `lineends/expression_if` body (Allman braces, real source) --

	public function testCorpusExpressionIfBody():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class Main\n{\n\tpublic function new()\n\t{\n\t\tfun.expr = if (fun.ret == null || switch (fun.ret)\n\t\t{\n\t\t\tcase TPath (p): true;\n\t\t\tdefault: false;\n\t\t})\n\t\t{\n\t\t\tmacro throw "abstract method, must override";\n\t\t}\n\t\telse\n\t\t{\n\t\t\tmacro return throw "abstract method, must override";\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, cls.members.length);
	}

	// -- Idempotency: verbatim corpus source --

	public function testCorpusExpressionIfRoundTrip():Void {
		roundTrip(
			'class Main\n{\n\tpublic function new()\n\t{\n\t\tfun.expr = if (fun.ret == null || switch (fun.ret)\n\t\t{\n\t\t\tcase TPath (p): true;\n\t\t\tdefault: false;\n\t\t})\n\t\t{\n\t\t\tmacro throw "abstract method, must override";\n\t\t}\n\t\telse\n\t\t{\n\t\t\tmacro return throw "abstract method, must override";\n\t\t}\n\t}\n}'
		);
	}

	// -- Regression: plain Assign without `;` MUST still throw (gate-false catch-all) --

	public function testNoPlainAssignRegression():Void {
		Assert.raises(() -> HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx = a + b\n\t}\n}'));
	}

	// -- Regression: Assign+ObjectLit without `;` MUST still throw (kept strict) --

	public function testNoObjectLitAssignRegression():Void {
		Assert.raises(() -> HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx = {a: 1}\n\t}\n}'));
	}

	// -- Regression: pre-slice path — Assign+IfExpr WITH `;` still parses --

	public function testAssignIfWithSemiUnchanged():Void {
		final cls:HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx = if (a) { 1; } else { 2; };\n\t}\n}');
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
	}
}
