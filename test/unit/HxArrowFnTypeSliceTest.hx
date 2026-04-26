package unit;

import utest.Assert;
import anyparse.format.WhitespacePolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxArrowFnType;
import anyparse.grammar.haxe.HxArrowParam;
import anyparse.grammar.haxe.HxArrowParamBody;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxType;
import anyparse.grammar.haxe.HxTypeRef;
import anyparse.grammar.haxe.HxTypedefDecl;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Slice ω-arrow-fn-type — new-form (Haxe 4) arrow function type
 * `(args) -> ret` on `HxType`.
 *
 * Validates `HxType.ArrowFn(fn:HxArrowFnType)` placed BEFORE
 * `HxType.Parens` in source order so the parser tries the arrow-fn
 * shape first; when the trailing `->` is missing the branch rolls
 * back and `Parens` (or any other `(`-prefixed atom) takes over.
 *
 * `HxArrowParam` Alt-enum split:
 *  - `Named(body:HxArrowParamBody)` — `name:Type` form (`(name:String) -> Void`).
 *    Tried first via `tryBranch`. Commit point is the `:` lead on
 *    `HxArrowParamBody.type` — when the parens contain a bare type
 *    whose initial token is an identifier, the branch parses the
 *    identifier as a candidate name, fails to match `:`, and rolls back.
 *  - `Positional(type:HxType)` — fallback that catches every shape the
 *    named form rejects (bare typeref, qualified, parameterised,
 *    nested arrow, anon struct, `(Inner)` parens).
 *
 * Writer emission: `@:fmt(functionTypeHaxe4)` on `HxArrowFnType.ret`'s
 * `@:lead('->')` routes through `whitespacePolicyLead` so
 * `opt.functionTypeHaxe4:WhitespacePolicy` controls the spacing.
 * Default `Both` matches haxe-formatter's
 * `whitespace.functionTypeHaxe4Policy: @:default(Around)` and emits
 * `(args) -> ret`. The old-form curried arrow `Int->Bool` keeps its
 * `@:fmt(tight)` on `HxType.Arrow` and is unaffected by this knob.
 */
@:nullSafety(Strict)
class HxArrowFnTypeSliceTest extends HxTestHelpers {

	private function expectArrowFnType(t:Null<HxType>):HxArrowFnType {
		return switch t {
			case null: throw 'expected HxType.ArrowFn, got null';
			case ArrowFn(fn): fn;
			case _: throw 'expected HxType.ArrowFn, got non-ArrowFn variant';
		};
	}

	private function expectPositionalParam(p:HxArrowParam):HxType {
		return switch p {
			case Positional(type): type;
			case Named(_): throw 'expected HxArrowParam.Positional, got Named';
		};
	}

	private function expectNamedParam(p:HxArrowParam):HxArrowParamBody {
		return switch p {
			case Named(body): body;
			case Positional(_): throw 'expected HxArrowParam.Named, got Positional';
		};
	}

	public function testEmptyArgsArrow():Void {
		final v:HxVarDecl = parseSingleVarDecl('class Foo { var f:() -> Void; }');
		final fn:HxArrowFnType = expectArrowFnType(v.type);
		Assert.equals(0, fn.args.length);
		Assert.equals('Void', (expectNamedType(fn.ret).name : String));
	}

	public function testSinglePositionalArg():Void {
		final v:HxVarDecl = parseSingleVarDecl('class Foo { var f:(Int) -> Bool; }');
		final fn:HxArrowFnType = expectArrowFnType(v.type);
		Assert.equals(1, fn.args.length);
		Assert.equals('Int', (expectNamedType(expectPositionalParam(fn.args[0])).name : String));
		Assert.equals('Bool', (expectNamedType(fn.ret).name : String));
	}

	public function testMultiPositionalArgs():Void {
		final v:HxVarDecl = parseSingleVarDecl('class Foo { var f:(Int, String) -> Bool; }');
		final fn:HxArrowFnType = expectArrowFnType(v.type);
		Assert.equals(2, fn.args.length);
		Assert.equals('Int', (expectNamedType(expectPositionalParam(fn.args[0])).name : String));
		Assert.equals('String', (expectNamedType(expectPositionalParam(fn.args[1])).name : String));
		Assert.equals('Bool', (expectNamedType(fn.ret).name : String));
	}

