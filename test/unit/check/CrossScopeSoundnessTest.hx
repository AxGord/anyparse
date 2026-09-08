package unit.check;

import anyparse.check.Check.CrossFileFix;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * ONE fixture for the whole class of defect S177, S179 and S180 found one call site at a time: a
 * check that asks the REPORT-scope index a question only the RESOLUTION scope can answer, and
 * reads "not found in the files this run was given" as "does not exist".
 *
 * The shape is always the same and is exactly what `hxq patch <one file> --write --fix` runs: the
 * report scope is ONE file, the project declares `resolutionRoots`, and a second file reaches into
 * the first by a route no single-file analysis can see — an `@:access` grant, an `@:allow` grant,
 * a subtype, a reflection call naming the member. Every previously found site licensed a REWRITE
 * that way: `unused-private` called a live member dead (S177), `unused-parameter` deleted a
 * parameter a cross-file caller still passes (S179), `naming` renamed a field and orphaned an
 * `@:access` grantee (S179), and `naming` renamed a field a reflection call in another file reads
 * by name (S180).
 *
 * So the assertion is differential rather than per-rule, and it runs over `Linter.builtins()` —
 * the roster itself, so a new check joins it by being registered: for every cell, whatever the
 * NARROW-report run writes into the declaring file, the WIDE-report run over the same two files
 * must write too. An edit only the narrow run produces is an edit licensed by a file the run could
 * not see, which is the defect in its writing form. The sibling assertion covers the reporting
 * form: a `CrossFileFix` may only name files the report scope holds.
 *
 * `KNOWN_DIVERGENCES` is the escape hatch and it is EMPTY by contract. A line there is a filed
 * defect with an address, never a way to keep this green.
 *
 * A THIRD arm asks what those four repairs never did: what a project that declares `resolutionLibs`
 * and no `resolutionRoots` gets. The scope is still DECLARED and it holds an installed library, but
 * not one file of the project's own — the key fills `projectRoots` AND joins the library half, so
 * without it the widened index and the reflection scan are BOTH starved.
 * `LIBS_ONLY_REGRESSIONS` is what that costs over the same cells, and there the mitigation is a
 * sentence rather than soundness: source roots nobody declared cannot be invented, so the tool says so
 * out loud (`ConfigDisagreement.warnMissingProjectRoots`).
 */
class CrossScopeSoundnessTest extends Test {

	/** The declaring file — the only one in the report scope of the narrow arm. */
	private static inline final DECL_FILE: String = 'pkg/A.hx';

	/** The reaching file — outside the report scope of the narrow arm, inside its resolution scope. */
	private static inline final REACH_FILE: String = 'pkg/B.hx';

	/** The one file a `resolutionLibs`-only scope holds: installed, third-party, and no relation to the project. */
	private static inline final LIB_FILE: String = 'lib/third/Third.hx';

	/** A declaration file whose private members are also read WITHIN it. */
	private static final A_USED: String = 'package pkg;\n\nclass A {\n\n\tprivate var My_Field: Int = 0;\n\n'
		+ '\tpublic function new() {}\n\n\tpublic function read(): Int {\n\t\treturn My_Field + helper(1, 2);\n\t}\n\n'
		+ '\tprivate function helper(a: Int, b: Int): Int {\n\t\treturn a;\n\t}\n\n}\n';

	/** The same declarations with NO in-file read — the `unused-private` / `unused-parameter` shape. */
	private static final A_UNUSED: String = 'package pkg;\n\nclass A {\n\n\tprivate var My_Field: Int = 0;\n\n'
		+ '\tpublic function new() {}\n\n\tprivate function helper(a: Int, b: Int): Int {\n\t\treturn a;\n\t}\n\n}\n';

	/** `A_USED` granting its private members to `B` from its own header. */
	private static final A_ALLOW: String = 'package pkg;\n\n@:allow(pkg.B)\nclass A {\n\n\tprivate var My_Field: Int = 0;\n\n'
		+ '\tpublic function new() {}\n\n\tpublic function read(): Int {\n\t\treturn My_Field + helper(1, 2);\n\t}\n\n'
		+ '\tprivate function helper(a: Int, b: Int): Int {\n\t\treturn a;\n\t}\n\n}\n';

