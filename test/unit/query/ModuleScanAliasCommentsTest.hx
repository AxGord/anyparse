package unit.query;

import anyparse.query.ModuleScan;

/**
 * An alias import's statement text is decoded with its comments blanked out, so a keyword or a path written inside a
 * comment can neither be taken for the alias keyword nor for the aliased path.
 */
class ModuleScanAliasCommentsTest extends Test {

	@:pin('control') @:killer('M-MODULESCAN-COMMENTS-KEPT')
	public function testBlockCommentBeforeTheKeywordIsNotDecoded(): Void {
		Assert.equals('a.b.C', ModuleScan.aliasTargetOf('import a.b.C /* z.W as */ as D;'));
	}

	@:pin('control') @:killer('M-MODULESCAN-COMMENTS-KEPT')
	public function testLineCommentBeforeTheKeywordIsNotDecoded(): Void {
		Assert.equals('a.b.C', ModuleScan.aliasTargetOf('import a.b.C // z.W as\n as D;'));
	}

	@:pin('control') @:killer('M-MODULESCAN-COMMENTS-KEPT')
	public function testUnterminatedBlockCommentRunsToTheEnd(): Void {
		Assert.equals('', ModuleScan.aliasTargetOf('import a.b.C /* z.W as'));
	}

	@:pin('guard')
	public function testAnAliasWithoutCommentsDecodes(): Void {
		Assert.equals('a.b.C', ModuleScan.aliasTargetOf('import a.b.C as D;'));
		Assert.equals('', ModuleScan.aliasTargetOf('import a.b.C;'));
	}

	@:pin('control') @:killer('M-FRAGMENT-REGIONS-STRING-BLIND')
	public function testSlashesInsideAStringLiteralAreNotAComment(): Void {
		Assert.equals('a.b.C', ModuleScan.aliasTargetOf('import a.b.C "//" as D;'));
		Assert.equals('a.b.C', ModuleScan.aliasTargetOf('import a.b.C \'/*\' as D;'));
	}

}