	public function testSingleNamedArg():Void {
		final v:HxVarDecl = parseSingleVarDecl('class Foo { var f:(name:String) -> Void; }');
		final fn:HxArrowFnType = expectArrowFnType(v.type);
		Assert.equals(1, fn.args.length);
		final named:HxArrowParamBody = expectNamedParam(fn.args[0]);
		Assert.equals('name', (named.name : String));
		Assert.equals('String', (expectNamedType(named.type).name : String));
		Assert.equals('Void', (expectNamedType(fn.ret).name : String));
	}

	public function testMultiNamedArgs():Void {
		final v:HxVarDecl = parseSingleVarDecl('class Foo { var f:(resolve:Dynamic, reject:Dynamic) -> Void; }');
		final fn:HxArrowFnType = expectArrowFnType(v.type);
		Assert.equals(2, fn.args.length);
		final a0:HxArrowParamBody = expectNamedParam(fn.args[0]);
		Assert.equals('resolve', (a0.name : String));
		Assert.equals('Dynamic', (expectNamedType(a0.type).name : String));
		final a1:HxArrowParamBody = expectNamedParam(fn.args[1]);
		Assert.equals('reject', (a1.name : String));
		Assert.equals('Dynamic', (expectNamedType(a1.type).name : String));
	}

	public function testMixedNamedAndPositional():Void {
		// `(Int, name:String) -> Bool` — positional first, named second.
		// Each `HxArrowParam` enum is matched independently, so the
		// macro pipeline imposes no positional-before-named ordering.
		final v:HxVarDecl = parseSingleVarDecl('class Foo { var f:(Int, name:String) -> Bool; }');
		final fn:HxArrowFnType = expectArrowFnType(v.type);
		Assert.equals(2, fn.args.length);
		Assert.equals('Int', (expectNamedType(expectPositionalParam(fn.args[0])).name : String));
		final named:HxArrowParamBody = expectNamedParam(fn.args[1]);
		Assert.equals('name', (named.name : String));
		Assert.equals('String', (expectNamedType(named.type).name : String));
	}

	public function testRightAssociativeChain():Void {
		// `(Int) -> (String) -> Bool` — each parens cluster is its own
		// `ArrowFn`; the outer's ret is itself an `ArrowFn`.
		final v:HxVarDecl = parseSingleVarDecl('class Foo { var f:(Int) -> (String) -> Bool; }');
		final outer:HxArrowFnType = expectArrowFnType(v.type);
		Assert.equals(1, outer.args.length);
		Assert.equals('Int', (expectNamedType(expectPositionalParam(outer.args[0])).name : String));
		final inner:HxArrowFnType = expectArrowFnType(outer.ret);
		Assert.equals(1, inner.args.length);
		Assert.equals('String', (expectNamedType(expectPositionalParam(inner.args[0])).name : String));
		Assert.equals('Bool', (expectNamedType(inner.ret).name : String));
	}

	public function testParameterisedTypeAsPositionalArg():Void {
		// `(Array<Int>) -> Void` — the named branch tries `Array` then
		// expects `:`, fails on `<`, rolls back to Positional(Named(Array<Int>)).
		final v:HxVarDecl = parseSingleVarDecl('class Foo { var f:(Array<Int>) -> Void; }');
		final fn:HxArrowFnType = expectArrowFnType(v.type);
		Assert.equals(1, fn.args.length);
		final argType:HxType = expectPositionalParam(fn.args[0]);
		final ref:HxTypeRef = expectNamedType(argType);
		Assert.equals('Array', (ref.name : String));
		final params:Null<Array<HxType>> = ref.params;
		Assert.notNull(params);
		if (params == null) return;
		Assert.equals(1, params.length);
		Assert.equals('Int', (expectNamedType(params[0]).name : String));
	}