	/** The reacher that takes the access by `@:access` on itself. */
	private static final B_ACCESS: String = 'package pkg;\n\n@:access(pkg.A)\nclass B {\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function reach(a: A): Int {\n\t\treturn a.My_Field + a.helper(3, 4);\n\t}\n\n}\n';

	/** The reacher that inherits the access — a Haxe `private` member is visible to a subtype. */
	private static final B_SUBTYPE: String = 'package pkg;\n\nclass B extends A {\n\n\tpublic function new() {\n\t\tsuper();\n\t}\n\n'
		+ '\tpublic function reach(): Int {\n\t\treturn My_Field + helper(3, 4);\n\t}\n\n}\n';

	/** The reacher whose access comes from the DECLARING file's `@:allow`, so nothing in B says so. */
	private static final B_PLAIN: String = 'package pkg;\n\nclass B {\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function reach(a: A): Int {\n\t\treturn a.My_Field + a.helper(3, 4);\n\t}\n\n}\n';

	/** The reacher that names the member as a STRING inside a reflection call. */
	private static final B_REFLECT: String = 'package pkg;\n\nclass B {\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function reach(a: A): Dynamic {\n\t\treturn Reflect.field(a, \'My_Field\');\n\t}\n\n}\n';

	/** A haxelib source — what `resolutionLibs` alone puts in the scope, and it reaches nothing of the project. */
	private static final LIB_THIRD_PARTY: String = 'package third;\n\nclass Third {\n\n\tpublic function new() {}\n\n}\n';

	/** The two-file cells: one per route by which the second file reaches the first. */
	private static final CELLS: Array<Cell> = [
		{ name: 'access-grant', decl: A_USED, grantee: B_ACCESS },
		{ name: 'subtype', decl: A_USED, grantee: B_SUBTYPE },
		{ name: 'allow-grant', decl: A_ALLOW, grantee: B_PLAIN },
		{ name: 'reflection', decl: A_USED, grantee: B_REFLECT },
		{ name: 'access-grant-unread-in-file', decl: A_UNUSED, grantee: B_ACCESS },
		{ name: 'reflection-unread-in-file', decl: A_UNUSED, grantee: B_REFLECT }
	];

	/**
	 * The `<rule>@<cell>` pairs whose narrow-report `fix` writes an edit the wide-report run does
	 * not. EMPTY is the contract; a line here is a filed defect with an address, never a way to
	 * keep this test green.
	 */
	private static final KNOWN_EDIT_DIVERGENCES: Array<String> = [];

	/** The same list for the REPORTING form of the defect. Empty by the same contract. */
	private static final KNOWN_REPORT_DIVERGENCES: Array<String> = [];

	/**
	 * What a project declaring `resolutionLibs` and NO `resolutionRoots` loses — MEASURED, and the one
	 * list in this class that is not empty by contract.
	 *
	 * Fourteen entries over the six cells: `naming` renames a field five of the six routes reach,
	 * `unused-parameter` deletes a parameter three cross-file callers still pass, `unused-private` deletes
	 * two live members. Ten are WRITES and four are findings, which is the same defect one step earlier.
	 * Every one of them is a repair S177 / S179 / S180 shipped and this scope shape undoes. One cell is
	 * absent by right: `allow-grant` puts the `@:allow` in the DECLARING file, so the narrow report scope
	 * sees the grant without help and both arms refuse alike.
	 */
	private static final LIBS_ONLY_REGRESSIONS: Array<String> = [
		'edit:naming@access-grant',
		'edit:naming@access-grant-unread-in-file',
		'edit:naming@reflection',
		'edit:naming@reflection-unread-in-file',
		'edit:naming@subtype',
		'edit:unused-parameter@access-grant',
		'edit:unused-parameter@access-grant-unread-in-file',
		'edit:unused-parameter@subtype',
		'edit:unused-private@access-grant-unread-in-file',
		'edit:unused-private@reflection-unread-in-file',
		'report:unused-parameter@access-grant',
		'report:unused-parameter@access-grant-unread-in-file',
		'report:unused-parameter@subtype',
		'report:unused-private@access-grant-unread-in-file'
	];

	/** No check writes into the declaring file an edit the same two files, both reported, refuse. */
	@:pin('control')
	@:killer('M-REFLECTION-REPORT-INDEX-DELETE')
	public function testNarrowReportWritesNothingTheWideRunRefuses(): Void {
		Assert.equals(KNOWN_EDIT_DIVERGENCES.join('\n'), narrowOnlyEdits().join('\n'));
	}

