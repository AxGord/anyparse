package unit.check.common.design;

import anyparse.check.LintConfig;
import anyparse.check.common.design.FixTextSyntax;
import anyparse.query.format.LintFormat;
import sys.io.File;

/**
 * The `fix-text-syntax` check: the text of an edit that carries a token of the grammar's own vocabulary is reported,
 * through a concatenation, a ternary or a local; a helper of the file whose returned text does is reported when its
 * result reaches an edit text or a configured sink; nothing is read without `roots`, or outside them.
 */
class FixTextSyntaxTest extends Test {

	private static final CONFIG: String = '{"rules":{"fix-text-syntax":{"roots":["src"],"sinks":["AddMember.memberEdit"]}}}';
	private static final HELPER: String = 'function h(): String { return \'final x = 1;\'; }';

	@:pin('control')
	@:killer('M-FIX-TEXT-SYNTAX-TOKEN-UNREAD')
	public function testAKeywordInAnEditTextIsReported(): Void {
		final found: Array<Violation> = violationsOf('return [{ span: s, text: \'return $$v;\' }];');
		Assert.equals(1, found.length);
		Assert.equals('literal', found[0].data?.family);
		Assert.equals('return', found[0].data?.subject);
	}

	public function testADelimiterAndAnOperatorAreSyntaxToo(): Void {
		Assert.equals(1, violationsOf('return [{ span: s, text: \'$$a.\' }];').length);
		Assert.equals(1, violationsOf('return [{ span: s, text: \' + \' }];').length);
	}

	@:pin('control')
	@:killer('M-FIX-TEXT-SYNTAX-NAME-IS-SYNTAX')
	public function testADeletionANameAndALineBreakSpellNoSyntax(): Void {
		Assert.equals(0, violationsOf('return [{ span: s, text: \'\' }];').length);
		Assert.equals(0, violationsOf('return [{ span: s, text: name }];').length);
		Assert.equals(0, violationsOf('return [{ span: s, text: \'_$$name\' }];').length);
		Assert.equals(0, violationsOf('return [{ span: s, text: \'\\n\\t\' }];').length);
	}

	public function testAConcatenationAndATernaryAreRead(): Void {
		Assert.equals(1, violationsOf('return [{ span: s, text: x + (c ? \'if (a) b;\' : \'\') }];').length);
	}

	@:pin('control')
	@:killer('M-FIX-TEXT-SYNTAX-LOCAL-UNFOLLOWED')
	public function testALocalHoldingTheTemplateIsRead(): Void {
		Assert.equals(1, violationsOf('final t = \'final x = 1;\'; return [{ span: s, text: t }];').length);
	}

	public function testAnObjectWithoutBothEditFieldsIsNoEdit(): Void {
		Assert.equals(0, violationsOf('return [{ message: \'return x;\' }];').length);
		Assert.equals(0, violationsOf('return [{ text: \'return x;\' }];').length);
	}

	@:pin('control')
	@:killer('M-FIX-TEXT-SYNTAX-HELPER-UNFOLLOWED')
	public function testAHelperWhoseResultIsTheEditTextIsReportedAtTheHelper(): Void {
		final found: Array<Violation> = violationsOf('return [{ span: s, text: h() }];', HELPER);
		Assert.equals(1, found.length);
		Assert.equals('helper', found[0].data?.family);
		Assert.equals('h -> edit text', found[0].data?.subject);
	}

	@:pin('control')
	@:killer('M-FIX-TEXT-SYNTAX-SINK-UNREAD')
	public function testAHelperReachingAConfiguredSinkThroughALocalIsReported(): Void {
		final found: Array<Violation> =
			violationsOf('final m = h(); AddMember.memberEdit(src, tree, \'T\', m, plugin); return [];', HELPER);
		Assert.equals(1, found.length);
		Assert.equals('h -> AddMember.memberEdit', found[0].data?.subject);
	}

	public function testAHelperNothingFeedsIsLeftAlone(): Void {
		Assert.equals(0, violationsOf('log(h()); return [];', HELPER).length);
	}

	public function testAHelperThatReturnsNoSyntaxIsLeftAlone(): Void {
		Assert.equals(0, violationsOf('return [{ span: s, text: h() }];', 'function h(): String { return name; }').length);
	}