	public function testCurriedArrowAsPositionalArg():Void {
		// `(Int->Bool) -> Void` — pre-slice this parsed as
		// `Arrow(Parens(Arrow(Int,Bool)), Void)`; with `ArrowFn` placed
		// before `Parens` it now uniformly routes through the new-form
		// shape `ArrowFn([Positional(Arrow(Int,Bool))], Void)`.
		final v:HxVarDecl = parseSingleVarDecl('class Foo { var f:(Int->Bool) -> Void; }');
		final fn:HxArrowFnType = expectArrowFnType(v.type);
		Assert.equals(1, fn.args.length);
		final argType:HxType = expectPositionalParam(fn.args[0]);
		switch argType {
			case Arrow(l, r):
				Assert.equals('Int', (expectNamedType(l).name : String));
				Assert.equals('Bool', (expectNamedType(r).name : String));
			case _: Assert.fail('expected Arrow(Int,Bool), got ${argType}');
		}
		Assert.equals('Void', (expectNamedType(fn.ret).name : String));
	}

	public function testNestedArrowFnInsideArrowFn():Void {
		// `(resolve:(value:Dynamic) -> Void) -> Void` — the inner named-
		// arg's type is itself an `ArrowFn`. From `issue_56_arrow_functions`.
		final v:HxVarDecl = parseSingleVarDecl(
			'class Foo { var f:(resolve:(value:Dynamic) -> Void) -> Void; }'
		);
		final outer:HxArrowFnType = expectArrowFnType(v.type);
		Assert.equals(1, outer.args.length);
		final outerArg:HxArrowParamBody = expectNamedParam(outer.args[0]);
		Assert.equals('resolve', (outerArg.name : String));
		final innerFn:HxArrowFnType = expectArrowFnType(outerArg.type);
		Assert.equals(1, innerFn.args.length);
		final innerArg:HxArrowParamBody = expectNamedParam(innerFn.args[0]);
		Assert.equals('value', (innerArg.name : String));
		Assert.equals('Dynamic', (expectNamedType(innerArg.type).name : String));
		Assert.equals('Void', (expectNamedType(innerFn.ret).name : String));
		Assert.equals('Void', (expectNamedType(outer.ret).name : String));
	}

