package unit.check.common.design;

import anyparse.check.Check;
import anyparse.check.LintConfig;
import anyparse.check.Severity;
import anyparse.check.SourceEntry;
import anyparse.check.common.design.HelperCopy;
import anyparse.query.Cli;
import unit.cli.CliFixture;

using StringTools;

/**
 * The `helper-copy` check: a function repeating, up to the names of its bindings, a function declared under a
 * configured `homes` path. Each property of the comparison is pinned by its own fixture: what the key ignores (names),
 * what it keeps (types and body), the floor under which nothing is compared, and where a home begins.
 */
class HelperCopyCheckTest extends Test {

	private static final CONFIG: String = '{"rules":{"helper-copy":{"enabled":true,"homes":["util/"]}}}';
	private static final HOME: SourceEntry = {
		file: 'src/util/Strings.hx',
		source: 'package util;\n\nclass Strings {\n\tpublic static function isBlank(text: String): Bool {\n'
			+ '\t\tfor (i in 0...text.length) {\n\t\t\tfinal c: Int = text.charCodeAt(i);\n'
			+ '\t\t\tif (c != 32 && (c < 9 || c > 13)) return false;\n\t\t}\n\t\treturn true;\n\t}\n\n\tpublic static function one(x: '
			+ 'Int): Int {\n\t\treturn x + 1;\n\t}\n\n\tpublic static function before(text: String, mark: String): String {\n'
			+ '\t\tfinal at: Int = text.indexOf(mark);\n\t\treturn at < 0 ? text : text.substring(0, at);\n\t}\n}\n'
	};
	private static final COPY: String = 'package own;\n\nclass Own {\n\tprivate static function blank(s: String): Bool {\n'
		+ '\t\tfor (k in 0...s.length) {\n\t\t\tfinal ch: Int = s.charCodeAt(k);\n'
		+ '\t\t\tif (ch != 32 && (ch < 9 || ch > 13)) return false;\n\t\t}\n\t\treturn true;\n\t}\n}\n';

