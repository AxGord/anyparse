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
			'class C { static inline final RANK_A:Int = 0; static final RANK_B = 1; static final RANK_C = 2; static function '
			+ 'r(x:Int):Int { return x == 0 ? RANK_A : RANK_B; } }'
		);
		Assert.equals(1, vs.length);
		assertAdvisory(vs[0]);
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
			'class C { static final RANK_A = 0; static final RANK_B = 1; static final RANK_C = 2; static final KIND_A = 0; static final '
			+ 'KIND_B = 1; static final KIND_C = 2; static function r(x:Int):Int { return x == 0 ? RANK_A : RANK_B; } '
			+ 'static function k(x:Int):Int { return x == 0 ? KIND_A : KIND_B; } }'
		);
		Assert.equals(2, vs.length);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C { static final RANK_A = 0; static final RANK_B = 1; static final RANK_C = 2; static function '
			+ 'r(x:Int):Int { return x == 0 ? RANK_A : RANK_B; } }';
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

	public function testNegativeLiteralConstantCounted(): Void {
		// A `-1` sentinel parses as `Neg(IntLit)`; it must still count toward the group,
		// else a negative sentinel (`RANK_UNKNOWN = -1`) drops the set below the threshold.
		Assert.equals(
			1,
			violations(
				'class C { static final RANK_UNKNOWN = -1; static final RANK_LOW = 0; static final RANK_HIGH = 1; static function '
				+ 'r(x:Int):Int { return x < 0 ? RANK_UNKNOWN : RANK_LOW; } }'
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
				'class C { static final CFG_MIN = 3; static final CFG_MAX = 9; static final CFG_STEP = 2; static function f(a:Int, '
				+ 'b:Int):Bool { return a >= CFG_MIN && b <= CFG_MAX && a % CFG_STEP == 0; } }'
			).length
		);
	}

	public function testInterchangeableViaAssignment(): Void {
		// MODE_A and MODE_B are assigned to one variable on alternate branches — a
		// shared assignment sink, so the group reads as an enumeration.
		Assert.equals(
			1,
			violations(
				'class C { static final MODE_A = 0; static final MODE_B = 1; static final MODE_C = 2; static function pick(x:Int):Int {'
				+ ' var m:Int = 0; if (x > 0) m = MODE_A; else m = MODE_B; return m; } }'
			).length
		);
	}

	public function testWholeTypeStringConstantsFlagged(): Void {
		// A type declaring NOTHING but same-typed distinct `static inline final` constants
		// IS the enumeration — no in-file use is needed as evidence, and the alignment-style
		// constants that motivate this arm are read only from other files.
		final vs: Array<Violation> = violations(
			'class Align { public static inline final CENTER:String = \'center\'; public static inline final LEFT:String = \'left\'; '
			+ 'public static inline final RIGHT:String = \'right\'; }'
		);
		Assert.equals(1, vs.length);
		assertAdvisory(vs[0]);
		Assert.isTrue(vs[0].message.contains('String'));
		Assert.isTrue(vs[0].message.contains('3'));
	}

	public function testWholeTypeIntConstantsFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class Level { public static inline final LOW:Int = 0; public static inline final MID:Int = 1; public static inline '
				+ 'final HIGH:Int = 2; }'
			).length
		);
	}

	public function testWholeTypeWithMethodNotFlagged(): Void {
		// A method makes the type more than a constant namespace — an enum abstract would
		// have to carry it, which is a judgement the check does not make.
		Assert.equals(
			0,
			violations(
				'class Align { public static inline final CENTER:String = \'center\'; public static inline final LEFT:String = \'left\'; '
				+ 'public static inline final RIGHT:String = \'right\'; public static function all():Int { return 3; } }'
			).length
		);
	}

	public function testWholeTypeWithConstructorNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class Align { public static inline final CENTER:String = \'center\'; public static inline final LEFT:String = \'left\'; '
				+ 'public static inline final RIGHT:String = \'right\'; public function new() {} }'
			).length
		);
	}

	public function testWholeTypeWithInheritanceNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class Align extends Base { public static inline final CENTER:String = \'center\'; public static inline final '
				+ 'LEFT:String = \'left\'; public static inline final RIGHT:String = \'right\'; }'
			).length
		);
	}

	public function testWholeTypeMixedPrimitivesNotFlagged(): Void {
		// Two primitive types are two concepts — no single underlying type to pick.
		Assert.equals(
			0,
			violations(
				'class Mix { public static inline final A:String = \'a\'; public static inline final B:Int = 1; public static inline '
				+ 'final C:String = \'c\'; }'
			).length
		);
	}

	public function testWholeTypeDuplicateValuesNotFlagged(): Void {
		// Two names on one value are aliases, not distinct enumeration members.
		Assert.equals(
			0,
			violations(
				'class Dup { public static inline final A:String = \'x\'; public static inline final B:String = \'x\'; public static '
				+ 'inline final C:String = \'y\'; }'
			).length
		);
	}

	public function testWholeTypeNonInlineNotFlagged(): Void {
		// Without `inline` the members are storage, not compile-time substituted values.
		Assert.equals(
			0,
			violations(
				'class Align { public static final CENTER:String = \'center\'; public static final LEFT:String = \'left\'; public static '
				+ 'final RIGHT:String = \'right\'; }'
			).length
		);
	}

	public function testWholeTypeNonLiteralValueNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class Align { public static inline final CENTER:String = \'center\'; public static inline final LEFT:String = \'left\'; '
				+ 'public static inline final BOTH:String = CENTER + LEFT; }'
			).length
		);
	}

	public function testWholeTypeMutableMemberNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class Align { public static inline final CENTER:String = \'center\'; public static inline final LEFT:String = \'left\'; '
				+ 'public static inline final RIGHT:String = \'right\'; static var current:String = \'center\'; }'
			).length
		);
	}

	public function testWholeTypeInstanceMemberNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class Align { public static inline final CENTER:String = \'center\'; public static inline final LEFT:String = \'left\'; '
				+ 'public static inline final RIGHT:String = \'right\'; final own:String = \'x\'; }'
			).length
		);
	}

	public function testWholeTypeBelowThresholdNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class Pair { public static inline final A:String = \'a\'; public static inline final B:String = \'b\'; }').length
		);
	}

	public function testWholeTypeAbstractUnderlyingNotFlagged(): Void {
		// An `abstract A(Int)` already carries an underlying type; converting it is a
		// different edit, and its underlying-type node is not a constant member.
		Assert.equals(
			0,
			violations(
				'abstract A(Int) {'
				+ ' public static inline final X:Int = 1; public static inline final Y:Int = 2; public static inline final Z:Int = 3; }'
			).length
		);
	}

	public function testWholeTypeMetadataOnMemberStillFlagged(): Void {
		// Metadata annotates a member without adding behaviour to the type.
		Assert.equals(
			1,
			violations(
				'class Align { @:keep public static inline final CENTER:String = \'center\'; public static inline final LEFT:String = '
				+ '\'left\'; public static inline final RIGHT:String = \'right\'; }'
			).length
		);
	}

	public function testWholeTypeConditionalMemberNotFlagged(): Void {
		// A `#if`-guarded member projects as a `Conditional` node, which is not a modifier,
		// a metadata annotation or a constant — so the whitelist refuses the container. An
		// enum abstract whose member set depends on a build flag is a different edit.
		Assert.equals(
			0,
			violations(
				'class Guarded { public static inline final A:String = \'a\'; public static inline final B:String = \'b\';\n#if debug\n'
				+ 'public static inline final C:String = \'c\';\n#end\n }'
			).length
		);
	}

	public function testWholeTypeReportedOnceWhenPrefixArmAlsoMatches(): Void {
		// The whole-type arm subsumes the prefix arm for the same container: one finding,
		// not two, when the constants also share a prefix and feed one sink elsewhere.
		final vs: Array<Violation> = violations(
			'class E { public static inline final RANK_A:Int = 0; public static inline final RANK_B:Int = 1; public static inline final '
			+ 'RANK_C:Int = 2; }\nclass U { static function r(x:Int):Int { return x == 0 ? RANK_A : RANK_B; } }'
		);
		Assert.equals(1, vs.length);
	}

	/** Every finding of this check is a report-only `prefer-enum-abstract` advisory. */
	private function assertAdvisory(v: Violation): Void {
		Assert.equals('prefer-enum-abstract', v.rule);
		Assert.equals(Severity.Info, v.severity);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferEnumAbstract().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
