package unit.check.common.imports;

import anyparse.check.Check;
import anyparse.check.common.imports.RedundantImport;
import anyparse.query.CanonicalEdit;

/**
 * `redundant-import` against statements the index cannot read. Haxe lets the LAST statement binding a name win, so
 * only a statement BETWEEN the module import and its sub-type import can make the sub-type import load-bearing: one
 * below it, or above the module import, wins or loses the same with and without it.
 */
@:nullSafety(Strict)
class RedundantImportOrderTest extends Test {

	private static final HEAD: String = 'package app;\n\nimport pkg.M;\nimport pkg.M.E;\n';
	private static final TAIL: String = '\nclass C {\n\n\tvar e:E = A;\n\n}\n';
	private static final MODULE: String = 'package pkg;\n\nclass M {}\n\nenum E {\n\tA;\n\tB;\n}\n';

	public function testUnresolvedUsingBelowTheSubTypeImportKeepsTheFinding(): Void {
		Assert.equals(1, violationsOf('${HEAD}using lib.Unknown;\n$TAIL').length);
	}

	public function testUnresolvedImportBelowTheSubTypeImportKeepsTheFinding(): Void {
		Assert.equals(1, violationsOf('${HEAD}import lib.Unknown;\n$TAIL').length);
	}

	public function testFixRemovesTheSubTypeImportAboveAnUnresolvedUsing(): Void {
		final src: String = '${HEAD}using lib.Unknown;\n$TAIL';
		final files: Array<{ file: String, source: String }> = fileSet(src);
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: RedundantImport = new RedundantImport();
		final fixed: String = CanonicalEdit.applyEdits(
			src, check.fix(src, CheckFixture.violationsIn(check, files, plugin), plugin, CheckFixture.index(files, plugin))
		);
		Assert.isFalse(fixed.contains('import pkg.M.E;'));
		Assert.isTrue(fixed.contains('import pkg.M;'));
		Assert.isTrue(fixed.contains('using lib.Unknown;'));
	}

	public function testUnresolvedUsingBetweenTheTwoKeepsTheSubTypeImport(): Void {
		final src: String = 'package app;\n\nimport pkg.M;\nusing lib.Unknown;\nimport pkg.M.E;\n$TAIL';
		Assert.equals(0, violationsOf(src).length);
	}

	public function testUnresolvedImportBetweenTheTwoKeepsTheSubTypeImport(): Void {
		final src: String = 'package app;\n\nimport pkg.M;\nimport lib.Unknown;\nimport pkg.M.E;\n$TAIL';
		Assert.equals(0, violationsOf(src).length);
	}

	/** Above the module import the unresolved statement loses to the module import for every name it shares. */
	public function testUnresolvedUsingAboveTheModuleImportKeepsTheFinding(): Void {
		final src: String = 'package app;\n\nusing lib.Unknown;\nimport pkg.M;\nimport pkg.M.E;\n$TAIL';
		Assert.equals(1, violationsOf(src).length);
	}

	/** A module import BELOW the sub-type import outranks it, so nothing between the two can matter. */
	public function testModuleImportBelowTheSubTypeImportIgnoresWhatSitsBetween(): Void {
		final src: String = 'package app;\n\nimport pkg.M.E;\nusing lib.Unknown;\nimport pkg.M;\n$TAIL';
		Assert.equals(1, violationsOf(src).length);
	}

	/** The window opens at the NEAREST module import: an unresolved using above the second one decides nothing. */
	public function testWindowOpensAtTheNearestModuleImport(): Void {
		final src: String = 'package app;\n\nimport pkg.M;\nusing lib.Unknown;\nimport pkg.M;\nimport pkg.M.E;\n$TAIL';
		final subType: Array<Violation> = violationsOf(src).filter(v -> v.message.contains('pkg.M.E'));
		Assert.equals(1, subType.length);
	}

	/** Above the import, an unresolved statement may declare the name the deletion would hand back to it. */
	public function testOwnPackageImportKeepsAnUnresolvedStatementAbove(): Void {
		// The typing layer reads the order and refuses beside any statement it cannot read, below the import too.
		final files: Array<{ file: String, source: String }> = [
			{ file: 'app/C.hx', source: 'package app;\n\nusing lib.Unknown;\nimport app.Helper;\n\nclass C {\n\n\tvar h:Helper;\n\n}\n' },
			{ file: 'app/Helper.hx', source: 'package app;\n\nclass Helper {}\n' }
		];
		Assert.equals(0, CheckFixture.violationsIn(new RedundantImport(), files).length);
	}

	private function violationsOf(src: String): Array<Violation> {
		return CheckFixture.violationsIn(new RedundantImport(), fileSet(src));
	}

	private function fileSet(src: String): Array<{ file: String, source: String }> {
		return [{ file: 'app/C.hx', source: src }, { file: 'pkg/M.hx', source: MODULE }];
	}

}
