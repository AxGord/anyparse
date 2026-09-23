package unit.check;

import anyparse.check.Check;
import anyparse.check.Linter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.cli.command.LintCommand;
import unit.CheckFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `prefer-final-field` and `prefer-final-public-field` on an owner a build macro reaches. Such an owner
 * used to get no finding at all, which silenced both rules on every OpenFL `Sprite` subclass; it now
 * gets its finding, with the edit declined without a compiler oracle and admitted, through
 * typecheck-and-revert, under one. Every other owner keeps the ordinary fix.
 */
@:nullSafety(Strict) class PreferFinalMacroOwnerTest extends Test {

	/** A private field assigned only at its declaration, in a class a `@:build` macro reaches. */
	private static inline final PRIVATE_BUILT: String =
		'@:build(M.f()) class C {\n\tprivate var a:Int = 1;\n\tpublic function new() {}\n\tpublic function get():Int return a;\n}';

	/** A public field never reassigned, in a class a `@:build` macro reaches. */
	private static inline final PUBLIC_BUILT: String = '@:build(M.f()) class C {\n\tpublic var a:Int = 1;\n\tpublic function new() {}\n}';

	private static inline final PRIVATE_RULE: String = 'prefer-final-field';
	private static inline final PUBLIC_RULE: String = 'prefer-final-public-field';

	@:pin('control') @:killer('M-PFF-MACRO-SILENT')
	public function testAPrivateFieldOfAMacroBuiltOwnerIsReportedAndDeclined(): Void {
		final vs: Array<Violation> = violations(PRIVATE_RULE, PRIVATE_BUILT);
		Assert.equals(1, vs.length);
		if (vs.length == 1) Assert.notNull(vs[0].declineReason);
	}

	@:pin('control') @:killer('M-PFF-MACRO-FIXED')
	public function testAPrivateFieldOfAMacroBuiltOwnerIsNotFixedWithoutTheOracle(): Void {
		Assert.equals(PRIVATE_BUILT, fixed(PRIVATE_RULE, PRIVATE_BUILT, false));
	}

	@:pin('control') @:killer('M-PFF-MACRO-NEVER-ADMITTED')
	public function testAPrivateFieldOfAMacroBuiltOwnerIsFixedUnderTheOracle(): Void {
		Assert.equals(PRIVATE_BUILT.replace('private var', 'private final'), fixed(PRIVATE_RULE, PRIVATE_BUILT, true));
	}

	@:pin('control') @:killer('M-PFPF-MACRO-SILENT')
	public function testAPublicFieldOfAMacroBuiltOwnerIsReportedAndDeclined(): Void {
		final vs: Array<Violation> = violations(PUBLIC_RULE, PUBLIC_BUILT);
		Assert.equals(1, vs.length);
		if (vs.length == 1) Assert.notNull(vs[0].declineReason);
	}

	@:pin('control') @:killer('M-PFPF-MACRO-FIXED')
	public function testAPublicFieldOfAMacroBuiltOwnerIsNotFixedWithoutTheOracle(): Void {
		Assert.equals(PUBLIC_BUILT, fixed(PUBLIC_RULE, PUBLIC_BUILT, false));
	}

	@:pin('control') @:killer('M-PFPF-MACRO-NEVER-ADMITTED')
	public function testAPublicFieldOfAMacroBuiltOwnerIsFixedUnderTheOracle(): Void {
		Assert.equals(PUBLIC_BUILT.replace('public var', 'public final'), fixed(PUBLIC_RULE, PUBLIC_BUILT, true));
	}

	/** The grant usually arrives through an `@:autoBuild` INTERFACE, so the class itself carries no metadata. */
	public function testAnAutoBuildInterfaceMakesTheOwnerMacroBuilt(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C implements I {\n\tpublic var a:Int = 1;\n\tpublic function new() {}\n}' },
			{ file: 'I.hx', source: '@:autoBuild(M.f()) interface I {}' }
		];
		final vs: Array<Violation> = runOn(PUBLIC_RULE, files, false).filter(v -> v.file == 'C.hx');
		Assert.equals(1, vs.length);
		if (vs.length == 1) Assert.notNull(vs[0].declineReason);
	}

	/**
	 * The null-guarded default FOLD is refused on a macro-built owner even under the oracle: it turns a
	 * `(default, null)` property into a plain field (a builder listing `FProp` fields then sees none) and
	 * moves the default after whatever the builder prepends to the constructor — both compile.
	 */
	@:pin('control') @:killer('M-FINAL-MACRO-FOLD-ADMITTED')
	public function testTheFoldIsNeverAdmittedOnAMacroBuiltOwner(): Void {
		final prop: String = '@:build(B.build()) class C {\n\tpublic var x(default, null):Int = 1;\n\n'
			+ '\tpublic function new(?p:Int) {\n\t\tif (p != null) x = p;\n\t}\n}';
		Assert.equals(prop, fixed(PUBLIC_RULE, prop, true));
		final field: String = 'class C implements I {\n\tprivate var x:Int = 1;\n\n\tpublic function new(?p:Int) {\n'
			+ '\t\tif (p != null) x = p;\n\t}\n\n\tpublic function get():Int return x;\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: field },
			{ file: 'I.hx', source: '@:autoBuild(B.build()) interface I {}' }
		];
		final vs: Array<Violation> = runOn(PRIVATE_RULE, files, true).filter(v -> v.file == 'C.hx');
		Assert.equals(1, vs.length);
		if (vs.length == 1) Assert.notNull(vs[0].declineReason);
	}

	/** A builder whose module reads field finality can generate something else for `final`, which the oracle cannot see. */
	@:pin('control') @:killer('M-FINAL-MACRO-FINALITY-BLIND')
	public function testABuilderReadingFinalityDeclinesEvenUnderTheOracle(): Void {
		final owner: { file: String, source: String } = { file: 'C.hx', source: PUBLIC_BUILT };
		final reads: String = 'class M {\n\tpublic static function f():Array<haxe.macro.Expr.Field> {\n'
			+ '\t\treturn [for (f in haxe.macro.Context.getBuildFields()) if (!f.access.contains(AFinal)) f];\n\t}\n}';
		final blind: String = 'class M {\n\tpublic static function f():Array<haxe.macro.Expr.Field> {\n'
			+ '\t\treturn haxe.macro.Context.getBuildFields();\n\t}\n}';
		final declined: Array<Violation> = runOn(PUBLIC_RULE, [owner, { file: 'M.hx', source: reads }], true).filter(v -> v.file == 'C.hx');
		Assert.equals(1, declined.length);
		if (declined.length == 1) Assert.notNull(declined[0].declineReason);
		final admitted: Array<Violation> = runOn(PUBLIC_RULE, [owner, { file: 'M.hx', source: blind }], true).filter(v -> v.file == 'C.hx');
		Assert.equals(1, admitted.length);
		if (admitted.length == 1) Assert.isNull(admitted[0].declineReason, 'the control');
	}

	/** Without a builder nothing changes: the finding carries no decline and the plain fix lands. */
	public function testAnOrdinaryOwnerKeepsThePlainFix(): Void {
		final plain: String = PUBLIC_BUILT.replace('@:build(M.f()) ', '');
		final vs: Array<Violation> = violations(PUBLIC_RULE, plain);
		Assert.equals(1, vs.length);
		if (vs.length == 1) Assert.isNull(vs[0].declineReason);
		Assert.equals(plain.replace('public var', 'public final'), fixed(PUBLIC_RULE, plain, false));
	}

	/** With an oracle both rules are VERIFIED; without one they stay in the unverified full-scope loop. */
	public function testTheOracleDecidesWhichPathTheFixTakes(): Void {
		for (id in [PRIVATE_RULE, PUBLIC_RULE]) {
			final check: Null<Check> = Linter.byId(id);
			if (check == null) {
				Assert.fail('$id is not registered');
				continue;
			}
			Assert.isTrue(check is RiskyFix);
			Assert.equals(1, LintCommand.partitionChecks([check], true).risky.length);
			Assert.equals(1, LintCommand.partitionChecks([check], false).fullScope.length);
		}
	}

	/** Rule `id`'s findings over `files`, with the oracle-relaxed candidate set on when `oracle`. */
	private function runOn(id: String, files: Array<{ file: String, source: String }>, oracle: Bool): Array<Violation> {
		final check: Null<Check> = Linter.byId(id);
		if (check == null || !(check is OracleRelaxable)) {
			Assert.fail('$id is not an OracleRelaxable check');
			return [];
		}
		(cast check: OracleRelaxable).setOracleRelaxed(oracle);
		final out: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		(cast check: OracleRelaxable).setOracleRelaxed(false);
		return out;
	}

	/** Rule `id`'s findings over `src` as `C.hx`, no oracle. */
	private function violations(id: String, src: String): Array<Violation> {
		final check: Null<Check> = Linter.byId(id);
		return check == null ? [] : check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** `src` after rule `id`'s fix, with the oracle-relaxed candidate set on when `oracle`. */
	private function fixed(id: String, src: String, oracle: Bool): String {
		final check: Null<Check> = Linter.byId(id);
		if (check == null || !(check is OracleRelaxable)) {
			Assert.fail('$id is not an OracleRelaxable check');
			return src;
		}
		(cast check: OracleRelaxable).setOracleRelaxed(oracle);
		final out: String = CheckFixture.fixedSource(check, src);
		(cast check: OracleRelaxable).setOracleRelaxed(false);
		return out;
	}

}
