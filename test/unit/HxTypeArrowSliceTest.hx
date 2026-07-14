package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxType;
import anyparse.grammar.haxe.HxTypeRef;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Slice `ω-hxtype-arrow` — function-arrow type variant on `HxType`.
 *
 * Validates the new `Arrow(left:HxType, right:HxType)` Pratt branch
 * activated by `@:infix('->', 0, 'Right')` on `HxType`. Right-
 * associativity ensures `Int->Bool->Void` nests as
 * `Arrow(Int, Arrow(Bool, Void))`. Type-param composition routes
 * through the existing `HxTypeRef.params:Array<HxType>` recursion
 * (post-foundation) — `Array<Int->Void>` parses without revisiting
 * params.
 *
 * The new (parenthesised) syntax `(Int) -> Int`, `(Int, String) -> Bool`
 * is NOT covered here — it requires a parenthesised-type atom that
 * lands as a separate slice.
 */
class HxTypeArrowSliceTest extends HxTestHelpers {

	private function expectArrow(t: Null<HxType>): { left: HxType, right: HxType } {
		return switch t {
			case null: throw 'expected HxType.Arrow, got null';
			case Arrow(l, r): { left: l, right: r };
			case _: throw 'expected HxType.Arrow, got non-Arrow variant';
		};
	}

	public function testSimpleArrow(): Void {
		final ast: HxClassDecl = HaxeParser.parse('class Foo { var f:Void->Void; }');
		Assert.equals(1, ast.members.length);
		final v: HxVarDecl = expectVarMember(ast.members[0].member);
		final arr = expectArrow(v.type);
		Assert.equals('Void', (expectNamedType(arr.left).name: String));
		Assert.equals('Void', (expectNamedType(arr.right).name: String));
	}

	public function testRightAssoc(): Void {
		final ast: HxClassDecl = HaxeParser.parse('class Foo { var f:Int->String->Void; }');
		final v: HxVarDecl = expectVarMember(ast.members[0].member);
		final outer = expectArrow(v.type);
		Assert.equals('Int', (expectNamedType(outer.left).name: String));
		// right-assoc: outer.right itself is an Arrow.
		final inner = expectArrow(outer.right);
		Assert.equals('String', (expectNamedType(inner.left).name: String));
		Assert.equals('Void', (expectNamedType(inner.right).name: String));
	}

	public function testRightAssocFourSegments(): Void {
		final ast: HxClassDecl = HaxeParser.parse('class Foo { var f:Int->String->Bool->Void; }');
		final v: HxVarDecl = expectVarMember(ast.members[0].member);
		var cur: HxType = v.type;
		final names: Array<String> = [];
		while (true) {
			switch cur {
				case Arrow(l, r):
					names.push((expectNamedType(l).name: String));
					cur = r;
				case Named(ref):
					names.push((ref.name: String));
					break;
				case _:
					Assert.fail('unexpected variant');
					return;
			}
		}
		Assert.equals('Int,String,Bool,Void', names.join(','));
	}

	public function testArrowWithTypeParamLeft(): Void {
		final ast: HxClassDecl = HaxeParser.parse('class Foo { var f:Array<Int>->Void; }');
		final v: HxVarDecl = expectVarMember(ast.members[0].member);
		final arr = expectArrow(v.type);
		final leftRef: HxTypeRef = expectNamedType(arr.left);
		Assert.equals('Array', (leftRef.name: String));
		Assert.notNull(leftRef.params);
		Assert.equals(1, leftRef.params.length);
		Assert.equals('Int', (expectNamedType(leftRef.params[0].type).name: String));
		Assert.equals('Void', (expectNamedType(arr.right).name: String));
	}

	public function testArrowInsideTypeParam(): Void {
		final ast: HxClassDecl = HaxeParser.parse('class Foo { var f:Array<Int->Void>; }');
		final v: HxVarDecl = expectVarMember(ast.members[0].member);
		final outerRef: HxTypeRef = expectNamedType(v.type);
		Assert.equals('Array', (outerRef.name: String));
		Assert.notNull(outerRef.params);
		Assert.equals(1, outerRef.params.length);
		final inner = expectArrow(outerRef.params[0].type);
		Assert.equals('Int', (expectNamedType(inner.left).name: String));
		Assert.equals('Void', (expectNamedType(inner.right).name: String));
	}

