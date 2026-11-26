package unit.check.common.members;

import anyparse.check.LintConfig;
import anyparse.check.common.members.MemberOrder;
import anyparse.check.common.members.MemberSpacing;
import anyparse.query.CanonicalEdit;
import haxe.io.Path;

/**
 * Under `emptyLines.metadataCountsAsDocComment` the writer treats a class member whose head carries metadata as
 * doc-led, so `member-order` must predict the blank lines `fmt` writes around it: a metadata member glued between
 * two plain ones is reported, and the writer's own output is not.
 */
@:nullSafety(Strict)
class MemberOrderMetadataAsDocTest extends Test {

	private static final METADATA_AS_DOC: String = '{"emptyLines": {"metadataCountsAsDocComment": true}}';
	private static final META_TIGHT: String = 'class C {\n\tprivate var a:Int;\n\t@:keep\n\tprivate var b:Int;\n\tprivate var c:Int;\n}\n';

	private final _trees: ConfigTrees = new ConfigTrees('apq-member-order-metadata-as-doc-test');

	public function teardown(): Void {
		_trees.removeAll();
	}

	/**
	 * The writer sets a metadata member off by a blank on each side, and the check reports the glued source and
	 * its fix lands the same blanks. Killed by `M-MEMBER-GAP-POLICY-META-UNREAD`, `M-MO-WRITER-META-UNREAD` and
	 * `M-MO-WRITER-META-UNREAD-PREV`.
	 */
	@:pin('control')
	@:killer('M-MEMBER-GAP-POLICY-META-UNREAD', 'M-MO-WRITER-META-UNREAD', 'M-MO-WRITER-META-UNREAD-PREV')
	public function testAMetadataMemberIsPredictedAsTheWriterSetsItOff(): Void {
		final written: String = new HaxeQueryPlugin().writeRoundTrip(META_TIGHT, METADATA_AS_DOC) ?? '';
		Assert.equals(1, blanksBetween(written, 'private var a:Int;', '@:keep'), written);
		Assert.equals(1, blanksBetween(written, 'private var b:Int;', 'private var c:Int;'), written);
		final file: String = Path.join([_trees.withFormatConfig('tree', METADATA_AS_DOC), 'C.hx']);
		Assert.equals(1, violations(file, META_TIGHT).length);
		Assert.equals(0, violations(file, written).length, 'the writer\'s own output is not reported');
		final raw: String = CanonicalEdit.applyEdits(
			META_TIGHT, CheckFixture.fixRun(new MemberOrder(), [{ file: file, source: META_TIGHT }], null, null, emptyConfig()).edits
		);
		Assert.equals(1, blanksBetween(raw, 'private var a:Int;', '@:keep'), raw);
		Assert.equals(1, blanksBetween(raw, 'private var b:Int;', 'private var c:Int;'), raw);
	}

	/** With the key off, the writer keeps a metadata member glued and so does the check. */
	public function testAMetadataMemberIsPlainWithTheKeyOff(): Void {
		final file: String = Path.join([_trees.withFormatConfig('tree-off', '{}'), 'C.hx']);
		Assert.equals(META_TIGHT, new HaxeQueryPlugin().writeRoundTrip(META_TIGHT, '{}') ?? '');
		Assert.equals(0, violations(file, META_TIGHT).length);
	}

	/**
	 * Metadata kept on its declaration's line leaves a plain member: the writer keeps a glued run tight under
	 * `lineEnds.metadataVar: none`, and the check reports none of its gaps.
	 */
	@:pin('control')
	@:killer('M-MO-META-OWN-LINE-UNREAD')
	public function testAGluedMetadataRunIsPlain(): Void {
		final json: String = '{"emptyLines": {"metadataCountsAsDocComment": true}, "lineEnds": {"metadataVar": "none"}}';
		final src: String = 'class C {\n\t@:auto public var a:Int;\n\t@:auto public var b:Int;\n\t@:auto public var c:Int;\n}\n';
		Assert.equals(src, new HaxeQueryPlugin().writeRoundTrip(src, json) ?? '');
		final file: String = Path.join([_trees.withFormatConfig('tree-glued', json), 'C.hx']);
		Assert.equals(0, violations(file, src).length);
	}

	/** An annotation on a line of its own above one glued to the declaration sets the member off, in the writer and the check alike. */
	@:pin('control')
	@:killer('M-MO-META-RUN-BREAK-UNREAD')
	public function testASplitMetadataRunIsDocLed(): Void {
		final json: String = '{"emptyLines": {"metadataCountsAsDocComment": true}, "lineEnds": {"metadataVar": "none"}}';
		final src: String = 'class C {\n\tprivate var a:Int;\n\t@:keep\n\t@:x private var b:Int;\n\tprivate var c:Int;\n}\n';
		final written: String = new HaxeQueryPlugin().writeRoundTrip(src, json) ?? '';
		Assert.equals(1, blanksBetween(written, 'private var a:Int;', '@:keep'), written);
		final file: String = Path.join([_trees.withFormatConfig('tree-split', json), 'C.hx']);
		Assert.isTrue(violations(file, src).length > 0);
		Assert.equals(0, violations(file, written).length, 'the writer\'s own output is not reported');
	}

	private function violations(file: String, src: String): Array<Violation> {
		return CheckFixture.violationsIn(new MemberOrder(), [{ file: file, source: src }], null, emptyConfig());
	}

	private static function emptyConfig(): (String) -> LintConfig {
		final cfg: LintConfig = LintConfig.parse('{}');
		return _ -> cfg;
	}

	private static function blanksBetween(text: String, before: String, after: String): Int {
		final from: Int = text.indexOf(before) + before.length;
		return MemberSpacing.blankLineCount(text.substring(from, text.indexOf(after, from)));
	}

}
