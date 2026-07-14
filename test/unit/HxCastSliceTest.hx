package unit;

import utest.Assert;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxType;

/**
 * Tests for the `cast` keyword expression atoms in the Haxe grammar.
 *
 * - `TypedCastExpr(info:HxTypedCast)` — `cast(target, Type)` checked
 *   cast. Wraps `HxTypedCast` typedef carrying `target:HxExpr` after
 *   `(` and `type:HxType` after `,` with closing `)`. Same field-pair
 *   pattern as `HxCatchClause` (`catch (name:Type)`).
 * - `CastExpr(operand:HxExpr)` — bare `cast x` unsafe cast. Operand
 *   parses at atom-level (Slice 46 `@:fmt(atomOperand)`), matching
 *   Haxe's unary-operator binding: `cast` binds tighter than any
 *   binary infix, so `cast a + b` is `Add(CastExpr(a), b)` and
 *   `cast (x) is Bool` is `Is(CastExpr(ParenExpr(x)), Bool)`.
 *
 * Source order in `HxExpr` puts `TypedCastExpr` before `CastExpr` so
 * the parenthesised form tries first; the `tryBranch` rollback in
 * `Lowering` reverts when the comma is absent (`cast (x)` / `cast x`)
 * and the bare branch picks up the operand.
 *
 * `@:fmt(tightOnParenOperand('ParenExpr', 'ECheckTypeExpr'))` (Slice
 * 46) drops the kw trailing space when the operand is a leading-`(`
 * ctor — so `cast (x)` round-trips as tight `cast(x)` and
 * `cast (x:Int)` as `cast(x : Int)`, matching haxe-formatter's
 * cast-as-function-call convention.
 *
 * Before the proper grammar/Pratt rules, `cast(x, T)` parsed
 * incidentally as `Call(IdentExpr("cast"), [...])` — byte-perfect
 * round-trip but semantic loss (`T` stored as expression, not type).
 * The cast slice fixed the AST shape; Slice 46 fixed the unary binding
 * tightness exposed by `cast … is X` fixtures.
 */
class HxCastSliceTest extends HxTestHelpers {

	// ======== TypedCastExpr — `cast(expr, Type)` ========

	public function testTypedCastBasic(): Void {
		final decl = parseSingleVarDecl('class C { var f:Int = cast(x, Int); }');
		switch decl.init {
			case TypedCastExpr(info):
				switch info.target {
					case IdentExpr(name):
						Assert.equals('x', (name: String));
					case _:
						Assert.fail('expected IdentExpr target');
				}
				Assert.equals('Int', (expectNamedTypeFromHxType(info.type).name: String));
			case null, _:
				Assert.fail('expected TypedCastExpr, got ${decl.init}');
		}
	}

	public function testTypedCastComplexExpr(): Void {
		final decl = parseSingleVarDecl('class C { var f:Int = cast(a + b, Float); }');
		switch decl.init {
			case TypedCastExpr(info):
				switch info.target {
					case Add(IdentExpr(a), IdentExpr(b)):
						Assert.equals('a', (a: String));
						Assert.equals('b', (b: String));
					case _:
						Assert.fail('expected Add(a, b) target');
				}
				Assert.equals('Float', (expectNamedTypeFromHxType(info.type).name: String));
			case null, _:
				Assert.fail('expected TypedCastExpr');
		}
	}

	public function testTypedCastGenericType(): Void {
		final decl = parseSingleVarDecl('class C { var f:Int = cast(x, Map<String, Int>); }');
		switch decl.init {
			case TypedCastExpr(info):
				final ref = expectNamedTypeFromHxType(info.type);
				Assert.equals('Map', (ref.name: String));
				Assert.notNull(ref.params);
				Assert.equals(2, ref.params.length);
			case null, _:
				Assert.fail('expected TypedCastExpr(Map<...>)');
		}
	}

