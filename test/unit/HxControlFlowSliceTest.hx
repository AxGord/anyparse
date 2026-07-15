package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxIfStmt;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Tests for slice κ₁: ??= operator, if/else, while, and block statements.
 *
 * New concept: `@:optional @:kw` on struct Ref fields — the keyword
 * is the commit point for the optional branch (matchKw instead of
 * matchLit). Used by `HxIfStmt.elseBody`.
 *
 * ??= is purely additive (one ctor, zero pipeline changes). BlockStmt
 * uses existing Case 4 pattern. WhileStmt uses only existing patterns.
 */
class HxControlFlowSliceTest extends HxTestHelpers {

	/** Parse function body statements from a single-function class. */
	private function parseBody(source: String): Array<HxStatement> {
		final fn: HxFnDecl = parseSingleFnDecl(source);
		return fnBodyStmts(fn);
	}

	// --- ??= operator ---

	public function testNullCoalAssignSmoke(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class C { var x:Int = a ??= b; }');
		switch decl.init {
			case NullCoalAssign(IdentExpr(l), IdentExpr(r)):
				Assert.equals('a', (l: String));
				Assert.equals('b', (r: String));
			case null, _:
				Assert.fail('expected NullCoalAssign(IdentExpr, IdentExpr), got ${decl.init}');
		}
	}

	public function testNullCoalAssignRightAssoc(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class C { var x:Int = a ??= b ??= c; }');
		switch decl.init {
			case NullCoalAssign(IdentExpr(l), NullCoalAssign(IdentExpr(m), IdentExpr(r))):
				Assert.equals('a', (l: String));
				Assert.equals('b', (m: String));
				Assert.equals('c', (r: String));
			case null, _:
				Assert.fail('expected NullCoalAssign(a, NullCoalAssign(b, c)), got ${decl.init}');
		}
	}

	public function testNullCoalStillWorks(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class C { var x:Int = a ?? b; }');
		switch decl.init {
			case NullCoal(_, _):
				Assert.pass();
			case null, _:
				Assert.fail('expected NullCoal, got ${decl.init}');
		}
	}

	// --- if statement ---

	public function testIfSingleStatement(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { if (x) a = 1; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(stmt):
				switch stmt.cond {
					case IdentExpr(v):
						Assert.equals('x', (v: String));
					case null, _:
						Assert.fail('expected IdentExpr cond');
				}
				switch stmt.thenBody {
					case ExprStmt(_):
						Assert.pass();
					case null, _:
						Assert.fail('expected ExprStmt then');
				}
				Assert.isNull(stmt.elseBody);
			case null, _:
				Assert.fail('expected IfStmt');
		}
	}

