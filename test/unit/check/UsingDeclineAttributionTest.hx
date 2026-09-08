package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.CheckScan;
import anyparse.check.DeadBinderCounterLoop;
import anyparse.check.PreferExists;
import anyparse.check.PreferFind;
import anyparse.check.PreferLpad;
import anyparse.check.Severity;
import anyparse.check.UsingScan;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * Who a `using`-insert refusal is allowed to NAME, and the one question the seam used to answer
 * with no evidence at all.
 *
 * ## Three defects, one register
 *
 * `Violation.declineReason` is the field a rule owes its reader when it withholds an edit, and
 * `apq lint --fix` reads nothing else. Three ways it was written wrong, all in the seam the six
 * static-extension rules share:
 *
 * - **A whole branch wrote nothing.** `prefer-lpad`, `prefer-find` and the `prefer-exists` /
 *   `prefer-foreach` engine each dropped their entire edit set when another `using` in the file
 *   could also supply the method, and said nothing about it — `prefer-lpad` because the branch was
 *   the left half of a `&&` that short-circuited past `appendUsingInsert`, the other two because
 *   they returned `[]` at the decision point. The ledger then reported the rule as one that
 *   withheld an edit "without saying why", which is the sentence S169 spent a slice removing from
 *   the one rule that had it.
 * - **The `Guarded` branch named findings it never decided.** It writes its sentence on every
 *   violation it is handed, and all four callers handed it the WHOLE `run` output — including
 *   findings the fix had already skipped for their own cause (an unproven range in `prefer-lpad`,
 *   a `byKey` miss in `prefer-find` / `prefer-exists`, an edit the containment filter dropped in
 *   `dead-binder-counter-loop`). "No edit" is true of those; "the `#if` region decided it" is not.
 * - **An empty offset list read as coverage.** `usingScopeAt` asks whether every rewrite site is
 *   inside the guarded region, and an empty array passes that loop with nothing to iterate — so a caller that
 *   asked before it had collected its sites was told the guarded `using` covered them, kept its
 *   rewrites, and wrote extension calls that bind nothing in the builds the region is compiled out
 *   of. Its own doc named the hazard and nothing checked it.
 *
 * ## What the fixtures address
 *
 * The first two go through the rules' own `fix`, because the defect is the CALLER's: what a rule
 * hands the shared gate, and whether it reaches the gate at all. The third addresses
 * `usingScopeAt` directly — no caller passes an empty array today (all four guard on a non-empty
 * edit set first), so the contract is what shipped wrong and there is no source-level route to it.
 * Each `control` is paired with a `guard` differing in one thing only. The Latin adjective for a loop that passes because it
 * never runs is deliberately absent from this class, arm name included: the prose-claim census reads that word in a fixture doc
 * as the fixture asserting its OWN non-emptiness, which is a different claim from the one made here about the code under test.
 */
@:nullSafety(Strict)
class UsingDeclineAttributionTest extends Test {

	/** A module whose only `using StringTools;` sits inside a `#if` region the class below is outside of. */
	private static inline final GUARDED: String = 'package p;\n\n#if FLAG\nusing StringTools;\n#end\n\nclass C {\n'
		+ "\tfunction f() {\n\t\tfor (i in 0...100) g(if (i < 10) '00$i' else '0$i');\n\t}\n}\n";

	/** The same ladder in a file whose header declares an UNRELATED `using` — the conflicting-module gate. */
	private static inline final CONFLICTING_LPAD: String = 'package p;\n\nusing Other;\n\nclass C {\n'
		+ "\tfunction f() {\n\t\tfor (i in 0...100) g(if (i < 10) '00$i' else '0$i');\n\t}\n}\n";

	/** A `find`-shaped loop in a file whose header declares an unrelated `using`. */
	private static inline final CONFLICTING_FIND: String = 'package p;\n\nusing Other;\n\nclass C {\n'
		+ '\tfunction f(xs:Array<Int>):Null<Int> {\n\t\tfor (x in xs) if (x > 2) return x;\n\t\treturn null;\n\t}\n}\n';

	/** An `exists`-shaped loop in a file whose header declares an unrelated `using`. */
	private static inline final CONFLICTING_EXISTS: String = 'package p;\n\nusing Other;\n\nclass C {\n'
		+ '\tfunction f(xs:Array<Int>):Bool {\n\t\tfor (x in xs) if (x > 2) return true;\n\t\treturn false;\n\t}\n}\n';

	/** A `Map` counter loop needing `count()` beside an `Array` one that needs nothing, under an unrelated `using`. */
	private static inline final CONFLICTING_COUNT: String = 'package p;\n\nusing Other;\n\nclass C {\n'
		+ '\tfunction f(table:Map<Int, Int>, items:Array<Int>):Void {\n'
		+ '\t\tvar i = 0;\n\t\tfor (x in table) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}\n'
		+ '\t\tvar j = 0;\n\t\tfor (y in items) {\n\t\t\twork(j);\n\t\t\tj++;\n\t\t}\n\t}\n}\n';

