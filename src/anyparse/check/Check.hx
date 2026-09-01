package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * One finding produced by a `Check`. `file` is the path the finding
 * belongs to (so a flat `Array<Violation>` from several checks can be
 * grouped back per file); `span` is the source range to report (null
 * when the check cannot resolve one — rendered without a coordinate);
 * `rule` is the producing check's `id()`; `severity` ranks it; `message`
 * is the human-facing description; the optional `declineReason` is
 * why no autofix edit was produced for it.
 */
typedef Violation = {
	var file: String;
	var span: Null<Span>;
	var rule: String;
	var severity: Severity;
	var message: String;

	/**
	 * Why THIS finding got no autofix edit, in the producing check's OWN words, or null —
	 * the default, and the state of every finding nothing declined.
	 *
	 * Written AT the site that declines, by the code that decides to decline: in `run` when a
	 * whole-scope gate closes before any edit is computed (`prefer-typed-throw`'s catch-clause
	 * scan), inside `fix` when the gate is per-site (`import-order`'s same-simple-name guard —
	 * `fix` is handed the caller's OWN violation objects, so a note set there reaches the
	 * reporter). Writing it anywhere else means inventing a reason, which is the defect the
	 * field exists to end.
	 *
	 * Only `apq lint --fix`'s per-rule unfixed ledger reads it. The text report and the json /
	 * checkstyle records are built field by field from the other five, so a rule that adopts
	 * this one changes no reported byte.
	 */
	@:optional var declineReason: Null<String>;
}

/**
 * A single analysis check. The framework is grammar-agnostic: a check
 * receives the same in-memory `(file, source)` set the query layer uses
 * plus the `GrammarPlugin` for the language, and returns the violations
 * it found across all of them. A check that parses a file itself is
 * responsible for skipping (not throwing on) unparseable input — the
 * `Linter` does not catch per-check exceptions, so a check must be as
 * tolerant as `SymbolIndex.build`.
 *
 * This is the documented extension seam of the analysis layer, mirroring
 * the `Strategy` / `Format` / `GrammarPlugin` plugin contracts: a new
 * check is a new class, never a core change. `run` is the only behaviour;
 * `id` / `description` are metadata for the `lint` CLI's selection and
 * usage output.
 */
@:nullSafety(Strict)
interface Check {

	/** Stable kebab-case identifier, e.g. `unused-import`. */
	public function id(): String;

	/** One-line description for `lint --help` / the rule listing. */
	public function description(): String;

	/**
	 * Run the check across `files` and return every violation found, in
	 * the check's natural order. Must not throw on unparseable input.
	 *
	 * CONSUMERS: call `Linter.collect` (or `Linter.run`) rather than this directly — that is where the
	 * central reification gate drops a finding written inside a `macro …` quotation, and a consumer
	 * that reaches past it silently re-opens the class of bug the gate exists for.
	 */
	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation>;

	/**
	 * The source edits that fix the auto-fixable subset of `violations` —
	 * the caller passes this check's OWN violations for ONE file (same
	 * `source`). Each edit is a raw `{span, text}` the caller batches into a
	 * single `RefactorSupport.canonicalize` per file, so several fixes apply
	 * without the span-shift a re-emit-per-fix would cause (`text` replaces
	 * `[span.from, span.to)`; empty = a deletion). A check with no autofix,
	 * or none applicable to these violations, returns an empty array — that
	 * is the default for any non-fixable check.
	 *
	 * JUSTIFICATION CONTRACT: every emitted edit must be justified by a
	 * violation in THIS call. `violations` is always a SUBSET of what `run`
	 * reported — `Linter.collect` drops the quoted and the suppressed before
	 * any fix path sees a finding — so an edit derived from the SOURCE rather
	 * than from `violations` can outlive the finding that motivated it. The
	 * worked example is on `GroupedFix`, whose grouping seam says which edits
	 * are inseparable, never that one is deserved.
	 *
	 * SAYING WHY NOTHING CAME BACK: an empty array is the same answer for a
	 * check that has NO autofix and for one whose gate declined HERE, and
	 * `apq lint --fix` reported the two identically until a reader filed work
	 * on a guard the rule already had. A check with no autofix at all declares
	 * `NoAutofix` and gives the reason once, on the class; a check that HAS a
	 * fix and withholds it at a site writes `Violation.declineReason` on that
	 * finding, naming the gate — here, or in `run` when the gate is
	 * whole-scope. Declaring neither is allowed and is not a defect: the run
	 * then reports only what it observed, that the fix was called for these
	 * findings and answered nothing.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }>;

}

/**
 * A `Check` that reads per-file `apqlint.json` OPTIONS (e.g. complexity `max`,
 * magic-number `ignore`, thread-safety `sinks`) while it runs — as opposed to
 * enablement / severity, which the framework applies after the fact. `Linter.run`
 * injects the caller's memoised per-file resolver so a large run does not re-walk
 * the ancestor directories and re-parse the JSON once per file per check. A check
 * invoked directly (a unit `check.run`) is never injected and falls back to its own
 * `LintConfig.discover`, so it still resolves config correctly — just unmemoised.
 */
@:nullSafety(Strict)
interface ConfigAware {

