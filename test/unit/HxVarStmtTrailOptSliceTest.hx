package unit;

import utest.Assert;
import anyparse.grammar.haxe.HxStatement;

/**
 * Tests for slice ω-vardecl-trailOpt — flips `HxStatement.VarStmt` and
 * `HxStatement.FinalStmt` from `@:trail(';')` to `@:trailOpt(';')`. The
 * trailing semicolon becomes optional on parse so var/final declarations
 * with a `}`-terminated initializer (block, switch, if-with-else block,
 * try-with-block, …) drop their `;` the way real Haxe does — `}` already
 * terminates the statement.
 *
 * The leniency is broader than Haxe's spec (`var x = 5\nvar y = 6` is now
 * accepted even though Haxe rejects it), but the formatter only ever
 * emits canonical `;`, so the relaxed parse has no observable effect on
 * round-trip output. Member-level `HxClassMember.VarMember` /
 * `FinalMember` were since converged to the same `@:trailOpt(';')`
 * (Phase 3 Slice 13); member-level leniency lives in
 * `HxMemberVarTrailOptSliceTest`. This file stays statement-scope.
 *
 * Mirrors slice ω-typedef-trailOpt's test shape (`HxTypedefSemiSliceTest`)
 * and reuses the same `:trailOpt` Lit-strategy mechanism (no new macro
 * code path).
 */
class HxVarStmtTrailOptSliceTest extends HxTestHelpers {

	// ======== Block-terminated rhs (the corpus motivator) ========

	public function testVarSwitchRhsNoSemi(): Void {
		// `var foo = switch a { case _: 1; }` — no `;` after the closing
		// `}` of the switch initializer. Pre-slice: parse failure.
		final stmts: Array<HxStatement> = parseFunctionBody('var foo = switch a { case _: 1; }');
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case VarStmt(decl):
				Assert.equals('foo', (decl.name: String));
				Assert.notNull(decl.init);
			case _:
				Assert.fail('expected VarStmt, got ${stmts[0]}');
		}
	}

	public function testVarBlockRhsNoSemi(): Void {
		// `var foo = { 1; 2; }` — block-expression initializer, no `;`.
		final stmts: Array<HxStatement> = parseFunctionBody('var foo = { 1; 2; }');
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case VarStmt(decl):
				Assert.equals('foo', (decl.name: String));
			case _:
				Assert.fail('expected VarStmt, got ${stmts[0]}');
		}
	}

	public function testFinalSwitchRhsNoSemi(): Void {
		// `final` variant — same shape, parallel meta change.
		final stmts: Array<HxStatement> = parseFunctionBody('final foo = switch a { case _: 1; }');
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case FinalStmt(decl):
				Assert.equals('foo', (decl.name: String));
			case _:
				Assert.fail('expected FinalStmt, got ${stmts[0]}');
		}
	}

	public function testVarFollowedBySecondVarNoSemi(): Void {
		// Pre-S10.4: `var x = 5` (no `;`) followed by another statement was
		// accepted because the per-stmt `@:trailOpt(';')` was position-
		// agnostic. After S10.4 the BlockBody Star owns sep emission and
		// `;` between non-block-ended stmts is required — matches real
		// Haxe's strict rejection.
		Assert.raises(parseFunctionBody.bind('var x = 5\nvar y = 6;'));
	}

	public function testFinalFollowedBySecondFinalNoSemi(): Void {
		// Sister contract of `testVarFollowedBySecondVarNoSemi` — S10.5
		// migrated `FinalStmt` to BlockBody Star sep-ownership, so the
		// same strict-rejection contract applies to `final` declarations.
		Assert.raises(parseFunctionBody.bind('final x = 5\nfinal y = 6;'));
	}

	// ======== Trailing `;` still accepted (canonical input) ========

	public function testVarWithSemiStillParses(): Void {
		final stmts: Array<HxStatement> = parseFunctionBody('var foo = 5;');
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case VarStmt(decl):
				Assert.equals('foo', (decl.name: String));
			case _:
				Assert.fail('expected VarStmt');
		}
	}

	public function testVarSwitchRhsWithSemi(): Void {
		final stmts: Array<HxStatement> = parseFunctionBody('var foo = switch a { case _: 1; };');
		Assert.equals(1, stmts.length);
	}

	public function testFinalWithSemiStillParses(): Void {
		final stmts: Array<HxStatement> = parseFunctionBody('final foo = 5;');
		Assert.equals(1, stmts.length);
	}

	// ======== Round-trip — writer emits canonical `;` ========

	public function testRoundTripCanonicalisesMissingSemi(): Void {
		// Source has no `;` after the switch close; the writer always
		// emits `;`, so the second pass produces `;`-terminated form
		// and the third pass agrees. Idempotency holds.
		roundTrip('class C { static function m() { var foo = switch a { case _: 1; } } }');
		roundTrip('class C { static function m() { final foo = { 1; 2; } } }');
		roundTrip('class C { static function m() { var foo = switch a { case _: 1; }; } }');
	}

	// ======== Helpers ========

	private function parseFunctionBody(src: String): Array<HxStatement> {
		final wrapped: String = 'class C { static function m() { ${src} } }';
		return fnBodyStmts(parseSingleFnDecl(wrapped));
	}

}
