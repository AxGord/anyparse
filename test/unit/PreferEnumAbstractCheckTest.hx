package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferEnumAbstract;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

using StringTools;

/**
 * The `prefer-enum-abstract` check: a class / abstract declaring three or more
 * `static final <PREFIX>_*` numeric constants that share a name prefix AND are
 * used interchangeably (two or more feeding one return / assignment sink) is
 * flagged `Info` — a suggestion to group them into an `enum abstract`. A domain
 * namespace of independent knobs (shared prefix, no shared sink), an existing enum
 * abstract, a mutable `static var`, an instance field, a non-numeric constant, a
 * sub-threshold group and a prefix-less name are all left alone. Report-only.
 */
class PreferEnumAbstractCheckTest extends Test {

	public function testCandidateFlagged(): Void {
		// RANK_A and RANK_B are returned as the two branches of one ternary — the
		// interchangeable-use signal that marks the group an enumeration.
		final vs: Array<Violation> = violations(
			'class C { static inline final RANK_A:Int = 0; static final RANK_B = 1; static final RANK_C = 2; static function r(x:Int):Int { return x == 0 ? RANK_A : RANK_B; } }'
		);
		Assert.equals(1, vs.length);
		Assert.equals('prefer-enum-abstract', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.contains("'RANK_*'"));
		Assert.isTrue(vs[0].message.contains('3'));
	}

	public function testBelowThresholdNotFlagged(): Void {
		// Two constants are not yet a set (MIN_GROUP is 3).
		Assert.equals(0, violations('class C { static final KIND_X = 0; static final KIND_Y = 1; }').length);
	}

	public function testNoSharedPrefixNotFlagged(): Void {
		Assert.equals(0, violations('class C { static final ALPHA = 0; static final BETA = 1; static final GAMMA = 2; }').length);
	}

	public function testInstanceFieldNotFlagged(): Void {
		// Non-static final fields are instance state, not constants.
		Assert.equals(0, violations('class C { final RANK_A = 0; final RANK_B = 1; final RANK_C = 2; }').length);
	}

	public function testMutableVarNotFlagged(): Void {
		Assert.equals(0, violations('class C { static var RANK_A = 0; static var RANK_B = 1; static var RANK_C = 2; }').length);
	}

	public function testEnumAbstractSkipped(): Void {
		// An existing enum abstract already IS the target form.
		Assert.equals(0, violations('enum abstract R(Int) { final RANK_A = 0; final RANK_B = 1; final RANK_C = 2; }').length);
	}

	public function testNonNumericNotFlagged(): Void {
		Assert.equals(0, violations('class C { static final MSG_A = "a"; static final MSG_B = "b"; static final MSG_C = "c"; }').length);
	}

	public function testTwoPrefixGroupsBothFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class C { static final RANK_A = 0; static final RANK_B = 1; static final RANK_C = 2; static final KIND_A = 0; static final KIND_B = 1; static final KIND_C = 2; static function r(x:Int):Int { return x == 0 ? RANK_A : RANK_B; } static function k(x:Int):Int { return x == 0 ? KIND_A : KIND_B; } }'
		);
		Assert.equals(2, vs.length);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C { static final RANK_A = 0; static final RANK_B = 1; static final RANK_C = 2; static function r(x:Int):Int { return x == 0 ? RANK_A : RANK_B; } }';
		final check: PreferEnumAbstract = new PreferEnumAbstract();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { static final RANK_A = ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-enum-abstract'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-enum-abstract'));
	}

	private function violations(src: String): Array<Violation> {
		return new PreferEnumAbstract().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	public function testNegativeLiteralConstantCounted(): Void {
		// A `-1` sentinel parses as `Neg(IntLit)`; it must still count toward the group,
		// else a negative sentinel (`RANK_UNKNOWN = -1`) drops the set below the threshold.
		Assert.equals(
			1,
			violations(
				'class C { static final RANK_UNKNOWN = -1; static final RANK_LOW = 0; static final RANK_HIGH = 1; static function r(x:Int):Int { return x < 0 ? RANK_UNKNOWN : RANK_LOW; } }'
			).length
		);
	}

	public function testNamespaceNotFlagged(): Void {
		// A domain namespace of independent tuning knobs shares a prefix but each is
		// only ever a comparison operand — never a shared result value — so the
		// interchangeability gate leaves it alone.
		Assert.equals(
			0,
			violations(
				'class C { static final CFG_MIN = 3; static final CFG_MAX = 9; static final CFG_STEP = 2; static function f(a:Int, b:Int):Bool { return a >= CFG_MIN && b <= CFG_MAX && a % CFG_STEP == 0; } }'
			).length
		);
	}

	public function testInterchangeableViaAssignment(): Void {
		// MODE_A and MODE_B are assigned to one variable on alternate branches — a
		// shared assignment sink, so the group reads as an enumeration.
		Assert.equals(
			1,
			violations(
				'class C { static final MODE_A = 0; static final MODE_B = 1; static final MODE_C = 2; static function pick(x:Int):Int { var m:Int = 0; if (x > 0) m = MODE_A; else m = MODE_B; return m; } }'
			).length
		);
	}

}