	/** Inject the linter's per-file config resolver, or null to fall back to `discover`. */
	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void;

}

/**
 * Opt-OUT marker for a `Check` that legitimately needs to see INSIDE a `macro …` quotation.
 *
 * By default every finding whose span sits inside a reification subtree is dropped before it is
 * ever reported or fixed — source written there is the AST the surrounding program BUILDS, so a
 * rewrite that is equivalent anywhere else hands the macro different data instead, and a
 * report-only finding there is un-actionable besides (see `ReificationScan`). The drop is applied
 * once, in `Linter.collect`, through which every consumer of a check's findings reads them.
 *
 * NOTHING implements this today, and no builtin should without a reason written down beside it.
 * The slot exists so the central drop is a policy a future check can DECLINE rather than a trap
 * it cannot see: a check that analyses quotations AS DATA — a macro-hygiene rule, a reification
 * linter — would otherwise silently report nothing at all and give no hint why.
 */
@:nullSafety(Strict)
interface QuotationAware {}

/**
 * Opt-in marker for a `Check` whose `fix()` edits are STRUCTURALLY RISKY — a
 * rewrite or deletion NOT gated by a structurally-provable shape invariant, so
 * it can emit parseable-but-miscompiling output (the class of bug the 2026-07
 * autofix campaign found report-canaries missed and only a real `--fix` +
 * typecheck caught). A check that does NOT implement this marker is trusted and
 * applied unverified — the default, and the state of EVERY builtin today.
 *
 * When the project configures a compiler oracle (`apqlint.json` `compilerOracle`),
 * `apq lint --fix` applies a `RiskyFix` check's edits speculatively, typechecks
 * the project, and REVERTS any file whose risky edit breaks the build — that
 * file's finding degrades to report-only. Without an oracle configured, a risky
 * check is left report-only wholesale (its `fix()` never runs), so the no-oracle
 * path is byte-identical to a run with no risky checks at all. The intended
 * first consumers are a future avoid-dynamic fix and any rewrite lacking a
 * provable shape gate; the machinery lives in `FixVerifier` / `CompilerOracle`.
 */
interface RiskyFix {}
/**
 * Opt-in MARKER of a `Check` that reads the project's framework roster
 * (`LintConfig.frameworksFor`) — the `apqlint.json` `frameworks` contracts naming which member
 * names a framework reaches by name, on which root types.
 *
 * Its one consumer is `Cli.runLint`, which warns when a lint scope spans `apqlint.json` roots
 * that disagree about that roster. The warning says the first root's roster "applies to all N
 * file(s)", and that sentence is only true when some rule in the run actually reads one: a
 * `--rule prefer-single-quotes` run over two such roots applies no roster at all and gets no
 * line. Gating on this marker is what keeps the diagnostic from being a claim about work the
 * run did not do — the same defect, in the opposite direction, as the silence it replaced.
 *
 * DECLARED rather than inferred from "who calls `frameworksFor`": that caller list is invisible
 * from the CLI, and a fifth consumer added without the marker would silently re-open the gap.
 */

interface FrameworkAware {}

/**
 * Opt-in capability of a `RiskyFix` `Check` whose autofix has a RELAXED candidate set the
 * compiler oracle unlocks. `Cli.applyLintFixes` calls `setOracleRelaxed(true)` exactly when it
 * moves the check into the verified `RiskyFix` path (an oracle is configured), so the check may
 * drop a structural gate it keeps for the no-oracle safe path and emit the extra candidates —
 * always applied through the typecheck-and-revert pipeline, never unverified. Without the call
 * (no oracle, or a non-relaxable risky check) the gate stays on. The first consumer is
 * `prefer-inline`, which drops its null-safety gate to reach object-literal / block-lambda bodies.
 */
@:nullSafety(Strict)
interface OracleRelaxable {