	public function testArrowFnAsFnReturnType():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar():(Int) -> Bool { return null; } }');
		final fn:HxArrowFnType = expectArrowFnType(decl.returnType);
		Assert.equals(1, fn.args.length);
		Assert.equals('Int', (expectNamedType(expectPositionalParam(fn.args[0])).name : String));
		Assert.equals('Bool', (expectNamedType(fn.ret).name : String));
	}

	public function testArrowFnAsFnParamType():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar(cb:() -> Void):Void {} }');
		Assert.equals(1, decl.params.length);
		final paramType:HxType = expectRequiredParam(decl.params[0]).type;
		final fn:HxArrowFnType = expectArrowFnType(paramType);
		Assert.equals(0, fn.args.length);
		Assert.equals('Void', (expectNamedType(fn.ret).name : String));
	}

	public function testArrowFnAsTypedefRhs():Void {
		final module:HxModule = HaxeModuleParser.parse('typedef Cb = (Int, String) -> Bool;');
		Assert.equals(1, module.decls.length);
		final td:HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		Assert.equals('Cb', (td.name : String));
		final fn:HxArrowFnType = expectArrowFnType(td.type);
		Assert.equals(2, fn.args.length);
		Assert.equals('Int', (expectNamedType(expectPositionalParam(fn.args[0])).name : String));
		Assert.equals('String', (expectNamedType(expectPositionalParam(fn.args[1])).name : String));
		Assert.equals('Bool', (expectNamedType(fn.ret).name : String));
	}

	public function testRollbackToParensWhenNoTrailingArrow():Void {
		// `(Int->Bool)` alone (no following `->`) — `ArrowFn` parses
		// the args list, fails to match the trailing `->`, rolls back
		// to `Parens` which wraps the inner Arrow.
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar(cb:(Int->Bool)):Void {} }');
		final paramType:HxType = expectRequiredParam(decl.params[0]).type;
		switch paramType {
			case Parens(_): Assert.pass();
			case _: Assert.fail('expected Parens, got ${paramType}');
		}
	}

	public function testBareTypeNotAffected():Void {
		// `Int->Bool` (no parens) parses unchanged as old-form Arrow.
		final v:HxVarDecl = parseSingleVarDecl('class Foo { var f:Int->Bool; }');
		switch v.type {
			case Arrow(l, r):
				Assert.equals('Int', (expectNamedType(l).name : String));
				Assert.equals('Bool', (expectNamedType(r).name : String));
			case _: Assert.fail('expected Arrow(Int,Bool), got ${v.type}');
		}
	}

	public function testWriterEmitsAroundSpacedArrow():Void {
		final out:String = writeWith('class Foo { var f:(Int)->Bool; }', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('var f:(Int) -> Bool;') != -1, 'expected `(Int) -> Bool` in: <$out>');
	}

	public function testWriterEmitsAroundSpacedEmptyArrow():Void {
		final out:String = writeWith('class Foo { var f:()->Void; }', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('var f:() -> Void;') != -1, 'expected `() -> Void` in: <$out>');
	}

	public function testWriterEmitsAroundSpacedMultiArgArrow():Void {
		final out:String = writeWith('class Foo { var f:(Int,String)->Bool; }', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('var f:(Int, String) -> Bool;') != -1, 'expected `(Int, String) -> Bool` in: <$out>');
	}

	public function testWriterTightWhenPolicyNone():Void {
		final out:String = writeWith('class Foo { var f:(Int) -> Bool; }', WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('var f:(Int)->Bool;') != -1, 'expected `(Int)->Bool` in: <$out>');
		Assert.isTrue(out.indexOf(') -> Bool') == -1, 'did not expect spaced `->` in: <$out>');
	}

	public function testWriterRespectsNamedParam():Void {
		final out:String = writeWith('class Foo { var f:(name:String) -> Void; }', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('var f:(name:String) -> Void;') != -1, 'expected `(name:String) -> Void` in: <$out>');
	}

	public function testFunctionTypeHaxe4DefaultIsBoth():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(WhitespacePolicy.Both, defaults.functionTypeHaxe4);
	}

	public function testFunctionTypeHaxe4LoaderMapsAround():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"whitespace":{"functionTypeHaxe4Policy":"around"}}'
		);
		Assert.equals(WhitespacePolicy.Both, opts.functionTypeHaxe4);
	}

	public function testFunctionTypeHaxe4LoaderMapsNone():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"whitespace":{"functionTypeHaxe4Policy":"none"}}'
		);
		Assert.equals(WhitespacePolicy.None, opts.functionTypeHaxe4);
	}

	public function testRoundTrip():Void {
		roundTrip('class Foo { var f:() -> Void; }', 'empty-args');
		roundTrip('class Foo { var f:(Int) -> Bool; }', 'single-positional');
		roundTrip('class Foo { var f:(Int, String) -> Bool; }', 'multi-positional');
		roundTrip('class Foo { var f:(name:String) -> Void; }', 'single-named');
		roundTrip('class Foo { var f:(resolve:Dynamic, reject:Dynamic) -> Void; }', 'multi-named');
		roundTrip('class Foo { var f:(Int, name:String) -> Bool; }', 'mixed');
		roundTrip('class Foo { var f:(Int) -> (String) -> Bool; }', 'right-assoc');
		roundTrip('class Foo { var f:(Array<Int>) -> Void; }', 'parameterised-arg');
		roundTrip('class Foo { var f:(resolve:(value:Dynamic) -> Void) -> Void; }', 'nested-arrowfn-named');
		roundTrip('class Foo { function bar(cb:() -> Void):Void {} }', 'fn-param-type');
		roundTrip('class Foo { function bar():(Int) -> Bool { return null; } }', 'fn-return-type');
		roundTrip('typedef Cb = (Int, String) -> Bool;', 'typedef-rhs');
	}

	private inline function writeWith(src:String, policy:WhitespacePolicy):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts(policy));
	}

	private inline function makeOpts(policy:WhitespacePolicy):HxModuleWriteOptions {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.functionTypeHaxe4 = policy;
		return opts;
	}
}
