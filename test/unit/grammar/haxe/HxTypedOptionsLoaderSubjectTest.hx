package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.grammar.haxe.HxTypedOptionsRewrite;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `HxTypedOptionsRewrite` leaves a call whose loaded options are the subject of the test — read only by field — on its JSON
 * document and names its method, rewrites a call whose options reach a writer, and writes a `{}` document as the bare baseline.
 */
@:nullSafety(Strict)
final class HxTypedOptionsLoaderSubjectTest extends Test {

	private static final KIT: String = 'unit.grammar.haxe.HxWriteOptionsKit';
	private static final DOC: String = '\'{"emptyLines": {"afterPackage": 2}}\'';

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-NO-SUBJECT')
	public function testALoaderSubjectCallStaysOnItsDocumentAndIsNamed(): Void {
		final subjects: Array<String> = [];
		final text: String = rewritten(
			'\tfunction loads() {\n\t\tfinal opts = HaxeFormatConfigLoader.loadHxFormatJson($DOC);\n'
			+ '\t\tAssert.equals(2, opts.afterPackage);\n\t}\n',
			subjects
		);
		Assert.isTrue(text.contains('loadHxFormatJson'), text);
		Assert.isFalse(text.contains('forkWith'), text);
		Assert.same(['loader subject: loads'], subjects);
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-NO-SUBJECT')
	public function testAnInlineFieldReadIsASubject(): Void {
		final text: String = rewritten(
			'\tfunction loads() {\n\t\tAssert.equals(2, HaxeFormatConfigLoader.loadHxFormatJson($DOC).afterPackage);\n\t}\n', []
		);
		Assert.isFalse(text.contains('forkWith'), text);
	}

	@:pin('guard')
	public function testAWriterCallIsRewritten(): Void {
		final subjects: Array<String> = [];
		final text: String = rewritten(
			'\tfunction writes() {\n\t\tfinal opts = HaxeFormatConfigLoader.loadHxFormatJson($DOC);\n\t\tw(opts);\n\t}\n', subjects
		);
		Assert.isTrue(text.contains('forkWith(edited -> edited.afterPackage = 2)'), text);
		Assert.same([], subjects);
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-NO-SUBJECT')
	public function testAMixedMethodRewritesOnlyItsWriterCalls(): Void {
		final text: String = rewritten(
			'\tfunction both() {\n\t\tfinal a = HaxeFormatConfigLoader.loadHxFormatJson($DOC);\n\t\tAssert.equals(2, a.afterPackage);\n'
			+ '\t\tfinal b = HaxeFormatConfigLoader.loadHxFormatJson($DOC);\n\t\tw(b);\n\t}\n',
			[]
		);
		Assert.isTrue(text.contains('final a = HaxeFormatConfigLoader.loadHxFormatJson('), text);
		Assert.isTrue(text.contains('final b = HxWriteOptionsKit.forkWith(edited -> edited.afterPackage = 2)'), text);
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-EMPTY-FORK')
	public function testAnEmptyDocumentIsTheBareBaseline(): Void {
		final text: String = rewritten(
			'\tfunction writes() {\n\t\tfinal opts = HxWriteOptionsKit.strictJson(\'{}\');\n\t\tw(opts);\n\t}\n', []
		);
		Assert.isFalse(text.contains('edited -> {}'), text);
		Assert.isTrue(text.contains("HaxeFormatConfigLoader.loadHxFormatJson('{}')"), text);
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-ASSERT-SUBJECT')
	public function testAFieldReadUnderAnAssertionIsASubjectEvenWhenAWriterGetsTheOptions(): Void {
		final subjects: Array<String> = [];
		final text: String = rewritten(
			'\tfunction both() {\n\t\tfinal opts = HaxeFormatConfigLoader.loadHxFormatJson($DOC);\n'
			+ '\t\tAssert.equals(2, opts.afterPackage);\n\t\tw(opts);\n\t}\n',
			subjects
		);
		Assert.isFalse(text.contains('forkWith'), text);
		Assert.same(['loader subject: both'], subjects);
	}

	@:pin('guard')
	public function testAFieldReadOutsideAnAssertionLeavesAWriterCallRewritten(): Void {
		final subjects: Array<String> = [];
		final text: String = rewritten(
			'\tfunction both() {\n\t\tfinal opts = HaxeFormatConfigLoader.loadHxFormatJson($DOC);\n'
			+ '\t\tfinal shown = opts.afterPackage;\n\t\tw(opts);\n\t}\n',
			subjects
		);
		Assert.isTrue(text.contains('forkWith(edited -> edited.afterPackage = 2)'), text);
		Assert.same([], subjects);
	}

	/** A module of the kit's package whose class `S` holds `members`, rewritten; a refusal is a failure. */
	private static function rewritten(members: String, subjects: Array<String>): String {
		final src: String = 'package unit.grammar.haxe;\n\nimport utest.Assert;\n\nfinal class S {\n\n$members\n}\n';
		return switch HxTypedOptionsRewrite.rewrite(src, KIT, true, new HaxeQueryPlugin(), null, subjects) {
			case Ok(t, _): t;
			case Err(message):
				Assert.fail(message);
				'';
		};
	}

}
