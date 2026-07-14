package unit;

import utest.Assert;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxMemberDecl;
import anyparse.grammar.haxe.HxMemberModifier;
import anyparse.grammar.haxe.HaxeParser;

/**
 * Slice apq-P5 (macro-modifier + hex bundle) — the last clean
 * additive of the self-parse tail drill.
 *
 * Two independent additive grammar extensions, both zero core /
 * synth / writer ripple:
 *
 *  - `HxMemberModifier.Macro` (`@:kw('macro')`): the macro-function
 *    modifier (`public static macro function f()`), member-position
 *    only. Unblocks `Build.hx` self-parse. Asserted against the same
 *    `HxMemberDecl.modifiers` contract as `HxModifierSliceTest`.
 *  - `HxExpr.HexLit(v:HxHexLit)`: `@:re @:rawString` hex terminal
 *    (`0x20` / `0XFF`), source-verbatim like `RegexLit`. Unblocks
 *    `query/Text.hx` self-parse. Asserted via the same
 *    `parseSingleVarDecl` + `roundTrip` contract as
 *    `HxRegexLitSliceTest`, plus decimal/zero/float regression so the
 *    new leaf does not steal `IntLit`/`FloatLit` matches.
 */
class HxMacroModHexSliceTest extends HxTestHelpers {

	public function testLowercaseHex(): Void {
		Assert.equals('0x20', hexOf('class C { var x = 0x20; }'));
	}

	public function testUppercaseHexAndPrefix(): Void {
		// Both the `0X` prefix case and upper/lower hex digits round-trip
		// verbatim — decoding to Int would lose this distinction.
		Assert.equals('0XFF', hexOf('class C { var x = 0XFF; }'));
		Assert.equals('0xDeadBeef', hexOf('class C { var x = 0xDeadBeef; }'));
	}

	public function testDecimalStillIntLit(): Void {
		// `42` must NOT match the hex terminal — it has no `0x` prefix.
		final decl: HxVarDecl = parseSingleVarDecl('class C { var x = 42; }');
		switch decl.init {
			case IntLit(v):
				Assert.equals(42, (v: Int));
			case null, _:
				Assert.fail('expected IntLit(42), got ${decl.init}');
		}
	}

	public function testBareZeroStillIntLit(): Void {
		// `0` has no `x` after it; hex regex fails, rolls back to IntLit.
		final decl: HxVarDecl = parseSingleVarDecl('class C { var x = 0; }');
		switch decl.init {
			case IntLit(v):
				Assert.equals(0, (v: Int));
			case null, _:
				Assert.fail('expected IntLit(0), got ${decl.init}');
		}
	}

	public function testFloatStillFloatLit(): Void {
		// `0.5` starts with `0` but the hex regex needs `x`; float wins.
		final decl: HxVarDecl = parseSingleVarDecl('class C { var x = 0.5; }');
		switch decl.init {
			case FloatLit(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected FloatLit, got ${decl.init}');
		}
	}

	public function testHexRoundTrip(): Void {
		roundTrip('class C { var x = 0x20; var y = 0XFF; var z = 0xDeadBeef; }', 'P5-hex-lit');
	}

	public function testMacroModifierBare(): Void {
		final ast: HxClassDecl = HaxeParser.parse('class Foo { macro function f():Void {} }');
		final m: HxMemberDecl = ast.members[0];
		Assert.equals(1, m.modifiers.length);
		Assert.equals(Macro, m.modifiers[0]);
		switch m.member {
			case FnMember(decl):
				Assert.equals('f', (decl.name: String));
			case _:
				Assert.fail('expected FnMember');
		}
	}

	public function testMacroModifierBuildHxShape(): Void {
		// The exact `Build.hx` form that the dogfood self-parse needs.
		final ast: HxClassDecl = HaxeParser.parse('class Foo { public static macro function buildParser():Void {} }');
		final m: HxMemberDecl = ast.members[0];
		Assert.equals(3, m.modifiers.length);
		Assert.equals(Public, m.modifiers[0]);
		Assert.equals(Static, m.modifiers[1]);
		Assert.equals(Macro, m.modifiers[2]);
		switch m.member {
			case FnMember(decl):
				Assert.equals('buildParser', (decl.name: String));
			case _:
				Assert.fail('expected FnMember');
		}
	}

	private function hexOf(source: String): String {
		final decl: HxVarDecl = parseSingleVarDecl(source);
		return switch decl.init {
			case HexLit(v): (v: String);
			case null, _: throw 'expected HexLit, got ${decl.init}';
		}
	}

}
