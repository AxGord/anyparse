package unit.check;

import anyparse.check.ConfigDisagreement;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.ReflectionScan;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.cli.command.LintCommand;
import haxe.io.Path;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * The SCOPE half of the reflection gate — the one input that decides whether a "nothing
 * reflects this name" answer is evidence or an artefact of how the lint was invoked.
 *
 * Five checks refuse a rewrite when a name could be spelled by a runtime `Reflect` /
 * `Type.resolveClass` call, and the refusal is only as wide as the strings
 * `ReflectionScan.reflectionSurface` was given. Two ways that set used to be narrower than
 * the project, both measured end to end before this class existed:
 *
 *  - the surface was the REPORT set alone, so a resolution scope the project declared over
 *    its own sources was invisible: `hxq lint <one-file> --fix` converted a type that
 *    `Type.resolveClass('pkg.Align')` in a sibling file reaches, oracle green, and the same
 *    call answered null afterwards;
 *  - `inline-constant` was missing from `Cli.partitionChecks`'s whole-scope list while the
 *    three siblings sharing its gate were on it, so from pass 2 the gate saw only the files
 *    an earlier pass had changed — a two-file fixture whose whole-set REPORT named ONE
 *    finding had the same command report `fixed 2 issue(s) over 3 pass(es)`.
 *
 * Both failures are SILENT: the rewrite compiles and breaks only when the code runs.
 *
 * A third way the set comes out narrower is not a defect in this wiring at all but a hole in a
 * project's own config, and unlike those two it has no repair: a scope declaring `resolutionLibs`
 * and no `resolutionRoots` is DECLARED and holds installed libraries only, so the surface is the
 * report set again while `hasDeclaredResolutionScope` answers yes. Roots nobody declared cannot be
 * invented, so the only honest move is to say so — which `testALibsOnlyScopeIsNamedAsAGap` pins,
 * and `CrossScopeSoundnessTest.LIBS_ONLY_REGRESSIONS` prices.
 */
@:nullSafety(Strict)
class LintScopeGateTest extends Test {

	/** A report file with no string literal of its own — the surface it produces is whatever the SCOPE adds. */
	private static inline final BARE_REPORT: String = 'package pkg;\n\nclass Align {\n\tpublic static inline final LEFT:Int = 0;\n}';

	/** A file OUTSIDE the report set whose literal is the only thing keeping `Align` alive at run time. */
	private static inline final RESOLVER: String =
		'package pkg;\n\nclass Use {\n\tpublic static function m():Dynamic {\n\t\treturn Type.resolveClass(\'pkg.Align\');\n\t}\n}';

	/** The same, spelled through interpolation — the half `literalOf` answers null for. */
	private static inline final INTERPOLATING: String =
		"package pkg;\n\nclass Use {\n\tpublic static function m(p:String):Dynamic {\n\t\treturn Reflect.field(this, '${p}Value');\n\t}\n}";

	public function new(): Void {
		super();
	}

	/** A qualified type path in a RESOLUTION-scope file reaches the type gate. */
	public function testResolutionScopeLiteralReachesTheTypeGate(): Void {
		final surface: ReflectionSurface = scoped(BARE_REPORT, [{ file: 'pkg/Use.hx', source: RESOLVER }]);
		Assert.isTrue(ReflectionScan.runtimeTypePath(surface.whole, 'Align'));
	}

	/**
	 * Control: the identical file OUTSIDE any scope is invisible, which is the defect this pins.
	 *
	 * It differs from its positive twin in ONE thing — whether a scope was injected. Reaching for a
	 * bare plugin instead would have varied the plugin TYPE as well, and then a pass would not say
	 * which of the two the answer came from.
	 */
	public function testTheSameLiteralOutsideAnyScopeIsInvisible(): Void {
		Assert.isFalse(ReflectionScan.runtimeTypePath(unscoped(BARE_REPORT).whole, 'Align'));
	}

