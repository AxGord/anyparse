package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxStatement;

/**
 * Tests for the TINY-bundle slice adding `final` binding statement and
 * `untyped` expression atoms to the Haxe grammar.
 *
 * - `FinalStmt(decl:HxVarDecl)` — `final name:Type = init;` immutable
 *   local binding, parallel to `VarStmt`. Reuses `HxVarDecl` verbatim.
 * - `UntypedExpr(operand:HxExpr)` — `untyped expr` atom in `HxExpr`,
 *   placed before `MetaExpr`/`IdentExpr` so the keyword commits before
 *   the bare-identifier catch-all.
 *
 * Member-level `final x = 1;` (immutable field) is NOT in this slice —
 * it requires lookahead in the `HxMemberDecl` modifier Star (since
 * `HxModifier` already lists `final`, the Star greedily consumes it
 * before `HxClassMember` dispatches). See `HxClassMember` doc for the
 * deferred-slice note.
 */
class HxFinalUntypedSliceTest extends HxTestHelpers {

	// ======== FinalStmt — statement-level final binding ========

	public function testFinalStmtBare():Void {
		final fn:HxFnDecl = parseSingleFnDecl('class C { function m():Void { final x = 1; } }');
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case FinalStmt(decl):
				Assert.equals('x', (decl.name : String));
				Assert.isNull(decl.type);
				switch decl.init {
					case IntLit(v): Assert.equals(1, (v : Int));
					case null, _: Assert.fail('expected IntLit(1) init');
				}
			case null, _: Assert.fail('expected FinalStmt, got ${stmts[0]}');
		}
	}

	public function testFinalStmtTyped():Void {
		final fn:HxFnDecl = parseSingleFnDecl('class C { function m():Void { final x:Int = 1; } }');
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		switch stmts[0] {
			case FinalStmt(decl):
				Assert.equals('x', (decl.name : String));
				Assert.equals('Int', (expectNamedType(decl.type).name : String));
			case null, _: Assert.fail('expected FinalStmt(typed)');
		}
	}

	public function testFinalStmtNoInit():Void {
		final fn:HxFnDecl = parseSingleFnDecl('class C { function m():Void { final x:Int; } }');
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		switch stmts[0] {
			case FinalStmt(decl):
				Assert.equals('x', (decl.name : String));
				Assert.equals('Int', (expectNamedType(decl.type).name : String));
				Assert.isNull(decl.init);
			case null, _: Assert.fail('expected FinalStmt(no init)');
		}
	}

	public function testFinalStmtMultipleInBody():Void {
		final fn:HxFnDecl = parseSingleFnDecl('class C { function m():Void { final a = 1; var b = 2; final c = 3; } }');
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		Assert.equals(3, stmts.length);
		switch stmts[0] {
			case FinalStmt(d): Assert.equals('a', (d.name : String));
			case null, _: Assert.fail('expected FinalStmt');
		}
		switch stmts[1] {
			case VarStmt(d): Assert.equals('b', (d.name : String));
			case null, _: Assert.fail('expected VarStmt');
		}
		switch stmts[2] {
			case FinalStmt(d): Assert.equals('c', (d.name : String));
			case null, _: Assert.fail('expected FinalStmt');
		}
	}

	public function testFinalStmtIdentifierPrefixNotConsumed():Void {
		// `finalists` must parse as a regular var stmt (word-boundary on `final` kw).
		final fn:HxFnDecl = parseSingleFnDecl('class C { function m():Void { var finalists = 1; } }');
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		switch stmts[0] {
			case VarStmt(d): Assert.equals('finalists', (d.name : String));
			case null, _: Assert.fail('expected VarStmt(finalists)');
		}
	}

	public function testFinalStmtRoundTrip():Void {
		roundTrip('class C { function m():Void { final x = 1; } }', 'final x = 1;');
		roundTrip('class C { function m():Void { final x:Int = 1; } }', 'final x:Int = 1;');
		roundTrip('class C { function m():Void { final x:Int; } }', 'final x:Int;');
	}

	// ======== UntypedExpr — `untyped expr` atom ========

	public function testUntypedAtom():Void {
		final decl = parseSingleVarDecl('class C { var f:Int = untyped 1; }');
		switch decl.init {
			case UntypedExpr(IntLit(v)): Assert.equals(1, (v : Int));
			case null, _: Assert.fail('expected UntypedExpr(IntLit), got ${decl.init}');
		}
	}

	public function testUntypedWrapsIdent():Void {
		final decl = parseSingleVarDecl('class C { var f:Int = untyped foo; }');
		switch decl.init {
			case UntypedExpr(IdentExpr(name)): Assert.equals('foo', (name : String));
			case null, _: Assert.fail('expected UntypedExpr(IdentExpr)');
		}
	}

	public function testUntypedWrapsCall():Void {
		final decl = parseSingleVarDecl('class C { var f:Int = untyped foo(); }');
		switch decl.init {
			case UntypedExpr(Call(IdentExpr(name), args)):
				Assert.equals('foo', (name : String));
				Assert.equals(0, args.length);
			case null, _: Assert.fail('expected UntypedExpr(Call)');
		}
	}

	public function testUntypedAsStatement():Void {
		final fn:HxFnDecl = parseSingleFnDecl('class C { function m():Void { untyped foo(); } }');
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		switch stmts[0] {
			case ExprStmt(UntypedExpr(Call(IdentExpr(name), _))):
				Assert.equals('foo', (name : String));
			case null, _: Assert.fail('expected ExprStmt(UntypedExpr(Call))');
		}
	}

	public function testUntypedScopesFullExpression():Void {
		// `untyped a + b` — `untyped` wraps the full expression (matches
		// Haxe semantics: the keyword disables type-checking for the
		// entire RHS, not just the next atom). Implementation: the ctor
		// operand is `HxExpr` (Pratt-resolved), not `HxExpr` atom.
		final decl = parseSingleVarDecl('class C { var f:Int = untyped a + b; }');
		switch decl.init {
			case UntypedExpr(Add(IdentExpr(a), IdentExpr(b))):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
			case null, _: Assert.fail('expected UntypedExpr(Add(a, b)), got ${decl.init}');
		}
	}

	public function testUntypedNested():Void {
		final decl = parseSingleVarDecl('class C { var f:Int = untyped untyped x; }');
		switch decl.init {
			case UntypedExpr(UntypedExpr(IdentExpr(x))):
				Assert.equals('x', (x : String));
			case null, _: Assert.fail('expected UntypedExpr(UntypedExpr(x))');
		}
	}

	public function testUntypedIdentifierPrefixNotConsumed():Void {
		// `untypedFoo` must parse as a bare identifier (word boundary on kw).
		final decl = parseSingleVarDecl('class C { var f:Int = untypedFoo; }');
		switch decl.init {
			case IdentExpr(name): Assert.equals('untypedFoo', (name : String));
			case null, _: Assert.fail('expected IdentExpr(untypedFoo)');
		}
	}

	public function testUntypedRoundTrip():Void {
		roundTrip('class C { var f:Int = untyped 1; }', 'untyped 1');
		roundTrip('class C { var f:Int = untyped foo(); }', 'untyped foo()');
		roundTrip('class C { function m():Void { untyped foo(); } }', 'stmt-level untyped');
	}

	// ======== UntypedAtom — bare `untyped` (no operand) ========

	public function testUntypedAtomBareInReturn():Void {
		// `return untyped;` — bare `untyped` keyword, no operand.
		// PEG tries UntypedExpr(operand) first; operand-parse fails at `;`,
		// tryBranch rolls back, UntypedAtom matches kw and succeeds.
		final fn:HxFnDecl = parseSingleFnDecl('class C { function m():Void { return untyped; } }');
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		switch stmts[0] {
			case ReturnStmt(UntypedAtom): Assert.pass();
			case null, _: Assert.fail('expected ReturnStmt(UntypedAtom), got ${stmts[0]}');
		}
	}

	public function testUntypedAtomRoundTrip():Void {
		roundTrip('class C { function m():Void { return untyped; } }', 'return untyped;');
	}

	// ======== UntypedBlockStmt — `untyped { stmts }` block statement ========

	public function testUntypedBlockStmtAsStatement():Void {
		// `untyped { foo(); }` at stmt-level — no trailing `;` required,
		// dispatches via dedicated `UntypedBlockStmt` ctor (kw 'untyped' +
		// HxFnBlock payload) BEFORE the bare-`{` `BlockStmt`.
		final fn:HxFnDecl = parseSingleFnDecl('class C { function m():Void { untyped { foo(); } } }');
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		switch stmts[0] {
			case UntypedBlockStmt(body):
				Assert.equals(1, body.block.stmts.length);
				switch body.block.stmts[0] {
					case ExprStmt(Call(IdentExpr(name), _)): Assert.equals('foo', (name : String));
					case null, _: Assert.fail('expected inner ExprStmt(Call(foo))');
				}
			case null, _: Assert.fail('expected UntypedBlockStmt, got ${stmts[0]}');
		}
	}

	public function testUntypedBlockStmtRoundTrip():Void {
		roundTrip('class C { function m():Void { untyped { foo(); } } }', 'untyped { foo(); }');
	}

	// ======== UntypedBlockBody — `function f():Type untyped { body }` ========

	public function testUntypedBlockBodyOnFn():Void {
		// `function f():Int untyped { return 1; }` — fn-body modifier form.
		// Body parses as HxFnBody.UntypedBlockBody not BlockBody.
		final fn:HxFnDecl = parseSingleFnDecl('class C { function f():Int untyped { return 1; } }');
		switch fn.body {
			case UntypedBlockBody(body):
				Assert.equals(1, body.block.stmts.length);
			case null, _: Assert.fail('expected UntypedBlockBody, got ${fn.body}');
		}
	}

	public function testUntypedBlockBodyRoundTrip():Void {
		roundTrip('class C { function f():Int untyped { return 1; } }', 'untyped fn body');
	}

	// ======== Combined: final stmt holding untyped init ========

	public function testFinalHoldsUntyped():Void {
		final fn:HxFnDecl = parseSingleFnDecl('class C { function m():Void { final x = untyped 1; } }');
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		switch stmts[0] {
			case FinalStmt(decl):
				switch decl.init {
					case UntypedExpr(IntLit(v)): Assert.equals(1, (v : Int));
					case null, _: Assert.fail('expected UntypedExpr(IntLit) init');
				}
			case null, _: Assert.fail('expected FinalStmt');
		}
	}

}
