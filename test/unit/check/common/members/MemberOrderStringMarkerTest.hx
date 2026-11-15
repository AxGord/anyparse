package unit.check.common.members;

import anyparse.check.LintConfig;
import anyparse.check.common.members.MemberOrder;

/** `member-order` reads a directive line's comment by the lexical regions, not by a marker scan. */
@:nullSafety(Strict)
final class MemberOrderStringMarkerTest extends Test {

	/** A `//` inside a string on a directive line is no comment: the block is not pinned and reorders. */
	@:pin('control')
	@:killer('M-HCM-E-MEMBERORDER-STRING')
	public function testDirectiveLineStringMarkerDoesNotPin(): Void {
		final src: String =
			'class C {\n\tpublic final a:S;\n\n\tprivate var p:Int = 0;\n\n\t#if (X == "//")\n\tpublic var g:Int = 0;\n\t#end\n}';
		final check: MemberOrder = new MemberOrder();
		check.setConfigResolver(_ -> LintConfig.parse('{}'));
		Assert.isTrue(
			CheckFixture.edits(check, src, new HaxeQueryPlugin()).length > 0, 'the string is no note, so the block reorders: $src'
		);
	}

}
