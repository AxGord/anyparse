package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.CheckstyleConfigLoader;
import anyparse.query.GrammarPlugin.CheckOverrides;
import anyparse.runtime.ParseError;

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
		Assert.equals(true, CheckstyleConfigLoader.loadOverrides('{"checks":[{"type":"Type","props":{}}]}')
			.explicitTypeIgnoreEnumAbstract);
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

}
