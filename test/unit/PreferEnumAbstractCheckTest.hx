package unit;

import anyparse.check.Check.GroupedEdit;
import anyparse.check.Check.RiskyFix;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferEnumAbstract;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

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

	/** The three-constant `Align` fixture every whole-type FIX test starts from. */
	private static inline final THREE_STRING_CONSTANTS: String = 'class Align { public static inline final A:String = \'a\'; public '
		+ 'static inline final B:String = \'b\'; public static inline final C:String = \'c\'; }';

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

	public function testWholeTypeStringFixEmitsEnumAbstract(): Void {
		// The motivating conversion, pinned verbatim: the class head becomes an `enum abstract`
		// over the constants' own primitive with a `to` clause, and each member loses the
		// modifiers and the type annotation that an enum-abstract value may not carry.
		final src: String = 'class HorizontalAlignment {\n\tpublic static inline final CENTER:String = \'center\';\n\tpublic static '
			+ 'inline final LEFT:String = \'left\';\n\tpublic static inline final NONE:String = \'none\';\n\tpublic static inline '
			+ 'final RIGHT:String = \'right\';\n\tpublic static inline final STRETCH:String = \'stretch\';\n}';
		Assert.equals(
			'enum abstract HorizontalAlignment(String) to String {\n\tfinal CENTER = \'center\';\n\tfinal LEFT = \'left\';\n\t'
			+ 'final NONE = \'none\';\n\tfinal RIGHT = \'right\';\n\tfinal STRETCH = \'stretch\';\n}',
			fixedSource(src)
		);
	}

	public function testWholeTypeIntFixEmitsToIntClause(): Void {
		// The Int arm takes the same shape: `to Int` is what keeps `keyCode == Codes.LEFT`
		// compiling against an Int-typed field.
		Assert.equals(
			'enum abstract Codes(Int) to Int {\n\tfinal LEFT = 37;\n\tfinal UP = 38;\n\tfinal RIGHT = 39;\n}',
			fixedSource(
				'class Codes {\n\tpublic static inline final LEFT:Int = 37;\n\tpublic static inline final UP:Int = 38;\n\tpublic '
				+ 'static inline final RIGHT:Int = 39;\n}'
			)
		);
	}

	public function testFixKeepsDocsMetadataAndOrder(): Void {
		// The edits are the head replacement plus two deletions per member and nothing else, so a
		// doc comment, a per-member annotation, a line comment and the blank lines between
		// members all survive verbatim, in source order.
		final src: String = 'class Kind {\n\t/** first. */\n\tpublic static inline final B:String = \'b\';\n\n\t// second\n\t'
			+ '@:deprecated public static inline final A:String = \'a\';\n\tpublic static inline final C:String = \'c\';\n}';
		Assert.equals(
			'enum abstract Kind(String) to String {\n\t/** first. */\n\tfinal B = \'b\';\n\n\t// second\n\t@:deprecated final A = '
			+ '\'a\';\n\tfinal C = \'c\';\n}',
			fixedSource(src)
		);
	}

	public function testFixHandlesMemberWithoutAnnotation(): Void {
		// No `:T` annotation means no annotation edit — the member is already in the target shape
		// once its modifiers go.
		Assert.equals(
			'enum abstract Kind(String) to String { final A = \'a\'; final B = \'b\'; final C = \'c\'; }',
			fixedSource(
				'class Kind { public static inline final A = \'a\'; public static inline final B = \'b\'; public static '
				+ 'inline final C = \'c\'; }'
			)
		);
	}

	public function testFixRefusesAnnotatedContainer(): Void {
		// `@:keep` / `@:rtti` / `@:build` attach behaviour to a CLASS declaration; whether it
		// survives the change of declaration kind is not knowable from the annotation's name, and
		// the reflection cases are the one hazard the compiler oracle cannot see. Still REPORTED.
		final src: String = '@:keep class Align { public static inline final A:String = \'a\'; public static inline final B:String = '
			+ '\'b\'; public static inline final C:String = \'c\'; }';
		Assert.equals(1, violations(src).length);
		Assert.equals(src, fixedSource(src));
	}

	public function testFixRefusesTypeParameters(): Void {
		// `class Generic<T>` and `class Plain` have identical subtrees — the parameter list is
		// textual only — so the head gate is what refuses it, and the template never silently
		// drops a `<T>`.
		final src: String = 'class Generic<T> { public static inline final A:String = \'a\'; public static inline final B:String = '
			+ '\'b\'; public static inline final C:String = \'c\'; }';
		Assert.equals(1, violations(src).length);
		Assert.equals(src, fixedSource(src));
	}

	public function testFixRefusesReflectionNamedType(): Void {
		// A converted type stops existing as a runtime class, so a `Type.resolveClass('Align')`
		// anywhere in scope keeps compiling and starts answering null — the one silent breakage,
		// and the reason the fix does not lean on the oracle alone.
		Assert.equals(0, alignFixEdits('class Use { static function f() { return Type.resolveClass(\'Align\'); } }', false));
	}

	public function testFixConvertsWhenTheStringNamesSomethingElse(): Void {
		// The discriminating half of the pair above: same two files, same reflection call, a
		// different name inside the literal — and the conversion goes through.
		Assert.equals(7, alignFixEdits('class Use { static function f() { return Type.resolveClass(\'Other\'); } }', false));
	}

	public function testFixRefusesInterpolatedReflectionNamedType(): Void {
		// The reflection key may be COMPUTED, and `literalOf` answers null for an interpolated
		// literal — so a scan over plain literals alone reads this call as naming nothing and the
		// conversion goes through, leaving `Type.resolveClass` to answer null at runtime.
		Assert.equals(0, alignFixEdits('class Use { static function f(p:String) { return Type.resolveClass(\'$${p}Align\'); } }', false));
	}

	public function testFixConvertsWhenTheInterpolationNamesSomethingElse(): Void {
		// The discriminating half: same interpolated call, a fragment no candidate name contains.
		Assert.equals(7, alignFixEdits('class Use { static function f(p:String) { return Type.resolveClass(\'$${p}Other\'); } }', false));
	}

	public function testFixRefusesQualifiedReflectionNamedType(): Void {
		// The runtime lookup takes a FULLY-QUALIFIED path, so the literal that reaches `Align` at
		// run time is `pkg.Align` and never the bare name — a whole-literal gate comparing against
		// the simple name reads this call as naming nothing and converts the type out from under it.
		Assert.equals(0, alignFixEdits('class Use { static function f() { return Type.resolveClass(\'pkg.Align\'); } }', false));
	}

	public function testFixRefusesDeeplyQualifiedReflectionNamedType(): Void {
		// Same shape at depth, and through the enum entry point — the surface is every plain
		// literal in scope, so which reflection call spells it is not part of the question.
		Assert.equals(0, alignFixEdits('class Use { static function f() { return Type.resolveEnum(\'a.b.c.Align\'); } }', false));
	}

	public function testFixConvertsWhenTheQualifiedPathNamesSomethingElse(): Void {
		// The discriminating half: a qualified path whose last segment is a different type.
		Assert.equals(7, alignFixEdits('class Use { static function f() { return Type.resolveClass(\'pkg.Other\'); } }', false));
	}

	public function testFixConvertsWhenTheNameIsOnlyASubstringOfTheQualifiedPath(): Void {
		// The suffix test is a DOT-PATH test, not a substring one: `pkg.MisAlign` ends with the
		// candidate's name but not with `.Align`, so it names a different type and the conversion
		// goes through — otherwise every name that is a suffix of a sibling's would block.
		Assert.equals(7, alignFixEdits('class Use { static function f() { return Type.resolveClass(\'pkg.MisAlign\'); } }', false));
	}

	public function testFixRefusesQualifiedInterpolatedReflectionNamedType(): Void {
		// The computed half of the same blind spot: the static fragment of `'${p}.Align'` is
		// `.Align`, which the simple name does not contain — so the fragment test has to read the
		// fragment's last dot-segment, exactly as the whole-literal test reads the literal's.
		Assert.equals(0, alignFixEdits('class Use { static function f(p:String) { return Type.resolveClass(\'$${p}.Align\'); } }', false));
	}

	public function testFixConvertsWhenTheQualifiedInterpolationNamesSomethingElse(): Void {
		// The discriminating half, and it has to spell the candidate name to BE one: the surface is
		// narrowed to files whose raw text mentions a candidate, so a fixture naming only `Other`
		// never reaches the fragment test at all and would pass however the predicate answered.
		// `MisAlign` clears that pre-filter, and its last segment is not contained in `Align`.
		Assert.equals(
			7, alignFixEdits('class Use { static function f(p:String) { return Type.resolveClass(\'$${p}.MisAlign\'); } }', false)
		);
	}

	public function testFixWithoutRunYieldsNothing(): Void {
		// Fail-closed: the whole-scope refusals live in `run`, so a `fix` that skipped it must
		// not convert anything at all.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final vs: Array<Violation> = new PreferEnumAbstract().run([{ file: 'Align.hx', source: THREE_STRING_CONSTANTS }], plugin);
		Assert.equals(0, new PreferEnumAbstract().fix(THREE_STRING_CONSTANTS, vs, plugin).length);
	}

	public function testFixRefusesSubtypedContainer(): Void {
		// An abstract cannot host a subtype. The index knows; the oracle would too, as a compile
		// error, but refusing here saves the spawn and names the reason.
		Assert.equals(0, alignFixEdits('class Sub extends Align {}', true));
	}

	public function testFixIsRiskyAndSoLeftReportOnlyWithoutAnOracle(): Void {
		// The marker is the contract: two residual breakage shapes (an inferred local used as the
		// underlying type, an inferred collection) need real inference, so every conversion is
		// typechecked project-wide and reverted per file when a call site breaks.
		Assert.isTrue((new PreferEnumAbstract(): Dynamic) is RiskyFix);
	}

	public function testFixGroupsEveryEditOfOneConversion(): Void {
		// One conversion is one atomic unit for the verifier's bisect. Before this, a fixture whose
		// call site broke bisected down to a COMPILING subset that kept `public static inline final
		// A = 'a'` inside the `enum abstract` — a plain static field, no longer a value of the
		// enumeration, and indistinguishable from success to anything that only asks "does it build".
		final edits: Array<GroupedEdit> = groupedEdits(THREE_STRING_CONSTANTS);
		Assert.equals(7, edits.length);
		for (e in edits) Assert.equals(0, e.group);
	}

	public function testFixGroupsTwoContainersApart(): Void {
		// Two conversions in one file are INDEPENDENT: the verifier may keep one and drop the other.
		final decl: String = 'class A { public static inline final X:String = \'x\'; public static inline final Y:String = \'y\'; '
			+ 'public static inline final Z:String = \'z\'; }\nclass B { public static inline final P:Int = 1; public static inline '
			+ 'final Q:Int = 2; public static inline final R:Int = 3; }';
		final edits: Array<GroupedEdit> = groupedEdits(decl);
		final groups: Array<Null<Int>> = [];
		for (e in edits) if (!groups.contains(e.group)) groups.push(e.group);
		Assert.equals(2, groups.length);
	}

	public function testFixIsThePureProjectionOfFixGrouped(): Void {
		// The `GroupedFix` contract: the two views may disagree about how edits SPLIT, never about
		// which edits there are. Nothing else detects a divergence.
		final decl: String = THREE_STRING_CONSTANTS;
		final check: PreferEnumAbstract = new PreferEnumAbstract();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final vs: Array<Violation> = check.run([{ file: 'A.hx', source: decl }], plugin);
		final flat: Array<{ span: Span, text: String }> = check.fix(decl, vs, plugin);
		final grouped: Array<GroupedEdit> = check.fixGrouped(decl, vs, plugin);
		Assert.equals(grouped.length, flat.length);
		for (i in 0...flat.length) {
			Assert.equals(grouped[i].span.from, flat[i].span.from);
			Assert.equals(grouped[i].span.to, flat[i].span.to);
			Assert.equals(grouped[i].text, flat[i].text);
		}
	}

	/**
	 * The number of fix edits `THREE_STRING_CONSTANTS` yields when `other` is the second file in
	 * scope — 7 for a conversion (one head plus two per member), 0 for a refusal. `withIndex`
	 * supplies the `SymbolIndex` the resolution-backed gates read.
	 */
	private function alignFixEdits(other: String, withIndex: Bool): Int {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final files: Array<{ file: String, source: String }> = [
			{ file: 'Align.hx', source: THREE_STRING_CONSTANTS },
			{ file: 'Other.hx', source: other }
		];
		final check: PreferEnumAbstract = new PreferEnumAbstract();
		final vs: Array<Violation> = check.run(files, plugin);
		final index: Null<SymbolIndex> = withIndex ? SymbolIndex.build(files, plugin) : null;
		return check.fix(THREE_STRING_CONSTANTS, vs, plugin, index).length;
	}

	/** `decl`'s own grouped fix edits, run and fixed on one instance over a single-file scope. */
	private function groupedEdits(decl: String): Array<GroupedEdit> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: PreferEnumAbstract = new PreferEnumAbstract();
		return check.fixGrouped(decl, check.run([{ file: 'A.hx', source: decl }], plugin), plugin);
	}

	/** Every finding of this check is a report-only `prefer-enum-abstract` advisory. */
	private function assertAdvisory(v: Violation): Void {
		Assert.equals('prefer-enum-abstract', v.rule);
		Assert.equals(Severity.Info, v.severity);
	}

	private function fixedSource(src: String): String {
		return CheckFixture.fixedSource(new PreferEnumAbstract(), src);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferEnumAbstract().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