	/** The interpolated half widens with the scope too — one scan, both questions. */
	public function testResolutionScopeFragmentReachesTheMemberGate(): Void {
		final surface: ReflectionSurface = scoped(BARE_REPORT, [{ file: 'pkg/Use.hx', source: INTERPOLATING }]);
		Assert.isTrue(ReflectionScan.runtimeNameFragment(surface.fragments, 'computeValue'));
	}

	/** Control for the fragment half: same plugin, same report file, no scope — no fragment. */
	public function testTheSameFragmentOutsideAnyScopeIsInvisible(): Void {
		Assert.isFalse(ReflectionScan.runtimeNameFragment(unscoped(BARE_REPORT).fragments, 'computeValue'));
	}

	/**
	 * The REPORT set is still scanned — the scope is a union, not a replacement.
	 *
	 * The literal lives ONLY in the report file and the injected scope names no report half of its
	 * own, so an implementation that read the resolution sources INSTEAD of the report set answers
	 * false here. With the scope's report half set to the report array, as it is under `Cli`, this
	 * assertion would hold for the replacement implementation too and would prove nothing.
	 */
	public function testReportFileIsStillScanned(): Void {
		final surface: ReflectionSurface = scoped(RESOLVER, [{ file: 'pkg/Other.hx', source: BARE_REPORT }]);
		Assert.isTrue(ReflectionScan.runtimeTypePath(surface.whole, 'Align'));
	}

	/**
	 * A file in BOTH halves is scanned once.
	 *
	 * Not a tidiness point: `inline-constant`'s `reflectedElsewhere` COUNTS occurrences in
	 * `whole` and subtracts the constant's own value, so a report file scanned twice doubles
	 * a self-named constant's own literal and turns `count > self` true on nothing at all.
	 */
	public function testAFileInBothHalvesIsScannedOnce(): Void {
		final report: Array<{ file: String, source: String }> = [{ file: 'pkg/Use.hx', source: RESOLVER }];
		final surface: ReflectionSurface = withScope(report, report, []);
		var seen: Int = 0;
		for (s in surface.whole) if (s == 'pkg.Align') seen++;
		Assert.equals(1, seen);
	}

	/**
	 * `inline-constant` runs over the FULL report set on every `--fix` pass, like the three
	 * siblings that share its reflection gate.
	 */
	public function testInlineConstantIsAWholeScopeRule(): Void {
		Assert.isTrue(fullScopeIds().contains('inline-constant'));
		Assert.isFalse(activeScopeIds().contains('inline-constant'));
	}

	/** Control: a rule whose whole verdict is same-file stays on the active subset, where it belongs. */
	public function testASameFileRuleStaysOnTheActiveSubset(): Void {
		Assert.isTrue(activeScopeIds().contains('redundant-parens'));
		Assert.isFalse(fullScopeIds().contains('redundant-parens'));
	}

