package unit;

import anyparse.check.Check;
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
 *
 * Plus the `using` WEDGE and its `usingAfterImports` opt-out: import runs a `using` group is
 * wedged between are ONE block, merged and sorted with the group moved below them — and the four
 * refusals that keep a merge from rebinding a name or misattributing a comment.
 */
class ImportBlockOrderCheckTest extends Test {

	/** The reported incident's shape: an ordered block with one import appended past its end. */
	private static inline final APPENDED: String = 'package app;\n\nimport app.base.Host;\nimport pkg.mid.events.Alpha;\n'
		+ 'import pkg.mid.SetBeta;\nimport util.Valid;\nimport app.deep.Mod.Widget;\n\nclass C {}\n';

	/**
	 * The WEDGE incident, verbatim from `TM/src/tests/unit/FileSystemSyncTest.hx`: a `#if`-guarded
	 * `#error` header, a wildcard import, a sorted run, a `using`, then a SECOND sorted run.
	 */
	private static inline final WEDGE: String = 'package tests.unit;\n\n#if !UNIT_TESTS\n#error "unit only"\n#end\n'
		+ 'import tink.unit.Assert.*;\nimport fs.DrillsFolderWatcher;\nimport fs.FSUtil;\nimport haxe.io.Path;\n\n'
		+ 'using tink.CoreApi;\n\nimport fs.FolderWatcher;\nimport haxe.Exception;\n\nclass C {}\n';

	/** The `usingAfterImports` opt-out — the pre-wedge reading, where a `using` is an immovable run boundary. */
	private static inline final KEEP_USING: String = '{"rules":{"import-order":{"usingAfterImports":false}}}';

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

