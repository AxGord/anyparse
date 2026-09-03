package unit.grammar.haxe;

import anyparse.grammar.haxe.CheckstyleConfigLoader;
import anyparse.query.GrammarPlugin.CheckOverrides;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.NamingPolicy.NamingPolicy;
import anyparse.runtime.ParseError;
import utest.Assert;
import utest.Test;

/**
 * `CheckstyleConfigLoader.loadOverrides` — maps a `checkstyle.json` onto the
 * neutral `CheckOverrides` the lint checks read. Each option's parse, its
 * checkstyle default when the check is present but omits the prop, and the
 * unset case when the check is absent are pinned; the lenient enum-string
 * matching (`policy` / `option`) and the `ModifierOrder.modifiers` kind mapping
 * are covered too.
 *
 * Since the loader reads the config through the declared `CheckstyleConfig`
 * schema, a modelled key carrying a wrong-typed value is a parse error rather
 * than a silently-dropped prop — `testRejectsWrongShape` pins that boundary.
 */
class CheckstyleConfigLoaderTest extends Test {

	public function testMagicNumberIgnore(): Void {
		Assert.same(
			[-1.0, 0, 1, 2, 100],
			CheckstyleConfigLoader.loadOverrides('{"checks":[{"type":"MagicNumber","props":{"ignoreNumbers":[-1,0,1,2,100]}}]}')
				.magicNumberIgnore
		);
	}

	public function testMagicNumberDefaultWhenPropOmitted(): Void {
		Assert.same(
			[-1.0, 0, 1, 2], CheckstyleConfigLoader.loadOverrides('{"checks":[{"type":"MagicNumber","props":{}}]}').magicNumberIgnore
		);
	}

	public function testMagicNumberUnsetWhenCheckAbsent(): Void {
		Assert.isNull(CheckstyleConfigLoader.loadOverrides('{"checks":[]}').magicNumberIgnore);
	}

	public function testUnusedImportIgnoreModules(): Void {
		Assert.same(
			['haxe.macro.Expr', 'Foo'],
			CheckstyleConfigLoader.loadOverrides(
				'{"checks":[{"type":"UnusedImport","props":{"ignoreModules":["haxe.macro.Expr","Foo"]}}]}'
			)
				.unusedImportIgnoreModules
		);
	}

	public function testModifierOrderDefaultMapsToOurKinds(): Void {
		// FINAL maps to Final; MACRO / DYNAMIC stay unranked and are dropped.
		Assert.same(
			['Override', 'Public', 'Private', 'Static', 'Inline', 'Final'],
			CheckstyleConfigLoader.loadOverrides('{"checks":[{"type":"ModifierOrder","props":{}}]}').modifierOrder
		);
	}

	public function testModifierOrderCustomDropsUnranked(): Void {
		// MACRO is dropped (our check does not rank it); FINAL maps to Final, PUBLIC_PRIVATE expands to two kinds.
		Assert.same(
			['Static', 'Public', 'Private', 'Override', 'Final'],
			CheckstyleConfigLoader.loadOverrides(
				'{"checks":[{"type":"ModifierOrder","props":{"modifiers":["STATIC","MACRO","PUBLIC_PRIVATE","OVERRIDE","FINAL"]}}]}'
			)
				.modifierOrder
		);
	}

	public function testStringLiteralOnlySingleEnables(): Void {
		Assert.equals(
			true,
			CheckstyleConfigLoader.loadOverrides('{"checks":[{"type":"StringLiteral","props":{"policy":"onlySingle"}}]}')
				.preferSingleQuotesEnabled
		);
	}

	public function testStringLiteralDefaultDisables(): Void {
		Assert.equals(
			false, CheckstyleConfigLoader.loadOverrides('{"checks":[{"type":"StringLiteral","props":{}}]}').preferSingleQuotesEnabled
		);
	}

	public function testStringLiteralDoubleDisables(): Void {
		Assert.equals(
			false,
			CheckstyleConfigLoader.loadOverrides('{"checks":[{"type":"StringLiteral","props":{"policy":"doubleAndInterpolation"}}]}')
				.preferSingleQuotesEnabled
		);
	}

	public function testTypeIgnoreEnumAbstractFalse(): Void {
		Assert.equals(
			false,
			CheckstyleConfigLoader.loadOverrides('{"checks":[{"type":"Type","props":{"ignoreEnumAbstractValues":false}}]}')
				.explicitTypeIgnoreEnumAbstract
		);
	}

	public function testTypeDefaultTrue(): Void {
		Assert.equals(true, CheckstyleConfigLoader.loadOverrides('{"checks":[{"type":"Type","props":{}}]}').explicitTypeIgnoreEnumAbstract);
	}

