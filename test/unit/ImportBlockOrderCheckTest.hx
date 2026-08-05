package unit;

import anyparse.check.Check;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.ImportBlockOrder;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.TypeRefPrinter;
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

	public function testTwoImportsOnOneLineEndTheBlock(): Void {
		// Neither shared-line import is separable as a line, so the run ends at them and what
		// remains is a run of one — nothing to report, nothing to permute. Without the two
		// separability guards the shared line joins a block and the reorder DUPLICATES it.
		final src: String = 'package app;\n\nimport m.Mid; import q.Q;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(0, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testFirstImportWithALeadingCommentIsReportOnly(): Void {
		// A comment above the block's FIRST import belongs to the block, not to that import — a
		// header, a license banner, a `CHECKSTYLE:OFF` marker, a group label. Moving it into the
		// block's middle and stranding it above a different import are both wrong, so the finding
		// stays report-only.
		final src: String = 'package app;\n\n// group two\nimport z.Zeta;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testCommentTextInsideABlockCommentIsNotAbsorbed(): Void {
		// A `//`-looking line INSIDE a `/* … */` region is comment TEXT. Absorbing it into the
		// first import's movable chunk would both tear the region apart and trip the
		// leading-comment refusal, leaving the block unfixed.
		final src: String = 'package app;\n\nimport z.Zeta;\n/* note\n// still inside */\nimport a.Beta;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(
			'package app;\n\nimport z.Zeta;\n/* note\n// still inside */\nimport a.Alpha;\nimport a.Beta;\n\nclass C {}\n', fixed(src)
		);
	}

	public function testSameSecondaryTypeNameIsReportOnly(): Void {
		// Two MODULE imports whose modules each declare a same-named secondary type bind that name
		// twice, and Haxe lets the last win — the module paths alone do not reveal it, so the
		// refusal has to read the resolution index.
		final src: String = 'package app;\n\nimport two.ModB;\nimport one.ModA;\n\nclass C {}\n';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'app/C.hx', source: src },
			{ file: 'one/ModA.hx', source: 'package one;\n\nclass ModA {}\n\nclass Shared {}\n' },
			{ file: 'two/ModB.hx', source: 'package two;\n\nclass ModB {}\n\nclass Shared {}\n' }
		];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: ImportBlockOrder = new ImportBlockOrder();
		final vs: Array<Violation> = check.run(files, plugin).filter(v -> v.file == 'app/C.hx');
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, plugin, SymbolIndex.build(files, plugin)).length);
	}

	public function testAnInsertedImportSatisfiesTheRule(): Void {
		// The two halves of the feature must read a block the same way: an import the shared
		// `ImportOrder` seat places must not be a finding for the rule built on that same seat.
		final src: String = 'package app;\n\nimport app.base.Host;\nimport pkg.mid.events.Alpha;\nimport pkg.mid.SetBeta;\n\nclass C {}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final printer: TypeRefPrinter = TypeRefPrinter.forFile(src, plugin.parseFile(src), plugin.importMap(src));
		printer.print('app.deep.Mod.Widget');
		final inserted: String = RefactorSupport.applyEdits(src, printer.pendingImportEdits());
		Assert.equals(0, violations(inserted).length, 'the insert seat and the rule agree:\n$inserted');
	}

	public function testAnInsertIntoARunSplitFileSatisfiesTheRule(): Void {
		// The two-wave incident, as the acceptance for the RUN model. A `using` splits the imports
		// into two runs, each sorted, their concatenation not — read as one list the file looks
		// unordered, the fresh import is appended past the file's last import, and THIS rule then
		// reports the line the inserter had just placed. One shared run model, zero waves.
		final src: String = 'package app;\n\nimport a.Alpha;\nimport m.Mid;\nimport z.Zeta;\n'
			+ '\nusing ext.Tools;\n\nimport b.Bee;\nimport c.Cee;\n\nclass C {}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.equals(0, violations(src).length, 'the shape starts clean');
		final printer: TypeRefPrinter = TypeRefPrinter.forFile(src, plugin.parseFile(src), plugin.importMap(src));
		printer.print('a.Aaa');
		final inserted: String = RefactorSupport.applyEdits(src, printer.pendingImportEdits());
		Assert.equals(0, violations(inserted).length, 'the insert seat and the rule agree:\n$inserted');
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
		final check: Null<Check> = Linter.byId('import-order');
		Assert.notNull(check);
		Assert.isTrue(Std.isOfType(check, DefaultOff), 'import-order is opt-in');
		Assert.equals(133, Linter.builtins().length);
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
