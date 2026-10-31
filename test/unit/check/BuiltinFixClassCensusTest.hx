package unit.check;

import anyparse.check.Check;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * The builtin fix census: which of `Linter.builtins()` declares a verified class, and how
 * many there are at all.
 *
 * ## Why this is pinned
 *
 * `--fix` runs a check's edits through one of two nets. A `RiskyFix` check is typechecked and
 * reverted per candidate (`FixVerifier`), and left report-only wholesale when no
 * `compilerOracle` is configured. EVERY other check is applied UNVERIFIED — and until this
 * census the only thing behind them was `Cli.reconcileSafePass`, which returns at its first
 * line without an oracle. So the safe/risky split is the whole of the classification, it is a
 * DECLARATION rather than a measurement, and a new builtin joins the unverified side by
 * saying nothing. This test makes joining it deliberate.
 *
 * ## The observed half, and where it came from
 *
 * The declaration says nothing about what a fix DOES, so the class of each fix was observed
 * rather than read: every `Check.fix` / `fixGrouped` / `fixWithOracle` call site was
 * instrumented in a scratch build and `lint --all --fix` run over this project's `src` + `test`
 * and over a copy of Pony, once without an oracle and once with. Only part of the builtins
 * produced an edit at all — the rest never fired on that corpus, which is the honest limit
 * of such a census.
 *
 * A dozen SAFE rules emitted a pure deletion (`dead-code`, `dead-store`, `duplicate-case`,
 * `join-array-pushes`, `join-single-use-local`, `narrow-local-scope`,
 * `prefer-static-extension`, `unnecessary-null-check`, `unused-import`, `unused-local`,
 * `unused-parameter`, `unused-private`) and many more a REPLACEMENT shorter than the span it
 * covers. That is what refused the obvious repair: demoting deleting safe fixes to report-only
 * without an oracle costs a fifth of the run's edits, and demoting the shrinking ones as well
 * costs most of them.
 *
 * `DefiniteAssignmentGuard` is what landed instead: it refuses the one class of deleting edit
 * the language itself refuses, per check, with no compiler, at no measurable cost — both trees
 * byte-identical under it, with zero refusals on either.
 */
class BuiltinFixClassCensusTest extends Test {

	/**
	 * A source tripping three of the declared rules at once — `identical-operands` on `a == a`,
	 * `magic-number` on the literal, `doc-coverage` on the undocumented type — so
	 * `testEveryDeclaredNoAutofixRuleAnswersNoEdit` executes its claim on real findings rather than on
	 * an empty violation list.
	 */
	private static inline final TRIPWIRE: String = 'class C {\n\tpublic function f(a: Int): Void {\n\t\tif (a == a) trace(4711);\n\t}\n}\n';

	private static inline final LOST_HINT: String =
		'builtins lost from registration (fix the registration, or delete the name from the census file by hand; a loss is never recorded): ';
	private static inline final ADDED_HINT: String =
		'builtins missing from the census file (record with `APQ_CENSUS_RECORD=1 APQ_TEST=unit.check.BuiltinFixClassCensusTest node bin/test.js`, then state which fix-class list the rule joins): ';

	/** The recorded builtin names, one JSON string per line, sorted. */
	private static inline final CENSUS_FILE: String = 'test/testkit/builtin-census.json';

	/**
	 * The registered set is the recorded one, by NAME; `decide` holds the whole decision. Record mode
	 * adds names and never removes one.
	 */
	public function testTheBuiltinSetIsTheRecordedOne(): Void {
		final actual: Array<String> = [for (check in Linter.builtins()) check.id()];
		final recorded: Array<String> = readRecorded();
		final record: Bool = Sys.getEnv('APQ_CENSUS_RECORD') == '1';
		if (shouldWrite(actual, recorded, record)) save(render(actual));
		Assert.same([], complaints(actual, recorded, record));
	}

	public function testDifferenceIsBySetNotByPosition(): Void {
		Assert.same(['c'], difference(['b', 'a', 'c'], ['a', 'b']));
		Assert.same([], difference(['a'], ['a', 'z']));
	}