	public function testUsingSplitsTheBlockAndStaysPutUnderTheOptOut(): Void {
		// `"usingAfterImports": false` restores the pre-wedge reading: a `using` is a run boundary
		// that never moves, and the two import runs around it are ordered separately.
		final src: String =
			'package app;\n\nimport z.Zeta;\nimport z.Alpha;\nusing ext.One;\nimport a.Beta;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(2, violations(src, KEEP_USING).length);
		Assert.equals(
			'package app;\n\nimport z.Alpha;\nimport z.Zeta;\nusing ext.One;\nimport a.Alpha;\nimport a.Beta;\n\nclass C {}\n',
			fixed(src, KEEP_USING)
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

	// --- the `using` wedge: runs separated by a `using` group are ONE block ---

	public function testWedgedUsingIsFlagged(): Void {
		final vs: Array<Violation> = violations(WEDGE);
		Assert.equals(1, vs.length);
		Assert.equals('import-order', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.contains("'tink.CoreApi'"), 'names the wedged using: ${vs[0].message}');
	}

	public function testWedgedUsingIsMovedBelowTheMergedBlock(): Void {
		// Both runs are ordered on their own, so nothing was reported before the wedge reading — the
		// file was a fixed point no rule repaired. The fix must also be its own fixed point.
		final expected: String = 'package tests.unit;\n\n#if !UNIT_TESTS\n#error "unit only"\n#end\nimport tink.unit.Assert.*;\n'
			+ 'import fs.DrillsFolderWatcher;\nimport fs.FSUtil;\nimport fs.FolderWatcher;\nimport haxe.Exception;\n'
			+ 'import haxe.io.Path;\n\nusing tink.CoreApi;\n\nclass C {}\n';
		Assert.equals(expected, fixed(WEDGE));
		Assert.equals(0, violations(expected).length, 'the fix converges in one pass');
	}

	public function testWedgeFixOutputSurvivesTheWriter(): Void {
		switch RefactorSupport.canonicalize(WEDGE, edits(WEDGE), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.contains('import haxe.io.Path;\n\nusing tink.CoreApi;'), text);
				Assert.isTrue(text.contains('import fs.FSUtil;\nimport fs.FolderWatcher;'), text);
			case Err(message):
				Assert.fail('wedge canonicalize Err: $message');
		}
	}

	public function testWedgeIsNotTouchedUnderTheOptOut(): Void {
		Assert.equals(0, violations(WEDGE, KEEP_USING).length);
		Assert.equals(WEDGE, fixed(WEDGE, KEEP_USING));
	}

	public function testSeveralWedgedUsingsKeepTheirRelativeOrder(): Void {
		// Haxe ranks static extensions in REVERSE declaration order, so the group may only move as a
		// whole. `ext.Two` before `ext.One` is the order the source carries and the order the output
		// must carry — a merge that SORTED the group would silently reverse the two extensions.
		final src: String = 'package app;\n\nimport z.Zeta;\nusing ext.Two;\nusing ext.One;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals('package app;\n\nimport a.Alpha;\nimport z.Zeta;\n\nusing ext.Two;\nusing ext.One;\n\nclass C {}\n', fixed(src));
	}

	public function testAChainedWedgeMergesEveryRunAtOnce(): Void {
		// run / using / run / using / run is ONE wedge carrying two `using` groups, not two wedges.
		final src: String =
			'package app;\n\nimport z.Zeta;\nusing ext.One;\nimport m.Mid;\nusing ext.Two;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(1, violations(src).length);
		Assert.equals(
			'package app;\n\nimport a.Alpha;\nimport m.Mid;\nimport z.Zeta;\n\nusing ext.One;\nusing ext.Two;\n\nclass C {}\n', fixed(src)
		);
	}

	public function testAMergedRunIsSortedByTheWedgeEditAlone(): Void {
		// Both runs are unordered AND wedged, so the file carries three findings — two per-run, one
		// wedge. Only the wedge's edit may be emitted: the per-run spans sit INSIDE its region, and
		// emitting both would hand the caller two overlapping edits over one range.
		final src: String = 'package app;\n\nimport z.Zeta;\nimport m.Mid;\nusing ext.One;\nimport b.Bee;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(3, violations(src).length);
		Assert.equals(1, edits(src).length);
		Assert.equals(
			'package app;\n\nimport a.Alpha;\nimport b.Bee;\nimport m.Mid;\nimport z.Zeta;\n\nusing ext.One;\n\nclass C {}\n', fixed(src)
		);
	}

	public function testAUsingOutsideEveryGapIsNotAWedge(): Void {
		// The blank-line GROUP is preserved: the file HAS a top-level `using`, but not between the
		// two runs, so no gap holds one and there is nothing to merge.
		final src: String =
			'package app;\n\nimport z.Alpha;\nimport z.Zeta;\n\nimport a.Alpha;\nimport a.Beta;\n\nusing ext.One;\n\nclass C {}\n';
		Assert.equals(0, violations(src).length);
	}

	public function testAWildcardBesideTheUsingBlocksTheMerge(): Void {
		// The gap must hold NOTHING but the `using` group: a wildcard binds names the ordering cannot
		// see, so the runs around it stay separate.
		Assert.equals(
			0, violations('package app;\n\nimport z.Zeta;\nusing ext.One;\nimport other.*;\nimport a.Alpha;\n\nclass C {}\n').length
		);
	}

	public function testAGuardedRegionBesideTheUsingBlocksTheMerge(): Void {
		final src: String =
			'package app;\n\nimport z.Zeta;\nusing ext.One;\n#if js\nimport js.Browser;\n#end\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(0, violations(src).length);
	}

	public function testAnUnliftableUsingRefusesEveryWedgeInTheFile(): Void {
		// Two `using` statements sharing a line cannot be moved as lines, so the file's `using` group
		// cannot be relocated intact — and a wedge LOWER in the file must not be repaired either.
		final src: String =
			'package app;\n\nusing ext.One; using ext.Two;\nimport z.Zeta;\nusing ext.Three;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(0, violations(src).length);
	}

	// --- wedge refusals: the merge is reported, the rewrite is not made ---

	public function testWedgeWithALeadingCommentOnTheBlockIsReportOnly(): Void {
		// Same refusal as the plain reorder: a comment above the block's FIRST import belongs to the
		// block, and the merge can neither carry it nor strand it.
		final src: String = 'package app;\n\n// third-party\nimport z.Zeta;\nusing ext.One;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testWedgeWithALeadingCommentOnAnInteriorRunIsReportOnly(): Void {
		// The SECOND run's head carries the label — which was a block head of its own until the merge
		// proposed to fold it in. Carrying `// second group` into the middle of the sorted block is
		// the same misattribution the first-line refusal exists to stop, one run down.
		final src: String =
			'package app;\n\nimport z.Zeta;\nusing ext.One;\n// second group\nimport a.Alpha;\nimport a.Beta;\n\nclass C {}\n';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testTwoMergedRunsBindingOneSimpleNameIsReportOnly(): Void {
		// The refusal only a MERGE can trip: `z.Alpha` and `a.Alpha` never shared a run, so no
		// per-run reorder could ever have compared them. Folding them into one block would let the
		// sort decide which declaration a bare `Alpha` means.
		final src: String =
			'package app;\n\nimport z.Zeta;\nimport z.Alpha;\nusing ext.One;\nimport a.Beta;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(3, violations(src).length);
		Assert.equals(
			'package app;\n\nimport z.Alpha;\nimport z.Zeta;\nusing ext.One;\nimport a.Alpha;\nimport a.Beta;\n\nclass C {}\n', fixed(src),
			'the merge is refused, so each run is still reordered on its own'
		);
	}

	public function testAUsingOfAnUnknownModuleIsReportOnly(): Void {
		// `mystery.Facade` is in no index the run can see, so what it declares is UNKNOWN — and the
		// last-segment fallback would answer "binds only `Facade`, no collision" on no evidence.
		// Exactly the shape a multi-type facade module has, so the merge refuses until the project
		// declares the library.
		final src: String = 'package app;\n\nimport z.Zeta;\nusing mystery.Facade;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testUsingOvertakingAnImportItShadowsIsReportOnly(): Void {
		// `using ext.Shadow` declares a SECONDARY `Alpha` and currently loses that name to the import
		// BELOW it; moving it past that import would silently rebind the name.
		final src: String = 'package app;\n\nimport z.Zeta;\nusing ext.Shadow;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
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
		final printer: TypeRefPrinter = TypeRefPrinter.forFile(src, plugin.parseFile(src), plugin.importMap(src), plugin);
		printer.print('app.deep.Mod.Widget');
		final inserted: String = RefactorSupport.applyEdits(src, printer.pendingImportEdits());
		Assert.equals(0, violations(inserted).length, 'the insert seat and the rule agree:\n$inserted');
	}

	public function testAnInsertIntoARunSplitFileSatisfiesTheRuleUnderTheOptOut(): Void {
		// The two-wave incident, as the acceptance for the RUN model. A `using` splits the imports
		// into two runs, each sorted, their concatenation not — read as one list the file looks
		// unordered, the fresh import is appended past the file's last import, and THIS rule then
		// reports the line the inserter had just placed. One shared run model, zero waves.
		// Read under the `usingAfterImports` opt-out, which is where the run model alone decides the
		// verdict: with the wedge merge on, the shape is a finding in its own right (see
		// `testWedgedUsingIsFlagged`) and would mask what this acceptance is about.
		final src: String = 'package app;\n\nimport a.Alpha;\nimport m.Mid;\nimport z.Zeta;\n'
			+ '\nusing ext.One;\n\nimport b.Bee;\nimport c.Cee;\n\nclass C {}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.equals(0, violations(src, KEEP_USING).length, 'the shape starts clean');
		final printer: TypeRefPrinter = TypeRefPrinter.forFile(src, plugin.parseFile(src), plugin.importMap(src), plugin);
		printer.print('a.Aaa');
		final inserted: String = RefactorSupport.applyEdits(src, printer.pendingImportEdits());
		Assert.equals(0, violations(inserted, KEEP_USING).length, 'the insert seat and the rule agree:\n$inserted');
	}

	public function testAnInsertIntoARunSplitFileAddsNoOrderFinding(): Void {
		// The same acceptance under the SHIPPED default. The wedge finding is there before and after
		// — what the seat must not do is add a SECOND one by dropping its line in the wrong run.
		final src: String = 'package app;\n\nimport a.Alpha;\nimport m.Mid;\nimport z.Zeta;\n'
			+ '\nusing ext.One;\n\nimport b.Bee;\nimport c.Cee;\n\nclass C {}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final printer: TypeRefPrinter = TypeRefPrinter.forFile(src, plugin.parseFile(src), plugin.importMap(src), plugin);
		printer.print('a.Aaa');
		final inserted: String = RefactorSupport.applyEdits(src, printer.pendingImportEdits());
		final after: Array<Violation> = violations(inserted);
		Assert.equals(1, after.length, 'no finding beyond the wedge the shape already carried:\n$inserted');
		Assert.isTrue(after[0].message.contains('splits the import block'), after[0].message);
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
		Assert.equals(165, Linter.builtins().length);
	}

	/**
	 * A module whose WHOLE body is `#if`-guarded carries its import block inside the region, and the
	 * rule judges it there. Read at the top level only the file offers no block at all, so the same
	 * disorder that is a finding one line higher goes unreported — the gap that let an inserting
	 * fixer's own line stand unflagged.
	 */
	public function testGuardedBlockIsJudged(): Void {
		final source: String = 'package app;\n\n#if DEBUG\nimport z.Zed;\nimport a.Al;\nimport m.Mid;\n\nclass C {}\n#end\n';
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.equals('import-order', vs[0].rule);
	}

	/** The guarded block's autofix sorts it in place, inside the region. */
	public function testGuardedBlockIsSortedInPlace(): Void {
		Assert.equals(
			'package app;\n\n#if DEBUG\nimport a.Al;\nimport m.Mid;\nimport z.Zed;\n\nclass C {}\n#end\n',
			fixed('package app;\n\n#if DEBUG\nimport z.Zed;\nimport a.Al;\nimport m.Mid;\n\nclass C {}\n#end\n')
		);
	}

	// --- helpers -------------------------------------------------------------------

	/**
	 * The scope `src` is read in: the file under test plus the stub library modules the `using`
	 * fixtures name. A wedge merge refuses a `using` whose module the index cannot see, so a
	 * fixture writing `using ext.One;` needs `ext/One.hx` to exist for the merge to be reachable at
	 * all — `mystery.Facade` is deliberately absent, which is what makes that refusal testable.
	 * `ext.Shadow` declares a SECONDARY `Alpha`, the collision the overtake refusal reads.
	 */
	private function scope(src: String): Array<{ file: String, source: String }> {
		return [
			{ file: 'app/C.hx', source: src },
			{ file: 'ext/One.hx', source: 'package ext;\n\nclass One {}\n' },
			{ file: 'ext/Two.hx', source: 'package ext;\n\nclass Two {}\n' },
			{ file: 'ext/Three.hx', source: 'package ext;\n\nclass Three {}\n' },
			{ file: 'ext/Shadow.hx', source: 'package ext;\n\nclass Shadow {}\n\nclass Alpha {}\n' },
			{ file: 'tink/CoreApi.hx', source: 'package tink;\n\nclass CoreApi {}\n' }
		];
	}

	/** The check's findings for `src`, with `config` (raw `apqlint.json` text) in effect when given. */
	private function violations(src: String, ?config: String): Array<Violation> {
		final check: ImportBlockOrder = configured(config);
		return check.run(scope(src), new HaxeQueryPlugin()).filter(v -> v.file == 'app/C.hx');
	}

	/** The check's autofix edits for `src`, resolved against the stub-library index. */
	private function edits(src: String, ?config: String): Array<{ span: Span, text: String }> {
		final files: Array<{ file: String, source: String }> = scope(src);
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: ImportBlockOrder = configured(config);
		final own: Array<Violation> = check.run(files, plugin).filter(v -> v.file == 'app/C.hx');
		return check.fix(src, own, plugin, SymbolIndex.build(files, plugin));
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