	public function testTypedCastIsNotCallExpression(): Void {
		// Regression: before this slice, `cast(x, T)` parsed as
		// Call(IdentExpr("cast"), [...]). Verify it now parses as
		// TypedCastExpr — semantic AST shape, not call shape.
		final decl = parseSingleVarDecl('class C { var f:Int = cast(x, Int); }');
		switch decl.init {
			case Call(IdentExpr(_), _):
				Assert.fail('regressed: cast(x, T) parsed as Call');
			case TypedCastExpr(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected TypedCastExpr');
		}
	}

	public function testTypedCastRoundTrip(): Void {
		roundTrip('class C { var f:Int = cast(x, Int); }', 'cast(x, Int)');
		roundTrip('class C { var f:Int = cast(a + b, Float); }', 'cast(a + b, Float)');
		roundTrip('class C { var f:Int = cast(x, Map<String, Int>); }', 'cast(x, Map<...>)');
	}

	// ======== CastExpr — `cast x` (bare unsafe cast) ========

	public function testCastBareIdent(): Void {
		final decl = parseSingleVarDecl('class C { var f:Int = cast x; }');
		switch decl.init {
			case CastExpr(IdentExpr(name)):
				Assert.equals('x', (name: String));
			case null, _:
				Assert.fail('expected CastExpr(IdentExpr), got ${decl.init}');
		}
	}

	public function testCastBareCall(): Void {
		final decl = parseSingleVarDecl('class C { var f:Int = cast foo(); }');
		switch decl.init {
			case CastExpr(Call(IdentExpr(name), args)):
				Assert.equals('foo', (name: String));
				Assert.equals(0, args.length);
			case null, _:
				Assert.fail('expected CastExpr(Call)');
		}
	}

	public function testCastBareFieldAccess(): Void {
		final decl = parseSingleVarDecl('class C { var f:Int = cast x.field; }');
		switch decl.init {
			case CastExpr(FieldAccess(IdentExpr(x), field)):
				Assert.equals('x', (x: String));
				Assert.equals('field', (field: String));
			case null, _:
				Assert.fail('expected CastExpr(FieldAccess)');
		}
	}

	public function testCastSingleArgParenIsBareCast(): Void {
		// `cast (x)` (or `cast(x)` without comma) is bare cast applied to
		// a parenthesised expression — TypedCastExpr requires the comma.
		final decl = parseSingleVarDecl('class C { var f:Int = cast (x); }');
		switch decl.init {
			case CastExpr(ParenExpr(IdentExpr(name))):
				Assert.equals('x', (name: String));
			case null, _:
				Assert.fail('expected CastExpr(ParenExpr), got ${decl.init}');
		}
	}

	public function testCastBindsAtomNotFullExpression(): Void {
		// Slice 46: `cast a + b` — `cast` is a unary operator that binds
		// tighter than any binary infix (Haxe semantics: `cast a` is the
		// expression that becomes the left operand of `+`). Implementation:
		// `@:fmt(atomOperand)` on `CastExpr` routes operand parse to
		// `parseHxExprAtom`, so the trailing `+ b` stays for the outer
		// Pratt loop. Pre-slice this parsed as `CastExpr(Add(a, b))`.
		final decl = parseSingleVarDecl('class C { var f:Int = cast a + b; }');
		switch decl.init {
			case Add(CastExpr(IdentExpr(a)), IdentExpr(b)):
				Assert.equals('a', (a: String));
				Assert.equals('b', (b: String));
			case null, _:
				Assert.fail('expected Add(CastExpr(a), b), got ${decl.init}');
		}
	}

	public function testCastBindsTighterThanIs(): Void {
		// Slice 46: `cast x is Bool` — atom-bound `cast x` becomes the
		// left of `is`. Pre-slice parsed as `CastExpr(Is(x, Bool))`.
		final decl = parseSingleVarDecl('class C { var f:Bool = cast x is Bool; }');
		switch decl.init {
			case Is(CastExpr(IdentExpr(name)), _):
				Assert.equals('x', (name: String));
			case null, _:
				Assert.fail('expected Is(CastExpr(x), Bool), got ${decl.init}');
		}
	}

	public function testCastParenIsBindsTighterThanIs(): Void {
		// Slice 46: `cast (x) is Bool` — operand `(x)` is ParenExpr atom,
		// then `is Bool` is the outer Pratt operator. The
		// `tightOnParenOperand` writer knob then drops the kw trailing
		// space (operand=ParenExpr) so output is `cast(x) is Bool`.
		final decl = parseSingleVarDecl('class C { var f:Bool = cast (x) is Bool; }');
		switch decl.init {
			case Is(CastExpr(ParenExpr(IdentExpr(name))), _):
				Assert.equals('x', (name: String));
			case null, _:
				Assert.fail('expected Is(CastExpr(ParenExpr(x)), Bool), got ${decl.init}');
		}
	}

	public function testCastECheckTypeBindsTighterThanIs(): Void {
		// Slice 46: `cast (x:Int) is Bool` — operand `(x:Int)` is
		// ECheckTypeExpr atom; `is Bool` is the outer Pratt operator.
		final decl = parseSingleVarDecl('class C { var f:Bool = cast (x:Int) is Bool; }');
		switch decl.init {
			case Is(CastExpr(ECheckTypeExpr(info)), _):
				switch info.expr {
					case IdentExpr(name): Assert.equals('x', (name: String));
					case _: Assert.fail('expected IdentExpr(x) as ECheckType expr');
				}
			case null, _:
				Assert.fail('expected Is(CastExpr(ECheckTypeExpr(...)), Bool), got ${decl.init}');
		}
	}

	public function testCastAsStatement(): Void {
		final fn: HxFnDecl = parseSingleFnDecl('class C { function m():Void { cast foo(); } }');
		final stmts: Array<HxStatement> = fnBodyStmts(fn);
		switch stmts[0] {
			case ExprStmt(CastExpr(Call(IdentExpr(name), _))):
				Assert.equals('foo', (name: String));
			case null, _:
				Assert.fail('expected ExprStmt(CastExpr(Call))');
		}
	}

	public function testCastIdentifierPrefixNotConsumed(): Void {
		// `castle` must parse as a regular identifier (word boundary on `cast` kw).
		final decl = parseSingleVarDecl('class C { var f:Int = castle; }');
		switch decl.init {
			case IdentExpr(name):
				Assert.equals('castle', (name: String));
			case null, _:
				Assert.fail('expected IdentExpr(castle)');
		}
	}

	public function testCastBareRoundTrip(): Void {
		roundTrip('class C { var f:Int = cast x; }', 'cast x');
		roundTrip('class C { var f:Int = cast foo(); }', 'cast foo()');
		roundTrip('class C { var f:Int = cast (x); }', 'cast (x)');
		roundTrip('class C { function m():Void { cast foo(); } }', 'stmt-level cast');
	}

	// ======== Slice 46 writer: tight `cast(` on paren-form operand ========

	public function testWriterCastParenTight(): Void {
		// Slice 46 (writer half): `cast (x)` round-trips as tight
		// `cast(x)` because operand=ParenExpr is in the
		// `tightOnParenOperand` list. Bare `cast x` keeps the space.
		writerEquals('class C { var f:Int = cast (x); }', 'class C {\n\tvar f:Int = cast(x);\n}\n', 'tight `cast(x)` on ParenExpr operand');
	}

	public function testWriterCastECheckTypeTight(): Void {
		writerEquals(
			'class C { var f:Int = cast (x:Int); }', 'class C {\n\tvar f:Int = cast(x : Int);\n}\n',
			'tight `cast(x : Int)` on ECheckTypeExpr operand'
		);
	}

	public function testWriterCastIdentSpaced(): Void {
		writerEquals(
			'class C { var f:Int = cast x; }', 'class C {\n\tvar f:Int = cast x;\n}\n',
			'spaced `cast x` on bare IdentExpr operand (knob does not fire)'
		);
	}

	public function testWriterCastIsBoolTight(): Void {
		// The pre-Slice-46 fixture-failing case: `cast (x) is Bool`
		// round-trips as `cast(x) is Bool` with tight cast paren.
		writerEquals(
			'class C { function m():Void { (cast (x) is Bool); } }', 'class C {\n\tfunction m():Void {\n\t\t(cast(x) is Bool);\n\t}\n}\n',
			'tight `cast(x)` survives the outer `is Bool` Pratt frame'
		);
	}

	// ======== Combined: nested cast forms ========

	public function testTypedCastWrapsBareCast(): Void {
		// `cast(cast x, Int)` — TypedCastExpr whose target is CastExpr.
		final decl = parseSingleVarDecl('class C { var f:Int = cast(cast x, Int); }');
		switch decl.init {
			case TypedCastExpr(info):
				switch info.target {
					case CastExpr(IdentExpr(name)): Assert.equals('x', (name: String));
					case _: Assert.fail('expected CastExpr target, got ${info.target}');
				}
			case null, _:
				Assert.fail('expected TypedCastExpr(CastExpr)');
		}
	}

	public function testCastWrapsTypedCast(): Void {
		// `cast cast(x, Int)` — bare CastExpr wrapping TypedCastExpr.
		final decl = parseSingleVarDecl('class C { var f:Int = cast cast(x, Int); }');
		switch decl.init {
			case CastExpr(TypedCastExpr(info)):
				switch info.target {
					case IdentExpr(name): Assert.equals('x', (name: String));
					case _: Assert.fail('expected IdentExpr target');
				}
			case null, _:
				Assert.fail('expected CastExpr(TypedCastExpr)');
		}
	}

	// ======== HxType helper (local to this file) ========

	private function expectNamedTypeFromHxType(t: HxType): anyparse.grammar.haxe.HxTypeRef {
		return switch t {
			case Named(ref): ref;
			case _: throw 'expected HxType.Named, got $t';
		};
	}

}