	/**
	 * The wiring of the three outcomes, not just the set difference: an add without record mode fails and
	 * names the command, an add in record mode writes and passes, a loss fails and writes nothing even in
	 * record mode. Killed by arms `M-CENSUS-ADD-UNDETECTED` and `M-CENSUS-LOST-UNDETECTED`.
	 */
	@:pin('control')
	@:killer('M-CENSUS-ADD-UNDETECTED')
	@:killer('M-CENSUS-LOST-UNDETECTED')
	public function testDecideFailsOnAddWritesOnRecordAndNeverRecordsALoss(): Void {
		final plain: Array<String> = complaints(['a', 'new-rule'], ['a'], false);
		Assert.isFalse(shouldWrite(['a', 'new-rule'], ['a'], false));
		Assert.equals(1, plain.length);
		Assert.stringContains('new-rule', plain[0]);
		Assert.stringContains('APQ_CENSUS_RECORD=1 APQ_TEST=unit.check.BuiltinFixClassCensusTest node bin/test.js', plain[0]);
		Assert.isTrue(shouldWrite(['a', 'new-rule'], ['a'], true));
		Assert.same([], complaints(['a', 'new-rule'], ['a'], true));
		Assert.isFalse(shouldWrite(['a', 'new-rule'], ['a', 'gone'], true));
		Assert.stringContains('gone', complaints(['a', 'new-rule'], ['a', 'gone'], true).join('\n'));
		Assert.same([], complaints(['a'], ['a'], false));
	}

	public function testTheseAreTheRiskyFixRules(): Void {
		// The ONLY builtins whose edits a compiler verifies before they land. Everything else
		// in `builtins()` is applied unverified when the run has no oracle.
		Assert.same([
			'avoid-dynamic',
			'dead-null-guard',
			'hoist-embedded-assignment',
			'null-safety-strict',
			'prefer-access-meta',
			'prefer-case-guard',
			'prefer-count',
			'prefer-enum-abstract',
			'prefer-exists',
			'prefer-final-field',
			'prefer-final-public-field',
			'prefer-inline',
			'prefer-map-bind',
			'prefer-map-type',
			'prefer-null-coalescing',
			'redundant-import',
			'redundant-isvar',
			'scratch-field',
			'shorten-type-ref',
			'typed-event-constant',
			'unstored-property',
			'unused-public-member'
		], idsImplementing(c -> c is RiskyFix));
	}

	public function testTheseAreTheOracleAssistedRules(): Void {
		Assert.same(['avoid-dynamic', 'explicit-local-type', 'explicit-type'], idsImplementing(c -> c is OracleAssisted));
	}

	public function testTheseRulesDeclareNoAutofixAtAll(): Void {
		Assert.same([
			'anon-type-dup',
			'assignment-in-condition',
			'complexity',
			'doc-coverage',
			'doc-length',
			'doc-measurement-claim',
			'duplicate-code',
			'duplicate-code-renamed',
			'english-comments',
			'extract-repeated-expression',
			'guard-pin-arm-reach',
			'identical-operands',
			'impossible-cast',
			'loop-bound-length-mismatch',
			'magic-number',
			'map-as-set',
			'null-dereference',
			'nullable-switch-missing-null',
			'oversized-type',
			'owned-types',
			'possible-null-dereference',
			'refusal-assert-ignores-message',
			'shadowing-case-binder',
			'static-init-order',
			'string-literal-dup',
			'substr-negative-start',
			'swallowed-exception',
			'thread-safety',
			'unchecked-nullable',
			'unguarded-nullable-deref',
			'unused-return-value',
			'zero-count-unparsed-fixture'
		], idsImplementing(c -> c is NoAutofix));
	}

