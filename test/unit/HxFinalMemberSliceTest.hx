package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxClassMember;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxInterfaceDecl;
import anyparse.grammar.haxe.HxMemberDecl;
import anyparse.grammar.haxe.HxMemberModifier;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.runtime.ParseError;

/**
 * Tests for the ω-final-member slice — class / interface / abstract
 * member-level `final NAME [: Type] [= init];` immutable field
 * declaration via `HxClassMember.FinalMember(HxVarDecl)`.
 *
 * Mirrors `HxStatement.FinalStmt` at the statement level: same
 * `HxVarDecl` body, same optional type and initializer, same `;`
 * trail. Dispatch reaches this branch because `HxMemberDecl.modifiers`
 * carries `Array<HxMemberModifier>` (no `Final`), so the modifier Star
 * yields when it sees `final` and `HxClassMember`'s `@:kw('final')`
 * commits.
 *
 * Unblocks haxe-formatter fork fixture
 * `issue_563_typed_interface_final` (the only fork fixture whose sole
 * blocker was member-level `final` parsing — others either use
 * statement-level final or typedef-anon final, both on independent
 * code paths).
 */
class HxFinalMemberSliceTest extends HxTestHelpers {

	public function new():Void {
		super();
	}

	// ======== FinalMember dispatch ========

	public function testFinalMemberWithTypeNoInit():Void {
		final ast:HxClassDecl = HaxeParser.parse('class A { final x:Int; }');
		Assert.equals(1, ast.members.length);
		final decl:HxVarDecl = expectFinalMember(ast.members[0].member);
		Assert.equals('x', (decl.name : String));
		Assert.equals('Int', (expectNamedType(decl.type).name : String));
		Assert.isNull(decl.init);
	}

	public function testFinalMemberWithInitNoType():Void {
		final ast:HxClassDecl = HaxeParser.parse('class A { final x = 1; }');
		final decl:HxVarDecl = expectFinalMember(ast.members[0].member);
		Assert.equals('x', (decl.name : String));
		Assert.isNull(decl.type);
		switch decl.init {
			case IntLit(v): Assert.equals(1, (v : Int));
			case null, _: Assert.fail('expected IntLit init');
		}
	}

	public function testFinalMemberWithTypeAndInit():Void {
		final ast:HxClassDecl = HaxeParser.parse('class A { final x:Int = 42; }');
		final decl:HxVarDecl = expectFinalMember(ast.members[0].member);
		Assert.equals('x', (decl.name : String));
		Assert.equals('Int', (expectNamedType(decl.type).name : String));
		switch decl.init {
			case IntLit(v): Assert.equals(42, (v : Int));
			case null, _: Assert.fail('expected IntLit init');
		}
	}

	public function testFinalMemberInInterface():Void {
		// issue_563_typed_interface_final fork fixture shape.
		final module:HxModule = HaxeModuleParser.parse('interface V { final v:Null<String>; }');
		Assert.equals(1, module.decls.length);
		final iface:HxInterfaceDecl = expectInterfaceDecl(module.decls[0]);
		Assert.equals(1, iface.members.length);
		final decl:HxVarDecl = expectFinalMember(iface.members[0].member);
		Assert.equals('v', (decl.name : String));
		Assert.equals('Null', (expectNamedType(decl.type).name : String));
	}

	public function testFinalMemberWithPublicModifier():Void {
		final ast:HxClassDecl = HaxeParser.parse('class A { public final x:Int = 1; }');
		final m:HxMemberDecl = ast.members[0];
		Assert.equals(1, m.modifiers.length);
		Assert.equals(Public, m.modifiers[0]);
		final decl:HxVarDecl = expectFinalMember(m.member);
		Assert.equals('x', (decl.name : String));
	}

	public function testFinalMemberWithStaticModifier():Void {
		final ast:HxClassDecl = HaxeParser.parse('class A { static final K:Int = 0; }');
		final m:HxMemberDecl = ast.members[0];
		Assert.equals(1, m.modifiers.length);
		Assert.equals(Static, m.modifiers[0]);
		final decl:HxVarDecl = expectFinalMember(m.member);
		Assert.equals('K', (decl.name : String));
	}

	public function testFinalMemberWithMultipleModifiers():Void {
		final ast:HxClassDecl = HaxeParser.parse('class A { public static final K:Int = 0; }');
		final m:HxMemberDecl = ast.members[0];
		Assert.equals(2, m.modifiers.length);
		Assert.equals(Public, m.modifiers[0]);
		Assert.equals(Static, m.modifiers[1]);
		final decl:HxVarDecl = expectFinalMember(m.member);
		Assert.equals('K', (decl.name : String));
	}

	public function testFinalMembersMixedWithVarAndFn():Void {
		final source:String = 'class A { var a:Int; final b:Int = 1; function f():Void {} final c = 2; }';
		final ast:HxClassDecl = HaxeParser.parse(source);
		Assert.equals(4, ast.members.length);
		switch ast.members[0].member {
			case VarMember(d): Assert.equals('a', (d.name : String));
			case _: Assert.fail('expected VarMember a');
		}
		switch ast.members[1].member {
			case FinalMember(d): Assert.equals('b', (d.name : String));
			case _: Assert.fail('expected FinalMember b');
		}
		switch ast.members[2].member {
			case FnMember(d): Assert.equals('f', (d.name : String));
			case _: Assert.fail('expected FnMember f');
		}
		switch ast.members[3].member {
			case FinalMember(d): Assert.equals('c', (d.name : String));
			case _: Assert.fail('expected FinalMember c');
		}
	}

	public function testFinalIdentifierPrefixNotConsumed():Void {
		// `finalists` must not match the `final` kw — word-boundary on
		// `expectKw` rejects `final` followed by an identifier-continuation
		// character. The dispatch falls to the next HxClassMember branch,
		// none of which match `finalists`, so parse fails (no member
		// keyword recognised). This is the same word-boundary guarantee
		// HxModifier provided previously.
		Assert.raises(() -> HaxeParser.parse('class A { finalists:Int; }'), ParseError);
	}

	public function testFinalMemberRejectsLegacyFinalVar():Void {
		// Negative regression — the legacy `final var x:Int;` form is no
		// longer accepted at the member position. `final` is consumed as
		// the FinalMember introducer; the body then expects an identifier
		// for the var name and fails on the `var` reserved keyword.
		Assert.raises(() -> HaxeParser.parse('class A { final var x:Int; }'), ParseError);
	}

	// ======== Round-trip ========

	public function testFinalMemberRoundTrip():Void {
		roundTrip('class A { final x:Int; }');
		roundTrip('class A { final x = 1; }');
		roundTrip('class A { final x:Int = 1; }');
		roundTrip('class A { public static final K:Int = 0; }');
		roundTrip('interface V { final v:Null<String>; }');
		roundTrip('class A { var a:Int; final b:Int = 1; final c = 2; }');
	}

	// ======== helpers ========

	private function expectFinalMember(member:HxClassMember):HxVarDecl {
		return switch member {
			case FinalMember(decl): decl;
			case _: throw 'expected FinalMember, got $member';
		};
	}
}
