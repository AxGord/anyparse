package unit;

import anyparse.check.Check;
import anyparse.check.FixVerifier;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.Cli;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * What `lint --fix` SAYS about an edit set the writer-emit gate refused, and about a refusal
 * that lands on a later pass.
 *
 * Two silences, both of them shaped so that nothing in a run's output contradicts them.
 *
 * `noteFixOutcome` used to run BEFORE the `BodySlotGuard` filter, so a check whose edits the
 * guard threw away was recorded as having produced them: `edits` went up, `declined` stayed at
 * zero, and the per-rule "reported but got no edit" block therefore had no row for the rule at
 * all. The guard had ALREADY computed the human-readable reason at that call site — it is the
 * value the filter compares to `null` — and the run discarded it.
 *
 * The `canonicalize` backstop under it was muted after pass 1 (`if (passes == 1 && …)`), which
 * is precisely where a slot emptied BETWEEN two checks lands: the per-check filter cannot see
 * a pair, so this is that pair's only report, and it also feeds the summary's
 * `N file(s) skipped`. A later-pass refusal left the file unwritten AND uncounted.
 *
 * The pins go through the private statics the driver is made of (`@:access`), because the output
 * itself is a `Sys.stderr` write with no seam a test can read.
 *
 * S34 added the other half of the same silence, and one wording. A refusal that first lands on a
 * LATER pass is not a re-report, so it cannot go into `declined` (a first-pass count, kept
 * comparable with `reported`) — it went nowhere at all, and `gateRefusalLines` is the block it
 * reaches now. And a file can be in BOTH `changedFiles` and `noted` since the backstop started
 * reporting every pass, so `N file(s) skipped` had stopped telling "never fixed" from "partly
 * fixed, then refused".
 */
@:access(anyparse.query.Cli)
class LintFixDeclineWiringSliceTest extends Test {

	/** `unused-local` on a declaration that IS a brace-less `if` body — the shape the guard refuses. */
	private static final REFUSED: String =
		'package p;\n\nclass C {\n\tpublic function f(c: Bool): Void {\n\t\tif (c) var y: Int = 1;\n\t}\n\n}\n';

	/** A fixable finding in a file the writer would reformat — `canonicalize` refuses it with `reformat` false. */
	private static final NOT_CANONICAL: String =
		'package p;\n\nclass C {\n    public function f(): Void {\n        var y: Int = 1;\n    }\n}\n';

	/**
	 * Canonical under COMPILED DEFAULTS (which is what a null `optsJson` gives these pins), with a
	 * comment INSIDE a modifier run and one unrelated fixable finding: `modifier-order`'s reorder
	 * moves the modifiers around `/*inline*\/` and the writer will not re-emit it, while
	 * `prefer-single-quotes` has nothing to do with any of that.
	 */
	private static final REFUSED_BY_WRITER: String =
		'package p;\n\nclass G {\n\n\tfinal private /*inline*/ function f():String {\n\t\treturn "x";\n\t}\n\n}\n';

	/** Canonical under compiled defaults, with one string literal a hand-built edit set can straddle. */
	private static final OVERLAP_SOURCE: String =
		'package p;\n\nclass C {\n\n\tpublic function f():String {\n\t\treturn "aaa";\n\t}\n\n}\n';