	/** No check REPORTS on the declaring file a finding the same two files, both reported, do not. */
	@:pin('control')
	@:killer('M-CONFINEMENT-REPORT-INDEX-DEAD')
	public function testNarrowReportFindsNothingTheWideRunDoesNot(): Void {
		Assert.equals(KNOWN_REPORT_DIVERGENCES.join('\n'), narrowOnlyFindings().join('\n'));
	}

	/**
	 * A cross-file autofix may only name files the report scope holds.
	 *
	 * Reported over BOTH files on purpose. Handed the declaring file ALONE this seam is
	 * UNREACHABLE: `crossFileFix` then gets an index over one file, no cross-file occurrence is
	 * expressible, and every `CrossFileFix` check returns an empty list — measured at 0 slices on
	 * all six cells AND under each of the four declared arm cuts, so the containment assertion
	 * never executed and the test could not fail. The slice counter is what stops that returning.
	 */
	public function testCrossFileEditsNameOnlyReportedFiles(): Void {
		final reportFiles: Array<String> = [DECL_FILE, REACH_FILE];
		var slices: Int = 0;
		for (cell in CELLS) {
			final report: Array<SourceFile> = [
				{ file: DECL_FILE, source: cell.decl },
				{ file: REACH_FILE, source: cell.grantee }
			];
			final plugin: CachingGrammarPlugin = scoped(report, []);
			final index: SymbolIndex = SymbolIndex.build(report, plugin);
			for (check in Linter.builtins()) {
				final cross: Null<CrossFileFix> = check is CrossFileFix ? cast check : null;
				if (cross == null) continue;
				for (rename in cross.crossFileFix(report, check.run(report, plugin), plugin, index)) for (slice in rename) {
					slices++;
					Assert.isTrue(
						reportFiles.contains(slice.file), '${check.id()}@${cell.name} names ${slice.file}, outside the report scope'
					);
				}
			}
		}
		Assert.isTrue(slices > 0, 'no CrossFileFix produced an edit on this fixture — the containment assertion would guard nothing');
	}

	/**
	 * The fixture is not inert, in both dimensions the two differentials read.
	 *
	 * A differential over two runs that produce NOTHING is green for the wrong reason, and both
	 * assertions above compare a list against an empty one — the exact shape that rots into a
	 * tautology unnoticed. The three rules named here are the ones that DELETE or REWRITE a member
	 * on cross-file reachability evidence, which is the family the whole fixture exists for; a name
	 * dropping out is a coverage regression to look at, never a line to delete.
	 */
	public function testFixtureExercisesTheWritingRules(): Void {
		final exercised: Array<String> = narrowRulesEmittingEdits();
		for (rule in ['unused-parameter', 'unused-private', 'unused-public-member'])
			Assert.isTrue(exercised.contains(rule), '$rule writes nothing on this fixture any more — the differential is going vacuous');
		Assert.isTrue(exercised.length >= 5, 'only ${exercised.length} rule(s) write in the NARROW arm of this fixture');
		// `naming` can never appear above: on a green tree it REFUSES, and what it does emit leaves
		// through `crossFileFix` rather than `fix`. Yet `naming@` is where four of the five arm kills
		// land, so its non-vacuity is asserted on the REPORTING side, where the flag IS observable —
		// and per cell, so reordering `CELLS` cannot quietly re-point this at a different fixture.
		for (cell in CELLS) {
			final keys: Array<String> = findingKeys([{ file: DECL_FILE, source: cell.decl }], [{ file: REACH_FILE, source: cell.grantee }]);
			Assert.isTrue(
				keys.length >= 5, '${cell.name}: only ${keys.length} finding(s) — the reporting differential has nothing to compare'
			);
			Assert.equals(1, keys.filter(k -> k.split('|')[0] == 'naming').length, '${cell.name}: naming must still flag the declaration');
		}
	}

