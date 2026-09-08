package unit.check;

import anyparse.check.Check;
import anyparse.check.Linter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

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
 * slice the only thing behind them was `Cli.reconcileSafePass`, which returns at its first
 * line without an oracle. So the safe/risky split is the whole of the classification, it is a
 * DECLARATION rather than a measurement, and a new builtin joins the unverified side by
 * saying nothing. This test makes joining it deliberate.
 *
 * ## The measured half, and where it came from
 *
 * The declaration says nothing about what a fix DOES, so the class of each fix was measured
 * rather than read: every `Check.fix` / `fixGrouped` / `fixWithOracle` call site was
 * instrumented in a scratch build and `lint --all --fix` run over this project's `src` + `test`
 * and over a copy of Pony (869 files), once without an oracle and once with. 60 of the
 * builtins produced an edit at all — the rest never fired on that corpus, which is the honest
 * limit of a measured census.
 *
 * Of the 895 edits the two no-oracle arms produced, **12 SAFE rules emitted a pure deletion**
 * (`dead-code`, `dead-store`, `duplicate-case`, `join-array-pushes`, `join-single-use-local`,
 * `narrow-local-scope`, `prefer-static-extension`, `unnecessary-null-check`, `unused-import`,
 * `unused-local`, `unused-parameter`, `unused-private`) accounting for 182 edits, and 30 more
 * emitted a REPLACEMENT shorter than the span it covers — another 536. That is the number that
 * refused the obvious repair: demoting deleting safe fixes to report-only without an oracle
 * costs 20 % of the run's edits, `unused-import`'s 84 among them, and demoting the shrinking
 * ones as well costs 80 %.
 *
 * `DefiniteAssignmentGuard` is what landed instead: it refuses the one class of deleting edit
 * the language itself refuses, per check, with no compiler, and cost nothing measurable: Pony 869 files,
 * interleaved, base 29.6 / 29.9 s against this slice 30.0 / 30.1 s — inside the 0.4 s spread
 * of the identical binary — with both trees byte-identical at 697 edits in 210 files, and
 * anyparse src + test byte-identical at 106 edits in 43 files. Zero refusals on either.
 */
class BuiltinFixClassCensusTest extends Test {

	/**
	 * A source tripping three of the declared rules at once — `identical-operands` on `a == a`,
	 * `magic-number` on the literal, `doc-coverage` on the undocumented type — so
	 * `testEveryDeclaredNoAutofixRuleAnswersNoEdit` executes its claim on real findings rather than on
	 * an empty violation list.
	 */
	private static inline final TRIPWIRE: String = 'class C {\n\tpublic function f(a: Int): Void {\n\t\tif (a == a) trace(4711);\n\t}\n}\n';

	public function testTheBuiltinSetIsThisBig(): Void {
		// Shrinkage IS the acceptance test: a new builtin changes this number, and the author
		// then has to say which side of the verified/unverified split it joins.
		Assert.equals(180, Linter.builtins().length);
	}

	public function testTheseAreTheRiskyFixRules(): Void {
		// The ONLY builtins whose edits a compiler verifies before they land. Everything else
		// in `builtins()` is applied unverified when the run has no oracle.
		Assert.same([
			'avoid-dynamic',
			'dead-null-guard',
			'hoist-embedded-assignment',
			'prefer-case-guard',
			'prefer-enum-abstract',
			'prefer-exists',
			'prefer-inline',
			'prefer-interpolation',
			'prefer-map-type',
			'prefer-null-coalescing',
			'redundant-import',
			'shorten-type-ref',
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
			'asymmetric-branch-braces',
			'complexity',
			'doc-coverage',
			'duplicate-code',
			'english-comments',
			'extract-repeated-expression',
			'identical-operands',
			'impossible-cast',
			'magic-number',
			'null-dereference',
			'nullable-switch-missing-null',
			'oversized-type',
			'possible-null-dereference',
			'shadowing-case-binder',
			'shadowing-local',
			'shadowing-parameter',
			'string-literal-dup',
			'swallowed-exception',
			'thread-safety',
			'unchecked-nullable',
			'unguarded-nullable-deref',
			'unused-return-value'
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
	 * `member-order` does not report, so a class-wide stamp would have asserted the opposite. Each names
	 * its backlog id in its own `fix` doc-comment (T825 / T826 / T827).
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
			final found: Array<Violation> = check.run([{ file: 'C.hx', source: TRIPWIRE }], plugin);
			Assert.equals(0, check.fix(TRIPWIRE, found, plugin).length, check.id());
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
	 * it protects is the pairing this slice created — eleven rules gained the marker and
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
		return check is RiskyFix || check is OracleAssisted || check is CrossFileFix || check is GroupedFix || check is CarryingFix
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

}
