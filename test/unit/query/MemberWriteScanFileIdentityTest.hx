package unit.query;

import anyparse.check.SourceEntry;
import anyparse.query.MemberWriteScan;
import anyparse.query.SymbolIndex;

/**
 * The file a rewrite edits whole is told from another by its path: a copy of it holds the same text at another path, and its
 * subtype or `@:access` grantee reads the member where no edit of the declaring file reaches.
 */
class MemberWriteScanFileIdentityTest extends Test {

	private static final HOLDER: String = 'package use;\n\nclass Holder {\n\tprivate final marks: Map<String, Bool> = [];\n}\n';
	private static final SUBTYPE: String =
		'$HOLDER\nclass Sub extends Holder {\n\tpublic function also(c: String): Bool {\n\t\treturn marks.exists(c);\n\t}\n}\n';
	private static final GRANTEE: String = '$HOLDER\n@:access(use.Holder)\nclass Peek {\n\t// reads marks\n\tpublic function new() {}\n}\n';

	@:pin('control')
	@:killer('M-MWS-SUBTYPE-FILE-IDENTITY')
	public function testSubtypeInACopyOfTheApartFileStillMentionsTheMember(): Void {
		Assert.isTrue(subtypeMentions([copy('use/Holder.hx', SUBTYPE), copy('use/Copy.hx', SUBTYPE)]));
	}

	public function testSubtypeInTheApartFileAloneIsNotScanned(): Void {
		Assert.isFalse(subtypeMentions([copy('use/Holder.hx', SUBTYPE)]));
	}

	@:pin('control')
	@:killer('M-RSS-GRANT-FILE-IDENTITY')
	public function testGranteeInACopyOfTheApartFileStillMentionsTheMember(): Void {
		Assert.isTrue(granteeMentions([copy('use/Holder.hx', GRANTEE), copy('use/Copy.hx', GRANTEE)]));
	}

	public function testGranteeInTheApartFileAloneIsNotScanned(): Void {
		Assert.isFalse(granteeMentions([copy('use/Holder.hx', GRANTEE)]));
	}

	private static function copy(file: String, source: String): SourceEntry {
		return { file: file, source: source };
	}

	private static function subtypeMentions(files: Array<SourceEntry>): Bool {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return MemberWriteScan.subtypeMayReference('Holder', 'marks', SymbolIndex.build(files, plugin), plugin, 'use/Holder.hx');
	}

	private static function granteeMentions(files: Array<SourceEntry>): Bool {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return MemberWriteScan.accessGrantMayReference('Holder', 'marks', SymbolIndex.build(files, plugin), plugin, 'use/Holder.hx');
	}

}
