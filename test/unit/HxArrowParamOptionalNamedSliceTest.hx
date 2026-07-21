package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxArrowFnType;
import anyparse.grammar.haxe.HxArrowParamBody;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Slice fn-param-I — OPTIONAL NAMED argument in a function TYPE:
 * `(?b:Int) -> Void`.
 *
 * `HxArrowParam` had two branches: `Named` (`name:Type`, commit point
 * the `:` lead inside `HxArrowParamBody`) and the catch-all
 * `Positional` (any `HxType`, which covers the positional-optional
 * `?Int` via `HxType.OptionalArg`). Neither accepted `?` FOLLOWED BY a
 * name and a type annotation: `Positional` consumed `?b` as
 * `OptionalArg(Named(b))` and then the enclosing `@:sep(',')` /
 * `@:trail(')')` Star choked on the `:`.
 *
 * The slice adds a third branch, `@:lead('?') OptionalNamed`, sharing
 * `HxArrowParamBody` with `Named` and placed before the catch-all
 * `Positional`, which would otherwise swallow `?b` again.
 *
 * Real-world source: 3 Haxe stdlib modules.
 *  - `js/Lib.hx:75` and `flash/Lib.hx:104` — both declare
 *    `parseInt` as `(string:String, ?radix:Int) -> Float`.
 *  - `eval/luv/Udp.hx:98` — `?allocate:(size:Int) -> Buffer`, i.e. a
 *    nested function type sitting in the optional named slot.
 *
 * The positional-optional shape deliberately does NOT move: `(?Int)`
 * enters `OptionalNamed`, reads `Int` as a candidate name, fails the
 * mandatory `:` lead on `HxArrowParamBody.type`, and `tryBranch`
 * restores `ctx.pos`; `Named` then rejects the leading `?`, and
 * `Positional` reproduces the pre-slice `OptionalArg(Named(Int))` AST.
 * The regression cases below pin that for a type-shaped candidate name
 * (`?Int`), a qualified one (`?haxe.io.Bytes`) and a name-shaped one
 * (`?b`, the closest neighbour of all — it differs from `?b:Int` by
 * exactly the token that drives the rollback), plus the curried Haxe-3
 * form `Int->?Int->Void` which stays entirely on `HxType.OptionalArg`.
 *
 * The `HxArrowParam` destructuring helpers live in `HxTestHelpers` and
 * enumerate every ctor rather than ending on `case _:`, so a future
 * branch on that enum breaks the build there — the same tripwire that
 * surfaced the two switches this slice had to update.
 */
@:nullSafety(Strict)
class HxArrowParamOptionalNamedSliceTest extends HxTestHelpers {

