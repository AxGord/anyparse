package unit.check.common.members;

import anyparse.check.Check.FixEdit;
import anyparse.check.LintConfig;
import anyparse.check.SourceEntry;
import anyparse.check.common.members.PreferFinalClass;
import anyparse.query.CanonicalEdit;

/**
 * The closed-world arm of `prefer-final-class`: under the rule's `closedWorld` option a plain class nothing in the run's scope
 * extends is flagged `Info` and made `final`. An `extends` of any written form (plain, qualified, through an import alias,
 * under `#if`), a build macro reaching the class, a string naming it, an unreadable file spelling it, an extern class, an
 * `abstract class` and an interface keep it; without the option nothing is flagged. The arm is a `RiskyArm`: the trusted arm
 * hands the finding over and the edit comes from `riskyFix`.
 */
class PreferFinalClassClosedWorldTest extends Test {

	private static inline final ID: String = 'prefer-final-class';
	private static final CLOSED: String = '{"rules": {"prefer-final-class": {"closedWorld": true}}}';
	private static final HELPER: String = 'package app;\n\nclass Helper {\n\tpublic function new() {}\n}\n';

	@:pin('control')
	@:killer('M-PFC-CLOSED-NO-FINDINGS')
	public function testAClassNothingExtendsIsFlaggedUnderAClosedWorld(): Void {
		final files: Array<SourceEntry> = [helper(HELPER), user('class User {}')];
		Assert.same(['Helper', 'User'], reported(files, CLOSED));
	}

	@:pin('control')
	@:killer('M-PFC-CLOSED-WORLD-IGNORED')
	public function testWithoutTheOptionNothingIsFlagged(): Void {
		Assert.same([], reported([helper(HELPER)], '{}'));
		Assert.same([], reported([helper(HELPER)], '{"rules": {"prefer-final-class": {"closedWorld": false}}}'));
	}

	@:pin('control')
	@:killer('M-PFC-SUBTYPE-IGNORED')
	public function testAnExtendsOfAnyWrittenFormKeepsTheClass(): Void {
		for (sub in [
			'class Sub extends Helper {}',
			'class Sub extends app.Helper {}',
			'import app.Helper as H;\n\nclass Sub extends H {}',
			'#if foo\nclass Sub extends Helper {}\n#end',
			'#if foo\nclass Sub extends Helper {}\n#else\nclass Sub {}\n#end'
		]) Assert.same(sub.indexOf('#') >= 0 ? [] : ['Sub'], reported([helper(HELPER), user(sub)], CLOSED), sub);
	}

	@:pin('control')
	@:killer('M-PFC-BUILD-MACRO-IGNORED')
	public function testABuildMacroOnTheClassKeepsIt(): Void {
		Assert.same([], reported([helper('package app;\n\n@:build(app.Macro.build())\nclass Helper {}\n')], CLOSED));
		Assert.same([], reported([helper('package app;\n\n@:autoBuild(app.Macro.build())\nclass Helper {}\n')], CLOSED));
	}

	@:pin('control')
	@:killer('M-PFC-STRING-NAME-IGNORED')
	public function testAClassAStringNamesKeepsIt(): Void {
		final files: Array<SourceEntry> = [
			helper(HELPER),
			user('class User {\n\tfunction f() {\n\t\tType.resolveClass("app.Helper");\n\t}\n}')
		];
		Assert.same(['User'], reported(files, CLOSED));
	}

	@:pin('control')
	@:killer('M-PFC-SKIPPED-IGNORED')
	public function testAnUnreadableFileSpellingTheClassKeepsIt(): Void {
		Assert.same([], reported([helper(HELPER), user('class Bad extends Helper { function f(')], CLOSED));
	}

	@:pin('control')
	@:killer('M-PFC-EXTERN-IGNORED')
	public function testExternAbstractAndInterfaceAreNotCandidates(): Void {
		for (decl in [
			'extern class Helper {}',
			'abstract class Helper {}',
			'interface Helper {}',
			'final class Helper {}'
		]) Assert.same([], reported([helper('package app;\n\n$decl\n')], CLOSED), decl);
	}

	@:pin('control')
	@:killer('M-PFC-META-ARM-OVERLAP')
	public function testAClassCarryingTheFinalMetaIsTheMetaArmsAlone(): Void {
		final vs: Array<Violation> = violations([helper('package app;\n\n@:final class Helper {}\n')], CLOSED);
		Assert.equals(1, vs.length);
		Assert.stringContains('@:final meta', vs[0].message);
	}

	@:pin('control')
	@:killer('M-PFC-RISKY-FINDINGS-EMPTY', 'M-PFC-RISKY-FIX-EMPTY')
	public function testTheRiskyArmOwnsTheClosedWorldFindingAndInsertsFinal(): Void {
		final files: Array<SourceEntry> = [helper('package app;\n\n@:final class Meta {}\n\nclass Helper {}\n')];
		final check: PreferFinalClass = new PreferFinalClass();
		final vs: Array<Violation> = violations(files, CLOSED, check);
		Assert.equals(2, vs.length);
		final own: Array<Violation> = check.riskyArmFindings(vs);
		Assert.equals(1, own.length);
		Assert.stringContains('Helper', own[0].message);
		final edits: Array<FixEdit> = check.riskyFix(files[0].source, own, new HaxeQueryPlugin());
		Assert.equals('package app;\n\n@:final class Meta {}\n\nfinal class Helper {}\n', CanonicalEdit.applyEdits(files[0].source, edits));
	}

	@:pin('control')
	@:killer('M-PFC-NOT-HANDED-OFF')
	public function testTheTrustedArmHandsTheClosedWorldFindingOver(): Void {
		final config: LintConfig = LintConfig.parse(CLOSED);
		final run: FixRun = CheckFixture.fixRun(new PreferFinalClass(), [helper(HELPER)], null, null, _ -> config);
		Assert.equals(1, run.violations.length);
		Assert.equals(0, run.edits.length, 'the safe fix edits nothing');
		Assert.notNull(run.violations[0].declineReason);
	}

	@:pin('control')
	@:killer('M-PFC-METADATA-FIX-LOST')
	public function testTheMetaArmKeepsItsTrustedFix(): Void {
		final source: String = 'package app;\n\n@:final class Helper {}\n';
		Assert.equals(
			'package app;\n\nfinal class Helper {}\n',
			CanonicalEdit.applyEdits(source, CheckFixture.fixRun(new PreferFinalClass(), [helper(source)]).edits)
		);
	}

	public function testClosedWorldIsTheOnlyAcceptedKey(): Void {
		Assert.same(['closedWorld'], new PreferFinalClass().acceptedOptions());
	}

	private function violations(files: Array<SourceEntry>, json: String, ?check: PreferFinalClass): Array<Violation> {
		final config: LintConfig = LintConfig.parse(json);
		return CheckFixture.violationsIn(check ?? new PreferFinalClass(), files, null, _ -> config);
	}

	/** The names of the classes the closed-world arm reports in `files`. */
	private function reported(files: Array<SourceEntry>, json: String): Array<String> {
		return [ for (v in violations(files, json)) if (v.rule == ID && v.message.indexOf('closed world') > 0) v.message.split('\'')[1] ];
	}

	private static function helper(source: String): SourceEntry {
		return { file: 'app/Helper.hx', source: source };
	}

	private static function user(body: String): SourceEntry {
		return { file: 'app/User.hx', source: 'package app;\n\n$body\n' };
	}

}