	/**
	 * The four builtins whose `fix` returns nothing UNCONDITIONALLY and which deliberately do NOT declare
	 * `NoAutofix` — the honest remainder of the census above, and the reason the list is a list rather
	 * than a count.
	 *
	 * `default-repeated-argument` HAS an autofix: it lands through `CrossFileFix`, because the argument
	 * sites it deletes are in other files, so the per-file seam answering nothing is its design. The
	 * `--fix` ledger says so since this slice; a `NoAutofix` stamp here would have been false.
	 * `always-null-comparison` and `impossible-is-check` are the second kind: each is the always-FALSE
	 * dual of a rule that already fixes through `CheckScan.simplifyConditionFixes` (`dead-null-guard`,
	 * `redundant-is-check`), the helper carries that direction as a first-class case, and the fix is
	 * simply not written. `listener-symmetry` is the third: two of its three finding classes are design
	 * intent, but `not adjacent` is a member permutation `MemberOrder.fixWalk` already computes and
	 * `member-order` does not report, so a class-wide stamp would have asserted the opposite. Each says
	 * so in its own `fix` doc-comment.
	 *
	 * Nothing at runtime distinguishes the last three from a rule that CANNOT fix, which is exactly why
	 * they are written down: the next author to reach for a `NoAutofix` stamp on one of them has to edit
	 * this list first, and read why it is here.
	 */
	public function testTheseRulesReturnNoEditAndDeclareNothingOnPurpose(): Void {
		// `default-repeated-argument`'s exemption is machine-checkable: it HAS a fix, on the cross-file
		// seam, so `fix` answering nothing is the design rather than a decline.
		Assert.isTrue(idsImplementing(c -> c is CrossFileFix).contains('default-repeated-argument'));
		// The other three carry no seam at all, so the list is prose the compiler cannot derive; what it
		// CAN check is that none of the four has quietly joined the declared set.
		final declared: Array<String> = idsImplementing(c -> c is NoAutofix);
		for (id in [
			'always-null-comparison',
			'default-repeated-argument',
			'impossible-is-check',
			'listener-symmetry'
		]) Assert.isFalse(declared.contains(id), id);
	}

	/**
	 * A `NoAutofix` declaration is a claim about `fix`, and this executes it: every declared rule is
	 * asked for its own findings on a source that trips three of them, and must answer with nothing.
	 *
	 * The registry half — the list above — cannot catch a rule that declares the marker and returns an
	 * edit anyway, because a declaration and a body are two different places. Killed by arm
	 * `M-NO-AUTOFIX-STILL-EDITS`.
	 */
	@:pin('control')
	@:killer('M-NO-AUTOFIX-STILL-EDITS')
	public function testEveryDeclaredNoAutofixRuleAnswersNoEdit(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		for (check in Linter.builtins()) if (check is NoAutofix) {
			final found: Array<Violation> = CheckFixture.violations(check, TRIPWIRE, plugin);
			Assert.equals(0, CheckFixture.fixOf(check, TRIPWIRE, found, plugin).length, check.id());
		}
	}

	/**
	 * `noAutofixReason` has to say something the rule id and the marker do not. The interface's own doc
	 * asks for a fragment "in terms a reader can act on … never a restatement of the rule name", and
	 * `identical-operands` shipped exactly the shape it forbids as its `fix` doc-comment before this
	 * slice replaced it: "Identical-operands has no autofix — report-only".
	 *
	 * Three mechanical readings of that, and each is a NECESSARY condition rather than a sufficient one —
	 * no test can tell a useful sentence from a useless one, so this catches only the restatement:
	 * the reason may not OPEN with the id read as words; it may not contain "no autofix", which the
	 * ledger already prints ahead of it (`no autofix by design — `); and it may not contain
	 * "report-only", which is what the marker means. Containing the id's words elsewhere is fine and
	 * common — `swallowed-exception` opens "resolving a swallowed exception", which names the subject
	 * and then says something.
	 *
	 * Killed by arm `M-NO-AUTOFIX-REASON-IS-THE-RULE-NAME`.
	 */
	@:pin('control')
	@:killer('M-NO-AUTOFIX-REASON-IS-THE-RULE-NAME')
	public function testNoAutofixReasonIsNotTheRuleNameReadBack(): Void {
		for (check in Linter.builtins()) if (check is NoAutofix) {
			final reason: String = (cast check: NoAutofix).noAutofixReason();
			final lower: String = reason.toLowerCase();
			final id: String = check.id();
			Assert.isTrue(reason.length > 20, '$id: $reason');
			Assert.isTrue(reason.charAt(0) == reason.charAt(0).toLowerCase(), '$id: $reason');
			Assert.isFalse(lower.startsWith(id.split('-').join(' ')), '$id: $reason');
			Assert.isTrue(lower.indexOf('no autofix') == -1, '$id: $reason');
			Assert.isTrue(lower.indexOf('report-only') == -1, '$id: $reason');
		}
	}

