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
