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

	public function testAssignIfBlockBothNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx = if (a) { 1; } else { 2; }\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		final e: HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(Assign(_, IfExpr(_))));
	}

	// -- Post-Slice-44: Assign + IfExpr (block then + bare else) before
	// `}` now parses via the peek-`}` disjunct (ω-slice-X3). The bare
	// else's last token is the `2` literal, not `}`, but the enclosing
	// block's `}` is the next non-trivia byte so the gate elides `;`.
	// Pre-Slice-44 this raised on the missing `;`; the new behaviour
	// matches Haxe's last-stmt-in-block elision rule.

	public function testAssignIfBlockThenBareElseBeforeCloseBrace(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx = if (a) { 1; } else 2\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
	}

	// -- Isolated: Assign + IfExpr no else — body is block --

	public function testAssignIfNoElseBlockNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx = if (a) { 1; }\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
	}

	// -- Isolated: Assign + SwitchExpr no `;` (exercises endsWithCloseBrace fallback through Assign) --

	public function testAssignSwitchNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx = switch (a) { case 1: 2; case _: 3; }\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		final e: HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(Assign(_, SwitchExpr(_))));
	}

	// -- Isolated: compound-assign `+=` with if-RHS no `;` --

	public function testCompoundAssignIfBlockNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx += if (a) { 1; } else { 2; }\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		final e: HxExpr = expectExprStmt(stmts[0]);
		Assert.isTrue(e.match(AddAssign(_, IfExpr(_))));
	}

	// -- Isolated: multi-statement — Assign+IfExpr-no-semi followed by next stmt --

	public function testAssignIfFollowedByNextStmt(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx = if (a) { 1; } else { 2; }\n\t\ty = 5;\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(2, stmts.length);
	}

	// -- Isolated: corpus `lineends/expression_if` body (Allman braces, real source) --

	public function testCorpusExpressionIfBody(): Void {
		final cls: HxClassDecl = HaxeParser.parse(
			'class Main\n{\n\tpublic function new()\n\t{\n\t\tfun.expr = if (fun.ret == null || switch (fun.ret)\n\t\t{\n\t\t\tcase TPath (p): true;\n\t\t\tdefault: false;\n\t\t})\n\t\t{\n\t\t\tmacro throw "abstract method, must override";\n\t\t}\n\t\telse\n\t\t{\n\t\t\tmacro return throw "abstract method, must override";\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, cls.members.length);
	}

	// -- Idempotency: verbatim corpus source --

	public function testCorpusExpressionIfRoundTrip(): Void {
		roundTrip(
			'class Main\n{\n\tpublic function new()\n\t{\n\t\tfun.expr = if (fun.ret == null || switch (fun.ret)\n\t\t{\n\t\t\tcase TPath (p): true;\n\t\t\tdefault: false;\n\t\t})\n\t\t{\n\t\t\tmacro throw "abstract method, must override";\n\t\t}\n\t\telse\n\t\t{\n\t\t\tmacro return throw "abstract method, must override";\n\t\t}\n\t}\n}'
		);
	}

	// -- Post-Slice-44 (ω-slice-X3): Assign with non-brace RHS before
	// `}` now parses — the enclosing block's close brace acts as the
	// statement separator via the parse-time peek-`}` disjunct. The
	// intrinsic Assign-RHS carve-out in `stmtExprNoSemi` (`rhsCtor ==
	// 'ObjectLit' | 'ArrayExpr' | 'DollarBlockExpr' | 'Is'`) only
	// gates the recursive intrinsic check; peek-`}` overrides it when
	// `}` is the next non-trivia byte (the carve-out remains
	// load-bearing for the boundary-detection case below where the
	// next byte is NOT `}`).

	public function testPlainAssignBeforeCloseBraceNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx = a + b\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
	}

	public function testObjectLitAssignBeforeCloseBraceNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx = {a: 1}\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
	}

	public function testArrayExprAssignBeforeCloseBraceNoSemi(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx = [1, 2, 3]\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
	}

	// -- Regression: Assign-stmt boundary detection. When the next byte
	// after a `;`-less Assign is ANOTHER stmt token (ident, kw) — NOT
	// `}` — the gate's peek-`}` disjunct stays false and the `;`
	// remains required. Pins the multi-stmt boundary that the carve-out
	// originally guarded.

	public function testAssignFollowedByIdentRegression(): Void {
		Assert.raises(() -> HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx = a + b\n\t\ty = c\n\t}\n}'));
	}

	// -- Regression: pre-slice path — Assign+IfExpr WITH `;` still parses --

	public function testAssignIfWithSemiUnchanged(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tx = if (a) { 1; } else { 2; };\n\t}\n}');
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
	}

}
