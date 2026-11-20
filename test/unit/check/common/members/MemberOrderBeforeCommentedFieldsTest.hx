package unit.check.common.members;

import anyparse.check.LintConfig;
import anyparse.check.common.members.MemberOrder;
import haxe.io.Path;

/**
 * Under `emptyLines.beforeCommentedFields` the writer sets a member headed by line comments off by a blank line, and
 * `member-order` reads the same key: it asks that blank line and accepts the writer's output.
 */
@:nullSafety(Strict)
class MemberOrderBeforeCommentedFieldsTest extends Test {

	private static final ON: String = '{"emptyLines": {"beforeCommentedFields": 1}}';
	private static final VETOED: String =
		'{"emptyLines": {"beforeCommentedFields": 1, "metadataCountsAsDocComment": true, "beforeDocCommentEmptyLines": "none"}}';
	private static final SOURCE: String = 'class E {\n\tvar a:Int;\n\t// g\n\tvar b:Int;\n}\n';
	private static final VETOED_SOURCE: String = 'class E {\n\tvar a:Int;\n\t// g\n\t@:x\n\tvar b:Int;\n}\n';

	private final _trees: ConfigTrees = new ConfigTrees('apq-member-order-before-commented-fields-test');

	public function teardown(): Void {
		_trees.removeAll();
	}

	/** The glued source is reported under the key and accepted without it. */
	@:pin('control')
	@:killer('M-HEADING-MEMBER-GAP')
	public function testTheGluedSourceIsReportedOnlyUnderTheKey(): Void {
		Assert.equals(1, violations('tree-on', ON, SOURCE).length);
		Assert.equals(0, violations('tree-off', '{}', SOURCE).length);
	}

	@:pin('guard')
	public function testTheWritersOutputIsNotReported(): Void {
		final written: String = new HaxeQueryPlugin().writeRoundTrip(SOURCE, ON) ?? '';
		Assert.notEquals(SOURCE, written, 'the key sets the headed member off');
		Assert.equals(0, violations('tree', ON, written).length, written);
	}

	/** A headed member the doc veto keeps glued stays glued in the writer and is not reported. */
	@:pin('control')
	@:killer('M-HEADING-YIELDS-TO-VETO')
	public function testTheDocVetoOutranksTheHeading(): Void {
		Assert.equals(VETOED_SOURCE, new HaxeQueryPlugin().writeRoundTrip(VETOED_SOURCE, VETOED) ?? '');
		Assert.equals(0, violations('tree-veto', VETOED, VETOED_SOURCE).length);
	}

	private function violations(tree: String, format: String, src: String): Array<Violation> {
		final file: String = Path.join([_trees.withFormatConfig(tree, format), 'E.hx']);
		final cfg: LintConfig = LintConfig.parse('{}');
		return CheckFixture.violationsIn(new MemberOrder(), [{ file: file, source: src }], null, _ -> cfg);
	}

}