	/**
	 * The guard's refusal is the rule's ledger row, and it carries the guard's own sentence.
	 *
	 * RED at base on all four assertions but the first: the edits were dropped either way, while
	 * the rule was credited with 1 edit, counted 0 declines and offered no reason.
	 */
	public function testGuardRefusalBecomesTheRulesDeclineRow(): Void {
		#if (sys || nodejs)
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final check: Null<Check> = Linter.byId('unused-local');
		if (check == null) {
			Assert.fail('unused-local is not registered');
			return;
		}
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: REFUSED }];
		final own: Array<Violation> = check.run(files, plugin);
		Assert.isTrue(own.length > 0, 'the fixture reports at least one unused-local finding');
		final ledger: Map<String, RuleFixOutcome> = [];
		final groups: Array<RuleEdits> = Cli.collectFileLintEdits(REFUSED, own, [check], plugin, SymbolIndex.build(files, plugin));
		Cli.ledgerFileLintEdits(ledger, groups, true);
		final edits: Array<{ span: Span, text: String }> = Cli.contributedEdits(groups);
		Assert.equals(0, edits.length, 'the guard drops the check edits');
		final row: Null<RuleFixOutcome> = ledger['unused-local'];
		if (row == null) {
			Assert.fail('the refused rule has no ledger row');
			return;
		}
		Assert.equals(0, row.edits, 'an edit the gate refused is not an edit the rule produced');
		Assert.equals(own.length, row.declined, 'the findings it could not fix are counted as declined');
		Assert.equals(1, row.reasons.length, 'one reason, the guard\'s: ${row.reasons}');
		if (row.reasons.length == 0) return;
		Assert.isTrue(row.reasons[0].text.indexOf('IfStmt') != -1, 'the reason names the construct: ${row.reasons[0].text}');
		// CONTROL for the `unseen` filter in `gateRefusalLines`: a refusal the DECLINE row already
		// carries must not be repeated as an unaccounted-for one. Drop that filter and this goes red
		// while the later-pass pin below stays green.
		final declared: Map<String, String> = [];
		final lines: String = Cli.unfixedFixLedger(ledger, declared, [], []).join('');
		Assert.isTrue(lines.indexOf('fix DECLINED — ') != -1, 'a pass-1 refusal IS the rule\'s decline row: $lines');
		Assert.isTrue(lines.indexOf('edit set(s) refused') == -1, 'and it is not repeated in the gate-refusal block: $lines');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A `canonicalize` refusal on pass 2 is reported and counted, not dropped.
	 *
	 * `noted` IS the observable: the driver pushes the file there beside the stderr line, and the
	 * summary reads its length as `N file(s) skipped`. RED at base, where the whole arm sat behind
	 * `passes == 1`.
	 */
	public function testLaterPassRefusalIsStillReported(): Void {
		#if (sys || nodejs)
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final check: Null<Check> = Linter.byId('unused-local');
		if (check == null) {
			Assert.fail('unused-local is not registered');
			return;
		}
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: NOT_CANONICAL }];
		final noted: Array<String> = [];
		Cli.applyLintPass(
			files, files, plugin, [check], [], [check], _ -> LintConfig.parse('{}'), false, ['C.hx' => null], 2, noted, [], [], [], []
		);
		Assert.isTrue(noted.contains('C.hx'), 'the pass-2 refusal is reported and counted as a skipped file');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A gate refusal that first lands on a LATER pass still reaches the report, in the gate's own
	 * words.
	 *
	 * `declined` is a FIRST-pass count on purpose — a later pass re-reports whatever an earlier edit
	 * exposed, and summing those would count one finding several times — so a refusal, which is a
	 * standing fact about an edit set rather than a re-report, gets a list of its own and a block of
	 * its own. Without them `unfixedFixLedger` said nothing whatever about the rule, and that sentence
	 * is the ONLY thing telling a user why their fix vanished.
	 *
	 * RED at base: with `countDeclines` false the whole recording arm returned early, so the ledger
	 * produced no line naming the rule. The base-adapted copy spells the four-field anonymous shape
	 * inline, `RuleFixOutcome` having been private there.
	 */
	public function testLaterPassGateRefusalStillReachesTheReport(): Void {
		#if (sys || nodejs)
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final check: Null<Check> = Linter.byId('unused-local');
		if (check == null) {
			Assert.fail('unused-local is not registered');
			return;
		}
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: REFUSED }];
		final own: Array<Violation> = check.run(files, plugin);
		final ledger: Map<String, RuleFixOutcome> = [];
		// `countDeclines` false IS "this is not pass 1" — the driver passes `passes == 1`.
		final groups: Array<RuleEdits> = Cli.collectFileLintEdits(REFUSED, own, [check], plugin, SymbolIndex.build(files, plugin));
		Cli.ledgerFileLintEdits(ledger, groups, false);
		final edits: Array<{ span: Span, text: String }> = Cli.contributedEdits(groups);
		Assert.equals(0, edits.length, 'the guard drops the check edits on this pass too');
		final row: Null<RuleFixOutcome> = ledger['unused-local'];
		if (row == null) {
			Assert.fail('the refused rule has no ledger entry');
			return;
		}
		Assert.equals(0, row.declined, 'a later pass adds nothing to the first-pass decline count');
		Assert.equals(1, row.refusals.length, 'the gate refusal is recorded: ${row.refusals}');
		final declared: Map<String, String> = [];
		final lines: String = Cli.unfixedFixLedger(ledger, declared, [], []).join('');
		Assert.isTrue(lines.indexOf('unused-local') != -1, 'the rule reaches the report: $lines');
		Assert.isTrue(lines.indexOf('IfStmt') != -1, 'and the block carries the guard\'s own sentence: $lines');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * One rule's un-writable fix no longer costs the file's other rules their work.
	 *
	 * The writer-emit gate round-trips the WHOLE spliced file, so its verdict is per FILE: at base
	 * `modifier-order`'s reorder across a `/*inline*\/` comment took `prefer-single-quotes`'s edit
	 * down with it, on every pass, and the file was written not at all. Measured over 8645 external
	 * files: 2 files, 310 landable edits from twenty-odd rules thrown away between them.
	 *
	 * RED at base on every assertion — `salvageFileLintEdits` does not exist there, so the file
	 * does not compile.
	 */
	public function testARefusedRuleCostsOnlyItsOwnEdits(): Void {
		#if (sys || nodejs)
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final order: Null<Check> = Linter.byId('modifier-order');
		final quotes: Null<Check> = Linter.byId('prefer-single-quotes');
		if (order == null || quotes == null) {
			Assert.fail('modifier-order / prefer-single-quotes are not both registered');
			return;
		}
		final checks: Array<Check> = [order, quotes];
		final files: Array<{ file: String, source: String }> = [{ file: 'G.hx', source: REFUSED_BY_WRITER }];
		final own: Array<Violation> = Linter.run(files, plugin, checks, _ -> LintConfig.parse('{}'), false);
		final groups: Array<RuleEdits> = Cli.collectFileLintEdits(REFUSED_BY_WRITER, own, checks, plugin, SymbolIndex.build(files, plugin));
		Assert.equals(2, groups.length, 'both rules answered with edits: $groups');
		// DETECT-PROOF: the whole set really is refused, so the salvage below is doing work rather
		// than restating an `Ok` the gate would have given anyway.
		switch RefactorSupport.canonicalize(REFUSED_BY_WRITER, Cli.contributedEdits(groups), false, plugin, null) {
			case Ok(_, _):
				Assert.fail('the fixture no longer trips the writer-emit gate');
			case Err(message):
				final blamed: Array<String> = [];
				final settled: Null<{ text: String, rewrites: Null<Int> }> = Cli.salvageFileLintEdits(
					REFUSED_BY_WRITER, groups, message, plugin, null, blamed
				);
				if (settled == null) {
					Assert.fail('the salvage kept nothing: $message');
					return;
				}
				Assert.equals(1, blamed.length, 'exactly one rule is blamed: $blamed');
				Assert.isTrue(blamed[0].indexOf('modifier-order: ') == 0, 'and it is the refused one: ${blamed[0]}');
				// ONE assertion over both halves, so neither can be satisfied alone: the surviving
				// rule's rewrite sits inside the modifier run the refused rule wanted to reorder and
				// did not.
				Assert.isTrue(
					settled.text.indexOf('final private /*inline*/ function f():String {\n\t\treturn \'x\';') != -1,
					'the other rule\'s edit landed and the refused one did not: ${settled.text}'
				);
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A group DEFERRED for overlapping one the gate then refuses is still offered.
	 *
	 * `overlapped` is decided during collection against an accumulating set that still holds the
	 * edits the writer has not yet been asked about, so a check deferred behind a doomed one was
	 * never handed to the salvage at all — and since every pass recomputes the identical state, its
	 * edits were lost for ever. That is the defect this whole salvage exists to close, one level
	 * down, and it is why the overlap is RE-DERIVED here against the surviving set.
	 *
	 * The groups are hand-built rather than collected, so the overlap and the refusal are exactly
	 * the two facts under test: the wide edit leaves an unbalanced quote (the gate's `result does
	 * not parse`), the narrow one sits INSIDE its span and is writable on its own. RED at base,
	 * where `salvageFileLintEdits` does not exist.
	 */
	public function testAGroupDeferredByARefusedOverlapIsStillOffered(): Void {
		#if (sys || nodejs)
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final outer: Int = OVERLAP_SOURCE.indexOf('"aaa"');
		final inner: Int = OVERLAP_SOURCE.indexOf('aaa');
		Assert.isTrue(outer >= 0 && inner == outer + 1, 'the fixture holds the straddled literal');
		final refused: RuleEdits = {
			rule: 'r-refused',
			findings: [],
			edits: [{ span: new Span(outer, outer + 5), text: '\'aaa' }],
			overlapped: false,
			refusal: null
		};
		final deferred: RuleEdits = {
			rule: 'r-deferred',
			findings: [],
			edits: [{ span: new Span(inner, inner + 3), text: 'bbb' }],
			overlapped: true,
			refusal: null
		};
		final blamed: Array<String> = [];
		final settled: Null<{ text: String, rewrites: Null<Int> }> = Cli.salvageFileLintEdits(
			OVERLAP_SOURCE, [refused, deferred], 'FILE LEVEL SENTENCE', plugin, null, blamed
		);
		if (settled == null) {
			Assert.fail('the deferred group was never offered to the gate');
			return;
		}
		// ONE assertion over both halves: the deferred rule's rewrite landed and the refused one's
		// did not, so neither can be satisfied alone.
		Assert.isTrue(settled.text.indexOf('return "bbb";') != -1, 'the deferred edit landed: ${settled.text}');
		Assert.equals(1, blamed.length, 'only the refused rule is blamed: $blamed');
		Assert.isTrue(blamed[0].indexOf('r-refused: ') == 0, 'and it is the refused one: ${blamed[0]}');
		Assert.isNull(deferred.refusal, 'the deferred group is not blamed for its neighbour');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A source the WRITER cannot round-trip is not bisected, and every contributing rule is told
	 * the file-level reason.
	 *
	 * This is the bulk of the defect, not the headline: 50 of the 54 refusals measured over 8645
	 * external files are the file's own bytes, the same ones `apq fmt --write` refuses — and no
	 * subset of edits changes that answer, so asking the gate once per check would only pay N round
	 * trips to learn it again. RED at base (no `salvageFileLintEdits`).
	 */
	public function testASourceLevelRefusalIsNotBisected(): Void {
		#if (sys || nodejs)
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final check: Null<Check> = Linter.byId('prefer-single-quotes');
		if (check == null) {
			Assert.fail('prefer-single-quotes is not registered');
			return;
		}
		final source: String = 'package p;\n\nclass C {\n    public function f(): String {\n        return "x";\n    }\n}\n';
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: source }];
		final own: Array<Violation> = check.run(files, plugin);
		Assert.isTrue(own.length > 0, 'the fixture reports a fixable finding');
		final groups: Array<RuleEdits> = Cli.collectFileLintEdits(source, own, [check], plugin, SymbolIndex.build(files, plugin));
		Assert.equals(1, Cli.contributedEdits(groups).length, 'and the check produced its edit');
		final blamed: Array<String> = [];
		Assert.isNull(
			Cli.salvageFileLintEdits(source, groups, 'FILE LEVEL SENTENCE', plugin, null, blamed),
			'a source the writer cannot round-trip salvages nothing'
		);
		Assert.equals(0, blamed.length, 'and no rule is blamed for the file\'s own bytes: $blamed');
		Assert.equals('FILE LEVEL SENTENCE', groups[0].refusal, 'the rule is told the file-level reason instead');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * On the source-level arm an OVERLAPPED group is told the reason too.
	 *
	 * Nothing is written on that arm, so a group deferred at collection did not land its edits
	 * either — but the loop read `contributes`, which excludes an overlapped group, so it got no
	 * refusal row and `ledgerFileLintEdits` then credited it with edits on a run that wrote
	 * nothing. This is the arm that fires for 50 of the 54 refusals measured over 8645 files, so
	 * it is the common path. Found by review after the bisect arm's own re-derivation shipped.
	 */
	public function testASourceLevelRefusalBlamesAnOverlappedGroupToo(): Void {
		#if (sys || nodejs)
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final accepted: RuleEdits = {
			rule: 'r-accepted',
			findings: [],
			edits: [{ span: new Span(0, 1), text: 'p' }],
			overlapped: false,
			refusal: null
		};
		final deferred: RuleEdits = {
			rule: 'r-deferred',
			findings: [],
			edits: [{ span: new Span(0, 1), text: 'p' }],
			overlapped: true,
			refusal: null
		};
		final blamed: Array<String> = [];
		Assert.isNull(
			Cli.salvageFileLintEdits(NOT_CANONICAL, [accepted, deferred], 'FILE LEVEL SENTENCE', plugin, null, blamed),
			'a source the writer will not round-trip salvages nothing'
		);
		Assert.equals(0, blamed.length, 'and no rule is blamed for the file\'s own bytes: $blamed');
		Assert.equals('FILE LEVEL SENTENCE', accepted.refusal);
		Assert.equals('FILE LEVEL SENTENCE', deferred.refusal, 'the OVERLAPPED group is told the reason too');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * CONTROL: a file whose whole edit set the gate accepts is written, blames nobody, and is not
	 * counted as skipped.
	 *
	 * Green at base by arithmetic — the salvage runs ONLY in the `Err` arm, which this input never
	 * reaches, so the pass is byte-identical to the base's. Killed by running the salvage
	 * unconditionally, or by blaming a rule the gate never refused.
	 */
	public function testAnAcceptedFileIsWrittenAndBlamesNobody(): Void {
		#if (sys || nodejs)
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final check: Null<Check> = Linter.byId('prefer-single-quotes');
		if (check == null) {
			Assert.fail('prefer-single-quotes is not registered');
			return;
		}
		final source: String = 'package p;\n\nclass C {\n\n\tpublic function f():String {\n\t\treturn "x";\n\t}\n\n}\n';
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: source }];
		final noted: Array<String> = [];
		final changed: Array<String> = [];
		Cli.applyLintPass(
			files, files, plugin, [check], [], [check], _ -> LintConfig.parse('{}'), false, ['C.hx' => null], 1, noted, [], changed, [], []
		);
		Assert.equals(0, noted.length, 'nothing was refused: $noted');
		Assert.isTrue(changed.contains('C.hx'), 'and the file was written');
		Assert.isTrue(files[0].source.indexOf('\'x\'') != -1, 'with the edit in it: ${files[0].source}');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The summary's skip tail tells "never fixed" from "partly fixed, then refused".
	 *
	 * `noted` and `changedFiles` can hold the SAME file since the `canonicalize` backstop started
	 * reporting on every pass: an edit landed on pass 1 and a later pass was refused. `N file(s)
	 * skipped` on its own then read as "nothing was written here" about a file the run had already
	 * rewritten.
	 *
	 * RED at base, where the tail was `noted.length > 0 ? ', N file(s) skipped' : ''` — an expression
	 * that cannot produce the parenthetical for any input.
	 */
	public function testSkipTailNamesThePartlyFixedFiles(): Void {
		#if (sys || nodejs)
		Assert.equals(', 2 file(s) skipped (1 partly fixed first, then refused)', Cli.skippedTail(['a.hx', 'b.hx'], ['a.hx']));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * CONTROL: a run whose two sets are DISJOINT prints the bytes it always printed, and an empty
	 * `noted` prints nothing at all.
	 *
	 * Green by construction — the base tail expression yields exactly these two strings for these two
	 * inputs, so the change adds a case rather than moving one. Proved by MUTATION instead: make the
	 * parenthetical unconditional and this flips while the pin above stays green.
	 */
	public function testSkipTailIsUnchangedWhenNothingWasPartlyFixed(): Void {
		#if (sys || nodejs)
		Assert.equals(', 1 file(s) skipped', Cli.skippedTail(['a.hx'], ['b.hx']));
		Assert.equals('', Cli.skippedTail([], ['b.hx']));
		#else
		Assert.pass('non-sys target');
		#end
	}


	/**
	 * The decline row's `<n> of <reported>` label never states a part larger than its whole.
	 *
	 * `reported` is filled ONLY by the driver's pass-1 report loop in `applyLintPass`, so a caller
	 * that drives `computeFileLintEdits` itself — the pins above, and any embedder — leaves it at
	 * zero while `declined` counts real findings. The label's only test was `count == reported`, so
	 * the else arm fired and the run printed `unused-local 2 of 0`: a ratio out of a total smaller
	 * than its own part, in the one block that exists to explain why a fix vanished.
	 *
	 * RED at base, where the same ledger renders ` of 0`.
	 */
	public function testTheDeclineLabelNeverReadsOutOfZero(): Void {
		#if (sys || nodejs)
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final check: Null<Check> = Linter.byId('unused-local');
		if (check == null) {
			Assert.fail('unused-local is not registered');
			return;
		}
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: REFUSED }];
		final own: Array<Violation> = check.run(files, plugin);
		final ledger: Map<String, RuleFixOutcome> = [];
		Cli.ledgerFileLintEdits(ledger, Cli.collectFileLintEdits(REFUSED, own, [check], plugin, SymbolIndex.build(files, plugin)), true);
		final row: Null<RuleFixOutcome> = ledger['unused-local'];
		if (row == null) {
			Assert.fail('the refused rule has no ledger row');
			return;
		}
		Assert.equals(0, row.reported, 'nothing on this path fills the pass-1 report count');
		Assert.isTrue(row.declined > 0, 'while the declines are real findings');
		final declared: Map<String, String> = [];
		final lines: String = Cli.unfixedFixLedger(ledger, declared, [], []).join('');
		Assert.isTrue(lines.indexOf(' of 0') == -1, 'the label states no ratio out of nothing: $lines');
		Assert.isTrue(lines.indexOf('unused-local ${row.declined}:') != -1, 'it states the plain count instead: $lines');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A risky rule's findings reach the fix ledger, with the verifier's own sentence.
	 *
	 * The gap this closes: `FixVerifier` is the only place a `RiskyFix` check's fix is ever
	 * called, and it never received the ledger — so with a `compilerOracle` configured those 13
	 * rules put EDITS into the summary count and never a FINDING into the block that says what got
	 * no edit, and the block had to disclaim them instead of answering. The fold is asserted here
	 * off a constructed result rather than a real verification, because what has to hold is the
	 * ARITHMETIC (findings to `reported`, landed edits to `edits`, a file that landed none to
	 * `declined` under its recorded reason); whether the verifier fills the tallies correctly is
	 * `FixVerifierCoverageE2ETest`'s question, against the real compiler.
	 *
	 * At base `Cli.ledgerRiskyTallies` does not exist and the file does not compile.
	 */
	public function testARiskyRulesTalliesBecomeItsLedgerRow(): Void {
		#if (sys || nodejs)
		final ledger: Map<String, RuleFixOutcome> = [];
		Cli.ledgerRiskyTallies(ledger, riskyResult());
		final row: Null<RuleFixOutcome> = ledger['avoid-dynamic'];
		if (row == null) {
			Assert.fail('the risky rule has no ledger row');
			return;
		}
		Assert.equals(10, row.reported, 'every finding the phase saw, across all four files');
		Assert.equals(2, row.edits, 'and only the edits that landed');
		Assert.equals(8, row.declined, 'the findings in every file where none landed');
		// One row per distinct SENTENCE, from both of the verifier's lists — and the fourth file,
		// which is in neither, contributes findings to `declined` and no sentence at all. A run that
		// invented one for it, or that dropped the revert's, fails here.
		Assert.same([
			{ text: 'the compiler oracle does not compile this file', count: 3 },
			{ text: 'the compiler rejected it', count: 1 }
		], row.reasons);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The ledger stops disclaiming the risky rules once it has rows for them.
	 *
	 * One sentence, two states, and the pair is the pin: handed the risky ids the block names them
	 * as absent, handed none it says nothing about them at all — which is what `printUnfixedLedger`
	 * passes on a run whose risky phase actually ran (`RiskyFixOutcome.ledgered`). RED at base on
	 * both halves: the wording there is unconditional and claims the rules "never enter this
	 * ledger", a sentence that is now false exactly when the ledger holds their row.
	 */
	public function testTheRiskyDisclaimerIsOnlyForAPhaseThatDidNotRun(): Void {
		#if (sys || nodejs)
		final ledger: Map<String, RuleFixOutcome> = [];
		Cli.ledgerRiskyTallies(ledger, riskyResult());
		final declared: Map<String, String> = [];
		final absent: String = Cli.unfixedFixLedger(ledger, declared, [], ['avoid-dynamic']).join('');
		Assert.isTrue(absent.indexOf('the risky-fix path never ran them this run') != -1, 'a phase that did not run says so: $absent');
		final present: String = Cli.unfixedFixLedger(ledger, declared, [], []).join('');
		Assert.isTrue(present.indexOf('risky-fix path') == -1, 'a phase that ran leaves the disclaimer off: $present');
		Assert.isTrue(present.indexOf('avoid-dynamic 8 of 10:') != -1, 'and its row is what the reader gets instead: $present');
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * One risky-fix phase's outcome, shaped to exercise all THREE reason states of the fold in one
	 * call: `avoid-dynamic` landed both its edits in a covered file, landed none in a file the oracle
	 * does not compile (reason in `declined`), none in a file the compiler read and refused (reason in
	 * `reverted`, via `revertCauseText`), and none in a file that is in NEITHER list — an edit set that
	 * canonicalised back to its own source, which declines with nothing to quote.
	 *
	 * That last row is the one the fold got wrong first time round and the one a hand-built fixture is
	 * for: it is the shape `riskyDeclineReason` answers null for, and the shape whose real producer
	 * (`SourceNotCanonical`) is now excluded upstream instead. Built by hand rather than verified for
	 * real, so the ARITHMETIC is measured on its own; whether the verifier fills these rows correctly is
	 * `FixVerifierCoverageE2ETest`'s question, against the real compiler.
	 */
	private static function riskyResult(): FixVerifyResult {
		return {
			baseline: Confirmed,
			applied: ['Covered.hx'],
			appliedEdits: 2,
			reverted: [
				{
					file: 'Rejected.hx',
					rule: 'avoid-dynamic',
					cause: OracleRejected
				}
			],
			partials: [],
			declined: [
				{
					file: 'Uncovered.hx',
					rule: 'avoid-dynamic',
					edits: 3,
					reason: 'the compiler oracle does not compile this file'
				}
			],
			coverageUnknown: null,
			coverage: null,
			tallies: [
				{
					rule: 'avoid-dynamic',
					file: 'Covered.hx',
					findings: 2,
					edits: 2
				},
				{
					rule: 'avoid-dynamic',
					file: 'Uncovered.hx',
					findings: 3,
					edits: 0
				},
				{
					rule: 'avoid-dynamic',
					file: 'Rejected.hx',
					findings: 1,
					edits: 0
				},
				{
					rule: 'avoid-dynamic',
					file: 'Silent.hx',
					findings: 4,
					edits: 0
				}
			]
		};
	}
	#end

}
