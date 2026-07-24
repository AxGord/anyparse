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