	public function testArrowOnFnReturnType(): Void {
		final decl: HxFnDecl = parseSingleFnDecl('class Foo { function bar():Int->Void {} }');
		final arr = expectArrow(decl.returnType);
		Assert.equals('Int', (expectNamedType(arr.left).name: String));
		Assert.equals('Void', (expectNamedType(arr.right).name: String));
	}

	public function testArrowOnFnParamType(): Void {
		final decl: HxFnDecl = parseSingleFnDecl('class Foo { function bar(cb:Int->Void):Void {} }');
		Assert.equals(1, decl.params.length);
		final arr = expectArrow(expectRequiredParam(decl.params[0]).type);
		Assert.equals('Int', (expectNamedType(arr.left).name: String));
		Assert.equals('Void', (expectNamedType(arr.right).name: String));
	}

	public function testWhitespaceTolerantSpaces(): Void {
		final ast: HxClassDecl = HaxeParser.parse('class Foo { var f:Int -> Void; }');
		final v: HxVarDecl = expectVarMember(ast.members[0].member);
		final arr = expectArrow(v.type);
		Assert.equals('Int', (expectNamedType(arr.left).name: String));
		Assert.equals('Void', (expectNamedType(arr.right).name: String));
	}

	/**
	 * Slice ω-curried-optional-arg (`whitespace/issue_173`): the `?`
	 * optional-argument marker in a curried function type. Asserts the
	 * `OptionalArg` branch is reached and the flattened leaf sequence is
	 * preserved (grouping is intentionally not over-asserted — see the
	 * `OptionalArg` AST-shape note in `HxType`).
	 */
	private function arrowLeaves(t: HxType, acc: Array<String>): Void {
		switch t {
			case Arrow(l, r):
				arrowLeaves(l, acc);
				arrowLeaves(r, acc);
			case OptionalArg(inner):
				acc.push('?');
				arrowLeaves(inner, acc);
			case Named(ref):
				acc.push((ref.name: String));
			case _:
				acc.push('<other>');
		}
	}

	public function testCurriedOptionalArg(): Void {
		final ast: HxClassDecl = HaxeParser.parse('class Foo { var f:Int->?Int->Void; }');
		final v: HxVarDecl = expectVarMember(ast.members[0].member);
		final leaves: Array<String> = [];
		arrowLeaves(
			switch v.type {
				case null: throw 'null type';
				case t: t;
			},
			leaves
		);
		Assert.equals('Int,?,Int,Void', leaves.join(','));
	}

	public function testCurriedMultipleOptionalArgs(): Void {
		final ast: HxClassDecl = HaxeParser.parse('class Foo { var f:Int->?Int->?Int->?Int->?Int->Void; }');
		final v: HxVarDecl = expectVarMember(ast.members[0].member);
		final leaves: Array<String> = [];
		arrowLeaves(
			switch v.type {
				case null: throw 'null type';
				case t: t;
			},
			leaves
		);
		Assert.equals('Int,?,Int,?,Int,?,Int,?,Int,Void', leaves.join(','));
	}

	public function testOptionalArgRoundTrip(): Void {
		// `whitespace/issue_173` verbatim shapes — byte-identical re-emit
		// is the corpus metric this slice targets.
		roundTrip('class Main { public static function main() { var f:Int->?Int->Void; } }', 'issue_173-single');
		roundTrip('class Main { public static function main() { var f:Int->?Int->?Int->?Int->?Int->Void; } }', 'issue_173-multi');
	}

	public function testRoundTripTight(): Void {
		// Default `@:fmt(functionTypeHaxe3)` + `opt.functionTypeHaxe3 = None`
		// — writer emits `Int->Void` without surrounding spaces, matching
		// haxe-formatter's old-form arrow output. Writer Slice 6 added the
		// runtime knob; `None` reproduces the pre-slice `@:fmt(tight)` shape.
		roundTrip('class Foo { var f:Void->Void; }', 'simple-arrow');
		roundTrip('class Foo { var f:Int->String->Void; }', 'right-assoc-arrow');
		roundTrip('class Foo { var f:Array<Int>->Void; }', 'arrow-with-type-param-left');
		roundTrip('class Foo { var f:Array<Int->Void>; }', 'arrow-inside-type-param');
		roundTrip('class Foo { function bar():Int->Void {} }', 'arrow-return-type');
		roundTrip('class Foo { function bar(cb:Int->Void):Void {} }', 'arrow-param-type');
	}

}