	/**
	 * The Pony shape — `resolutionLibs` declared, `resolutionRoots` ABSENT — puts every proof S177,
	 * S179 and S180 widened back where it started.
	 *
	 * The key starves BOTH halves of the scope, and a one-variable matrix over this fixture says which
	 * half costs what: `projectRoots` empty with the sibling still in the library gives ONE divergence,
	 * the sibling gone from the library with `projectRoots` full gives THIRTEEN. So the reflection scan
	 * of `unused-private` is the one proof reading `RefactorSupport.resolutionProjectSourcesOf`
	 * (`projectRoots`, null when empty), and the other thirteen read the index `widestScopeIndex` hands
	 * back, which is `report ∪ library` — on a project declaring roots the library CONTAINS them
	 * (`LintCommand.resolutionThunk` concatenates), on a libs-only one it is haxelibs and the std and not
	 * one file of the project's own.
	 *
	 * So the list above is what `hxq lint <one file> --fix` writes there that the same command in this
	 * project refuses. It shrinks when the two arms CONVERGE, which is a repair in one direction and a
	 * regression of the roots-declared arm in the other — read a shrink together with the two differentials
	 * above, which go red for the second cause. A line APPEARING is a new site of the same defect. Until it
	 * is empty the mitigation is a sentence, not soundness — `ConfigDisagreement.warnMissingProjectRoots`.
	 */
	public function testALibsOnlyScopeLosesProofsTheRootsArmKeeps(): Void {
		Assert.equals(LIBS_ONLY_REGRESSIONS.join('\n'), libsOnlyExtras().join('\n'));
	}

	/**
	 * Every `<kind>:<rule>@<cell>` the LIBS-ONLY arm produces on the declaring file and the
	 * roots-declared arm does not — both kinds in one list, because the defect has both forms and the
	 * scope shape is what they share.
	 */
	private function libsOnlyExtras(): Array<String> {
		final out: Array<String> = [];
		for (cell in CELLS) {
			final report: Array<SourceFile> = [{ file: DECL_FILE, source: cell.decl }];
			final reach: Array<SourceFile> = [{ file: REACH_FILE, source: cell.grantee }];
			extraEdits(editsByRule(report, reach, cell.decl, false), editsByRule(report, reach, cell.decl), 'edit:', cell.name, out);
			extraFindings(findingKeys(report, reach, false), findingKeys(report, reach), 'report:', cell.name, out);
		}
		out.sort(Reflect.compare);
		return out;
	}

	/**
	 * Every rule with an edit in `some` that `every` does not also carry, appended to `out` as
	 * `<tag><rule>@<cell>`.
	 *
	 * The destination is a parameter because the three differentials in this class differ ONLY in
	 * which pair of arms they compare and how they tag the result — `libsOnlyExtras` collects both
	 * kinds into one list, the other two collect one kind each.
	 */
	private function extraEdits(
		some: Map<String, Array<String>>, every: Map<String, Array<String>>, tag: String, cell: String, out: Array<String>
	): Void {
		for (rule => edits in some) {
			final seen: Array<String> = every[rule] ?? [];
			for (edit in edits) if (!seen.contains(edit)) {
				final tagged: String = '$tag$rule@$cell';
				if (!out.contains(tagged)) out.push(tagged);
				break;
			}
		}
	}

	/** The same over finding KEYS, which carry a severity and an offset the tag drops. */
	private function extraFindings(some: Array<String>, every: Array<String>, tag: String, cell: String, out: Array<String>): Void {
		for (key in some) if (!every.contains(key)) {
			final tagged: String = '$tag${key.split('|')[0]}@$cell';
			if (!out.contains(tagged)) out.push(tagged);
		}
	}

	/** Every `<rule>@<cell>` whose narrow-report `fix` wrote an edit the wide-report run did not. */
	private function narrowOnlyEdits(): Array<String> {
		final out: Array<String> = [];
		for (cell in CELLS) {
			final report: Array<SourceFile> = [{ file: DECL_FILE, source: cell.decl }];
			final reach: Array<SourceFile> = [{ file: REACH_FILE, source: cell.grantee }];
			extraEdits(editsByRule(report, reach, cell.decl), editsByRule(report.concat(reach), [], cell.decl), '', cell.name, out);
		}
		out.sort(Reflect.compare);
		return out;
	}

	/**
	 * Every `<rule>@<cell>` whose narrow-report `run` REPORTS a finding on the declaring file that
	 * the wide-report run over the same two files does not — the same defect in its reporting form,
	 * one step before the writing one (`unused-private` called a live member dead that way in S177).
	 * A finding is keyed by rule, severity and start offset, so a message whose text merely re-renders
	 * is not a divergence.
	 */
	private function narrowOnlyFindings(): Array<String> {
		final out: Array<String> = [];
		for (cell in CELLS) {
			final report: Array<SourceFile> = [{ file: DECL_FILE, source: cell.decl }];
			final reach: Array<SourceFile> = [{ file: REACH_FILE, source: cell.grantee }];
			extraFindings(findingKeys(report, reach), findingKeys(report.concat(reach), []), '', cell.name, out);
		}
		out.sort(Reflect.compare);
		return out;
	}