	public function testEmptyBlockStmtEnables(): Void {
		Assert.equals(
			true, CheckstyleConfigLoader.loadOverrides('{"checks":[{"type":"EmptyBlock","props":{"option":"stmt"}}]}').emptyBlockEnabled
		);
	}

	public function testEmptyBlockDefaultDisables(): Void {
		Assert.equals(false, CheckstyleConfigLoader.loadOverrides('{"checks":[{"type":"EmptyBlock","props":{}}]}').emptyBlockEnabled);
	}

	public function testEmptyConfigYieldsNoOverrides(): Void {
		final ov: CheckOverrides = CheckstyleConfigLoader.loadOverrides('{}');
		Assert.isNull(ov.magicNumberIgnore);
		Assert.isNull(ov.preferSingleQuotesEnabled);
		Assert.isNull(ov.modifierOrder);
	}

	public function testRejectsWrongShape(): Void {
		// Valid JSON, wrong structure — the typed schema refuses it, and the caller
		// (HaxeQueryPlugin.checkOverrides) falls back to no overrides wholesale.
		final load: String -> CheckOverrides = CheckstyleConfigLoader.loadOverrides;
		Assert.raises(load.bind('{"checks":"nope"}'), ParseError);
		Assert.raises(load.bind('{"checks":[7,"x"]}'), ParseError);
		// MagicNumber present but ignoreNumbers is not an array: a modelled key with
		// a wrong-typed value is a parse error, not a silently-dropped prop.
		Assert.raises(load.bind('{"checks":[{"type":"MagicNumber","props":{"ignoreNumbers":"notarray"}}]}'), ParseError);
	}

	public function testPolicyWithBothKeywordsDisables(): Void {
		// A policy string containing both 'single' and 'double' is treated as double-preferring.
		Assert.equals(
			false,
			CheckstyleConfigLoader.loadOverrides('{"checks":[{"type":"StringLiteral","props":{"policy":"singleOrDouble"}}]}')
				.preferSingleQuotesEnabled
		);
	}

	public function testMultipleChecksAllMapped(): Void {
		final ov: CheckOverrides = CheckstyleConfigLoader.loadOverrides(
			'{"checks":[{"type":"MagicNumber","props":{"ignoreNumbers":[7]}},{"type":"EmptyBlock","props":{"option":"stmt"}}]}'
		);
		Assert.same([7.0], ov.magicNumberIgnore);
		Assert.equals(true, ov.emptyBlockEnabled);
	}

	/**
	 * `tokens` is what tells two `MemberName` entries apart, and dropping it made one of them DEAD.
	 * A project configuring the check twice — `CLASS / PUBLIC / PRIVATE / TYPEDEF` and `ENUM`, with
	 * different regexes — got two rules of the same category and the same empty selector, and
	 * `Naming.applicableRule` takes the FIRST that matches, so the second could never apply to
	 * anything. The `ENUM` arm is a different CATEGORY (checkstyle's `checkEnumFields` walks enum
	 * CONSTRUCTORS), not a narrowing of the first.
	 */
	public function testMemberNameEnumTokenBecomesItsOwnRule(): Void {
		final policy: NamingPolicy = CheckstyleConfigLoader.load(
			'{"checks":[{"type":"MemberName","props":{"format":"^[_a-z][_a-zA-Z0-9]*$","tokens":["CLASS","PUBLIC","PRIVATE","TYPEDEF"]}},'
			+ '{"type":"MemberName","props":{"format":"^[A-Z][A-z0-9_]*$","tokens":["ENUM"]}}]}'
		);
		Assert.equals(2, policy.length);
		Assert.equals(NamingCategory.Field, policy[0].category);
		Assert.equals(NamingCategory.EnumValue, policy[1].category);
		// Both PUBLIC and PRIVATE stated is no visibility narrowing at all — checkstyle's own reading.
		Assert.same([], policy[0].requireMods);
	}

	/**
	 * `MemberNameCheck.checkField` returns on `f.isStatic(p)` before it consults a single token, so a
	 * static field is not a member NAME to checkstyle — it is a `ConstantName` candidate. Reading it
	 * as one produced 55 of an 851-file tree's 231 naming findings, every one an UPPER_SNAKE static,
	 * and each would have been renamed toward the format the project wrote for its instance fields.
	 */
	public function testMemberNameNeverGovernsAStatic(): Void {
		final policy: NamingPolicy = CheckstyleConfigLoader.load(
			'{"checks":[{"type":"MemberName","props":{"format":"^[_a-z][_a-zA-Z0-9]*$"}}]}'
		);
		// An ABSENT `tokens` is checkstyle's "every token", so both arms are contributed.
		Assert.equals(2, policy.length);
		Assert.equals(NamingCategory.Field, policy[0].category);
		// `extern` rides the same selector: `NameCheckBase.ignoreExtern` defaults to TRUE, so a check
		// that never mentions it still exempts a declaration inside an `extern` type.
		Assert.same(['static', 'extern'], policy[0].forbidMods);
		Assert.equals(NamingCategory.EnumValue, policy[1].category);
	}