	/** Toggle the oracle-relaxed candidate set (see the type doc). */
	public function setOracleRelaxed(relaxed: Bool): Void;

}

/**
 * Opt-in marker for a `Check` that is OFF by default — dropped from the default
 * check set and from a bare `lint … --all` report unless a project explicitly
 * opts in via `apqlint.json` (`"rules": { "<id>": { "enabled": true } }`), or an
 * explicit `--rule <id>` selects it (which bypasses enablement, as for every rule).
 * The framework reads the marker where it applies enablement (`Cli.runLint` builds
 * the active set; `Linter.run` drops a disabled finding), inverting the
 * default-enabled assumption for these rules only. A check that does NOT implement
 * this marker is ON by default — the state of every other builtin. The first
 * consumer is `explicit-local-type`, a per-project style preference.
 */
@:nullSafety(Strict)
interface DefaultOff {}

/**
 * A check whose FIX emits syntax the language only gained at a given version.
 *
 * `??` and `?.` are Haxe 4.3; `haxe.Exception` is 4.1. A rule that rewrites into one of
 * them is correct on a project targeting that version and a silent portability break on a
 * project that does not — and nothing in the tree says which. On one library the three
 * rules in this family moved `??` from a single module into 27 (core types among them) and
 * raised the floor of 15 more modules from 4.0 to 4.1, all of which had to be undone by
 * hand alongside 54 existing `#if (haxe_ver >= 4.2)` guards.
 *
 * A project states its floor once (`apqlint.json` `languageVersion`), and a rule declaring
 * a higher minimum is dropped for that file. No declared version means no constraint —
 * the behaviour every existing config already has.
 *
 * `--rule <id>` still force-enables, exactly as it does for a config-disabled rule: an
 * explicit selection is the user overruling the project's own default.
 */
interface VersionGated {

	/** The lowest language version whose syntax this rule's fix may emit, as a dotted string (`'4.3'`). */
	function minLanguageVersion(): String;

}

/**
 * The type-query seam a `CompilerOracle`-backed display server exposes to an
 * `OracleAssisted` check: `typeAt` returns the compiler's OWN inferred type at a
 * byte position (the local's name token), or null when the position carries no
 * type / the query failed. The type text is already XML-decoded and trimmed — the
 * fully-qualified, possibly-generic form the compiler prints (`haxe.ds.Map<String, Int>`);
 * the check normalises and rejects it. The concrete implementation
 * (`CompilerDisplayOracle`) drives the Haxe display protocol against a warm
 * compilation server, but the seam is compiler-agnostic — a test double supplies
 * canned types with no process.
 */
@:nullSafety(Strict)
interface TypeOracle {

	/** The compiler's inferred type at `bytePos` in `file` (XML-decoded, trimmed), or null when none / the query failed. */
	public function typeAt(file: String, bytePos: Int): Null<String>;

}

/**
 * Opt-in marker for a `Check` whose autofix needs the compiler ORACLE while it
 * COMPUTES its edits (not merely to verify them afterwards, as `RiskyFix` does) —
 * a type the check cannot resolve structurally is asked of the `TypeOracle`. Active
 * ONLY when the project configures a `compilerOracle`; `Cli.applyLintFixes` then runs
 * `fixWithOracle` for each unfixed finding, applies the edits per file, and verifies
 * the file still typechecks (reverting it otherwise — the report-only fallback). With
 * no oracle configured the seam is never entered, so behaviour is byte-identical to a
 * run without the key. The consumers are `explicit-local-type`, whose resolver-unreachable
 * tail (generics / inference) only the compiler can name, `avoid-dynamic`, and
 * `explicit-type`, whose non-Void return types have no structural evidence at all.
 */
@:nullSafety(Strict)
interface OracleAssisted {

	/**
	 * The oracle-assisted source edits for `violations` (this check's OWN, for ONE
	 * `source` / file), each a raw `{span, text}` the caller batches into a single
	 * `RefactorSupport.canonicalize` — the same contract as `Check.fix`, but free to
	 * consult `oracle` for a type it cannot pin structurally. A finding the oracle
	 * cannot soundly type yields no edit.
	 */
	public function fixWithOracle(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, oracle: TypeOracle
	): Array<{ span: Span, text: String }>;

}

/**
 * One file's slice of a cross-file rename: the file path plus the raw
 * `{span, text}` edits that fall within THAT file's source. A `CrossFileFix`
 * groups its edits this way so `apq lint --fix` can canonicalize each affected
 * file independently while committing the whole rename atomically.
 */
typedef CrossFileEdits = {
	final file: String;
	final edits: Array<{ span: Span, text: String }>;
};

/**
 * Opt-in capability of a `Check` whose autofix spans MULTIPLE files atomically —
 * a rename whose references live in files OTHER than the one carrying the
 * violation (a private field read by a subtype, an `@:access` grantee). The
 * per-file `fix` seam cannot express this: its edits all land in one `source`.
 *
 * `crossFileFix` returns a list of INDEPENDENT renames; each rename is the set
 * of per-file edit slices (`CrossFileEdits`) that must all apply or none. `apq
 * lint --fix` canonicalizes every affected file and commits a rename only when
 * EVERY file's canonicalization succeeds — any failure reverts the whole rename
 * (the `CrossRename` / `CrossRenameMember` all-or-nothing contract, routed
 * through the lint pipeline). A check with no cross-file fix returns an empty
 * array. The first (and only) consumer is `naming`, for a non-confined private
 * field whose references cross into its subtypes / `@:access`-grant files.
 */
@:nullSafety(Strict)
interface CrossFileFix {