	/** Every finding the roster reports on the declaring file, as `<rule>|<severity>|<from>`. */
	private function findingKeys(report: Array<SourceFile>, reach: Array<SourceFile>, declaredRoots: Bool = true): Array<String> {
		final plugin: CachingGrammarPlugin = scoped(report, reach, declaredRoots);
		return [
			for (check in Linter.builtins()) for (v in check.run(
				report, plugin
			)) if (v.file == DECL_FILE) '${v.rule}|${v.severity}|${v.span?.from}'
		];
	}

	/**
	 * Every rule that emitted at least one edit on the declaring file in the NARROW arm, over any
	 * cell — the narrow arm alone, because it is the side whose output the differential requires
	 * to be a subset, and a floor met by the wide arm would leave that subset trivially empty.
	 */
	private function narrowRulesEmittingEdits(): Array<String> {
		final out: Array<String> = [];
		for (cell in CELLS) {
			final report: Array<SourceFile> = [{ file: DECL_FILE, source: cell.decl }];
			final reach: Array<SourceFile> = [{ file: REACH_FILE, source: cell.grantee }];
			for (rule => edits in editsByRule(report, reach, cell.decl)) if (edits.length > 0 && !out.contains(rule)) out.push(rule);
		}
		out.sort(Reflect.compare);
		return out;
	}

	/** Each check's `fix` edits for the declaring file, keyed by rule id, each rendered `from:to:text`. */
	private function editsByRule(
		report: Array<SourceFile>, reach: Array<SourceFile>, declSource: String, declaredRoots: Bool = true
	): Map<String, Array<String>> {
		final plugin: CachingGrammarPlugin = scoped(report, reach, declaredRoots);
		final index: SymbolIndex = SymbolIndex.build(report, plugin);
		final out: Map<String, Array<String>> = [];
		for (check in Linter.builtins()) {
			final vs: Array<Violation> = check.run(report, plugin).filter(v -> v.file == DECL_FILE);
			if (vs.length == 0) continue;
			final edits: Array<{ span: Span, text: String }> = check.fix(declSource, vs, plugin, index);
			out[check.id()] = [for (edit in edits) '${edit.span.from}:${edit.span.to}:${edit.text}'];
		}
		return out;
	}

	/**
	 * The plugin `LintCommand` builds for a project that declares `resolutionRoots`: the scope is
	 * DECLARED, and the library half carries the root files the report scope does not hold.
	 *
	 * `declaredRoots` false is the OTHER shape a real config has — `resolutionLibs` declared and
	 * `resolutionRoots` absent — and it is not merely a narrower version of the first: the scope is still
	 * DECLARED, it just holds an installed library where the project's own sources should be. Both halves
	 * lose them at once, which is what one key filling both buys: `RefactorSupport.resolutionProjectSourcesOf`
	 * answers null on the empty `projectRoots`, and the index behind `widestScopeIndex` becomes the report
	 * files plus a haxelib. What that costs is `LIBS_ONLY_REGRESSIONS`. Flipping `declared` to false as
	 * well changes none of it — the pinned cost is equally the cost of declaring no resolution at all —
	 * so the arm is named for the config shape it models, not for a behaviour only it has.
	 */
	private function scoped(report: Array<SourceFile>, reach: Array<SourceFile>, declaredRoots: Bool = true): CachingGrammarPlugin {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final library: Array<SourceFile> = declaredRoots ? reach : [{ file: LIB_FILE, source: LIB_THIRD_PARTY }];
		final roots: Array<SourceFile> = declaredRoots ? reach : [];
		plugin.setResolutionScope({
			declared: true,
			sources: () -> {report: report, projectRoots: roots, library: new LibrarySources(library) }
		});
		return plugin;
	}

}

/** One two-file cell: the declaring source, the reaching source, and the route's name. */
private typedef Cell = {
	final name: String;
	final decl: String;
	final grantee: String;
};

/** One source a scope half holds. */
private typedef SourceFile = {
	var file: String;
	var source: String;
};
