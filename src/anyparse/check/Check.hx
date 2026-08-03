package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.runtime.Span;
import anyparse.query.SymbolIndex;

/**
 * One finding produced by a `Check`. `file` is the path the finding
 * belongs to (so a flat `Array<Violation>` from several checks can be
 * grouped back per file); `span` is the source range to report (null
 * when the check cannot resolve one — rendered without a coordinate);
 * `rule` is the producing check's `id()`; `severity` ranks it; `message`
 * is the human-facing description.
 */
typedef Violation = {
	var file: String;
	var span: Null<Span>;
	var rule: String;
	var severity: Severity;
	var message: String;
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
 * run without the key. The first consumer is `explicit-local-type`, whose
 * resolver-unreachable tail (generics / inference) only the compiler can name.
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