	@:pin('control')
	@:killer('M-FIX-TEXT-SYNTAX-ROOTS-IGNORED')
	public function testNothingIsReadWithoutRootsOrOutsideThem(): Void {
		final rule: FixTextSyntax = new FixTextSyntax();
		Assert.equals('needs-config', rule.skipReason('src/T.hx', LintConfig.parse('{}')));
		Assert.isNull(rule.skipReason('src/T.hx', LintConfig.parse(CONFIG)));
		Assert.isNull(rule.skipReason('/work/tree/src/anyparse/T.hx', LintConfig.parse(CONFIG)));
		Assert.equals('outside-roots', rule.skipReason('test/T.hx', LintConfig.parse(CONFIG)));
		Assert.equals(0, violationsOf('return [{ span: s, text: \'return x;\' }];', '', 'test/T.hx').length);
	}

	public function testTheIdentityDoesNotMoveWithTheLine(): Void {
		final body: String = 'return [{ span: s, text: \'return $$v;\' }];';
		final before: Null<FindingData> = violationsOf(body)[0].data;
		final after: Null<FindingData> = violationsOf('\n\n$body')[0].data;
		Assert.notNull(before);
		Assert.equals(before?.member, after?.member);
		Assert.equals(before?.subject, after?.subject);
		Assert.equals('T.f', before?.member);
	}

	@:pin('control')
	@:killer('M-FIX-TEXT-SYNTAX-FINAL-CLASS-NAMELESS')
	public function testAFinalClassNamesItsTypeInTheIdentity(): Void {
		final literal: String = 'return [{ span: s, text: \'return $$v;\' }];';
		final source: String = 'final class T {\n\tfunction f() {\n\t\t$literal\n\t}\n\tfunction h(): String { return \'final x = 1;\'; }\n'
			+ '\tfunction g() {\n\t\treturn [{ span: s, text: h() }];\n\t}\n}\n';
		final found: Array<Violation> = CheckFixture.violationsIn(
			new FixTextSyntax(), [{ file: 'src/T.hx', source: source }], null, _ -> LintConfig.parse(CONFIG)
		);
		final members: Array<Null<String>> = found.map(v -> v.data?.member);
		Assert.isTrue(members.contains('T.f'));
		Assert.isTrue(members.contains('T.h'));
		Assert.equals(2, found.length);
	}

	@:pin('control')
	@:killer('M-FIX-TEXT-SYNTAX-BASELINE-UNREAD')
	public function testASiteTheBaselineRecordsIsNotReportedAgainButANewOneIs(): Void {
		final body: String = 'return [{ span: s, text: \'return $$v;\' }];';
		final trees: ConfigTrees = new ConfigTrees('fix-text-syntax');
		final snapshot: String = trees.make('baseline') + '/recorded.json';
		File.saveContent(snapshot, LintFormat.json(violationsOf(body), ['src/T.hx' => sourceOf(body, '')]));
		final config: String = '{"rules":{"fix-text-syntax":{"roots":["src"],"baseline":"$snapshot"}}}';
		Assert.equals(0, violationsOf(body, '', 'src/T.hx', config).length);
		Assert.equals(1, violationsOf('return [{ span: s, text: \'if (a) b;\' }];', '', 'src/T.hx', config).length);
		Assert.equals(
			1, violationsOf(body, '', 'src/T.hx', '{"rules":{"fix-text-syntax":{"roots":["src"],"baseline":"/missing.json"}}}').length
		);
		trees.removeAll();
	}

	/** The findings over a method `f` holding `body`, next to `extra` members, in `file`. */
	private function violationsOf(body: String, extra: String = '', file: String = 'src/T.hx', ?config: String): Array<Violation> {
		final text: String = config ?? CONFIG;
		return CheckFixture.violationsIn(
			new FixTextSyntax(),
			[{ file: file, source: sourceOf(body, extra) }],
			null, _ -> LintConfig.parse(text)
		);
	}

	private static function sourceOf(body: String, extra: String): String {
		return 'class T {\n\t$extra\n\tfunction f() {\n\t\t$body\n\t}\n}\n';
	}

}
