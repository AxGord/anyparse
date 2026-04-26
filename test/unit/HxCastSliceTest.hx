package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxType;

/**
 * Tests for the SMALL slice adding the `cast` keyword as a proper pair
 * of expression atoms in the Haxe grammar.
 *
 * - `TypedCastExpr(info:HxTypedCast)` — `cast(target, Type)` checked
 *   cast. Wraps `HxTypedCast` typedef carrying `target:HxExpr` after
 *   `(` and `type:HxType` after `,` with closing `)`. Same field-pair
 *   pattern as `HxCatchClause` (`catch (name:Type)`).
 * - `CastExpr(operand:HxExpr)` — bare `cast x` unsafe cast. Operand is
 *   the full `HxExpr` (Pratt-resolved), matching Haxe semantics where
 *   `cast` disables type-checking for the entire RHS.
 *
 * Source order in `HxExpr` puts `TypedCastExpr` before `CastExpr` so
 * the parenthesised form tries first; the `tryBranch` rollback in
 * `Lowering` reverts when the comma is absent (`cast (x)` / `cast x`)
 * and the bare branch picks up the operand.
 *
 * Before this slice, `cast(x, T)` parsed incidentally as
 * `Call(IdentExpr("cast"), [IdentExpr(x), IdentExpr(T)])` — byte-perfect
 * round-trip but semantic loss (`T` stored as expression, not type).
 * The slice fixes the AST shape; round-trip output is unchanged.
 */
class HxCastSliceTest extends HxTestHelpers {

	// ======== TypedCastExpr — `cast(expr, Type)` ========

	public function testTypedCastBasic():Void {
		final decl = parseSingleVarDecl('class C { var f:Int = cast(x, Int); }');
		switch decl.init {
			case TypedCastExpr(info):
				switch info.target {
					case IdentExpr(name): Assert.equals('x', (name : String));
					case _: Assert.fail('expected IdentExpr target');
				}
				Assert.equals('Int', (expectNamedTypeFromHxType(info.type).name : String));
			case null, _: Assert.fail('expected TypedCastExpr, got ${decl.init}');
		}
	}

	public function testTypedCastComplexExpr():Void {
		final decl = parseSingleVarDecl('class C { var f:Int = cast(a + b, Float); }');
		switch decl.init {
			case TypedCastExpr(info):
				switch info.target {
					case Add(IdentExpr(a), IdentExpr(b)):
						Assert.equals('a', (a : String));
						Assert.equals('b', (b : String));
					case _: Assert.fail('expected Add(a, b) target');
				}
				Assert.equals('Float', (expectNamedTypeFromHxType(info.type).name : String));
			case null, _: Assert.fail('expected TypedCastExpr');
		}
	}

	public function testTypedCastGenericType():Void {
		final decl = parseSingleVarDecl('class C { var f:Int = cast(x, Map<String, Int>); }');
		switch decl.init {
			case TypedCastExpr(info):
				final ref = expectNamedTypeFromHxType(info.type);
				Assert.equals('Map', (ref.name : String));
				Assert.notNull(ref.params);
				Assert.equals(2, ref.params.length);
			case null, _: Assert.fail('expected TypedCastExpr(Map<...>)');
		}
	}

	public function testTypedCastIsNotCallExpression():Void {
		// Regression: before this slice, `cast(x, T)` parsed as
		// Call(IdentExpr("cast"), [...]). Verify it now parses as
		// TypedCastExpr — semantic AST shape, not call shape.
		final decl = parseSingleVarDecl('class C { var f:Int = cast(x, Int); }');
		switch decl.init {
			case Call(IdentExpr(_), _): Assert.fail('regressed: cast(x, T) parsed as Call');
			case TypedCastExpr(_): Assert.pass();
			case null, _: Assert.fail('expected TypedCastExpr');
		}
	}

	public function testTypedCastRoundTrip():Void {
		roundTrip('class C { var f:Int = cast(x, Int); }', 'cast(x, Int)');
		roundTrip('class C { var f:Int = cast(a + b, Float); }', 'cast(a + b, Float)');
		roundTrip('class C { var f:Int = cast(x, Map<String, Int>); }', 'cast(x, Map<...>)');
	}

	// ======== CastExpr — `cast x` (bare unsafe cast) ========

	public function testCastBareIdent():Void {
		final decl = parseSingleVarDecl('class C { var f:Int = cast x; }');
		switch decl.init {
			case CastExpr(IdentExpr(name)): Assert.equals('x', (name : String));
			case null, _: Assert.fail('expected CastExpr(IdentExpr), got ${decl.init}');
		}
	}

