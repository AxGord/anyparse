package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxType;
import anyparse.grammar.haxe.HxTypeRef;
import anyparse.grammar.haxe.HxTypeParamDecl;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Slice `ω-hxtype-parens` — parenthesised-type atom on `HxType`.
 *
 * Validates the `Parens(inner:HxType)` atom branch added via
 * `@:wrap('(', ')')` — Case 3 single-Ref wrapping mirroring
 * `HxExpr.ParenExpr`. After the ω-arrow-fn-type slice landed
 * `HxType.ArrowFn` BEFORE `Parens` in source order, `Parens` is
 * reached only for `(...)` shapes NOT followed by `->` — e.g. the
 * type-param constraint surface (`<S:(pack.sub.Type)=...>`), bare
 * parens inside a type-param list (`Array<(Int)>`), and parens around
 * an arrow type with no outer arrow (`(Int->Bool)` as a function-
 * argument type).
 *
 * The new-form arrow shapes `() -> R`, `(T, U) -> R`, `(name:T) -> R`
 * and the single-arg `(T) -> R` (which now also routes through
 * `ArrowFn`, NOT `Arrow(Parens(T), R)` as in the pre-slice writer)
 * have their own coverage in `HxArrowFnTypeSliceTest`.
 */
class HxTypeParensSliceTest extends HxTestHelpers {

	private function expectParensType(t:Null<HxType>):HxType {
		return switch t {
			case null: throw 'expected HxType.Parens, got null';
			case Parens(inner): inner;
			case _: throw 'expected HxType.Parens, got non-Parens variant';
		};
	}

	private function expectArrowType(t:Null<HxType>):{left:HxType, right:HxType} {
		return switch t {
			case null: throw 'expected HxType.Arrow, got null';
			case Arrow(l, r): {left: l, right: r};
			case _: throw 'expected HxType.Arrow, got non-Arrow variant';
		};
	}

	public function testSimpleParensAroundNamed():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var f:(Int); }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final inner:HxType = expectParensType(v.type);
		Assert.equals('Int', (expectNamedType(inner).name : String));
	}

	public function testParensAroundQualifiedName():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var f:(pack.sub.Type); }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final inner:HxType = expectParensType(v.type);
		Assert.equals('pack.sub.Type', (expectNamedType(inner).name : String));
	}

	public function testParensAroundParameterised():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var f:(Array<Int>); }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final inner:HxType = expectParensType(v.type);
		final ref:HxTypeRef = expectNamedType(inner);
		Assert.equals('Array', (ref.name : String));
		Assert.notNull(ref.params);
		Assert.equals(1, ref.params.length);
		Assert.equals('Int', (expectNamedType(ref.params[0]).name : String));
	}

	public function testNestedParens():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var f:((Int)); }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final inner:HxType = expectParensType(v.type);
		final innerInner:HxType = expectParensType(inner);
		Assert.equals('Int', (expectNamedType(innerInner).name : String));
	}

	public function testParensAroundArrow():Void {
		// Bare `(Int->Bool)` as a function-argument type — no following
		// `->` so `ArrowFn` rolls back and `Parens` wins. Validates the
		// inner Arrow shape survives the wrap.
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar(cb:(Int->Bool)):Void {} }');
		Assert.equals(1, decl.params.length);
		final paramType:HxType = expectRequiredParam(decl.params[0]).type;
		final innerArrow = expectArrowType(expectParensType(paramType));
		Assert.equals('Int', (expectNamedType(innerArrow.left).name : String));
		Assert.equals('Bool', (expectNamedType(innerArrow.right).name : String));
	}

	public function testParensAsTypeParamConstraint():Void {
		// `class Foo<S:(pack.sub.Type)>` — the issue_650 driver shape.
		final ast:HxClassDecl = HaxeParser.parse('class Foo<S:(pack.sub.Type)> {}');
		Assert.notNull(ast.typeParams);
		Assert.equals(1, ast.typeParams.length);
		final tp:HxTypeParamDecl = ast.typeParams[0];
		Assert.equals('S', (tp.name : String));
		Assert.notNull(tp.constraint);
		final inner:HxType = expectParensType(tp.constraint);
		Assert.equals('pack.sub.Type', (expectNamedType(inner).name : String));
	}

	public function testParensAsTypeParamConstraintWithDefault():Void {
		// Full issue_650 line 11 shape: `<S:(pack.sub.Type)=pack.sub.TypeImpl>`.
		final ast:HxClassDecl = HaxeParser.parse('class Foo<S:(pack.sub.Type)=pack.sub.TypeImpl> {}');
		final tp:HxTypeParamDecl = ast.typeParams[0];
		Assert.equals('S', (tp.name : String));
		Assert.notNull(tp.constraint);
		Assert.equals('pack.sub.Type', (expectNamedType(expectParensType(tp.constraint)).name : String));
		Assert.notNull(tp.defaultValue);
		Assert.equals('pack.sub.TypeImpl', (expectNamedType(tp.defaultValue).name : String));
	}

	public function testParensInsideTypeParam():Void {
		// `Array<(Int)>` — Parens nested inside a type-param list.
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var f:Array<(Int)>; }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final outerRef:HxTypeRef = expectNamedType(v.type);
		Assert.equals('Array', (outerRef.name : String));
		Assert.notNull(outerRef.params);
		Assert.equals(1, outerRef.params.length);
		final inner:HxType = expectParensType(outerRef.params[0]);
		Assert.equals('Int', (expectNamedType(inner).name : String));
	}

	public function testParensOnFnReturnType():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar():(Int) {} }');
		final inner:HxType = expectParensType(decl.returnType);
		Assert.equals('Int', (expectNamedType(inner).name : String));
	}

	public function testParensOnFnParamType():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar(x:(Int)):Void {} }');
		Assert.equals(1, decl.params.length);
		final paramType:HxType = expectRequiredParam(decl.params[0]).type;
		Assert.equals('Int', (expectNamedType(expectParensType(paramType)).name : String));
	}

	public function testWhitespaceTolerantInsideParens():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var f:( Int ); }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		Assert.equals('Int', (expectNamedType(expectParensType(v.type)).name : String));
	}

	public function testRoundTrip():Void {
		roundTrip('class Foo { var f:(Int); }', 'simple-parens');
		roundTrip('class Foo { var f:(pack.sub.Type); }', 'parens-qualified');
		roundTrip('class Foo { var f:(Array<Int>); }', 'parens-parameterised');
		roundTrip('class Foo { var f:((Int)); }', 'nested-parens');
		roundTrip('class Foo { function bar(cb:(Int->Bool)):Void {} }', 'parens-around-arrow-as-arg-type');
		roundTrip('class Foo<S:(pack.sub.Type)> {}', 'parens-typeparam-constraint');
		roundTrip('class Foo<S:(pack.sub.Type) = pack.sub.TypeImpl> {}', 'parens-typeparam-constraint-with-default');
		roundTrip('class Foo { var f:Array<(Int)>; }', 'parens-inside-typeparam');
		roundTrip('class Foo { function bar():(Int) {} }', 'parens-return-type');
		roundTrip('class Foo { function bar(x:(Int)):Void {} }', 'parens-param-type');
	}
}