	/**
	 * The cross-file renames fixing `violations` (this check's OWN, across ALL
	 * `files`). `plugin` carries the resolution scope (report UNION libraries) for
	 * the checks that consult it; `index` is the report-scoped `SymbolIndex`. Each
	 * returned rename is a set of per-file `CrossFileEdits` the caller applies
	 * atomically. An empty array = nothing to fix.
	 */
	public function crossFileFix(
		files: Array<{ file: String, source: String }>, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<Array<CrossFileEdits>>;

}

/**
 * One fix edit plus the ATOMIC GROUP it belongs to. `span` / `text` are the raw edit
 * `Check.fix` returns (`text` replaces `[span.from, span.to)`, empty = a deletion);
 * `group` names the unit the edit may only be kept or dropped WITH. A null `group` is
 * the default and means independently revertible — exactly what every edit is today.
 * Ids are opaque and scoped to ONE `fixGrouped` call: equal non-null ids mean one
 * indivisible unit, and nothing more.
 */
typedef GroupedEdit = {
	final span: Span;
	final text: String;
	final group: Null<Int>;
}

/**
 * Opt-in capability of a `Check` whose autofix edits are NOT all independently
 * revertible — some of them only make sense together. The motivating class is the
 * ORPHAN IMPORT: a rewrite that shortens a qualified type reference also inserts the
 * `import` the short name needs, and dropping the rewrites while KEEPING the import
 * leaves a file that still compiles, so a verifier probing subsets has no way to tell
 * that subset is wrong. The flat `Array<{span, text}>` of `Check.fix` carries no slot
 * to say so; this seam adds one.
 *
 * The ONLY consumer is `FixVerifier`'s bisect, so grouping is honoured ONLY on the
 * `RiskyFix` path that verifier serves — and both implementors today are `RiskyFix`.
 * It is not honoured in the safe fix loop, which is also capable of splitting an edit
 * set: `Cli.computeFileLintEdits` gates per CHECK (`editsOverlapAny`) but then filters
 * per EDIT through `RefactorSupport.dropContainedEdits`. A `RiskyFix` check never
 * enters that loop (`Cli.applyLintFixes` routes it to the verifier instead), which is
 * why the gap is theoretical today — a future `GroupedFix` check that is NOT also
 * `RiskyFix` would have no grouping guarantee. `Cli`'s oracle-assisted batch is the
 * one path that genuinely cannot break a group: `verifyOracleBatch` restores a whole
 * file's `before`. A check that does not implement this interface is bisected per edit
 * exactly as before, byte for byte.
 *
 * CONTRACT: the justification rule on `Check.fix` binds here too, and grouping is where it is
 * easiest to lose. `shorten-type-ref` shipped the worked example: its `import` insert was
 * planned per source path and pushed whenever ANY rewrite survived, so a path whose every
 * occurrence carried a `noqa` left an orphan import behind — an edit no surviving violation
 * asked for, riding in a group with rewrites it had nothing to do with. Deriving an edit from
 * the SOURCE is what invites it; a group id does not make an edit deserved.
 *
 * CONTRACT: a `GroupedFix`'s `Check.fix` MUST be the pure projection of `fixGrouped`
 * (`[for (e in fixGrouped(...)) { span: e.span, text: e.text }]`), so the flat and the
 * grouped view can never disagree about WHICH edits a fix produces — only about how
 * they may be split. Nothing detects a divergence, so the obligation is on the
 * implementor.
 */
@:nullSafety(Strict)
interface GroupedFix {