	public function testCastBareCall():Void {
		final decl = parseSingleVarDecl('class C { var f:Int = cast foo(); }');
		switch decl.init {
			case CastExpr(Call(IdentExpr(name), args)):
				Assert.equals('foo', (name : String));
				Assert.equals(0, args.length);
			case null, _: Assert.fail('expected CastExpr(Call)');
		}
	}

	public function testCastBareFieldAccess():Void {
		final decl = parseSingleVarDecl('class C { var f:Int = cast x.field; }');
		switch decl.init {
			case CastExpr(FieldAccess(IdentExpr(x), field)):
				Assert.equals('x', (x : String));
				Assert.equals('field', (field : String));
			case null, _: Assert.fail('expected CastExpr(FieldAccess)');
		}
	}

	public function testCastSingleArgParenIsBareCast():Void {
		// `cast (x)` (or `cast(x)` without comma) is bare cast applied to
		// a parenthesised expression — TypedCastExpr requires the comma.
		final decl = parseSingleVarDecl('class C { var f:Int = cast (x); }');
		switch decl.init {
			case CastExpr(ParenExpr(IdentExpr(name))):
				Assert.equals('x', (name : String));
			case null, _: Assert.fail('expected CastExpr(ParenExpr), got ${decl.init}');
		}
	}

	public function testCastScopesFullExpression():Void {
		// `cast a + b` — `cast` wraps the full expression (matches Haxe
		// semantics: the keyword disables type-checking for the entire
		// RHS, not just the next atom). Implementation: operand is `HxExpr`
		// (Pratt-resolved), parallel to `UntypedExpr`.
		final decl = parseSingleVarDecl('class C { var f:Int = cast a + b; }');
		switch decl.init {
			case CastExpr(Add(IdentExpr(a), IdentExpr(b))):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
			case null, _: Assert.fail('expected CastExpr(Add(a, b)), got ${decl.init}');
		}
	}

	public function testCastAsStatement():Void {
		final fn:HxFnDecl = parseSingleFnDecl('class C { function m():Void { cast foo(); } }');
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		switch stmts[0] {
			case ExprStmt(CastExpr(Call(IdentExpr(name), _))):
				Assert.equals('foo', (name : String));
			case null, _: Assert.fail('expected ExprStmt(CastExpr(Call))');
		}
	}

	public function testCastIdentifierPrefixNotConsumed():Void {
		// `castle` must parse as a regular identifier (word boundary on `cast` kw).
		final decl = parseSingleVarDecl('class C { var f:Int = castle; }');
		switch decl.init {
			case IdentExpr(name): Assert.equals('castle', (name : String));
			case null, _: Assert.fail('expected IdentExpr(castle)');
		}
	}

	public function testCastBareRoundTrip():Void {
		roundTrip('class C { var f:Int = cast x; }', 'cast x');
		roundTrip('class C { var f:Int = cast foo(); }', 'cast foo()');
		roundTrip('class C { var f:Int = cast (x); }', 'cast (x)');
		roundTrip('class C { function m():Void { cast foo(); } }', 'stmt-level cast');
	}

	// ======== Combined: nested cast forms ========

	public function testTypedCastWrapsBareCast():Void {
		// `cast(cast x, Int)` — TypedCastExpr whose target is CastExpr.
		final decl = parseSingleVarDecl('class C { var f:Int = cast(cast x, Int); }');
		switch decl.init {
			case TypedCastExpr(info):
				switch info.target {
					case CastExpr(IdentExpr(name)): Assert.equals('x', (name : String));
					case _: Assert.fail('expected CastExpr target, got ${info.target}');
				}
			case null, _: Assert.fail('expected TypedCastExpr(CastExpr)');
		}
	}

	public function testCastWrapsTypedCast():Void {
		// `cast cast(x, Int)` — bare CastExpr wrapping TypedCastExpr.
		final decl = parseSingleVarDecl('class C { var f:Int = cast cast(x, Int); }');
		switch decl.init {
			case CastExpr(TypedCastExpr(info)):
				switch info.target {
					case IdentExpr(name): Assert.equals('x', (name : String));
					case _: Assert.fail('expected IdentExpr target');
				}
			case null, _: Assert.fail('expected CastExpr(TypedCastExpr)');
		}
	}

	// ======== HxType helper (local to this file) ========

	private function expectNamedTypeFromHxType(t:HxType):anyparse.grammar.haxe.HxTypeRef {
		return switch t {
			case Named(ref): ref;
			case _: throw 'expected HxType.Named, got $t';
		};
	}

}
