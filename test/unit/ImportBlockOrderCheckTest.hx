package unit;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.ImportBlockOrder;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `import-order` check: a contiguous block of plain imports carrying NO recognisable order
 * is reported, and the autofix permutes its whole lines back into order. Covers the block
 * boundaries (blank line, `using` / wildcard / alias, block comment), the `order` option, the
 * refusals that keep a load-bearing order intact, and the comment pinning.
 */
class ImportBlockOrderCheckTest extends Test {

	/** The reported incident's shape: an ordered block with one import appended past its end. */
	private static inline final APPENDED: String = 'package app;\n\nimport app.base.Host;\nimport pkg.mid.events.Alpha;\n'
		+ 'import pkg.mid.SetBeta;\nimport util.Valid;\nimport app.deep.Mod.Widget;\n\nclass C {}\n';

	public function testAppendedImportFlagged(): Void {
		final vs: Array<Violation> = violations(APPENDED);
		Assert.equals(1, vs.length);
		Assert.equals('import-order', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.contains("'app.deep.Mod.Widget'"), 'names the out-of-place import: ${vs[0].message}');
	}

	public function testAppendedImportIsMovedIntoPlace(): Void {
		Assert.equals(
			'package app;\n\nimport app.base.Host;\nimport app.deep.Mod.Widget;\nimport pkg.mid.events.Alpha;\n'
			+ 'import pkg.mid.SetBeta;\nimport util.Valid;\n\nclass C {}\n',
			fixed(APPENDED)
		);
	}

