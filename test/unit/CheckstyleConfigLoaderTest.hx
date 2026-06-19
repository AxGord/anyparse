package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.CheckstyleConfigLoader;
import anyparse.query.GrammarPlugin.CheckOverrides;

/**
 * `CheckstyleConfigLoader.loadOverrides` — maps a `checkstyle.json` onto the
 * neutral `CheckOverrides` the lint checks read. Each option's parse, its
 * checkstyle default when the check is present but omits the prop, and the
 * unset case when the check is absent are pinned; the lenient enum-string
 * matching (`policy` / `option`) and the `ModifierOrder.modifiers` kind mapping
 * are covered too.
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
		Assert.same(
			['Override', 'Public', 'Private', 'Static', 'Inline'],
			CheckstyleConfigLoader.loadOverrides('{"checks":[{"type":"ModifierOrder","props":{}}]}').modifierOrder
		);
	}

	public function testModifierOrderCustomDropsUnranked(): Void {
		// FINAL is dropped (our check does not rank it); PUBLIC_PRIVATE expands to two kinds.
		Assert.same(
			['Static', 'Public', 'Private', 'Override'],
			CheckstyleConfigLoader.loadOverrides(
				'{"checks":[{"type":"ModifierOrder","props":{"modifiers":["STATIC","PUBLIC_PRIVATE","OVERRIDE","FINAL"]}}]}'
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

	public function testToleratesWrongShape(): Void {
		// Valid JSON, wrong structure — tolerant, never throws (only Json.parse can).
		Assert.isNull(CheckstyleConfigLoader.loadOverrides('{"checks":"nope"}').magicNumberIgnore);
		Assert.isNull(CheckstyleConfigLoader.loadOverrides('{"checks":[7,"x"]}').magicNumberIgnore);
		// MagicNumber present but ignoreNumbers is not an array -> checkstyle default base.
		Assert.same(
			[-1.0, 0, 1, 2],
			CheckstyleConfigLoader.loadOverrides('{"checks":[{"type":"MagicNumber","props":{"ignoreNumbers":"notarray"}}]}')
				.magicNumberIgnore
		);
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