	/**
	 * A rule that declares "no autofix at all" must carry no fix-bearing seam either — each capability
	 * interface is a second place a fix can live, and a rule holding one while declaring the marker states
	 * two contradictory things about itself.
	 *
	 * A `guard`, not a `control`: nothing decides this in one member, so no source cut expresses it. What
	 * it protects is the pairing this slice created — the rules that gained the marker and
	 * `default-repeated-argument` was deliberately left without it BECAUSE it carries `CrossFileFix`.
	 */
	@:pin('guard')
	public function testNoDeclaredNoAutofixRuleCarriesAFixSeam(): Void {
		Assert.same([], idsImplementing(c -> c is NoAutofix && carriesAFixSeam(c)));
	}

	public function testDeadStoreIsOnTheUNVERIFIEDSide(): Void {
		// The one the campaign's corruption class came through: a fix that DELETES a local's
		// initializer, on the side of the split nothing typechecks. It is not a defect that it
		// is safe — its shape gate is real — but it is why the safe side needed a net of its own.
		final deadStore: Null<Check> = Linter.builtins().filter(c -> c.id() == 'dead-store')[0];
		Assert.notNull(deadStore);
		Assert.isFalse(deadStore is RiskyFix);
		Assert.isFalse(deadStore is NoAutofix);
	}

	/**
	 * Whether `check` declares any interface that carries or constrains a FIX — the six seams a fix can
	 * live on beside `Check.fix` itself.
	 *
	 * `VersionGated` is in the list because its whole content is a constraint on the syntax a fix may
	 * emit: a rule with no fix has nothing for it to gate. Enumerated rather than derived, because Haxe
	 * cannot ask "does this type implement an interface declaring a method" — so a SEVENTH seam added
	 * later reopens the hole, and the list is where a reader looking for it will be.
	 */
	private inline function carriesAFixSeam(check: Check): Bool {
		return check is RiskyFix
			|| check is OracleAssisted
			|| check is CrossFileFix
			|| check is GroupedFix
			|| check is CarryingFix
			|| check is VersionGated;
	}

	/** The ids of every builtin matching `predicate`, sorted — the census's declared column. */
	private function idsImplementing(predicate: (Check) -> Bool): Array<String> {
		final ids: Array<String> = [for (check in Linter.builtins()) if (predicate(check)) check.id()];
		ids.sort((a, b) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
		return ids;
	}

	private static function readRecorded(): Array<String> {
		final root: Any = Json.parse(File.getContent(CENSUS_FILE));
		return Reflect.field(root, 'builtins');
	}

	private static function render(names: Array<String>): String {
		final sorted: Array<String> = names.copy();
		sorted.sort((a, b) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
		return '{\n"builtins": [\n' + [for (name in sorted) '\t"$name"'].join(',\n') + '\n]\n}\n';
	}

	/** Whether a record run rewrites the file: only for pure additions, a loss is never recorded. */
	private static function shouldWrite(actual: Array<String>, recorded: Array<String>, record: Bool): Bool {
		return record && difference(recorded, actual).length == 0 && difference(actual, recorded).length > 0;
	}

	/**
	 * The failure messages of a run. A new rule is fatal until its author records it, and must then state
	 * which side of the verified/unverified fix split it joins; a loss is never recorded.
	 */
	private static function complaints(actual: Array<String>, recorded: Array<String>, record: Bool): Array<String> {
		final added: Array<String> = difference(actual, recorded);
		final removed: Array<String> = difference(recorded, actual);
		final messages: Array<String> = [];
		if (removed.length > 0) messages.push(LOST_HINT + removed.join(', '));
		if (added.length > 0 && !shouldWrite(actual, recorded, record)) messages.push(ADDED_HINT + added.join(', '));
		return messages;
	}

	/** Write through a temp file and a rename so an interrupted record never leaves a torn file. */
	private static function save(content: String): Void {
		final temp: String = '$CENSUS_FILE.tmp';
		File.saveContent(temp, content);
		FileSystem.rename(temp, CENSUS_FILE);
	}

	/** The members of `left` that `right` lacks, in `left`'s order. */
	private static function difference(left: Array<String>, right: Array<String>): Array<String> {
		return [for (name in left) if (!right.contains(name)) name];
	}

}
