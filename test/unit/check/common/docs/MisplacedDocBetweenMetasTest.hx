package unit.check.common.docs;

import anyparse.check.common.docs.MisplacedTypeDoc;
import anyparse.query.CanonicalEdit;

/**
 * A `/** … *\/` doc written between the metadata entries of one declaration is flagged by
 * `misplaced-type-doc`, and its fix moves the block before the first metadata entry.
 */
class MisplacedDocBetweenMetasTest extends Test {

	private static inline final BETWEEN: String = 'package p;\n\n@:keep\n/** Doc between metas. */\n@:native("X")\ntypedef A = {};\n';
	private static inline final BETWEEN_FIXED: String = 'package p;\n\n/** Doc between metas. */\n@:keep\n@:native("X")\ntypedef A = {};\n';
	private static inline final MEMBER: String =
		'package p;\n\nclass D {\n\t@:keep\n\t/** m */\n\t@:native("x")\n\tpublic var v: Int;\n}\n';
	private static inline final MEMBER_FIXED: String =
		'package p;\n\nclass D {\n\t/** m */\n\t@:keep\n\t@:native("x")\n\tpublic var v: Int;\n}\n';

	/** A doc above the run is the one the compiler keeps; the fix never drops either block. */
	private static inline final DOC_ABOVE: String =
		'package p;\n\n/** Above. */\n@:keep\n/** Between. */\n@:native("X")\ntypedef A = {};\n';

	@:pin('control')
	@:killer('M-BETWEEN-META-BLIND')
	public function testDocBetweenMetasFlagged(): Void {
		Assert.equals(1, CheckFixture.violations(new MisplacedTypeDoc(), BETWEEN).length);
	}

	@:pin('control')
	@:killer('M-BETWEEN-META-BLIND')
	public function testFixMovesDocBeforeMetaRun(): Void {
		Assert.equals(BETWEEN_FIXED, fixed(BETWEEN));
	}

	@:pin('control')
	@:killer('M-BETWEEN-META-TOPLEVEL-ONLY')
	public function testMemberDocBetweenMetasFlagged(): Void {
		Assert.equals(1, CheckFixture.violations(new MisplacedTypeDoc(), MEMBER).length);
	}

	@:pin('control')
	@:killer('M-BETWEEN-META-INDENT-LOST')
	public function testMemberFixKeepsIndentation(): Void {
		Assert.equals(MEMBER_FIXED, fixed(MEMBER));
	}

	@:pin('control')
	@:killer('M-BETWEEN-META-OVERWRITES-DOC')
	public function testDocAboveRunIsReportOnly(): Void {
		final vs: Array<Violation> = CheckFixture.violations(new MisplacedTypeDoc(), DOC_ABOVE);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('already has a doc above') >= 0, vs[0].message);
		Assert.equals(DOC_ABOVE, fixed(DOC_ABOVE));
	}

	public function testDocAboveRunIsNotFlagged(): Void {
		Assert.equals(0, CheckFixture.violations(new MisplacedTypeDoc(), BETWEEN_FIXED).length);
	}

	/** A typedef's fields live one level down, in its anonymous structure. */
	@:pin('control')
	@:killer('M-BETWEEN-META-TOPLEVEL-ONLY')
	public function testTypedefFieldDocBetweenMetasFlagged(): Void {
		Assert.equals(
			1,
			CheckFixture.violations(new MisplacedTypeDoc(), 'package p;\n\ntypedef T = {\n\t@:a\n\t/** d */\n\t@:b\n\tvar x: Int;\n}\n')
				.length
		);
	}

	/** A member inside a conditional region of a `final class` sits two containers down. */
	@:pin('control')
	@:killer('M-BETWEEN-META-COND-REGION')
	public function testConditionalMemberFlaggedAndFixed(): Void {
		final src: String = 'package p;\n\nfinal class F {\n\t#if js\n\t@:a\n\t/** d */\n\t@:b\n\tpublic var y: Int = 0;\n\t#end\n}\n';
		Assert.equals(1, CheckFixture.violations(new MisplacedTypeDoc(), src).length);
		Assert.equals(
			'package p;\n\nfinal class F {\n\t#if js\n\t/** d */\n\t@:a\n\t@:b\n\tpublic var y: Int = 0;\n\t#end\n}\n', fixed(src)
		);
	}

	/** Two blocks in one run: both reported, neither moved. */
	@:pin('control')
	@:killer('M-BETWEEN-META-TWO-BLOCKS')
	public function testTwoBlocksInOneRunAreReportOnly(): Void {
		final src: String = 'package p;\n\n@:a\n/** one */\n@:b\n/** two */\n@:c\ntypedef A = {};\n';
		final vs: Array<Violation> = CheckFixture.violations(new MisplacedTypeDoc(), src);
		Assert.equals(2, vs.length);
		Assert.isTrue(vs[0].message.indexOf('more than one doc block') >= 0, vs[0].message);
		Assert.equals(src, fixed(src));
	}

	/** A block sharing a line with a meta cannot move as whole lines, and the advice says why. */
	@:pin('control')
	@:killer('M-BETWEEN-META-SHARED-LINE')
	public function testSharedLineIsReportOnly(): Void {
		final src: String = 'package p;\n\n@:a /** inline */ @:b\ntypedef A = {};\n';
		final vs: Array<Violation> = CheckFixture.violations(new MisplacedTypeDoc(), src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('shares a line') >= 0, vs[0].message);
		Assert.equals(src, fixed(src));
	}

	/** A stranded package/import doc and a between-run doc on one type never land at the same anchor in one pass. */
	@:pin('control')
	@:killer('M-BETWEEN-META-STACKS')
	public function testStrandedAndBetweenDocsNeverStack(): Void {
		final src: String = 'package p;\n\n/** Stranded. */\nimport a.B;\n\n@:keep\n/** Between. */\n@:native("X")\nclass A {}\n';
		Assert.equals('package p;\n\nimport a.B;\n\n/** Stranded. */\n@:keep\n/** Between. */\n@:native("X")\nclass A {}\n', fixed(src));
	}

	private function fixed(src: String): String {
		return CanonicalEdit.applyEdits(src, CheckFixture.edits(new MisplacedTypeDoc(), src, new HaxeQueryPlugin()));
	}

}
