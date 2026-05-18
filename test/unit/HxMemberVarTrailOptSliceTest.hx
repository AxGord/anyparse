package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxClassMember;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Tests for Phase 3 Slice 13 — flips `HxClassMember.VarMember` and
 * `FinalMember` from mandatory `@:trail(';')` to
 * `@:trailOpt(';') @:fmt(trailOptShapeGate('endsWithCloseBrace', 'init'))`,
 * the byte twin of `HxStatement.VarStmt` / `FinalStmt`.
 *
 * A class field initializer that ends in `}` (`= function() { … }`,
 * `= switch (e) { … }`, recursive `= try { … } catch …`) may now omit
 * its terminating `;`, the way real Haxe does — the `}` already
 * terminates the member.
 *
 * The `trailOptShapeGate('endsWithCloseBrace', 'init')` is a WRITER
 * gate, not a parser gate: parser-side `@:trailOpt(';')` makes the
 * terminator unconditionally optional and position-agnostic, exactly
 * like statement-level `HxStatement.VarStmt` (see
 * `HxVarStmtTrailOptSliceTest.testVarFollowedBySecondVarNoSemi`). So a
 * NON-brace member init with no `;` (`class Foo { var x:Int = 42 }`)
 * now parses too — broader than Haxe's spec. This is harmless: the
 * writer always re-emits canonical `;` (plain mode falls back to
 * `_dt(';')` whenever the shape gate is false), so round-trip output
 * is unaffected. Member-level rules are now CONVERGENT with
 * statement-level.
 */
class HxMemberVarTrailOptSliceTest extends HxTestHelpers {

	// ======== Brace-terminated initializer, no `;` (the motivator) ========

	public function testMemberVarFnExprRhsNoSemi():Void {
		// `var a = function() { 1; }` with no `;`, followed by a sibling
		// member. Pre-slice: parse failure (member `@:trail(';')`).
		final members:Array<HxClassMember> = parseMembers('class Foo { var a = function() { 1; } var b = 2; }');
		Assert.equals(2, members.length);
		final decl:HxVarDecl = expectVarMember(members[0]);
		Assert.equals('a', (decl.name : String));
		Assert.notNull(decl.init);
	}

	public function testMemberVarSwitchRhsNoSemi():Void {
		final members:Array<HxClassMember> = parseMembers('class Foo { var a = switch x { case _: 1; } }');
		Assert.equals(1, members.length);
		final decl:HxVarDecl = expectVarMember(members[0]);
		Assert.equals('a', (decl.name : String));
	}

	public function testMemberFinalFnExprRhsNoSemi():Void {
		final members:Array<HxClassMember> = parseMembers('class Foo { final a = function() { 1; } }');
		Assert.equals(1, members.length);
		final decl:HxVarDecl = expectFinalMember(members[0]);
		Assert.equals('a', (decl.name : String));
	}

	// ======== Trailing `;` still accepted (canonical input) ========

	public function testMemberVarFnExprRhsWithSemi():Void {
		final members:Array<HxClassMember> = parseMembers('class Foo { var a = function() { 1; }; }');
		Assert.equals(1, members.length);
		Assert.equals('a', (expectVarMember(members[0]).name : String));
	}

	public function testMemberVarPlainStillParses():Void {
		final members:Array<HxClassMember> = parseMembers('class Foo { var a = 5; }');
		Assert.equals(1, members.length);
		Assert.equals('a', (expectVarMember(members[0]).name : String));
	}

	// ======== Non-brace init, no `;` — now lenient (parser-side) ========

	public function testMemberVarPlainNoSemiAccepted():Void {
		// `init` is `42` (IntLit). Haxe rejects a missing `;` here, but
		// parser-side `@:trailOpt` is position-agnostic so we accept it
		// (the shape gate is WRITER-only). Documenting the leniency so a
		// future strict-mode slice doesn't silently change the contract.
		// The writer still re-emits canonical `;`, so round-trip is safe
		// (see testRoundTripNonBraceInitCanonicalisesMissingSemi).
		final members:Array<HxClassMember> = parseMembers('class Foo { var x:Int = 42 }');
		Assert.equals(1, members.length);
		Assert.equals('x', (expectVarMember(members[0]).name : String));
	}

	public function testMemberFinalPlainNoSemiAccepted():Void {
		final members:Array<HxClassMember> = parseMembers('class Foo { final x:Int = 42 }');
		Assert.equals(1, members.length);
		Assert.equals('x', (expectFinalMember(members[0]).name : String));
	}

	public function testRoundTripNonBraceInitCanonicalisesMissingSemi():Void {
		// Lenient parse, canonical re-emit: writer always adds `;`.
		roundTrip('class Foo { var x:Int = 42 }');
		roundTrip('class Foo { final x:Int = 42 }');
	}

	// ======== Round-trip — writer emits canonical `;` ========

	public function testRoundTripCanonicalisesMissingSemi():Void {
		roundTrip('class C { var foo = switch a { case _: 1; } }');
		roundTrip('class C { final bar = function() { 1; } }');
		roundTrip('class C { var foo = switch a { case _: 1; }; }');
	}

	// ======== Helpers ========

	private function parseMembers(source:String):Array<HxClassMember> {
		final ast:HxClassDecl = HaxeParser.parse(source);
		return [for (m in ast.members) m.member];
	}

	private function expectFinalMember(member:HxClassMember):HxVarDecl {
		return switch member {
			case FinalMember(decl): decl;
			case _: throw 'expected FinalMember, got $member';
		};
	}

}
