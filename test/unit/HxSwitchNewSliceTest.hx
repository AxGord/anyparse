package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxCaseBranch;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxDefaultBranch;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxNewExpr;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxSwitchCase;
import anyparse.grammar.haxe.HxSwitchStmt;
import anyparse.runtime.ParseError;

/**
 * Tests for slice mu_1: switch statement and new expression.
 *
 * Switch statement: one Lowering change — `@:tryparse` metadata on
 * Star struct fields forces try-parse termination even on last fields
 * (D49). Case body terminates when the next token fails to parse as
 * an `HxStatement` (i.e. `case`, `default`, or `}`).
 *
 * New expression: zero Lowering changes — `@:kw('new')` on Case 3
 * (single Ref wrapping) already works.
 */
class HxSwitchNewSliceTest extends HxTestHelpers {

	/** Parse function body statements from a single-function class. */
	private function parseBody(source:String):Array<HxStatement> {
		final fn:HxFnDecl = parseSingleFnDecl(source);
		return fnBodyStmts(fn);
	}

	/** Extract switch statement from the first body statement. */
	private function parseSwitch(source:String):HxSwitchStmt {
		final body:Array<HxStatement> = parseBody(source);
		Assert.equals(1, body.length);
		return switch body[0] {
			case SwitchStmt(stmt): stmt;
			case null, _: throw 'expected SwitchStmt';
		};
	}

	// ---- Switch statement tests ----

	public function testEmptySwitch():Void {
		final sw:HxSwitchStmt = parseSwitch('class C { function f():Void { switch (x) {} } }');
		switch sw.expr {
			case IdentExpr(v): Assert.equals('x', (v : String));
			case null, _: Assert.fail('expected IdentExpr');
		}
		Assert.equals(0, sw.cases.length);
	}

	public function testSingleCaseWithBody():Void {
		final sw:HxSwitchStmt = parseSwitch('class C { function f():Void { switch (x) { case 1: y; } } }');
		Assert.equals(1, sw.cases.length);
		switch sw.cases[0] {
			case CaseBranch(branch):
				switch branch.pattern {
					case IntLit(v): Assert.equals(1, v);
					case null, _: Assert.fail('expected IntLit pattern');
				}
				Assert.equals(1, branch.body.length);
			case null, _: Assert.fail('expected CaseBranch');
		}
	}

	public function testMultipleCases():Void {
		final sw:HxSwitchStmt = parseSwitch('class C { function f():Void { switch (x) { case 1: a; case 2: b; } } }');
		Assert.equals(2, sw.cases.length);
		switch sw.cases[0] {
			case CaseBranch(b): Assert.equals(1, b.body.length);
			case null, _: Assert.fail('expected first CaseBranch');
		}
		switch sw.cases[1] {
			case CaseBranch(b): Assert.equals(1, b.body.length);
			case null, _: Assert.fail('expected second CaseBranch');
		}
	}

	public function testDefaultBranch():Void {
		final sw:HxSwitchStmt = parseSwitch('class C { function f():Void { switch (x) { default: y; } } }');
		Assert.equals(1, sw.cases.length);
		switch sw.cases[0] {
			case DefaultBranch(branch): Assert.equals(1, branch.stmts.length);
			case null, _: Assert.fail('expected DefaultBranch');
		}
	}

	public function testCaseAndDefault():Void {
		final sw:HxSwitchStmt = parseSwitch('class C { function f():Void { switch (x) { case 1: a; default: b; } } }');
		Assert.equals(2, sw.cases.length);
		switch sw.cases[0] {
			case CaseBranch(b):
				switch b.pattern {
					case IntLit(v): Assert.equals(1, v);
					case null, _: Assert.fail('expected IntLit');
				}
				Assert.equals(1, b.body.length);
			case null, _: Assert.fail('expected CaseBranch');
		}
		switch sw.cases[1] {
			case DefaultBranch(branch): Assert.equals(1, branch.stmts.length);
			case null, _: Assert.fail('expected DefaultBranch');
		}
	}

