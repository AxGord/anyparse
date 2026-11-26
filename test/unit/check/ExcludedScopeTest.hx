package unit.check;

import anyparse.check.EffectiveRules;
import anyparse.check.LintConfig;
import anyparse.check.LintDocuments;
import anyparse.check.Linter;
import anyparse.check.common.design.AnonTypeDup;
import anyparse.check.common.unused.UnusedPublicMember;

/**
 * The `excludePaths` / `excludeTypes` keys every rule's `apq.json` entry takes (`ExcludedScope`): a file or a top-level type
 * a rule's config scopes out has no finding of that rule, wherever the rule reports from.
 */
@:nullSafety(Strict)
final class ExcludedScopeTest extends Test {

	private static inline final RULE: String = 'unused-public-member';
	private static final CONSTANTS: String = 'package res;\n\nclass Consts {\n\tpublic static inline final zqxwvOne:String = "one";\n}\n';
	private static final PATH: String = '/proj/src/res/Consts.hx';

	/** The fixture is flagged without a scope, and a path naming the file, its directory or a glob over it drops the finding. */
	@:pin('control')
	@:killer('M-EXCLUDED-SCOPE-PATHS-BLIND')
	@:killer('M-EXCLUDED-SCOPE-RELATIVE-TO-DOCUMENT')
	@:killer('M-EXCLUDED-SCOPE-NOT-COLLECTED')
	public function testAnExcludedPathHasNoFindings(): Void {
		Assert.equals(1, constants('"enabled":true').length, 'the fixture is flagged on its own');
		Assert.equals(0, constants('"excludePaths":["src/res/Consts.hx"]').length, 'the file');
		Assert.equals(0, constants('"excludePaths":["src/res"]').length, 'its directory');
		Assert.equals(0, constants('"excludePaths":["src/**/Consts.hx"]').length, 'a glob');
	}

	/** A pattern naming something else leaves the findings as they were. */
	@:pin('control')
	@:killer('M-EXCLUDED-SCOPE-EMPTY-ENTRY')
	public function testANonMatchingPathLeavesTheFindingsUnchanged(): Void {
		final plain: Array<Violation> = constants('"enabled":true');
		final scoped: Array<Violation> = constants('"excludePaths":["src/other/","res/*.hx",""]');
		Assert.same(plain.map(v -> v.message), scoped.map(v -> v.message));
		Assert.equals(1, scoped.length);
	}

	/** A top-level type is named by its dotted path or a glob over it; a secondary type of the module by the module path. */
	@:pin('control')
	@:killer('M-EXCLUDED-SCOPE-TYPES-BLIND')
	@:killer('M-EXCLUDED-SCOPE-NOT-COLLECTED')
	public function testAnExcludedTypeHasNoFindings(): Void {
		Assert.equals(0, constants('"excludeTypes":["res.Consts"]').length, 'by path');
		Assert.equals(0, constants('"excludeTypes":["res.*"]').length, 'by glob');
		Assert.equals(1, constants('"excludeTypes":["res.Other","other.Consts"]').length, 'a type it does not name');
		final two: String = '$CONSTANTS\nclass Extra {\n\tpublic static inline final zqxwvTwo:String = "two";\n}\n';
		final left: Array<Violation> = found([{ file: PATH, source: two }], '"excludeTypes":["res.Consts.Extra"]');
		Assert.equals(1, left.length, 'a secondary type is named through its module');
		Assert.isTrue(left.length == 1 && left[0].message.indexOf('zqxwvOne') >= 0, left.map(v -> v.message).join('\n'));
	}

	/** A nested document's pattern is relative to ITS directory: the same entry covers one file and not the other. */
	@:pin('control')
	@:killer('M-EXCLUDED-SCOPE-RELATIVE-TO-DOCUMENT')
	public function testAPatternIsRelativeToTheDocumentThatWroteIt(): Void {
		final inner: LintConfig = LintConfig.parse('{"rules":{"$RULE":{"excludePaths":["Consts.hx"]}}}', '/proj/a');
		final outer: LintConfig = LintConfig.parse('{"rules":{"$RULE":{"excludePaths":["Consts.hx"]}}}', '/proj');
		final files: Array<{ file: String, source: String }> = [
			{ file: '/proj/a/Consts.hx', source: 'class A {\n\tpublic static inline final zqxwvA:String = "a";\n}\n' },
			{ file: '/proj/b/Consts.hx', source: 'class B {\n\tpublic static inline final zqxwvB:String = "b";\n}\n' }
		];
		final vs: Array<Violation> = Linter.run(
			files, new HaxeQueryPlugin(), [new UnusedPublicMember()], file -> file.indexOf('/proj/a/') == 0 ? inner : outer, true
		);
		Assert.same(['/proj/b/Consts.hx'], vs.map(v -> v.file));
	}

	/** An excluded file is dropped from the findings, never from the scan: what it uses stays used. */
	@:pin('guard')
	public function testAnExcludedFileStillCountsAsAReference(): Void {
		final user: String = 'class User {\n\tpublic static function main():Void {\n\t\ttrace(res.Consts.zqxwvOne);\n\t}\n}\n';
		final files: Array<{ file: String, source: String }> =
			[{ file: PATH, source: CONSTANTS }, { file: '/proj/src/User.hx', source: user }];
		Assert.equals(0, found(files, '"excludePaths":["src/User.hx"]').filter(v -> v.file == PATH).length);
	}