	/**
	 * `ConstantName`'s one pair. `INLINE` alone selects `static inline var` / `static inline final`
	 * and nothing else, so a plain `static final` — which carries no `inline` keyword — falls outside
	 * a rule the project narrowed that way. Stating BOTH tokens is what stating neither means.
	 */
	public function testConstantNameInlineTokenRequiresInline(): Void {
		final inlineOnly: NamingPolicy = CheckstyleConfigLoader.load(
			'{"checks":[{"type":"ConstantName","props":{"format":"^[A-Z]+$","tokens":["INLINE"]}}]}'
		);
		Assert.same(['inline'], inlineOnly[0].requireMods);
		Assert.same(['extern'], inlineOnly[0].forbidMods);
		final notInline: NamingPolicy = CheckstyleConfigLoader.load(
			'{"checks":[{"type":"ConstantName","props":{"format":"^[A-Z]+$","tokens":["NOTINLINE"]}}]}'
		);
		Assert.same([], notInline[0].requireMods);
		Assert.same(['inline', 'extern'], notInline[0].forbidMods);
		final both: NamingPolicy = CheckstyleConfigLoader.load(
			'{"checks":[{"type":"ConstantName","props":{"format":"^[A-Z]+$","tokens":["INLINE","NOTINLINE"]}}]}'
		);
		Assert.same([], both[0].requireMods);
		Assert.same(['extern'], both[0].forbidMods);
	}

	/**
	 * `MethodName`'s three pairs map straight onto the neutral modifier vocabulary. `PRIVATE` becomes
	 * "not public" rather than "carries private": a Haxe method with no visibility keyword IS
	 * private, and the projection writes no modifier for it, so requiring one would select only the
	 * members that say so out loud.
	 */
	public function testMethodNameTokensBecomeModifierSelectors(): Void {
		final policy: NamingPolicy = CheckstyleConfigLoader.load(
			'{"checks":[{"type":"MethodName","props":{"format":"^[a-z]+$","tokens":["PRIVATE","STATIC","NOTINLINE"]}}]}'
		);
		Assert.equals(1, policy.length);
		Assert.equals(NamingCategory.Method, policy[0].category);
		Assert.same(['static'], policy[0].requireMods);
		// `interface` leads because no token states it: `MethodNameCheck.checkClassType` returns on
		// `d.flags.contains(HInterface)` before it reaches a field, unconditionally, so every
		// `MethodName` rule carries the entry whatever its tokens say.
		Assert.same(['interface', 'public', 'inline', 'extern'], policy[0].forbidMods);
	}

	/**
	 * The boundary this adapter stops at. A token selecting a TYPE KIND — `CLASS` / `ABSTRACT` /
	 * `TYPEDEF` on `MemberName`, every `TypeName` token — has no counterpart on `NamedDecl`, which
	 * knows a declaration's category, its modifiers and the NAME of its enclosing type, never that
	 * type's kind. Such a token decides only WHETHER a field rule is contributed; it never narrows
	 * one, so the rule over-reports rather than silently governing nothing.
	 */
	public function testTypeKindTokensNarrowNothing(): Void {
		final types: NamingPolicy = CheckstyleConfigLoader.load(
			'{"checks":[{"type":"TypeName","props":{"format":"^[A-Z]","tokens":["INTERFACE"]}}]}'
		);
		Assert.equals(1, types.length);
		Assert.equals(NamingCategory.Type, types[0].category);
		Assert.same([], types[0].requireMods);
		Assert.same(['extern'], types[0].forbidMods);
		// `ENUM` alone contributes no field rule at all — checkstyle's three field arms all return.
		final enumOnly: NamingPolicy = CheckstyleConfigLoader.load(
			'{"checks":[{"type":"MemberName","props":{"format":"^[A-Z]","tokens":["ENUM"]}}]}'
		);
		Assert.equals(1, enumOnly.length);
		Assert.equals(NamingCategory.EnumValue, enumOnly[0].category);
	}