	/** The same `Map` counter loop in a file whose only `using Lambda;` sits inside a `#if` region the class is outside of. */
	private static inline final GUARDED_COUNT: String = 'package p;\n\n#if FLAG\nusing Lambda;\n#end\n\nclass C {\n'
		+ '\tfunction f(table:Map<Int, Int>):Void {\n\t\tvar i = 0;\n\t\tfor (x in table) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}\n\t}\n}\n';

	/**
	 * An empty `offsets` is a REFUSAL: with no site to test, nothing witnesses that the guarded region
	 * covers the rewrite, and the loop that would decide has nothing to iterate, so it falls through to
	 * the `InScope` this replaced. Killed by arm `M-USING-SCOPE-EMPTY-OFFSETS-INSCOPE`.
	 */
	@:pin('control')
	@:killer('M-USING-SCOPE-EMPTY-OFFSETS-INSCOPE')
	public function testEmptyOffsetsRefuseInsteadOfAnsweringInScope(): Void {
		Assert.equals(UsingScope.Guarded, UsingScan.usingScopeAt(headerOf(GUARDED), 'StringTools', []));
	}

	/** The witnessed twin: an offset INSIDE the region is covered, so the same header answers `InScope`. */
	@:pin('guard')
	public function testOffsetInsideTheGuardedRegionIsInScope(): Void {
		Assert.equals(UsingScope.InScope, UsingScan.usingScopeAt(headerOf(GUARDED), 'StringTools', [GUARDED.indexOf('using')]));
	}

	/** And an offset OUTSIDE it still refuses — the refusal is about coverage, not about the empty array. */
	@:pin('guard')
	public function testOffsetOutsideTheGuardedRegionRefuses(): Void {
		Assert.equals(UsingScope.Guarded, UsingScan.usingScopeAt(headerOf(GUARDED), 'StringTools', [GUARDED.indexOf('class C')]));
	}

	/**
	 * The refusal must not swallow the OTHER verdict: a module the file declares nowhere is `Absent`
	 * with an empty offset list too, because no guarded region is in play and the insert is the
	 * whole job. Without this, turning the empty case into a blanket refusal would silently stop
	 * every insert into a file with no `using` at all.
	 */
	@:pin('guard')
	public function testEmptyOffsetsStillAnswerAbsentForAnUndeclaredModule(): Void {
		Assert.equals(UsingScope.Absent, UsingScan.usingScopeAt(headerOf(GUARDED), 'Lambda', []));
	}

	/**
	 * `prefer-lpad` drops the whole set when another `using` could supply `lpad`, and now says so.
	 * The left half of a `&&` skipped the call that writes reasons, so the branch reported nothing.
	 * Killed by arm `M-LPAD-CONFLICT-SILENT`.
	 */
	@:pin('control')
	@:killer('M-LPAD-CONFLICT-SILENT')
	public function testLpadConflictingUsingRefusalNamesItself(): Void {
		final check: PreferLpad = new PreferLpad();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final found: Array<Violation> = check.run([{ file: 'C.hx', source: CONFLICTING_LPAD }], plugin);
		Assert.equals(1, found.length);
		Assert.equals(0, check.fix(CONFLICTING_LPAD, found, plugin).length);
		assertNamesTheConflict(found[0].declineReason, 'StringTools', 'lpad');
	}

	/** `prefer-find`'s copy of the same branch. Killed by arm `M-FIND-CONFLICT-SILENT`. */
	@:pin('control')
	@:killer('M-FIND-CONFLICT-SILENT')
	@:killer('M-FIND-CONFLICT-MIS-ATTRIBUTED')
	public function testFindConflictingUsingRefusalNamesItself(): Void {
		final check: PreferFind = new PreferFind();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final found: Array<Violation> = check.run([{ file: 'C.hx', source: CONFLICTING_FIND }], plugin);
		Assert.equals(1, found.length);
		final unmatched: Violation = probeViolation();
		Assert.equals(0, check.fix(CONFLICTING_FIND, found.concat([unmatched]), plugin).length);
		assertNamesTheConflict(found[0].declineReason, 'Lambda', 'find');
		// The other half of the same contract, in the caller whose subset comes from a `byKey`
		// lookup rather than a span pairing: a finding the candidate map never matched got no edit
		// for its own reason, and the conflict gate did not decide it.
		Assert.isNull(unmatched.declineReason);
	}

	/**
	 * The third copy, in the engine `prefer-exists` and `prefer-foreach` share. Killed by arm
	 * `M-BOOL-LOOP-CONFLICT-SILENT`.
	 */
	@:pin('control')
	@:killer('M-BOOL-LOOP-CONFLICT-SILENT')
	public function testExistsConflictingUsingRefusalNamesItself(): Void {
		final check: PreferExists = new PreferExists();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final found: Array<Violation> = check.run([{ file: 'C.hx', source: CONFLICTING_EXISTS }], plugin);
		Assert.equals(1, found.length);
		Assert.equals(0, check.fix(CONFLICTING_EXISTS, found, plugin).length);
		assertNamesTheConflict(found[0].declineReason, 'Lambda', 'exists');
	}

