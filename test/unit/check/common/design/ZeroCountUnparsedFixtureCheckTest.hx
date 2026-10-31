package unit.check.common.design;

import anyparse.check.LintConfig;
import anyparse.check.common.design.ZeroCountUnparsedFixture;

/**
 * The `zero-count-unparsed-fixture` check: a fixture that reaches a `sourceFields` field unchanged — written there, held
 * by a local, or handed through a helper of the same file — and does not parse is reported under a zero-count
 * assertion; a parsing fixture, a wrapped one, a declared skip-parse test and a non-zero count are not.
 */
class ZeroCountUnparsedFixtureCheckTest extends Test {

	private static final CONFIG: String = '{"rules":{"zero-count-unparsed-fixture":{"zeroAsserts":["Assert.equals"],'
		+ '"countFields":["length"],"sourceFields":["source"],"skipParseTests":["testSkip"]}}}';

	/** A helper handing its parameter straight to the source field. */
	private static final DIRECT: String =
		'\tfunction lint(src:String):Array<Int> {\n\t\treturn run([{ file: \'a.hx\', source: src }]);\n\t}\n';

	/** A helper wrapping its parameter in a class before it reaches the source field. */
	private static final WRAPPED: String =
		'\tfunction lint(src:String):Array<Int> {\n\t\treturn run([{ file: \'a.hx\', source: \'class C {\' + src + \'}\' }]);\n\t}\n';

	public function testAnUnparseableFieldValueIsReported(): Void {
		final vs: Array<Violation> = violationsOf(
			'testA', 'Assert.equals(0, run([{ file: \'a.hx\', source: \'class Bad {\' }]).length);', ''
		);
		Assert.equals(1, vs.length);
		Assert.equals('zero-count-unparsed-fixture', vs[0].rule);
	}

	public function testAFixtureHandedThroughAHelperIsReported(): Void {
		Assert.equals(1, violationsOf('testA', 'Assert.equals(0, lint(\'class Bad {\').length);', DIRECT).length);
	}

	public function testAFixtureHeldByALocalIsReported(): Void {
		Assert.equals(1, violationsOf('testA', 'final src = \'class Bad {\';\n\t\tAssert.equals(0, lint(src).length);', DIRECT).length);
	}

	@:pin('control')
	@:killer('M-ZERO-FIXTURE-PARSE-IGNORED')
	public function testAParsingFixtureIsLeftAlone(): Void {
		Assert.equals(0, violationsOf('testA', 'Assert.equals(0, lint(\'class Good {}\').length);', DIRECT).length);
	}

	@:pin('control')
	@:killer('M-ZERO-FIXTURE-WRAP-FOLLOWED')
	public function testAWrappedFixtureIsLeftAlone(): Void {
		Assert.equals(0, violationsOf('testA', 'Assert.equals(0, lint(\'return 1;\').length);', WRAPPED).length);
	}

	@:pin('control')
	@:killer('M-ZERO-FIXTURE-SKIP-IGNORED')
	public function testADeclaredSkipParseTestIsLeftAlone(): Void {
		Assert.equals(0, violationsOf('testSkip', 'Assert.equals(0, lint(\'class Bad {\').length);', DIRECT).length);
	}

	public function testANonZeroCountIsLeftAlone(): Void {
		Assert.equals(0, violationsOf('testA', 'Assert.equals(1, lint(\'class Bad {\').length);', DIRECT).length);
	}

	public function testNothingIsReadWithoutTheConfig(): Void {
		Assert.equals(0, violationsOf('testA', 'Assert.equals(0, lint(\'class Bad {\').length);', DIRECT, '{}').length);
		Assert.equals('needs-config', new ZeroCountUnparsedFixture().skipReason('T.hx', LintConfig.parse('{}')));
	}

	/** The findings over a test class whose method `name` holds `body`, beside `helper`. */
	private function violationsOf(name: String, body: String, helper: String, ?config: String): Array<Violation> {
		final source: String = 'class T {\n\tfunction $name():Void {\n\t\t$body\n\t}\n\n$helper}\n';
		final text: String = config ?? CONFIG;
		return CheckFixture.violationsIn(
			new ZeroCountUnparsedFixture(), [{ file: 'T.hx', source: source }], null, _ -> LintConfig.parse(text)
		);
	}

}
