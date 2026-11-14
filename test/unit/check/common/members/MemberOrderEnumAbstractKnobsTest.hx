package unit.check.common.members;

import anyparse.check.LintConfig;
import anyparse.check.common.members.MemberOrder;
import haxe.io.Path;

/**
 * An enum-abstract body reads the writer's `enumAbstractEmptyLines` knobs, so `member-order` must not report the
 * blank lines `fmt` writes there under `emptyLines.enumAbstractEmptyLines.metadataCountsAsDocComment`.
 */
@:nullSafety(Strict)
class MemberOrderEnumAbstractKnobsTest extends Test {

	private static final ENUM_ABSTRACT_META: String = '{"emptyLines": {"enumAbstractEmptyLines": {"metadataCountsAsDocComment": true}}}';
	private static final SOURCE: String = 'enum abstract E(Int) {\n\t@:meta\n\tvar A = 1;\n\tvar B = 2;\n}\n';

	private final _trees: ConfigTrees = new ConfigTrees('apq-member-order-enum-abstract-knobs-test');

	public function teardown(): Void {
		_trees.removeAll();
	}

	/**
	 * The writer sets the metadata member off by a blank, and its own output is not reported. Killed by
	 * `M-MEMBER-GAP-ENUM-ABSTRACT-UNREAD`.
	 */
	@:pin('control')
	@:killer('M-MEMBER-GAP-ENUM-ABSTRACT-UNREAD')
	public function testTheWritersEnumAbstractOutputIsNotReported(): Void {
		final written: String = new HaxeQueryPlugin().writeRoundTrip(SOURCE, ENUM_ABSTRACT_META) ?? '';
		Assert.notEquals(SOURCE, written, 'the knob sets the metadata member off');
		Assert.equals(0, violations('tree', ENUM_ABSTRACT_META, written).length, written);
	}

	/** The glued source is reported under the key, and is the writer's own output with the key off. */
	public function testTheGluedSourceIsReportedOnlyUnderTheKey(): Void {
		Assert.equals(1, violations('tree-on', ENUM_ABSTRACT_META, SOURCE).length);
		Assert.equals(SOURCE, new HaxeQueryPlugin().writeRoundTrip(SOURCE, '{}') ?? '');
		Assert.equals(0, violations('tree-off', '{}', SOURCE).length);
	}

	private function violations(tree: String, format: String, src: String): Array<Violation> {
		final file: String = Path.join([_trees.withFormatConfig(tree, format), 'E.hx']);
		final cfg: LintConfig = LintConfig.parse('{}');
		return CheckFixture.violationsIn(new MemberOrder(), [{ file: file, source: src }], null, _ -> cfg);
	}

}