	/**
	 * The same edits `Check.fix` returns for `violations` (this check's OWN, for ONE
	 * `source`), each carrying the atomic group it belongs to. A null `group` is an
	 * independently revertible edit; edits sharing a non-null id are kept or dropped
	 * together by the verifier's bisect. An empty array = nothing to fix.
	 */
	public function fixGrouped(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<GroupedEdit>;

}

/**
 * Opt-in declaration that a `Check` has NO autofix AT ALL — report-only BY DESIGN, rather
 * than because a gate closed on this run.
 *
 * The two readings of an unfixed finding — the rule CANNOT fix, or its fix DECLINED here —
 * were indistinguishable from outside, and `Check` had no slot that told them apart:
 * `fix` answers an empty array for both. `apq lint --fix`'s own tail spelled the ambiguity
 * out ("the check has no autofix, or when its fix declined here") and three readers took
 * the first branch; two of them filed work on it, and both rules HAD a fix —
 * `import-order`'s already carried the guard the work was to invent, `prefer-typed-throw`'s
 * is closed wholesale by a project-wide catch-clause gate.
 *
 * A check implementing this says the first reading is the true one, and `noAutofixReason`
 * says why a machine must not do the rewrite. A check that does NOT implement it is NOT
 * thereby claiming an autofix: the `--fix` ledger reports what it OBSERVED (the fix was
 * called for these findings and returned no edit) instead of guessing, which is where every
 * builtin starts. The declaration only upgrades that observation into a verdict.
 *
 * The other half of the same question — a check that HAS a fix and withheld it at one site —
 * is `Violation.declineReason`, written where the decline happens.
 */
@:nullSafety(Strict)
interface NoAutofix {

	/**
	 * Why the finding cannot be mechanised: a lower-case fragment the run prints after
	 * `no autofix by design — `, in terms a reader can act on ("which decomposition is right is
	 * a human call"), never a restatement of the rule name.
	 */
	public function noAutofixReason(): String;

}

/**
 * Opt-in declaration that part of this check's MESSAGE is a source MEASUREMENT — a
 * position or an extent that moves under an edit which is not a finding — and how to
 * blank it out for the purpose of IDENTITY.
 *
 * `apq lint-diff` keys a finding on `(file, rule, severity, message)`: line and column
 * are already excluded because they re-key every finding below an insertion. The message
 * carries the same hazard one field over, for the rules that quote a coordinate INSIDE it.
 * `duplicate-code` names its partner block `<path>:<line>`; `unused-local` names the
 * re-declaration that took a binding over; `oversized-type` quotes the type's line extent.
 * All three re-key on an edit that changed no finding, and the blast-radius gate then
 * reports movement where nothing moved — measured on one writer slice as eight moves
 * (`WrapList` / `WriterLowering` / `Cli` / `SymbolIndex`, 4184 lines against 4194) with
 * total findings 2256 against a base of 2256. A gate waived by reflex has stopped being a
 * gate, so the identity must not carry the drifting quantity.
 *
 * The MESSAGE keeps it. "This type is too big" without a size is useless, and the reader who
 * wants 4184 -> 4194 finds it in the two REPORTS — so identity and message come apart here
 * rather than the numbers coming out of the prose. `lint-diff` itself prints the KEY as its
 * example line, masked digits and all, because that is what it compared; a raw number there
 * would contradict the verdict beside it.
 *
 * The check declares this about ITSELF, and `lint-diff` holds no list of rules: the
 * registry is asked which of its checks implement this interface (`Linter.messageIdentities`),
 * so a new rule that quotes a coordinate is covered by writing this one method — never by
 * editing the consumer. That inversion is the point; the hard-coded pair of rule ids it
 * replaced could only ever be right for the rules someone had already tripped over.
 *
 * What must NOT be masked: a quantity that IS the finding. `oversized-type`'s member count,
 * `string-literal-dup`'s repetition count and `complexity`'s score all change only when the
 * code changes, and masking them would turn the gate off for exactly the movement it exists
 * to catch. `MessageMask`'s anchored primitives are narrow for that reason.
 */
@:nullSafety(Strict)
interface VolatileMessage {

	/**
	 * `message` — one this check's own `run` produced — with every source MEASUREMENT in it
	 * masked, and everything else left byte-identical. Must be idempotent, must be derived
	 * from `message` alone — not from instance state, which is why the registry may bind this
	 * method on a check it never configured — and must keep every quantity a reader would call
	 * a finding.
	 *
	 * Build it with `MessageMask.maskAfter` / `maskBefore`, anchored on the SAME constant the
	 * message was built from, so the two cannot drift apart; and pin it in the check's own
	 * test against a message `run` produced, never against a hand-written one — a missing
	 * anchor is a silent no-op that restores the false movement.
	 */
	public function messageIdentity(message: String): String;

}