	private static final CFG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 120}}';

	public function testSingleOptionalNamedArg(): Void {
		final v: HxVarDecl = parseSingleVarDecl('class Foo { var f:(?b:Int) -> Void; }');
		final fn: HxArrowFnType = expectArrowFnType(v.type);
		Assert.equals(1, fn.args.length);
		final body: HxArrowParamBody = expectOptionalNamedParam(fn.args[0]);
		Assert.equals('b', (body.name: String));
		Assert.equals('Int', (expectNamedType(body.type).name: String));
		Assert.equals('Void', (expectNamedType(fn.ret).name: String));
	}

	public function testStdlibParseIntSignature(): Void {
		// js/Lib.hx:75 and flash/Lib.hx:104, verbatim shape.
		final v: HxVarDecl = parseSingleVarDecl('class Foo { static var parseInt:(string:String, ?radix:Int) -> Float; }');
		final fn: HxArrowFnType = expectArrowFnType(v.type);
		Assert.equals(2, fn.args.length);
		Assert.equals('string', (expectNamedParam(fn.args[0]).name: String));
		final radix: HxArrowParamBody = expectOptionalNamedParam(fn.args[1]);
		Assert.equals('radix', (radix.name: String));
		Assert.equals('Int', (expectNamedType(radix.type).name: String));
	}

	public function testNestedArrowTypeInOptionalNamedSlot(): Void {
		// eval/luv/Udp.hx:98 — the optional named arg's type is itself a
		// new-form arrow type, so `HxArrowParamBody.type` must recurse
		// through the full `HxType` rule (it does; the slot is `HxType`).
		final v: HxVarDecl = parseSingleVarDecl('class Foo { var f:(?allocate:(size:Int) -> Buffer) -> Void; }');
		final fn: HxArrowFnType = expectArrowFnType(v.type);
		Assert.equals(1, fn.args.length);
		final alloc: HxArrowParamBody = expectOptionalNamedParam(fn.args[0]);
		Assert.equals('allocate', (alloc.name: String));
		final inner: HxArrowFnType = expectArrowFnType(alloc.type);
		Assert.equals(1, inner.args.length);
		Assert.equals('size', (expectNamedParam(inner.args[0]).name: String));
		Assert.equals('Buffer', (expectNamedType(inner.ret).name: String));
	}

	public function testPositionalOptionalStaysOnOptionalArg(): Void {
		// GUARD: `(?Int) -> Void` must keep the pre-slice AST
		// `ArrowFn([Positional(OptionalArg(Named(Int)))], Void)`. The
		// second case is the closest neighbour of all — `?b` differs from
		// the new `?b:Int` by exactly the token that drives the rollback,
		// and its candidate name is name-shaped rather than type-shaped.
		for (t => expectedName in ['(?Int) -> Void' => 'Int', '(?b) -> Void' => 'b']) {
			final v: HxVarDecl = parseSingleVarDecl('class Foo { var f:$t; }');
			final fn: HxArrowFnType = expectArrowFnType(v.type);
			Assert.equals(1, fn.args.length, t);
			switch fn.args[0] {
				case Positional(OptionalArg(Named(ref))):
					Assert.equals(expectedName, (ref.name: String), t);
				case _:
					Assert.fail('expected Positional(OptionalArg(Named)) for $t, got ${fn.args[0]}');
			}
			roundTrip('class Foo { var f:$t; }', t);
		}
	}

	public function testQualifiedPositionalOptionalStaysOnOptionalArg(): Void {
		// GUARD: `?pack.Sub.Type` — `OptionalNamed` reads `pack` as a
		// candidate name and fails on the `.`, so `Positional` wins.
		final v: HxVarDecl = parseSingleVarDecl('class Foo { var f:(?haxe.io.Bytes) -> Void; }');
		final fn: HxArrowFnType = expectArrowFnType(v.type);
		switch fn.args[0] {
			case Positional(OptionalArg(Named(ref))):
				Assert.equals('haxe.io.Bytes', (ref.name: String));
			case _:
				Assert.fail('expected Positional(OptionalArg(Named)), got ${fn.args[0]}');
		}
	}

	public function testNamedAndPositionalUnchanged(): Void {
		final v: HxVarDecl = parseSingleVarDecl('class Foo { var f:(Int, name:String) -> Bool; }');
		final fn: HxArrowFnType = expectArrowFnType(v.type);
		Assert.equals(2, fn.args.length);
		Assert.equals('Int', (expectNamedType(expectPositionalParam(fn.args[0])).name: String));
		Assert.equals('name', (expectNamedParam(fn.args[1]).name: String));
	}

	public function testCurriedOptionalArgUnchanged(): Void {
		// GUARD: the Haxe-3 curried `Int->?Int->Void` never reaches
		// `HxArrowParam` at all.
		roundTrip('class Foo { var f:Int->?Int->Void; }', 'curried optional');
		final v: HxVarDecl = parseSingleVarDecl('class Foo { var f:Int->?Int->Void; }');
		switch v.type {
			case Arrow(_, OptionalArg(_)):
				Assert.pass();
			case null, _:
				Assert.fail('expected Arrow(_, OptionalArg), got ${v.type}');
		}
	}

	public function testWriterEmitsTightQuestionMarkAndColon(): Void {
		writerEquals(
			'class Foo {\n\tvar f:(?b:Int)->Void;\n}', 'class Foo {\n\tvar f:(?b:Int) -> Void;\n}\n', 'tight source spaces arrow only'
		);
	}

	public function testLongArrowTypeSignatureWraps(): Void {
		final src: String = 'class D {\n\tvar handler:(firstArgument:String, ?secondArgument:Int, ?thirdArgument:Float, ?fourthArgument:Bool, ?fifthArg:String) -> Void;\n}';
		final expected: String = 'class D {\n\tvar handler:(firstArgument:String, ?secondArgument:Int, ?thirdArgument:Float, ?fourthArgument:Bool,\n\t\t\t?fifthArg:String) -> Void;\n}';
		Assert.equals(expected, triviaWrite(src));
	}

	public function testLongArrowTypeWithoutOptionalsWrapsUnchanged(): Void {
		// Control: the same five-param signature with no `?` markers. It
		// took an identical writer path before and after the slice, so a
		// change here would mean the slice moved arrow-type wrapping in
		// general rather than only for the new branch. (The last name is
		// two characters longer to keep the overflow point comparable
		// once the four `?` characters are gone.)
		final src: String = 'class D {\n\tvar handler:(firstArgument:String, secondArgument:Int, thirdArgument:Float, fourthArgument:Bool, fifthArgum:String) -> Void;\n}';
		final expected: String = 'class D {\n\tvar handler:(firstArgument:String, secondArgument:Int, thirdArgument:Float, fourthArgument:Bool,\n\t\t\tfifthArgum:String) -> Void;\n}';
		Assert.equals(expected, triviaWrite(src));
	}

	public function testRoundTripsAcrossEveryArrowParamForm(): Void {
		// `roundTrip` is idempotency only, so the three forms whose exact
		// bytes matter most get a `writerEquals` in the sibling test below
		// and this loop covers breadth.
		for (t in [
			'(?b:Int) -> Void',
			'(?Int) -> Void',
			'(b:Int) -> Void',
			'(Int) -> Void',
			'() -> Void',
			'(string:String, ?radix:Int) -> Float',
			'(Int, ?name:String, Bool) -> Void',
			'(?allocate:(size:Int) -> Buffer) -> Void',
			'(?opts:{?foo:Bool, ?bar:Int}) -> Void',
		]) {
			final source: String = 'class Foo { var f:$t; }';
			final module: HxModule = HaxeModuleParser.parse(source);
			Assert.equals(1, module.decls.length, t);
			roundTrip(source, t);
		}
	}

	public function testWriterBytesForTheCompoundForms(): Void {
		// Byte-exact companions to the breadth loop: the stdlib signature,
		// an anon struct in the optional slot, and a nested arrow type in
		// it. Idempotency would not notice a spacing regression in any of
		// the three.
		writerEquals(
			'class Foo { static var parseInt:(string:String, ?radix:Int)->Float; }',
			'class Foo {\n\tstatic var parseInt:(string:String, ?radix:Int) -> Float;\n}\n', 'stdlib parseInt'
		);
		writerEquals(
			'class Foo { var f:(?opts:{?foo:Bool, ?bar:Int})->Void; }', 'class Foo {\n\tvar f:(?opts:{?foo:Bool, ?bar:Int}) -> Void;\n}\n',
			'anon struct in optional slot'
		);
		writerEquals(
			'class Foo { var f:(?allocate:(size:Int)->Buffer)->Void; }',
			'class Foo {\n\tvar f:(?allocate:(size:Int) -> Buffer) -> Void;\n}\n', 'nested arrow in optional slot'
		);
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CFG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