	/**
	 * The guarded-region refusal names the finding whose rewrite it took down, and NOT one the fix
	 * had already skipped for its own cause. The second violation here carries a span no ladder
	 * sits at, so `prefer-lpad` never builds an edit for it — "no edit" is true of it and the `#if`
	 * region is not why. Killed by arm `M-GUARDED-DECLINE-MIS-ATTRIBUTED`.
	 */
	@:pin('control')
	@:killer('M-GUARDED-DECLINE-MIS-ATTRIBUTED')
	public function testGuardRefusalNamesOnlyTheFindingItTookDown(): Void {
		final check: PreferLpad = new PreferLpad();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final found: Array<Violation> = check.run([{ file: 'C.hx', source: GUARDED }], plugin);
		Assert.equals(1, found.length);
		final unmatched: Violation = probeViolation();
		Assert.equals(0, check.fix(GUARDED, found.concat([unmatched]), plugin).length);
		final reason: Null<String> = found[0].declineReason;
		Assert.notNull(reason);
		Assert.isTrue(reason != null && reason.indexOf('#if') != -1, reason);
		Assert.isNull(unmatched.declineReason);
	}

	/**
	 * The FOURTH copy of the same defect, and the one the brief did not name: `dead-binder-counter-loop`
	 * refuses per SITE rather than per file, which is the more precise design and was also the silent
	 * one.
	 *
	 * A conflicting `using` makes the `count()` form unspellable, so the site is skipped — while the
	 * `length`-form rewrites in the same file still land. The rule therefore returns a NON-EMPTY edit
	 * set, the ledger's `edits > 0` arm fires, and the dropped finding is invisible: it is neither an
	 * unfixed rule nor a named decline. Killed by arm `M-COUNT-CONFLICT-SILENT`.
	 */
	@:pin('control')
	@:killer('M-COUNT-CONFLICT-SILENT')
	public function testCounterLoopConflictNamesTheSkippedSiteAndKeepsTheOther(): Void {
		final check: DeadBinderCounterLoop = new DeadBinderCounterLoop();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final found: Array<Violation> = check.run([{ file: 'C.hx', source: CONFLICTING_COUNT }], plugin);
		Assert.equals(2, found.length);
		// The `length` site still rewrites — the refusal is per site, not per file.
		Assert.equals(1, check.fix(CONFLICTING_COUNT, found, plugin).length);
		final mapSite: Violation = found[0].message.indexOf('count()') != -1 ? found[0] : found[1];
		final arraySite: Violation = mapSite == found[0] ? found[1] : found[0];
		assertNamesTheConflict(mapSite.declineReason, 'Lambda', 'count');
		Assert.isNull(arraySite.declineReason, 'the site that still rewrote is not declined');
	}

	/**
	 * And a finding the fix pass never matched is not named by the `using` gate either — the subset
	 * `keptViolations` reconstructs after the containment filter, which is the one piece of this slice
	 * carrying real span arithmetic. Killed by arm `M-COUNT-GUARDED-MIS-ATTRIBUTED`.
	 */
	@:pin('control')
	@:killer('M-COUNT-GUARDED-MIS-ATTRIBUTED')
	public function testCounterLoopGuardRefusalNamesOnlyTheSurvivingFinding(): Void {
		final check: DeadBinderCounterLoop = new DeadBinderCounterLoop();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final found: Array<Violation> = check.run([{ file: 'C.hx', source: GUARDED_COUNT }], plugin);
		Assert.equals(1, found.length);
		final unmatched: Violation = probeViolation();
		Assert.equals(0, check.fix(GUARDED_COUNT, found.concat([unmatched]), plugin).length);
		final reason: Null<String> = found[0].declineReason;
		Assert.notNull(reason);
		Assert.isTrue(reason != null && reason.indexOf('#if') != -1, reason);
		Assert.isNull(unmatched.declineReason);
	}

	/**
	 * The reason is the shared sentence for the module and method the CALLER owes, so a hand-spelled copy
	 * in one of the three rules would drift and a copy naming the wrong module would too.
	 *
	 * Both halves are passed in rather than read back out of the answer: an earlier version inferred the
	 * module from whether the reason mentioned `StringTools`, which is the assertion satisfying itself —
	 * any module the rule chose would have been the one the expectation was built from.
	 */
	private function assertNamesTheConflict(reason: Null<String>, module: String, method: String): Void {
		Assert.notNull(reason);
		if (reason == null) return;
		Assert.equals(UsingScan.conflictingUsingDecline(module, method), reason);
	}

	/** The `using` header of `source`, built the way every rule sharing the seam builds it. */
	private function headerOf(source: String): UsingHeader {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) throw 'the fixture must parse';
		return UsingScan.headerOf(tree, source, plugin);
	}

	/** A finding at a span no site of any rule sits at — the "skipped for its own cause" half of every subset assertion here. */
	private function probeViolation(): Violation {
		return {
			file: 'C.hx',
			span: new Span(0, 1),
			rule: 'probe',
			severity: Severity.Info,
			message: 'a finding no site matches'
		};
	}

}