	/** The key is accepted under every rule, and a typo of it is said with the key it resembles. */
	@:pin('control')
	@:killer('M-OPTKEYS-SCOPE-KEYS')
	public function testTheScopeKeysAreAcceptedUnderAnyRule(): Void {
		final accepted: Map<String, Array<String>> = ['bare' => []];
		Assert.same([], said('{"rules":{"bare":{"excludePaths":["x"],"excludeTypes":["p.T"]}}}', accepted));
		Assert.same(
			['rules "bare" has unknown option "excludePath" — ignored; accepts: excludePaths'],
			said('{"rules":{"bare":{"excludePath":["x"]}}}', accepted)
		);
	}

	/** The rule listing reports a rule off for a file its `excludePaths` cover, whichever rule it is. */
	@:pin('control')
	@:killer('M-EFFECTIVE-EXCLUDED')
	@:killer('M-EXCLUDED-SCOPE-PATHS-BLIND')
	public function testTheListingReportsAScopedOutFileOff(): Void {
		final config: LintConfig = LintConfig.parse('{"rules":{"$RULE":{"excludePaths":["src/res"]}}}', '/proj');
		final check: UnusedPublicMember = new UnusedPublicMember();
		final out: RuleState = EffectiveRules.stateOf(check, PATH, config);
		Assert.isFalse(out.on);
		Assert.equals('config-excluded', out.reason);
		Assert.isTrue(EffectiveRules.stateOf(check, '/proj/src/app/Main.hx', config).on);
	}

	/** The fix is derived from the findings it is handed: an excluded constant gets no edit, the unexcluded one beside it is deleted. */
	@:pin('control')
	@:killer('M-EXCLUDED-SCOPE-NOT-COLLECTED')
	public function testFixLeavesAnExcludedConstant(): Void {
		final kept: String = 'class Consts {\n\n\tpublic static inline final zqxwvKept:Int = 3;\n\n}\n';
		final dropped: String = 'class Other {\n\n\tpublic static inline final zqxwvDropped:Int = 4;\n\n}\n';
		final files: Array<{ file: String, source: String }> = [
			{ file: '/proj/Consts.hx', source: kept },
			{ file: '/proj/Other.hx', source: dropped }
		];
		final config: LintConfig = LintConfig.parse('{"rules":{"$RULE":{"excludePaths":["Consts.hx"]}}}', '/proj');
		final check: UnusedPublicMember = new UnusedPublicMember();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final vs: Array<Violation> = Linter.run(files, plugin, [check], _ -> config, true);
		Assert.same(['/proj/Other.hx'], vs.map(v -> v.file), 'only the file nothing excludes is reported');
		Assert.equals(0, check.fix(kept, vs.filter(v -> v.file == '/proj/Consts.hx'), plugin).length, 'no edit for the excluded file');
		Assert.equals(1, check.fix(dropped, vs.filter(v -> v.file == '/proj/Other.hx'), plugin).length, 'the other constant is deleted');
	}

	/**
	 * A cross-file finding is anchored at an occurrence the scope keeps: with its first-listed file scoped out, the one
	 * finding moves to the next file instead of being dropped with its anchor.
	 */
	@:pin('control')
	@:killer('M-LINTER-REPORTABLE-IGNORES-SCOPE')
	public function testACrossFileFindingIsAnchoredOutsideTheExcludedFiles(): Void {
		final shape: String = 'class C { var a: { name: String, size: Int, kind: String }; }';
		final files: Array<{ file: String, source: String }> = [ for (name in ['A', 'B', 'C']) { file: '/proj/$name.hx', source: shape } ];
		final plain: LintConfig = LintConfig.parse('{"rules":{"anon-type-dup":{"enabled":true}}}', '/proj');
		final scoped: LintConfig = LintConfig.parse('{"rules":{"anon-type-dup":{"enabled":true,"excludePaths":["A.hx"]}}}', '/proj');
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.same(
			['/proj/A.hx'],
			Linter.run(files, plugin, [new AnonTypeDup()], _ -> plain, true).map(v -> v.file), 'anchored at the first file without a scope'
		);
		Assert.same(
			['/proj/B.hx'],
			Linter.run(files, plugin, [new AnonTypeDup()], _ -> scoped, true).map(v -> v.file), 'the excluded anchor is passed over'
		);
	}

	/** The findings of `unused-public-member` over `files`, the config `scope` written under it, resolved against `/proj`. */
	private static function found(files: Array<{ file: String, source: String }>, scope: String): Array<Violation> {
		final config: LintConfig = LintConfig.parse('{"rules":{"$RULE":{$scope}}}', '/proj');
		return Linter.run(files, new HaxeQueryPlugin(), [new UnusedPublicMember()], _ -> config, true);
	}

	private static function constants(scope: String): Array<Violation> {
		return found([{ file: PATH, source: CONSTANTS }], scope);
	}

	private static function said(config: String, accepted: Map<String, Array<String>>): Array<String> {
		final doc: Null<LintDocument> = LintDocuments.parseDocument(config);
		return doc == null ? ['document rejected'] : LintDocuments.unknownOptions(doc, accepted);
	}

}