	@:pin('control') @:killer('M-HELPER-COPY-NO-KEY') @:killer('M-HELPER-COPY-NO-RENAMING')
	public function testACopyUnderOtherNamesIsReported(): Void {
		final vs: Array<Violation> = violationsOf(COPY, 'src/Own.hx');
		Assert.equals(1, vs.length, messages(vs));
		Assert.equals('helper-copy', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('blank repeats Strings.isBlank up to the names of its bindings — call the helper', vs[0].message);
	}

	public function testTheHomeItselfIsNotReported(): Void {
		Assert.equals(0, violationsOf(COPY, 'src/Own.hx').filter(v -> v.file == HOME.file).length);
	}

	public function testADifferentBodyIsNotACopy(): Void {
		final other: String = COPY.replace('return true;', 'return false;');
		Assert.equals(0, violationsOf(other, 'src/Own.hx').length);
	}

	public function testADifferentParameterTypeIsNotACopy(): Void {
		final other: String = COPY.replace('s: String', 's: Dynamic');
		Assert.equals(0, violationsOf(other, 'src/Own.hx').length);
	}

	@:pin('control') @:killer('M-HELPER-COPY-NO-FLOOR')
	public function testAShortFunctionIsNotCompared(): Void {
		final tiny: String = 'package own;\n\nclass Own {\n\tprivate static function inc(y: Int): Int {\n\t\treturn y + 1;\n\t}\n}\n';
		Assert.equals(0, violationsOf(tiny, 'src/Own.hx').length);
	}

	@:pin('control') @:killer('M-HELPER-COPY-HOME-BY-SUBSTRING')
	public function testAHomeBeginsAtAPathSegment(): Void {
		final vs: Array<Violation> = violationsOf(COPY, 'src/myutil/Own.hx');
		Assert.equals(1, vs.length, messages(vs));
	}

	public function testWithoutHomesNothingIsReported(): Void {
		final files: Array<SourceEntry> = [HOME, { file: 'src/Own.hx', source: COPY }];
		final vs: Array<Violation> = CheckFixture.violationsIn(new HelperCopy(), files, null, _ -> LintConfig.parse('{}'));
		Assert.equals(0, vs.length, messages(vs));
	}

	public function testRegisteredAsDefaultOffAndReportOnly(): Void {
		final check: Null<Check> = Linter.byId('helper-copy');
		Assert.notNull(check);
		Assert.isTrue(Std.isOfType(check, DefaultOff), 'the rule needs a configured home, so a project opts in');
		final rule: HelperCopy = new HelperCopy();
		Assert.equals(0, CheckFixture.fixOf(rule, COPY, []).length);
		Assert.isTrue(rule.noAutofixReason().indexOf('judgement') >= 0, rule.noAutofixReason());
	}

	@:pin('control') @:killer('M-HELPER-COPY-PARAMETERS-UNORDERED')
	public function testSwappedParametersAreNotACopy(): Void {
		final swapped: String = 'package own;\n\nclass Own {\n\tprivate static function cut(mark: String, text: String): String {\n'
			+ '\t\tfinal at: Int = text.indexOf(mark);\n\t\treturn at < 0 ? text : text.substring(0, at);\n\t}\n}\n';
		Assert.equals(0, violationsOf(swapped, 'src/Own.hx').length);
		final same: String = swapped.replace('(mark: String, text: String)', '(text: String, mark: String)');
		Assert.equals(1, violationsOf(same, 'src/Own.hx').length);
	}

	@:pin('control') @:killer('M-HELPER-COPY-LITERAL-COLLAPSED')
	public function testADefaultsLiteralComparesExactly(): Void {
		final home: SourceEntry = {
			file: 'src/util/Pad.hx',
			source: 'package util;\n\nclass Pad {\n\tpublic static function cut(text: String, sep: String = "a b"): String {\n'
				+ '\t\tfinal at: Int = text.indexOf(sep);\n\t\treturn at < 0 ? text : text.substring(0, at);\n\t}\n}\n'
		};
		final copy: String = 'package own;\n\nclass Own {\n\tprivate static function clip(s: String, p: String = "a b"): String {\n'
			+ '\t\tfinal at: Int = s.indexOf(p);\n\t\treturn at < 0 ? s : s.substring(0, at);\n\t}\n}\n';
		final config: LintConfig = LintConfig.parse(CONFIG);
		final found: (String) -> Int = source ->
			CheckFixture.violationsIn(new HelperCopy(), [home, { file: 'src/Own.hx', source: source }], null, _ -> config).length;
		Assert.equals(1, found(copy));
		Assert.equals(0, found(copy.replace('"a b"', '"ab"')));
	}

	@:pin('control') @:killer('M-HELPER-COPY-EVERY-FILE-CANDIDATE')
	public function testAFileWhoseConfigNamesNoHomesIsNotACandidate(): Void {
		final named: LintConfig = LintConfig.parse(CONFIG);
		final bare: LintConfig = LintConfig.parse('{}');
		final files: Array<SourceEntry> = [HOME, { file: 'src/Own.hx', source: COPY }];
		final found: (String) -> Int = own ->
			CheckFixture.violationsIn(
				new HelperCopy(), files, null, file -> file == 'src/Own.hx' ? (own == 'named' ? named : bare) : named
			)
				.length;
		Assert.equals(1, found('named'));
		Assert.equals(0, found('bare'));
	}

	@:pin('control') @:killer('M-HELPER-COPY-REPORT-SCOPE-ONLY')
	public function testALintOfTheCopyAloneFindsTheHomeBeyondTheReportScope(): Void {
		#if (sys || nodejs)
		final tree: String = CliFixture.writeTree('helpercopyscope', [
			{ name: 'apq.json', source: '{"resolutionRoots":["src"],"rules":{"helper-copy":{"enabled":true,"homes":["util/"]}}}' },
			{ name: HOME.file, source: HOME.source },
			{ name: 'src/own/Own.hx', source: COPY }
		]);
		final lint: String = CliFixture.captureStdout(() ->
			Cli.run(['lint', '--rule', 'helper-copy', '--all', '--no-oracle', '$tree/src/own/Own.hx'])
		);
		CliFixture.removeDir(tree);
		Assert.stringContains('blank repeats Strings.isBlank', lint);
		#else
		Assert.pass('non-sys target');
		#end
	}

	private static function violationsOf(copy: String, copyFile: String): Array<Violation> {
		final config: LintConfig = LintConfig.parse(CONFIG);
		return CheckFixture.violationsIn(new HelperCopy(), [HOME, { file: copyFile, source: copy }], null, _ -> config);
	}

	private static function messages(vs: Array<Violation>): String {
		return vs.map(v -> '${v.file}: ${v.message}').join('\n');
	}

}