	public function testIfBlockBody(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { if (x) { a = 1; } } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(stmt):
				switch stmt.thenBody {
					case BlockStmt(stmts):
						Assert.equals(1, stmts.length);
					case null, _:
						Assert.fail('expected BlockStmt then');
				}
				Assert.isNull(stmt.elseBody);
			case null, _:
				Assert.fail('expected IfStmt');
		}
	}

	public function testIfElseSingleStatements(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { if (x) a = 1; else b = 2; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(stmt):
				switch stmt.thenBody {
					case ExprStmt(_):
						Assert.pass();
					case null, _:
						Assert.fail('expected ExprStmt then');
				}
				switch stmt.elseBody {
					case ExprStmt(_): Assert.pass();
					case null, _: Assert.fail('expected ExprStmt else');
				}
			case null, _:
				Assert.fail('expected IfStmt');
		}
	}

	public function testIfElseBlocks(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { if (x) { a = 1; } else { b = 2; } } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(stmt):
				switch stmt.thenBody {
					case BlockStmt(stmts):
						Assert.equals(1, stmts.length);
					case null, _:
						Assert.fail('expected BlockStmt then');
				}
				switch stmt.elseBody {
					case BlockStmt(stmts): Assert.equals(1, stmts.length);
					case null, _: Assert.fail('expected BlockStmt else');
				}
			case null, _:
				Assert.fail('expected IfStmt');
		}
	}

	public function testIfElseIfElse(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { if (a) x = 1; else if (b) x = 2; else x = 3; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(stmt):
				switch stmt.cond {
					case IdentExpr(v):
						Assert.equals('a', (v: String));
					case null, _:
						Assert.fail('expected IdentExpr a');
				}
				// else branch is another if
				switch stmt.elseBody {
					case IfStmt(inner):
						switch inner.cond {
							case IdentExpr(v):
								Assert.equals('b', (v: String));
							case null, _:
								Assert.fail('expected IdentExpr b');
						}
						switch inner.elseBody {
							case ExprStmt(_): Assert.pass();
							case null, _: Assert.fail('expected final else');
						}
					case null, _: Assert.fail('expected nested IfStmt');
				}
			case null, _:
				Assert.fail('expected IfStmt');
		}
	}

	public function testIfExpressionCondition(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { if (a + b) x = 1; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(stmt):
				switch stmt.cond {
					case Add(_, _): Assert.pass();
					case null, _: Assert.fail('expected Add in cond');
				}
			case null, _:
				Assert.fail('expected IfStmt');
		}
	}

	public function testDanglingElse(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { if (a) if (b) x = 1; else y = 2; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(outer):
				// else binds to inner if, not outer
				Assert.isNull(outer.elseBody);
				switch outer.thenBody {
					case IfStmt(inner):
						Assert.notNull(inner.elseBody);
					case null, _: Assert.fail('expected inner IfStmt');
				}
			case null, _:
				Assert.fail('expected IfStmt');
		}
	}

	public function testIfWhitespace(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void {  if  (  x  )  a = 1 ;  else  b = 2 ;  } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(stmt):
				Assert.notNull(stmt.elseBody);
			case null, _:
				Assert.fail('expected IfStmt');
		}
	}

	// --- while statement ---

	public function testWhileSingleStatement(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { while (x) a = 1; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case WhileStmt(stmt):
				switch stmt.cond {
					case IdentExpr(v):
						Assert.equals('x', (v: String));
					case null, _:
						Assert.fail('expected IdentExpr cond');
				}
				switch stmt.body {
					case ExprStmt(_): Assert.pass();
					case null, _: Assert.fail('expected ExprStmt body');
				}
			case null, _:
				Assert.fail('expected WhileStmt');
		}
	}

	public function testWhileBlockBody(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { while (x) { a = 1; b = 2; } } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case WhileStmt(stmt):
				switch stmt.body {
					case BlockStmt(stmts): Assert.equals(2, stmts.length);
					case null, _: Assert.fail('expected BlockStmt body');
				}
			case null, _:
				Assert.fail('expected WhileStmt');
		}
	}

	public function testWhileWhitespace(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void {  while  (  x  )  a = 1 ;  } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case WhileStmt(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected WhileStmt');
		}
	}

	// --- block statement ---

	public function testBlockInFunctionBody(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { { a = 1; b = 2; } } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case BlockStmt(stmts):
				Assert.equals(2, stmts.length);
			case null, _:
				Assert.fail('expected BlockStmt');
		}
	}

	public function testEmptyBlock(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { {} } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case BlockStmt(stmts):
				Assert.equals(0, stmts.length);
			case null, _:
				Assert.fail('expected BlockStmt');
		}
	}

	public function testNestedBlocks(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { { { a = 1; } } } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case BlockStmt(outer):
				Assert.equals(1, outer.length);
				switch outer[0] {
					case BlockStmt(inner): Assert.equals(1, inner.length);
					case null, _: Assert.fail('expected inner BlockStmt');
				}
			case null, _:
				Assert.fail('expected outer BlockStmt');
		}
	}

	// --- integration ---

	public function testIfInModuleRoot(): Void {
		final module: HxModule = HaxeModuleParser.parse('class C { function f():Void { if (x) return 1; else return 2; } }');
		Assert.equals(1, module.decls.length);
		final cls: HxClassDecl = expectClassDecl(module.decls[0]);
		final fn: HxFnDecl = expectFnMember(cls.members[0].member);
		final stmts: Array<HxStatement> = fnBodyStmts(fn);
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case IfStmt(stmt):
				switch stmt.thenBody {
					case ReturnStmt(_):
						Assert.pass();
					case null, _:
						Assert.fail('expected ReturnStmt');
				}
				switch stmt.elseBody {
					case ReturnStmt(_): Assert.pass();
					case null, _: Assert.fail('expected ReturnStmt else');
				}
			case null, _:
				Assert.fail('expected IfStmt');
		}
	}

	public function testMixedStatements(): Void {
		final body: Array<HxStatement> =
			parseBody('class C { function f():Void { var x:Int = 0; if (x) x = 1; while (x) x = x + 1; return x; } }');
		Assert.equals(4, body.length);
		switch body[0] {
			case VarStmt(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected VarStmt');
		}
		switch body[1] {
			case IfStmt(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected IfStmt');
		}
		switch body[2] {
			case WhileStmt(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected WhileStmt');
		}
		switch body[3] {
			case ReturnStmt(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected ReturnStmt');
		}
	}

	public function testIfWithWhileBody(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { if (a) while (b) x = 1; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(stmt):
				switch stmt.thenBody {
					case WhileStmt(_): Assert.pass();
					case null, _: Assert.fail('expected WhileStmt as if body');
				}
			case null, _:
				Assert.fail('expected IfStmt');
		}
	}

	public function testWordBoundaryIfx(): Void {
		// "ifx" should not match "if" keyword
		final body: Array<HxStatement> = parseBody('class C { function f():Void { ifx = 1; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ExprStmt(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected ExprStmt (ifx is identifier)');
		}
	}

	public function testWordBoundaryWhiled(): Void {
		// "whiled" should not match "while" keyword
		final body: Array<HxStatement> = parseBody('class C { function f():Void { whiled = 1; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ExprStmt(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected ExprStmt (whiled is identifier)');
		}
	}

	// --- empty statement `;` (Slice Q) ---

	public function testEmptyStatementAlone(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { ; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case EmptyStmt:
				Assert.pass();
			case null, _:
				Assert.fail('expected EmptyStmt');
		}
	}

	public function testEmptyStatementAfterBlock(): Void {
		// `}` closes the block (no terminator needed), leaving the `;`
		// as a standalone empty statement before the next statement.
		final body: Array<HxStatement> = parseBody('class C { function f():Void { { a; }; b; } }');
		Assert.equals(3, body.length);
		switch body[0] {
			case BlockStmt(stmts):
				Assert.equals(1, stmts.length);
			case null, _:
				Assert.fail('expected BlockStmt');
		}
		switch body[1] {
			case EmptyStmt:
				Assert.pass();
			case null, _:
				Assert.fail('expected EmptyStmt');
		}
		switch body[2] {
			case ExprStmt(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected ExprStmt');
		}
	}

	public function testEmptyStatementInSwitchCaseBody(): Void {
		// The WrapList.isOPLShape blocker shape: a brace-closed nested
		// switch as a case body, followed by the optional trailing `;`.
		final body: Array<HxStatement> = parseBody(
			'class C { function f():Void { switch a { case 1: switch b { case _: trace(9); }; case _: trace(0); } } }'
		);
		Assert.equals(1, body.length);
		// `switch a {…}` (no parens) → SwitchStmtBare; the inner
		// `switch b {…}` likewise. Mirrors WrapList.isOPLShape's
		// unparenthesized `switch arr[1] {…};` case body verbatim.
		switch body[0] {
			case SwitchStmtBare(sw):
				Assert.equals(2, sw.cases.length);
				switch sw.cases[0] {
					case CaseBranch(b):
						Assert.equals(2, b.body.length);
						switch b.body[0] {
							case SwitchStmtBare(_):
								Assert.pass();
							case null, _:
								Assert.fail('expected nested SwitchStmtBare');
						}
						switch b.body[1] {
							case EmptyStmt: Assert.pass();
							case null, _: Assert.fail('expected EmptyStmt after nested switch');
						}
					case null, _: Assert.fail('expected CaseBranch');
				}
			case null, _:
				Assert.fail('expected SwitchStmtBare');
		}
	}

	public function testExprStmtRegressionUnaffected(): Void {
		// EmptyStmt only fires when the statement starts with `;`;
		// `foo();` still parses as ExprStmt (consumes its own `;`).
		final body: Array<HxStatement> = parseBody('class C { function f():Void { foo(); } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ExprStmt(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected ExprStmt (not EmptyStmt)');
		}
	}

	public function testEmptyStatementDoubled(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { ;; } }');
		Assert.equals(2, body.length);
		switch body[0] {
			case EmptyStmt:
				Assert.pass();
			case null, _:
				Assert.fail('expected first EmptyStmt');
		}
		switch body[1] {
			case EmptyStmt:
				Assert.pass();
			case null, _:
				Assert.fail('expected second EmptyStmt');
		}
	}

	public function testEmptyStatementRoundTrip(): Void {
		roundTrip('class C { function f():Void { { a; }; b; } }', 'empty-stmt-after-block');
		roundTrip(
			'class C { function f():Void { switch a { case 1: switch b { case _: trace(9); }; case _: trace(0); } } }',
			'empty-stmt-in-switch-case'
		);
	}

	// --- Slice U regression: stmt-position var/final unaffected by HxExpr.VarExpr/FinalExpr ---

	public function testStmtVarFinalNotShiftedByExprCtors(): Void {
		// Adding HxExpr.VarExpr/FinalExpr must NOT make a statement-position
		// `var`/`final` parse as ExprStmt(VarExpr/FinalExpr): HxStatement
		// tries VarStmt/FinalStmt (@:kw) before the ExprStmt catch-all.
		final body: Array<HxStatement> = parseBody('class C { function f():Void { var x = 1; final y = 2; } }');
		Assert.equals(2, body.length);
		switch body[0] {
			case VarStmt(d):
				Assert.equals('x', (d.name: String));
			case null, _:
				Assert.fail('expected VarStmt(x), got ${body[0]}');
		}
		switch body[1] {
			case FinalStmt(d):
				Assert.equals('y', (d.name: String));
			case null, _:
				Assert.fail('expected FinalStmt(y), got ${body[1]}');
		}
	}

	// --- Slice W regression: stmt-position throw unaffected by HxExpr.ThrowExpr ---

	public function testStmtThrowNotShiftedByExprCtor(): Void {
		// Adding HxExpr.ThrowExpr must NOT make a statement-position
		// `throw e;` parse as ExprStmt(ThrowExpr): HxStatement tries
		// ThrowStmt (@:kw('throw'), declared before the ExprStmt
		// catch-all) first. The whole HxThrowBodySliceTest suite is the
		// writer-side net for this; this pins the parse-side AST shape.
		final body: Array<HxStatement> = parseBody('class C { function f():Void { throw 1; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ThrowStmt(IntLit(v)):
				Assert.equals(1, (v: Int));
			case null, _:
				Assert.fail('expected ThrowStmt(IntLit(1)), got ${body[0]}');
		}
	}

	// --- Slice V: macro-block / brace-terminated expr as no-`;` statement ---

	public function testMacroBlockStatementNoSemi(): Void {
		// `macro { … }` as a statement has no trailing `;` — the
		// shape gate (`stmtExprNoSemi` true for MacroExpr-over-BlockExpr)
		// makes the `;` optional. Pre-slice this failed `expected HxDecl`.
		final body: Array<HxStatement> = parseBody('class C { function f():Void { macro { var x = 1; } } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ExprStmt(e):
				switch e {
					case MacroExpr(_): Assert.pass();
					case null, _: Assert.fail('expected ExprStmt(MacroExpr), got ${body[0]}');
				}
			case null, _:
				Assert.fail('expected ExprStmt, got ${body[0]}');
		}
	}

	public function testMacroSwitchStatementNoSemi(): Void {
		// Brace-terminated superset: `macro switch (e) { … }` — gate
		// recurses into the MacroExpr operand (endsWithCloseBrace set).
		final body: Array<HxStatement> = parseBody('class C { function f():Void { macro switch e { case _: 1; } } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ExprStmt(e):
				switch e {
					case MacroExpr(_): Assert.pass();
					case null, _: Assert.fail('expected ExprStmt(MacroExpr), got ${body[0]}');
				}
			case null, _:
				Assert.fail('expected ExprStmt, got ${body[0]}');
		}
	}

	public function testNonBraceExprStillRequiresSemi(): Void {
		// Non-brace exprs keep the required `;` — the gate emits
		// `expectLit`, which throws to terminate the statement so the
		// Star loop boundary survives (the V −33 regression guard).
		final body: Array<HxStatement> = parseBody('class C { function f():Void { foo(); bar(); } }');
		Assert.equals(2, body.length);
		// Missing `;` between two non-brace calls must NOT parse —
		// mechanism B is stricter here than the reverted blanket
		// `:trailOpt` approach (which leniently accepted `foo() bar()`).
		Assert.raises(parseBody.bind('class C { function f():Void { foo() bar(); } }'));
	}

	public function testSwitchArmMultiStmtBoundaryPreserved(): Void {
		// The exact V minimal repro: a multi-statement switch-arm body.
		// `foo(e)` (non-brace) requires `;` so `throw 'x'` is a separate
		// statement, not over-consumed into the same expr.
		final body: Array<HxStatement> = parseBody("class C { function f():Void { switch e { case _: foo(e); throw 'x'; } } }");
		Assert.equals(1, body.length);
		switch body[0] {
			case SwitchStmtBare(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected SwitchStmtBare, got ${body[0]}');
		}
	}

	public function testMacroBlockStatementRoundTrip(): Void {
		roundTrip('class C { function f():Void { macro { var x = 1; } } }', 'macro-block-no-semi');
		roundTrip('class C { function f():Void { macro switch e { case _: 1; } } }', 'macro-switch-no-semi');
	}

	// --- Slice X2: bare no-`;` then-body before `else` (the sole
	// remaining WriterLowering.hx self-parse blocker). The Slice-V
	// ExprStmt trail gate is extended: `;` optional when an `else`
	// keyword immediately follows (non-consuming peekKw). AST is
	// identical to the `;`-terminated form (`;` consumed-not-stored).

	public function testIfBareThenBlockElse(): Void {
		// THE WriterLowering.hx blocker shape: `if (cond) bareCall`
		// newline `else { … }`. Pre-slice: `expected HxDecl` (IfStmt
		// failed on the missing `;`, expr fallback can't host a block
		// else-body).
		final body: Array<HxStatement> = parseBody('class C { function f():Void { if (c) g()\nelse { h(); } } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(stmt):
				switch stmt.thenBody {
					case ExprStmt(_):
						Assert.pass();
					case null, _:
						Assert.fail('expected ExprStmt then, got ${stmt.thenBody}');
				}
				switch stmt.elseBody {
					case BlockStmt(stmts): Assert.equals(1, stmts.length);
					case null, _: Assert.fail('expected BlockStmt else, got ${stmt.elseBody}');
				}
			case null, _:
				Assert.fail('expected IfStmt, got ${body[0]}');
		}
	}

	public function testIfBareThenBareElseNoSemiBeforeCloseBrace(): Void {
		// Post-Slice-44 (ω-slice-X3): the documented "danger zone" of the
		// pre-slice gate (bare else-body before enclosing `}`) is closed
		// by the parse-time peek-`}` disjunct. `if (c) g() else h()`
		// with NO `;` anywhere now parses: the else-peek relaxes the
		// then-body `;`, and the bare else-body `h()` is followed by
		// the enclosing block's `}` — peek-`}` triggers and the `;` is
		// elided. The "positionally-scoped soft-terminator" the prior
		// limitation comment named as the exit criterion IS the new
		// peek-`}` disjunct.
		final body: Array<HxStatement> = parseBody('class C { function f():Void { if (c) g() else h() } }');
		Assert.equals(1, body.length);
	}

	public function testIfBareThenElseIfChain(): Void {
		// P12: bare-then `else if (…) bare-then else { block }`.
		final body: Array<HxStatement> = parseBody('class C { function f():Void { if (c) g() else if (d) h() else { k(); } } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(stmt):
				switch stmt.elseBody {
					case IfStmt(inner):
						switch inner.elseBody {
							case BlockStmt(stmts): Assert.equals(1, stmts.length);
							case null, _: Assert.fail('expected BlockStmt final else, got ${inner.elseBody}');
						}
					case null, _: Assert.fail('expected nested IfStmt else, got ${stmt.elseBody}');
				}
			case null, _:
				Assert.fail('expected IfStmt, got ${body[0]}');
		}
	}

	public function testIfBareThenSemiBlockElseStillParses(): Void {
		// Regression (P7): the pre-existing `;`-terminated bare-then +
		// block-else form must still parse — the gate is OR-extended,
		// not replaced.
		final body: Array<HxStatement> = parseBody('class C { function f():Void { if (c) g(); else { h(); } } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(stmt):
				switch stmt.elseBody {
					case BlockStmt(stmts): Assert.equals(1, stmts.length);
					case null, _: Assert.fail('expected BlockStmt else, got ${stmt.elseBody}');
				}
			case null, _:
				Assert.fail('expected IfStmt, got ${body[0]}');
		}
	}

	public function testElsePeekScopedToElseOnly(): Void {
		// The else-peek must NOT relax `;` for a bare then-body NOT
		// followed by `else`: `if (c) g() h();` keeps the Slice-V
		// `;`-required boundary (next token `h`, not `else`), so the
		// IfStmt then-body's missing `;` is still fatal.
		Assert.raises(parseBody.bind('class C { function f():Void { if (c) g() h(); } }'));
	}

	public function testSliceVBoundaryStillIntactWithX2(): Void {
		// The V −33 regression guard, re-pinned under Slice X2: a
		// missing `;` between two non-brace calls (no `else` in sight)
		// must still NOT parse — peekKw('else') is false here.
		Assert.raises(parseBody.bind('class C { function f():Void { foo() bar(); } }'));
	}

	public function testBareThenNoElseNoSemiBeforeCloseBrace(): Void {
		// Post-Slice-44 (ω-slice-X3): the documented limitation is
		// closed. A bare non-`;` then-body with NO `else` and a block-
		// end terminator now parses — the body `g()` is followed by
		// the enclosing block's `}` so the parse-time peek-`}`
		// disjunct on `ExprStmt`'s gate elides the `;`. Multi-stmt
		// boundary detection is preserved (a bare-then followed by
		// another stmt with no `;` between them still throws — see
		// `testBareCallFollowedByBareCallStillRejected` above).
		final body: Array<HxStatement> = parseBody('class C { function f():Void { if (c) g() } }');
		Assert.equals(1, body.length);
	}

	public function testIfBareThenElseRoundTrip(): Void {
		roundTrip('class C { function f():Void { if (c) g()\nelse { h(); } } }', 'if-bare-then-block-else');
		roundTrip('class C { function f():Void { if (c) g(); else { h(); } } }', 'if-bare-then-semi-block-else');
	}

}