	public function testEmptyCaseBody():Void {
		final sw:HxSwitchStmt = parseSwitch('class C { function f():Void { switch (x) { case 1: case 2: y; } } }');
		Assert.equals(2, sw.cases.length);
		switch sw.cases[0] {
			case CaseBranch(b): Assert.equals(0, b.body.length);
			case null, _: Assert.fail('expected first CaseBranch');
		}
		switch sw.cases[1] {
			case CaseBranch(b): Assert.equals(1, b.body.length);
			case null, _: Assert.fail('expected second CaseBranch');
		}
	}

	public function testMultiStatementBody():Void {
		final sw:HxSwitchStmt = parseSwitch('class C { function f():Void { switch (x) { case 1: a; b; c; } } }');
		Assert.equals(1, sw.cases.length);
		switch sw.cases[0] {
			case CaseBranch(b): Assert.equals(3, b.body.length);
			case null, _: Assert.fail('expected CaseBranch');
		}
	}

	public function testNestedSwitch():Void {
		final sw:HxSwitchStmt = parseSwitch(
			'class C { function f():Void { switch (x) { case 1: switch (y) { case 2: z; } } } }'
		);
		Assert.equals(1, sw.cases.length);
		switch sw.cases[0] {
			case CaseBranch(b):
				Assert.equals(1, b.body.length);
				switch b.body[0] {
					case SwitchStmt(inner):
						Assert.equals(1, inner.cases.length);
					case null, _: Assert.fail('expected nested SwitchStmt');
				}
			case null, _: Assert.fail('expected CaseBranch');
		}
	}

	public function testSwitchExpressionSubject():Void {
		final sw:HxSwitchStmt = parseSwitch('class C { function f():Void { switch (a + b) { case 1: x; } } }');
		switch sw.expr {
			case Add(left, right):
				switch left {
					case IdentExpr(v): Assert.equals('a', (v : String));
					case null, _: Assert.fail('expected IdentExpr left');
				}
				switch right {
					case IdentExpr(v): Assert.equals('b', (v : String));
					case null, _: Assert.fail('expected IdentExpr right');
				}
			case null, _: Assert.fail('expected Add expr');
		}
	}

	public function testCaseWithCallPattern():Void {
		final sw:HxSwitchStmt = parseSwitch('class C { function f():Void { switch (x) { case Foo(a, b): y; } } }');
		Assert.equals(1, sw.cases.length);
		switch sw.cases[0] {
			case CaseBranch(b):
				switch b.pattern {
					case Call(operand, args):
						switch operand {
							case IdentExpr(v): Assert.equals('Foo', (v : String));
							case null, _: Assert.fail('expected IdentExpr operand');
						}
						Assert.equals(2, args.length);
					case null, _: Assert.fail('expected Call pattern');
				}
			case null, _: Assert.fail('expected CaseBranch');
		}
	}

	public function testSwitchWhitespace():Void {
		final sw:HxSwitchStmt = parseSwitch(
			'class C { function f():Void { switch  (  x  )  {  case  1  :  y  ;  } } }'
		);
		Assert.equals(1, sw.cases.length);
		switch sw.cases[0] {
			case CaseBranch(b): Assert.equals(1, b.body.length);
			case null, _: Assert.fail('expected CaseBranch');
		}
	}

	public function testWordBoundarySwitching():Void {
		// `switching` should parse as IdentExpr, not as `switch` keyword + `ing`
		final body:Array<HxStatement> = parseBody('class C { function f():Void { switching; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ExprStmt(expr):
				switch expr {
					case IdentExpr(v): Assert.equals('switching', (v : String));
					case null, _: Assert.fail('expected IdentExpr');
				}
			case null, _: Assert.fail('expected ExprStmt');
		}
	}