	public function testFixOutputSurvivesTheWriter(): Void {
		switch RefactorSupport.canonicalize(APPENDED, edits(APPENDED), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('import app.base.Host;\nimport app.deep.Mod.Widget;\nimport pkg.mid.events.Alpha;') >= 0, text);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	public function testAsciiOrderedBlockNotFlagged(): Void {
		Assert.equals(0, violations('package app;\n\nimport a.Alpha;\nimport m.Middle;\nimport z.Zeta;\n\nclass C {}\n').length);
	}

	public function testCaseFoldedBlockNotFlagged(): Void {
		// `pkg.mid.events.Alpha` before `pkg.mid.SetBeta` is the order an IDE writes and a human
		// reads. Only codepoint order disagrees, so the default `any` must accept it.
		Assert.equals(0, violations('package app;\n\nimport pkg.mid.events.Alpha;\nimport pkg.mid.SetBeta;\n\nclass C {}\n').length);
	}

	public function testSingleImportNeverFlagged(): Void {
		Assert.equals(0, violations('package app;\n\nimport z.Zeta;\n\nclass C {}\n').length);
	}

	// --- the `order` option ---

	public function testAsciiOptionFlagsACaseFoldedBlock(): Void {
		final src: String = 'package app;\n\nimport pkg.mid.events.Alpha;\nimport pkg.mid.SetBeta;\n\nclass C {}\n';
		final config: String = '{"rules":{"import-order":{"order":"ascii"}}}';
		Assert.equals(1, violations(src, config).length);
		Assert.equals('package app;\n\nimport pkg.mid.SetBeta;\nimport pkg.mid.events.Alpha;\n\nclass C {}\n', fixed(src, config));
	}

	public function testCaseInsensitiveOptionFlagsAnAsciiBlock(): Void {
		final src: String = 'package app;\n\nimport a.Zeta;\nimport a.alpha.Beta;\n\nclass C {}\n';
		final config: String = '{"rules":{"import-order":{"order":"case-insensitive"}}}';
		Assert.equals(1, violations(src, config).length);
		Assert.equals('package app;\n\nimport a.alpha.Beta;\nimport a.Zeta;\n\nclass C {}\n', fixed(src, config));
	}

	// --- block boundaries ---

	public function testBlankLineGroupsAreOrderedIndependently(): Void {
		// Each group is ordered on its own; the concatenation is not, and must not be reported —
		// a project's visual grouping is not disorder.
		Assert.equals(
			0, violations('package app;\n\nimport z.Alpha;\nimport z.Zeta;\n\nimport a.Alpha;\nimport a.Beta;\n\nclass C {}\n').length
		);
	}

	public function testGroupsAreFixedWithoutBeingMerged(): Void {
		final src: String = 'package app;\n\nimport z.Zeta;\nimport z.Alpha;\n\nimport a.Beta;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(2, violations(src).length);
		Assert.equals('package app;\n\nimport z.Alpha;\nimport z.Zeta;\n\nimport a.Alpha;\nimport a.Beta;\n\nclass C {}\n', fixed(src));
	}

	public function testUsingSplitsTheBlockAndStaysPut(): Void {
		// A `using`'s POSITION ranks static-extension resolution, so it is never part of a run and
		// never moves — the two import runs around it are ordered separately.
		final src: String =
			'package app;\n\nimport z.Zeta;\nimport z.Alpha;\nusing ext.Tools;\nimport a.Beta;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(2, violations(src).length);
		Assert.equals(
			'package app;\n\nimport z.Alpha;\nimport z.Zeta;\nusing ext.Tools;\nimport a.Alpha;\nimport a.Beta;\n\nclass C {}\n',
			fixed(src)
		);
	}

	public function testWildcardSplitsTheBlock(): Void {
		Assert.equals(0, violations('package app;\n\nimport z.Zeta;\nimport other.*;\nimport a.Alpha;\n\nclass C {}\n').length);
	}

	public function testAliasSplitsTheBlock(): Void {
		Assert.equals(0, violations('package app;\n\nimport z.Zeta;\nimport other.Thing as T;\nimport a.Alpha;\n\nclass C {}\n').length);
	}

	public function testBlockCommentEndsTheRun(): Void {
		// Only whole-line `//` comments are pinned to an import; a block comment between two
		// imports ends the run rather than being moved by a reorder that cannot read it.
		Assert.equals(0, violations('package app;\n\nimport z.Zeta;\n/* group two */\nimport a.Alpha;\n\nclass C {}\n').length);
	}

	public function testGuardedImportsAreNotPartOfTheBlock(): Void {
		Assert.equals(
			0, violations('package app;\n\nimport z.Zeta;\n#if js\nimport js.Browser;\n#end\nimport a.Alpha;\n\nclass C {}\n').length
		);
	}

	// --- refusals: the order is load-bearing, or the lines are not separable ---

	public function testSameSimpleNameIsReportedButNotReordered(): Void {
		// Haxe accepts both and lets the LAST win, so their relative order decides what a bare
		// `Widget` means. Reporting is fine; permuting them is a silent rebind.
		final src: String = 'package app;\n\nimport z.Widget;\nimport a.Widget;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testDuplicatePathIsReportedButNotReordered(): Void {
		final src: String = 'package app;\n\nimport z.Zeta;\nimport a.Alpha;\nimport z.Zeta;\n\nclass C {}\n';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testTwoImportsOnOneLineAreNotReordered(): Void {
		final src: String = 'package app;\n\nimport z.Zeta; import a.Alpha;\nimport a.Beta;\n\nclass C {}\n';
		Assert.equals(0, edits(src).length);
	}

	// --- comment pinning ---

	public function testLineCommentTravelsWithItsImport(): Void {
		final src: String = 'package app;\n\nimport a.Alpha;\n// the widget\nimport z.Zeta;\nimport a.Beta;\n\nclass C {}\n';
		Assert.equals('package app;\n\nimport a.Alpha;\nimport a.Beta;\n// the widget\nimport z.Zeta;\n\nclass C {}\n', fixed(src));
	}

	public function testTrailingCommentTravelsWithItsImport(): Void {
		final src: String = 'package app;\n\nimport z.Zeta; // last alphabetically\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals('package app;\n\nimport a.Alpha;\nimport z.Zeta; // last alphabetically\n\nclass C {}\n', fixed(src));
	}

	// --- registration ---

	public function testRegisteredAndDefaultOff(): Void {
		final check: Null<anyparse.check.Check> = Linter.byId('import-order');
		Assert.notNull(check);
		Assert.isTrue(Std.isOfType(check, DefaultOff), 'import-order is opt-in');
		Assert.equals(113, Linter.builtins().length);
	}

	// --- helpers -------------------------------------------------------------------

	/** The check's findings for `src`, with `config` (raw `apqlint.json` text) in effect when given. */
	private function violations(src: String, ?config: String): Array<Violation> {
		final check: ImportBlockOrder = configured(config);
		return check.run([{ file: 'app/C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** The check's autofix edits for `src`, resolved against a single-file index. */
	private function edits(src: String, ?config: String): Array<{ span: Span, text: String }> {
		final files: Array<{ file: String, source: String }> = [{ file: 'app/C.hx', source: src }];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: ImportBlockOrder = configured(config);
		return check.fix(src, check.run(files, plugin), plugin, SymbolIndex.build(files, plugin));
	}

	/** `src` with the check's raw edits spliced in — the reorder verbatim, before any writer pass. */
	private function fixed(src: String, ?config: String): String {
		return RefactorSupport.applyEdits(src, edits(src, config));
	}

	/** A check carrying `config` (raw `apqlint.json` text) as its per-file resolver, or the default one. */
	private function configured(config: Null<String>): ImportBlockOrder {
		final check: ImportBlockOrder = new ImportBlockOrder();
		if (config != null) {
			final parsed: LintConfig = LintConfig.parse(config);
			check.setConfigResolver(file -> parsed);
		}
		return check;
	}

}
