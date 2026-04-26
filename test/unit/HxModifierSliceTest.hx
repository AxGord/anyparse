package unit;

import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxMemberDecl;
import anyparse.grammar.haxe.HxMemberModifier;
import anyparse.grammar.haxe.HxClassMember;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.runtime.ParseError;
import utest.Assert;

/**
 * Tests for the modifier slice (slice ε): access and storage modifiers
 * (`public`, `private`, `static`, `inline`, `override`, `dynamic`,
 * `extern`) parsed as a `Star<HxMemberModifier>` field on the
 * `HxMemberDecl` wrapper typedef, using the try-parse termination mode
 * in `emitStarFieldSteps`.
 *
 * Member-level `final` is NOT a modifier — it routes through
 * `HxClassMember.FinalMember` (immutable field declaration).
 * `HxFinalMemberSliceTest` covers the FinalMember dispatch path; this
 * file just guards the rejection of the legacy `final var x:Int;` form
 * to confirm the modifier Star no longer eats `final`.
 */
class HxModifierSliceTest extends HxTestHelpers {

	public function new() {
		super();
	}

	public function testNoModifiers():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var x:Int; }');
		Assert.equals(1, ast.members.length);
		final m:HxMemberDecl = ast.members[0];
		Assert.equals(0, m.modifiers.length);
		switch m.member {
			case VarMember(decl): Assert.equals('x', (decl.name : String));
			case _: Assert.fail('expected VarMember');
		}
	}

	public function testSingleModifierPublic():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { public var x:Int; }');
		final m:HxMemberDecl = ast.members[0];
		Assert.equals(1, m.modifiers.length);
		Assert.equals(Public, m.modifiers[0]);
	}

	public function testSingleModifierPrivate():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { private var x:Int; }');
		final m:HxMemberDecl = ast.members[0];
		Assert.equals(1, m.modifiers.length);
		Assert.equals(Private, m.modifiers[0]);
	}

	public function testSingleModifierStatic():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { static var x:Int; }');
		final m:HxMemberDecl = ast.members[0];
		Assert.equals(1, m.modifiers.length);
		Assert.equals(Static, m.modifiers[0]);
	}

	public function testSingleModifierInline():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { inline function f():Void {} }');
		final m:HxMemberDecl = ast.members[0];
		Assert.equals(1, m.modifiers.length);
		Assert.equals(Inline, m.modifiers[0]);
	}

	public function testSingleModifierOverride():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { override function f():Void {} }');
		final m:HxMemberDecl = ast.members[0];
		Assert.equals(1, m.modifiers.length);
		Assert.equals(Override, m.modifiers[0]);
	}

	public function testLegacyFinalVarRejected():Void {
		// `final var x:Int;` was the legacy member form; HxMemberModifier
		// no longer lists Final, so the modifier Star yields and
		// HxClassMember.FinalMember consumes `final` then expects an
		// identifier (gets `var` keyword) — parse error. Modern
		// `final x:Int;` is the supported form (see HxFinalMemberSliceTest).
		Assert.raises(() -> HaxeParser.parse('class Foo { final var x:Int; }'), ParseError);
	}

	public function testSingleModifierDynamic():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { dynamic function f():Void {} }');
		final m:HxMemberDecl = ast.members[0];
		Assert.equals(1, m.modifiers.length);
		Assert.equals(Dynamic, m.modifiers[0]);
	}

	public function testSingleModifierExtern():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { extern var x:Int; }');
		final m:HxMemberDecl = ast.members[0];
		Assert.equals(1, m.modifiers.length);
		Assert.equals(Extern, m.modifiers[0]);
	}

	public function testTwoModifiers():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { public static var x:Int; }');
		final m:HxMemberDecl = ast.members[0];
		Assert.equals(2, m.modifiers.length);
		Assert.equals(Public, m.modifiers[0]);
		Assert.equals(Static, m.modifiers[1]);
	}

	public function testThreeModifiers():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { public static inline function f():Void {} }');
		final m:HxMemberDecl = ast.members[0];
		Assert.equals(3, m.modifiers.length);
		Assert.equals(Public, m.modifiers[0]);
		Assert.equals(Static, m.modifiers[1]);
		Assert.equals(Inline, m.modifiers[2]);
	}

	public function testReversedOrder():Void {
		// Order-independent: static public is valid Haxe
		final ast:HxClassDecl = HaxeParser.parse('class Foo { static public var x:Int; }');
		final m:HxMemberDecl = ast.members[0];
		Assert.equals(2, m.modifiers.length);
		Assert.equals(Static, m.modifiers[0]);
		Assert.equals(Public, m.modifiers[1]);
	}

	public function testModifierBeforeFunction():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { override public function bar():Void {} }');
		final m:HxMemberDecl = ast.members[0];
		Assert.equals(2, m.modifiers.length);
		Assert.equals(Override, m.modifiers[0]);
		Assert.equals(Public, m.modifiers[1]);
		switch m.member {
			case FnMember(decl): Assert.equals('bar', (decl.name : String));
			case _: Assert.fail('expected FnMember');
		}
	}

	public function testWordBoundaryPublicly():Void {
		// `publicly` should not match as `public` + `ly` — the word-
		// boundary check on `expectKw` prevents partial match, so the
		// modifier loop breaks and `publicly` is tried as the member
		// keyword, which also fails.
		Assert.raises(() -> HaxeParser.parse('class Foo { publicly var x:Int; }'), ParseError);
	}

	public function testWordBoundaryStatically():Void {
		Assert.raises(() -> HaxeParser.parse('class Foo { statically var x:Int; }'), ParseError);
	}

	public function testDuplicateModifiersAllowed():Void {
		// Semantic validation is not the parser's job — duplicate
		// modifiers are syntactically valid.
		final ast:HxClassDecl = HaxeParser.parse('class Foo { public public var x:Int; }');
		final m:HxMemberDecl = ast.members[0];
		Assert.equals(2, m.modifiers.length);
		Assert.equals(Public, m.modifiers[0]);
		Assert.equals(Public, m.modifiers[1]);
	}

	public function testMixedMembersWithAndWithoutModifiers():Void {
		final source:String = 'class Foo { public var x:Int; function f():Void {} private static var y:Bool; }';
		final ast:HxClassDecl = HaxeParser.parse(source);
		Assert.equals(3, ast.members.length);

		Assert.equals(1, ast.members[0].modifiers.length);
		Assert.equals(Public, ast.members[0].modifiers[0]);

		Assert.equals(0, ast.members[1].modifiers.length);

		Assert.equals(2, ast.members[2].modifiers.length);
		Assert.equals(Private, ast.members[2].modifiers[0]);
		Assert.equals(Static, ast.members[2].modifiers[1]);
	}

	public function testModifiersThroughModuleRoot():Void {
		final source:String = 'class A { public var x:Int; } class B { override function f():Void {} }';
		final module:HxModule = HaxeModuleParser.parse(source);
		Assert.equals(2, module.decls.length);

		final a:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals(1, a.members[0].modifiers.length);
		Assert.equals(Public, a.members[0].modifiers[0]);

		final b:HxClassDecl = expectClassDecl(module.decls[1]);
		Assert.equals(1, b.members[0].modifiers.length);
		Assert.equals(Override, b.members[0].modifiers[0]);
	}

	public function testWhitespaceBetweenModifiers():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { public\t\nstatic   var x:Int; }');
		final m:HxMemberDecl = ast.members[0];
		Assert.equals(2, m.modifiers.length);
		Assert.equals(Public, m.modifiers[0]);
		Assert.equals(Static, m.modifiers[1]);
	}

}