	/**
	 * The third scope shape, and the only one the tool cannot repair: `resolutionLibs` declared and
	 * `resolutionRoots` absent, which is what a real project out there looks like.
	 *
	 * Measured end to end on a two-file scratch project before this test was written:
	 * `hxq lint A.hx --rule naming --fix` renamed a private field and left B.hx, an `@:access`
	 * grantee, reading the old name — code that no longer compiles — while the same command under a
	 * config adding `"resolutionRoots": ["src"]` DECLINED, naming confinement. Both arms of that probe
	 * live on as `CrossScopeSoundnessTest.LIBS_ONLY_REGRESSIONS`; what CANNOT live anywhere is a
	 * repair, because source roots nobody declared cannot be invented. So the run says it once, and
	 * this pins the sentence together with the three shapes that must stay silent.
	 */
	@:access(anyparse.check.ConfigDisagreement)
	@:pin('control')
	@:killer('M-SCOPE-GAP-SILENT')
	public function testALibsOnlyScopeIsNamedAsAGap(): Void {
		final libsOnly: (String) -> LintConfig = _ -> LintConfig.parse('{"resolutionLibs":["utest"]}');
		final message: Null<String> = ConfigDisagreement.missingProjectRootsMessage(libsOnly, ['a/A.hx']);
		Assert.notNull(message, 'a DECLARED scope holding no project sources is the gap');
		if (message != null)
			Assert.equals(
				'apq: 1 of 1 file(s) this run reports sit under an apqlint.json declaring resolutionLibs and no'
				+ ' resolutionRoots — their resolution scope is this run\'s own files plus an installed library, with no other source of '
				+ 'the project in it, so the checks that prove a cross-file rewrite safe answer from the report scope alone: one can '
				+ 'report a live member as dead, rename a member another file reaches, or drop a parameter a cross-file caller still '
				+ 'passes, and --fix writes it. Declare "resolutionRoots" naming the project\'s own source dirs (e.g. ["src"])\n',
				message
			);
		Assert.isNull(
			ConfigDisagreement.missingProjectRootsMessage(
				_ -> LintConfig.parse('{"resolutionRoots":["src"],"resolutionLibs":["utest"]}'), ['a/A.hx']
			),
			'declared roots are exactly what the cross-scope proofs widen into — nothing to say'
		);
		Assert.isNull(
			ConfigDisagreement.missingProjectRootsMessage(_ -> LintConfig.parse('{}'), ['a/A.hx']),
			'a project declaring no resolution at all is deliberately out of scope — see the class doc'
		);
		Assert.isNull(ConfigDisagreement.missingProjectRootsMessage(libsOnly, []), 'and an empty scope has nobody to tell');
		// The COUNT is the point of this arm and it was a bug before a reviewer reproduced it: the
		// keys resolve as a union, but the SCOPE of a root document is not the whole run. A file
		// under a libs-only root is exposed however many sibling roots declare their own sources, so
		// the answer is per PATH and the sentence says how many.
		final mixed: (String) -> LintConfig = path ->
			LintConfig.parse(path == 'b/B.hx' ? '{"resolutionRoots":["src"]}' : '{"resolutionLibs":["utest"]}');
		final split: Null<String> = ConfigDisagreement.missingProjectRootsMessage(mixed, ['a/A.hx', 'b/B.hx']);
		Assert.notNull(split, 'a file under a libs-only root stays exposed when its SIBLING root declares roots');
		if (split != null) Assert.stringContains('apq: 1 of 2 file(s)', split);
	}

	/**
	 * A root that IS declared and matches no `.hx` is named — the blind spot the sibling notice has by
	 * construction, since it reads the config and the key is present there.
	 *
	 * Reproduced end to end before this existed: `{"resolutionLibs":["utest"],"resolutionRoots":["sources"]}`
	 * beside a real `src/` let `lint <one file> --rule naming --fix` rename a private field and orphan
	 * an `@:access` grantee, with no diagnostic at all — byte-identical damage to the shape the
	 * sibling notice does catch.
	 */
	@:access(anyparse.check.ConfigDisagreement)
	public function testARootMatchingNothingIsNamed(): Void {
		final message: Null<String> = ConfigDisagreement.unreachableProjectRootsMessage(['sources', 'lib']);
		Assert.notNull(message, 'a declared root that expands to nothing is the same gap one layer down');
		if (message != null) {
			Assert.stringContains('resolutionRoots: sources, lib match no .hx', message);
			Assert.stringContains('exactly as if the key were never declared', message);
		}
		Assert.isNull(ConfigDisagreement.unreachableProjectRootsMessage([]), 'every root matched something');
	}