	public function testSwitchInModule():Void {
		final module:HxModule = HaxeModuleParser.parse(
			'class C { function f():Void { switch (x) { case 1: y; default: z; } } }'
		);
		Assert.equals(1, module.decls.length);
		final cls:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals(1, cls.members.length);
		final fn:HxFnDecl = expectFnMember(cls.members[0].member);
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case SwitchStmt(sw): Assert.equals(2, sw.cases.length);
			case null, _: Assert.fail('expected SwitchStmt');
		}
	}

	public function testDefaultWithMultipleStatements():Void {
		final sw:HxSwitchStmt = parseSwitch(
			'class C { function f():Void { switch (x) { default: a; b; } } }'
		);
		Assert.equals(1, sw.cases.length);
		switch sw.cases[0] {
			case DefaultBranch(branch): Assert.equals(2, branch.stmts.length);
			case null, _: Assert.fail('expected DefaultBranch');
		}
	}

	public function testEmptyDefaultBody():Void {
		final sw:HxSwitchStmt = parseSwitch('class C { function f():Void { switch (x) { default: } } }');
		Assert.equals(1, sw.cases.length);
		switch sw.cases[0] {
			case DefaultBranch(branch): Assert.equals(0, branch.stmts.length);
			case null, _: Assert.fail('expected DefaultBranch');
		}
	}

	// ---- New expression tests ----

	public function testNewZeroArgs():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { new Foo(); } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ExprStmt(expr):
				switch expr {
					case NewExpr(ne):
						Assert.equals('Foo', (ne.type : String));
						Assert.equals(0, ne.args.length);
					case null, _: Assert.fail('expected NewExpr');
				}
			case null, _: Assert.fail('expected ExprStmt');
		}
	}

	public function testNewMultipleArgs():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { new Foo(1, 2); } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ExprStmt(expr):
				switch expr {
					case NewExpr(ne):
						Assert.equals('Foo', (ne.type : String));
						Assert.equals(2, ne.args.length);
						switch ne.args[0] {
							case IntLit(v): Assert.equals(1, v);
							case null, _: Assert.fail('expected IntLit arg 0');
						}
						switch ne.args[1] {
							case IntLit(v): Assert.equals(2, v);
							case null, _: Assert.fail('expected IntLit arg 1');
						}
					case null, _: Assert.fail('expected NewExpr');
				}
			case null, _: Assert.fail('expected ExprStmt');
		}
	}

	public function testNewWithExprArg():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { new Foo(a + b); } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ExprStmt(expr):
				switch expr {
					case NewExpr(ne):
						Assert.equals('Foo', (ne.type : String));
						Assert.equals(1, ne.args.length);
						switch ne.args[0] {
							case Add(_, _): Assert.pass();
							case null, _: Assert.fail('expected Add in arg');
						}
					case null, _: Assert.fail('expected NewExpr');
				}
			case null, _: Assert.fail('expected ExprStmt');
		}
	}

	public function testNewPostfixChain():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { new Foo().bar; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ExprStmt(expr):
				switch expr {
					case FieldAccess(operand, field):
						Assert.equals('bar', (field : String));
						switch operand {
							case NewExpr(ne): Assert.equals('Foo', (ne.type : String));
							case null, _: Assert.fail('expected NewExpr operand');
						}
					case null, _: Assert.fail('expected FieldAccess');
				}
			case null, _: Assert.fail('expected ExprStmt');
		}
	}

	public function testNewInSwitchBody():Void {
		final sw:HxSwitchStmt = parseSwitch(
			'class C { function f():Void { switch (x) { case 1: new Foo(); } } }'
		);
		Assert.equals(1, sw.cases.length);
		switch sw.cases[0] {
			case CaseBranch(b):
				Assert.equals(1, b.body.length);
				switch b.body[0] {
					case ExprStmt(expr):
						switch expr {
							case NewExpr(ne): Assert.equals('Foo', (ne.type : String));
							case null, _: Assert.fail('expected NewExpr');
						}
					case null, _: Assert.fail('expected ExprStmt');
				}
			case null, _: Assert.fail('expected CaseBranch');
		}
	}

	public function testWordBoundaryNewish():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { newish; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ExprStmt(expr):
				switch expr {
					case IdentExpr(v): Assert.equals('newish', (v : String));
					case null, _: Assert.fail('expected IdentExpr');
				}
			case null, _: Assert.fail('expected ExprStmt');
		}
	}

	public function testNewInModule():Void {
		final module:HxModule = HaxeModuleParser.parse(
			'class C { function f():Void { new Foo(1); } }'
		);
		Assert.equals(1, module.decls.length);
		final cls:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals(1, cls.members.length);
		final fn:HxFnDecl = expectFnMember(cls.members[0].member);
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case ExprStmt(expr):
				switch expr {
					case NewExpr(ne):
						Assert.equals('Foo', (ne.type : String));
						Assert.equals(1, ne.args.length);
					case null, _: Assert.fail('expected NewExpr');
				}
			case null, _: Assert.fail('expected ExprStmt');
		}
	}

	public function testNewWhitespace():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { new  Foo  (  1  ,  2  ) ; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ExprStmt(expr):
				switch expr {
					case NewExpr(ne):
						Assert.equals('Foo', (ne.type : String));
						Assert.equals(2, ne.args.length);
					case null, _: Assert.fail('expected NewExpr');
				}
			case null, _: Assert.fail('expected ExprStmt');
		}
	}

	// ---- Switch expression tests ----

	/** Extract the SwitchExpr atom from a return/expr/var-init outer statement. */
	private function expectSwitchExprRhs(source:String):HxSwitchStmt {
		final body:Array<HxStatement> = parseBody(source);
		Assert.equals(1, body.length);
		return switch body[0] {
			case ReturnStmt(expr) | ExprStmt(expr):
				switch expr {
					case SwitchExpr(stmt): stmt;
					case null, _: throw 'expected SwitchExpr rhs';
				}
			case VarStmt(decl):
				switch decl.init {
					case SwitchExpr(stmt): stmt;
					case null, _: throw 'expected SwitchExpr init';
				}
			case null, _: throw 'expected Return/Expr/Var stmt';
		};
	}

	public function testSwitchExprInReturn():Void {
		final sw:HxSwitchStmt = expectSwitchExprRhs(
			'class C { function f():String { return switch (x) { case 1: "a"; case _: "b"; }; } }'
		);
		Assert.equals(2, sw.cases.length);
	}

	public function testSwitchExprInVarInit():Void {
		final sw:HxSwitchStmt = expectSwitchExprRhs(
			'class C { function f():Void { var y:String = switch (x) { case 1: "a"; case _: "b"; }; } }'
		);
		Assert.equals(2, sw.cases.length);
	}

	public function testSwitchExprInCallArg():Void {
		final body:Array<HxStatement> = parseBody(
			'class C { function f():Void { trace(switch (x) { case 1: "a"; case _: "b"; }); } }'
		);
		Assert.equals(1, body.length);
		switch body[0] {
			case ExprStmt(expr):
				switch expr {
					case Call(_, args):
						Assert.equals(1, args.length);
						switch args[0] {
							case SwitchExpr(stmt): Assert.equals(2, stmt.cases.length);
							case null, _: Assert.fail('expected SwitchExpr arg');
						}
					case null, _: Assert.fail('expected Call');
				}
			case null, _: Assert.fail('expected ExprStmt');
		}
	}

	public function testSwitchExprInObjectField():Void {
		final body:Array<HxStatement> = parseBody(
			'class C { function f():Void { var o:Dynamic = {label: switch (x) { case 1: "a"; case _: "b"; }}; } }'
		);
		Assert.equals(1, body.length);
	}

	public function testSwitchStmtStillDispatchedAtStmtLevel():Void {
		// Statement-level `switch` must still hit HxStatement.SwitchStmt (no trailing `;`),
		// not be absorbed by HxExpr.SwitchExpr + ExprStmt (which requires `;`).
		final body:Array<HxStatement> = parseBody('class C { function f():Void { switch (x) { case 1: y; } } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case SwitchStmt(_): Assert.pass();
			case null, _: Assert.fail('expected SwitchStmt at statement level');
		}
	}
}
