package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleFastParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxEnumCtor;
import anyparse.grammar.haxe.HxEnumCtorDecl;
import anyparse.grammar.haxe.HxEnumDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxForStmt;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxParam;
import anyparse.grammar.haxe.HxStatement;
import anyparse.runtime.ParseError;

/**
 * Tests for slice lambda_1: for statement, enum ctor parameters, and void return.
 *
 * For statement: zero Lowering changes — `@:kw('in') @:trail(')')` on
 * the same struct field works via existing kw-lead + Ref-trail paths.
 *
 * Enum ctor parameters: zero Lowering changes — `HxEnumCtor` changed
 * from typedef to enum with `ParamCtor`/`SimpleCtor` branches. tryBranch
 * rollback disambiguates.
 *
 * Void return: one Lowering change — Case 0 extended to emit
 * `@:trail` on zero-arg `@:kw` branches (D48).
 */
class HxForEnumVoidSliceTest extends HxTestHelpers {

	/** Parse function body statements from a single-function class. */
	private function parseBody(source:String):Array<HxStatement> {
		final fn:HxFnDecl = parseSingleFnDecl(source);
		return fn.body;
	}

	// ---- For statement tests ----

	public function testForWithIdentIterable():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { for (x in items) x; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ForStmt(stmt):
				Assert.equals('x', (stmt.varName : String));
				switch stmt.iterable {
					case IdentExpr(v): Assert.equals('items', (v : String));
					case null, _: Assert.fail('expected IdentExpr for iterable');
				}
			case null, _: Assert.fail('expected ForStmt');
		}
	}

	public function testForWithBlockBody():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { for (x in items) { x; } } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ForStmt(stmt):
				Assert.equals('x', (stmt.varName : String));
				switch stmt.body {
					case BlockStmt(stmts): Assert.equals(1, stmts.length);
					case null, _: Assert.fail('expected BlockStmt body');
				}
			case null, _: Assert.fail('expected ForStmt');
		}
	}

	public function testNestedFor():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { for (i in a) for (j in b) x; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ForStmt(outer):
				Assert.equals('i', (outer.varName : String));
				switch outer.body {
					case ForStmt(inner):
						Assert.equals('j', (inner.varName : String));
					case null, _: Assert.fail('expected nested ForStmt');
				}
			case null, _: Assert.fail('expected ForStmt');
		}
	}

	public function testForWhitespace():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void {  for  (  x  in  items  )  x ;  } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ForStmt(stmt):
				Assert.equals('x', (stmt.varName : String));
				switch stmt.iterable {
					case IdentExpr(v): Assert.equals('items', (v : String));
					case null, _: Assert.fail('expected IdentExpr');
				}
			case null, _: Assert.fail('expected ForStmt');
		}
	}

	public function testForWithExpressionIterable():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { for (x in f(a)) x; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ForStmt(stmt):
				Assert.equals('x', (stmt.varName : String));
				switch stmt.iterable {
					case Call(operand, args):
						switch operand {
							case IdentExpr(v): Assert.equals('f', (v : String));
							case null, _: Assert.fail('expected IdentExpr');
						}
						Assert.equals(1, args.length);
					case null, _: Assert.fail('expected Call');
				}
			case null, _: Assert.fail('expected ForStmt');
		}
	}

	public function testForInModule():Void {
		final module:HxModule = HaxeModuleFastParser.parse('class C { function f():Void { for (x in items) x; } }');
		Assert.equals(1, module.decls.length);
		final cls:HxClassDecl = expectClassDecl(module.decls[0]);
		final fn:HxFnDecl = expectFnMember(cls.members[0].member);
		Assert.equals(1, fn.body.length);
		switch fn.body[0] {
			case ForStmt(_): Assert.isTrue(true);
			case null, _: Assert.fail('expected ForStmt');
		}
	}

	public function testWordBoundaryFormat():Void {
		Assert.raises(() -> parseBody('class C { function f():Void { format (x in items) x; } }'), ParseError);
	}

	public function testWordBoundaryForest():Void {
		Assert.raises(() -> parseBody('class C { function f():Void { forest (x in items) x; } }'), ParseError);
	}

	public function testRejectsMissingIn():Void {
		Assert.raises(() -> parseBody('class C { function f():Void { for (x items) x; } }'), ParseError);
	}

	public function testRejectsMissingCloseParen():Void {
		Assert.raises(() -> parseBody('class C { function f():Void { for (x in items x; } }'), ParseError);
	}

	// ---- Enum ctor parameters tests ----

	public function testSimpleCtorStillWorks():Void {
		final module:HxModule = HaxeModuleFastParser.parse('enum Color { Red; Green; Blue; }');
		final ed:HxEnumDecl = expectEnumDecl(module.decls[0]);
		Assert.equals(3, ed.ctors.length);
		Assert.equals('Red', (expectSimpleCtor(ed.ctors[0]) : String));
		Assert.equals('Green', (expectSimpleCtor(ed.ctors[1]) : String));
		Assert.equals('Blue', (expectSimpleCtor(ed.ctors[2]) : String));
	}

	public function testSingleParamCtor():Void {
		final module:HxModule = HaxeModuleFastParser.parse('enum Option { Some(v:Int); None; }');
		final ed:HxEnumDecl = expectEnumDecl(module.decls[0]);
		Assert.equals(2, ed.ctors.length);
		final decl:HxEnumCtorDecl = expectParamCtor(ed.ctors[0]);
		Assert.equals('Some', (decl.name : String));
		Assert.equals(1, decl.params.length);
		Assert.equals('v', (decl.params[0].name : String));
		Assert.equals('Int', (decl.params[0].type.name : String));
		Assert.equals('None', (expectSimpleCtor(ed.ctors[1]) : String));
	}

	public function testMultiParamCtor():Void {
		final module:HxModule = HaxeModuleFastParser.parse('enum Color { Rgb(r:Int, g:Int, b:Int); }');
		final ed:HxEnumDecl = expectEnumDecl(module.decls[0]);
		Assert.equals(1, ed.ctors.length);
		final decl:HxEnumCtorDecl = expectParamCtor(ed.ctors[0]);
		Assert.equals('Rgb', (decl.name : String));
		Assert.equals(3, decl.params.length);
		Assert.equals('r', (decl.params[0].name : String));
		Assert.equals('g', (decl.params[1].name : String));
		Assert.equals('b', (decl.params[2].name : String));
	}

	public function testCtorWithDefaultValue():Void {
		final module:HxModule = HaxeModuleFastParser.parse('enum E { A(x:Int = 0); }');
		final ed:HxEnumDecl = expectEnumDecl(module.decls[0]);
		Assert.equals(1, ed.ctors.length);
		final decl:HxEnumCtorDecl = expectParamCtor(ed.ctors[0]);
		Assert.equals(1, decl.params.length);
		Assert.equals('x', (decl.params[0].name : String));
		switch decl.params[0].defaultValue {
			case null: Assert.fail('expected default value');
			case IntLit(v): Assert.equals(0, (v : Int));
			case _: Assert.fail('expected IntLit default');
		}
	}

	public function testMixedSimpleAndParamCtors():Void {
		final module:HxModule = HaxeModuleFastParser.parse('enum Expr { Lit(v:Int); Add(a:Int, b:Int); Nil; }');
		final ed:HxEnumDecl = expectEnumDecl(module.decls[0]);
		Assert.equals(3, ed.ctors.length);
		final lit:HxEnumCtorDecl = expectParamCtor(ed.ctors[0]);
		Assert.equals('Lit', (lit.name : String));
		Assert.equals(1, lit.params.length);
		final add:HxEnumCtorDecl = expectParamCtor(ed.ctors[1]);
		Assert.equals('Add', (add.name : String));
		Assert.equals(2, add.params.length);
		Assert.equals('Nil', (expectSimpleCtor(ed.ctors[2]) : String));
	}

	public function testZeroParamCtorVsBareSimple():Void {
		final module:HxModule = HaxeModuleFastParser.parse('enum E { A(); B; }');
		final ed:HxEnumDecl = expectEnumDecl(module.decls[0]);
		Assert.equals(2, ed.ctors.length);
		final a:HxEnumCtorDecl = expectParamCtor(ed.ctors[0]);
		Assert.equals('A', (a.name : String));
		Assert.equals(0, a.params.length);
		Assert.equals('B', (expectSimpleCtor(ed.ctors[1]) : String));
	}

	public function testEnumCtorWhitespace():Void {
		final module:HxModule = HaxeModuleFastParser.parse('  enum  E  {  A ( x : Int , y : Int ) ;  B ;  }  ');
		final ed:HxEnumDecl = expectEnumDecl(module.decls[0]);
		Assert.equals(2, ed.ctors.length);
		final a:HxEnumCtorDecl = expectParamCtor(ed.ctors[0]);
		Assert.equals(2, a.params.length);
		Assert.equals('B', (expectSimpleCtor(ed.ctors[1]) : String));
	}

	public function testEnumCtorInModule():Void {
		final module:HxModule = HaxeModuleFastParser.parse('class Foo {} enum Option { Some(v:Int); None; }');
		Assert.equals(2, module.decls.length);
		final ed:HxEnumDecl = expectEnumDecl(module.decls[1]);
		Assert.equals(2, ed.ctors.length);
		final some:HxEnumCtorDecl = expectParamCtor(ed.ctors[0]);
		Assert.equals('Some', (some.name : String));
		Assert.equals(1, some.params.length);
	}

	// ---- Void return tests ----

	public function testVoidReturn():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { return; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case VoidReturnStmt: Assert.isTrue(true);
			case null, _: Assert.fail('expected VoidReturnStmt');
		}
	}

	public function testVoidReturnBeforeOtherStatements():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { return; x; } }');
		Assert.equals(2, body.length);
		switch body[0] {
			case VoidReturnStmt: Assert.isTrue(true);
			case null, _: Assert.fail('expected VoidReturnStmt');
		}
		switch body[1] {
			case ExprStmt(_): Assert.isTrue(true);
			case null, _: Assert.fail('expected ExprStmt');
		}
	}

	public function testVoidReturnInBlock():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { { return; } } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case BlockStmt(stmts):
				Assert.equals(1, stmts.length);
				switch stmts[0] {
					case VoidReturnStmt: Assert.isTrue(true);
					case null, _: Assert.fail('expected VoidReturnStmt');
				}
			case null, _: Assert.fail('expected BlockStmt');
		}
	}

	public function testReturnWithValueStillWorks():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { return 42; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ReturnStmt(value):
				switch value {
					case IntLit(v): Assert.equals(42, (v : Int));
					case null, _: Assert.fail('expected IntLit');
				}
			case null, _: Assert.fail('expected ReturnStmt');
		}
	}

	public function testVoidReturnInModule():Void {
		final module:HxModule = HaxeModuleFastParser.parse('class C { function f():Void { return; } }');
		Assert.equals(1, module.decls.length);
		final cls:HxClassDecl = expectClassDecl(module.decls[0]);
		final fn:HxFnDecl = expectFnMember(cls.members[0].member);
		Assert.equals(1, fn.body.length);
		switch fn.body[0] {
			case VoidReturnStmt: Assert.isTrue(true);
			case null, _: Assert.fail('expected VoidReturnStmt');
		}
	}
}