	#if (sys || nodejs)
	/**
	 * This project's OWN `apqlint.json` declares its sources as `resolutionRoots` — the residual the
	 * union above cannot close from inside a check, because it is a CONFIG fact. Without the key
	 * there is no resolution scope over the project's own files, so the documented edit-loop call
	 * `hxq lint <file> --all --no-oracle` answers every reflection gate from the ONE file it was
	 * handed, exactly the way the four tests above describe.
	 *
	 * Measured on a two-file probe in this tree with the key absent: `--fix --rule inline-constant`
	 * over the declaring file ALONE reported `fixed 1 issue(s)` and wrote `inline` onto a constant
	 * that a sibling file spells as `Reflect.field(o, "PROBE_TOKEN")`, while the same command over
	 * BOTH files refused — the one-file answer contradicted the two-file one. With the key it
	 * reports `fixed 0 issue(s)`. Changing the sibling's literal so it names nothing makes BOTH
	 * arms fix, which is what pins the literal as the discriminator.
	 *
	 * The assertion is COVERAGE, and over EVERY config that governs a linted file: the roots must
	 * span what the project's own gate lints (`tools/battery.sh` runs
	 * `hxq lint --format json --all src test`), since a narrower root leaves the same hole one
	 * directory smaller — dropping `test` measured 3 `unused-public-member` false positives across
	 * `src/` that the full scope suppresses. Declaring the roots only in the ROOT
	 * document once left all 741 files under `test/` blind, because a nested
	 * `apqlint.json` REPLACED its parent; it now extends it, so one declaration
	 * covers both trees and this assertion covers the fold.
	 */
	public function testTheProjectDeclaresItsOwnLintScopeAsResolutionRoots(): Void {
		final root: String = CliFixture.repoRoot();
		// BOTH probes, because the ANSWER has to hold for a file under either tree — but only the
		// ROOT document declares the key now. `test/apqlint.json` used to need its own copy, since
		// discovery stopped at the FIRST apqlint.json above the linted file and took it WHOLESALE;
		// measured then, the same two-file probe under `test/` reported the finding for the file
		// alone and refused over both. `LintConfig.discover` now folds the whole chain, so this
		// asserts INHERITANCE: revert it and the `test/` probe answers an empty scope again.
		for (probe in [
			'$root/src/anyparse/check/ReflectionScan.hx',
			'$root/test/unit/LintScopeGateTest.hx'
		]) {
			final roots: Array<String> = LintConfig.discover(probe).resolutionRoots();
			for (dir in ['src', 'test'])
				Assert.isTrue(
					roots.contains(Path.normalize('$root/$dir')), '$probe: its apqlint.json must declare "$dir" in resolutionRoots'
				);
		}
	}
	#end

	@:access(anyparse.query.Cli)
	private function fullScopeIds(): Array<String> {
		return [for (c in LintCommand.partitionChecks(Linter.builtins(), true).fullScope) c.id()];
	}

	@:access(anyparse.query.Cli)
	private function activeScopeIds(): Array<String> {
		return [
			for (c in LintCommand.partitionChecks(Linter.builtins(), true).activeScope) c.id()
		];
	}

	/**
	 * The surface for `reportSource` as the only report file, with `library` injected as the whole
	 * resolution scope — its report half deliberately EMPTY, so every one of these tests reads the
	 * report set and the resolution set as two distinguishable sources.
	 */
	private function scoped(reportSource: String, library: Array<{ file: String, source: String }>): ReflectionSurface {
		return withScope([{ file: 'pkg/Align.hx', source: reportSource }], [], library);
	}

	/** The same plugin WITHOUT a resolution scope — the one-variable counterpart of `scoped`. */
	private function unscoped(reportSource: String): ReflectionSurface {
		return ReflectionScan.reflectionSurface(
			[{ file: 'pkg/Align.hx', source: reportSource }], new CachingGrammarPlugin(new HaxeQueryPlugin())
		);
	}

	private function withScope(
		report: Array<{ file: String, source: String }>, scopeReport: Array<{ file: String, source: String }>,
		library: Array<{ file: String, source: String }>
	): ReflectionSurface {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionScope(
			{ declared: true, sources: () -> {report: scopeReport, projectRoots: [], library: new LibrarySources(library) } }
		);
		return ReflectionScan.reflectionSurface(report, plugin);
	}

}