	/**
	 * The autofix half a `checkstyle.json` cannot state. A config-derived rule used to carry no
	 * `normalize` at all, so `Naming.correctedName` had nothing to return and every finding such a
	 * policy produced was report-only BY CONSTRUCTION — 198 of an 851-file tree's 231. The
	 * corrections are the grammar's: a rule gets the ones the built-in policy attaches to ITS
	 * category, and none for a category the built-in itself leaves report-only.
	 */
	public function testConfigRuleCarriesItsCategorysNormalizer(): Void {
		final checks: Array<String> = [
			'{"type":"MethodName","props":{"format":"^[a-z][a-zA-Z0-9_]*$"}}',
			'{"type":"TypeName","props":{"format":"^[A-Z][a-zA-Z0-9]*$"}}',
			'{"type":"ParameterName","props":{"format":"^[a-z][a-zA-Z0-9]*$"}}'
		];
		final policy: NamingPolicy = CheckstyleConfigLoader.load('{"checks":[${checks.join(',')}]}');
		final method: Null<String -> Null<String>> = policy[0].normalize;
		Assert.notNull(method);
		if (method != null) Assert.equals('doThing', method('_doThing'));
		// A TYPE rename reaches every file that names it, so the built-in leaves it report-only.
		Assert.isNull(policy[1].normalize);
		final param: Null<String -> Null<String>> = policy[2].normalize;
		Assert.notNull(param);
		if (param != null) Assert.equals('countryId', param('country_id'));
	}

	/**
	 * And where it declines. `Field` is the category the built-in policy corrects two different ways
	 * — `_count` for a private field, `count` for a public one — so a config format admitting BOTH
	 * spellings gets neither: the config stated a format, not a preference, and an ordered fallback
	 * chain would answer by fiat a question its author never answered.
	 */
	public function testNormalizerDeclinesWhenTheFormatAdmitsTwoCorrections(): Void {
		final policy: NamingPolicy = CheckstyleConfigLoader.load(
			'{"checks":[{"type":"MemberName","props":{"format":"^[_a-z][_a-zA-Z0-9]*$","tokens":["CLASS"]}}]}'
		);
		final ambiguous: Null<String -> Null<String>> = policy[0].normalize;
		Assert.notNull(ambiguous);
		// `_bad_name` conforms both as `_badName` and as `bad_name` — two answers, so no answer.
		if (ambiguous != null) Assert.isNull(ambiguous('_bad_name'));
		// The same category under a format only ONE correction satisfies does answer.
		final prefixed: NamingPolicy = CheckstyleConfigLoader.load(
			'{"checks":[{"type":"MemberName","props":{"format":"^_[a-z][a-zA-Z0-9]*$","tokens":["CLASS"]}}]}'
		);
		final only: Null<String -> Null<String>> = prefixed[0].normalize;
		Assert.notNull(only);
		if (only != null) Assert.equals('_badName', only('bad_name'));
	}

	/**
	 * `NameCheckBase.ignoreExtern` was dropped along with `tokens`, and dropping it does not widen a
	 * rule — it NARROWS the exemption, which makes this adapter STRICTER than every config that never
	 * mentions the key, since checkstyle's own default is TRUE. Stated as `false` the rule contributes
	 * no `extern` entry and reaches the declarations again.
	 */
	public function testIgnoreExternDefaultsToTrueAndFalseIsStatable(): Void {
		final stated: NamingPolicy = CheckstyleConfigLoader.load(
			'{"checks":[{"type":"MethodName","props":{"format":"^[a-z]+$","ignoreExtern":false}}]}'
		);
		// `interface` survives every arm: it is not `ignoreExtern`'s and no prop states it — the
		// interface skip is hard-coded in `MethodNameCheck.checkClassType`, where `ignoreExtern` is a
		// field with a default. Stating `ignoreExtern: false` drops the `extern` entry and only that.
		Assert.same(['interface'], stated[0].forbidMods);
		final omitted: NamingPolicy = CheckstyleConfigLoader.load('{"checks":[{"type":"MethodName","props":{"format":"^[a-z]+$"}}]}');
		Assert.same(['interface', 'extern'], omitted[0].forbidMods);
		final explicit: NamingPolicy = CheckstyleConfigLoader.load(
			'{"checks":[{"type":"MethodName","props":{"format":"^[a-z]+$","ignoreExtern":true}}]}'
		);
		Assert.same(['interface', 'extern'], explicit[0].forbidMods);
	}

	/**
	 * `CatchParameterNameCheck` is the one naming check that does not extend `NameCheckBase`: it
	 * declares no `ignoreExtern` field at all, so checkstyle never exempts a catch variable for one.
	 * The flag is DROPPED for it rather than defaulted — the same reading that made this adapter drop
	 * `LocalVariableName` / `ParameterName`'s unread `tokens`.
	 */
	public function testCatchParameterNameCarriesNoExternGate(): Void {
		final policy: NamingPolicy = CheckstyleConfigLoader.load(
			'{"checks":[{"type":"CatchParameterName","props":{"format":"^[a-z]+$","ignoreExtern":true}},'
			+ '{"type":"LocalVariableName","props":{"format":"^[a-z]+$"}}]}'
		);
		Assert.equals(NamingCategory.CatchVar, policy[0].category);
		Assert.same([], policy[0].forbidMods);
		Assert.equals(NamingCategory.Local, policy[1].category);
		Assert.same(['extern'], policy[1].forbidMods);
	}

}
