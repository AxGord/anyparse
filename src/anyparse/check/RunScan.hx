package anyparse.check;

import anyparse.check.Check.FixEdit;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * The entry loops every check's `run` and `fix` share: parse each file or skip it, gate on the seams a
 * check resolved from the grammar, and gather what the per-file body produces. Pure statics over the
 * `(files, plugin)` / `(source, plugin)` a check already holds, like `CheckScan`; a sibling module
 * rather than more members of it, so the helper home stays under the type-size ratchet.
 */
@:nullSafety(Strict)
final class RunScan {

	/**
	 * `run` over every file the grammar parses, in the caller's order: `body` sees the entry, its tree and
	 * the one output array, and a file that does not parse is skipped. `parse` overrides the projection
	 * (`CheckScan.parseBranchAwareOrNull` for a branch-aware check).
	 */
	public static function collect(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin,
		body: (entry:{ file: String, source: String }, tree:QueryNode, out:Array<Violation>) -> Void,
		?parse: (plugin:GrammarPlugin, source:String) -> Null<QueryNode>
	): Array<Violation> {
		final parseOrNull: (plugin:GrammarPlugin, source:String) -> Null<QueryNode> = parse ?? CheckScan.parseOrNull;
		final out: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = parseOrNull(plugin, entry.source);
			if (tree != null) body(entry, tree, out);
		}
		return out;
	}

	/**
	 * `collect` gated on a resolved seam bundle: a null `seams` is the grammar lacking the construct, so the
	 * answer is no findings and no file is parsed; otherwise `body` sees the bundle non-null. The loop is
	 * restated rather than routed through `collect`: a generic helper that hands the caller's callback to a
	 * closure of its own makes strict null safety drop every narrowing inside that callback at the call site.
	 */
	public static function collectWith<S>(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, seams: Null<S>,
		body: (entry:{ file: String, source: String }, tree:QueryNode, seams:S, out:Array<Violation>) -> Void,
		?parse: (plugin:GrammarPlugin, source:String) -> Null<QueryNode>
	): Array<Violation> {
		if (seams == null) return [];
		final parseOrNull: (plugin:GrammarPlugin, source:String) -> Null<QueryNode> = parse ?? CheckScan.parseOrNull;
		final out: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = parseOrNull(plugin, entry.source);
			if (tree != null) body(entry, tree, seams, out);
		}
		return out;
	}

	/**
	 * `fix` over ONE source: `body` sees the parsed tree and answers the edits; a source that does not parse
	 * yields none. `parse` overrides the projection as in `collect`.
	 */
	public static function edits(
		plugin: GrammarPlugin, source: String, body: (tree:QueryNode) -> Array<FixEdit>,
		?parse: (plugin:GrammarPlugin, source:String) -> Null<QueryNode>
	): Array<FixEdit> {
		final parseOrNull: (plugin:GrammarPlugin, source:String) -> Null<QueryNode> = parse ?? CheckScan.parseOrNull;
		final tree: Null<QueryNode> = parseOrNull(plugin, source);
		return tree == null ? [] : body(tree);
	}

	/**
	 * `edits` gated on a resolved seam bundle: a null `seams` yields no edits without parsing; otherwise
	 * `body` sees the tree and the bundle non-null. Restated rather than routed through `edits`, for the
	 * reason `collectWith` gives.
	 */
	public static function editsWith<S>(
		plugin: GrammarPlugin, source: String, seams: Null<S>, body: (tree:QueryNode, seams:S) -> Array<FixEdit>,
		?parse: (plugin:GrammarPlugin, source:String) -> Null<QueryNode>
	): Array<FixEdit> {
		if (seams == null) return [];
		final parseOrNull: (plugin:GrammarPlugin, source:String) -> Null<QueryNode> = parse ?? CheckScan.parseOrNull;
		final tree: Null<QueryNode> = parseOrNull(plugin, source);
		return tree == null ? [] : body(tree, seams);
	}

	/**
	 * `run` over every file WITHOUT a parse — the loop of a lexical check that reads comment units or
	 * regions straight off the source; `body` sees the entry and the one output array.
	 */
	public static function gather(
		files: Array<{ file: String, source: String }>, body: (entry:{ file: String, source: String }, out:Array<Violation>) -> Void
	): Array<Violation> {
		final out: Array<Violation> = [];
		for (entry in files) body(entry, out);
		return out;
	}

	/**
	 * The `from:to` key of every spanned violation, in report order — the set a fix walk matches its
	 * candidates against, spelled as `CheckScan.collectSpanEdits` spells its lookup key.
	 */
	public static function spanKeys(violations: Array<Violation>): Array<String> {
		final keys: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) keys.push('${span.from}:${span.to}');
		}
		return keys;
	}

	/** The start offset of every spanned violation, in report order — `spanKeys` for a fix keyed on position alone. */
	public static function spanStarts(violations: Array<Violation>): Array<Int> {
		final starts: Array<Int> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) starts.push(span.from);
		}
		return starts;
	}

	/** The plugin as a `TypeInfoProvider`, or null when the grammar offers no type information. */
	public static function typeInfoOf(plugin: GrammarPlugin): Null<TypeInfoProvider> {
		return plugin is TypeInfoProvider ? cast plugin : null;
	}

	/**
	 * Runs `body` for every spanned violation whose `from:to` key resolves in `byKey`, in report order — the
	 * match loop of a fix that answers more than one edit per finding; `CheckScan.collectSpanEdits` is the
	 * one-edit form.
	 */
	public static function eachMatched<T>(violations: Array<Violation>, byKey: Map<String, T>, body: (match:T, span:Span) -> Void): Void {
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final match: Null<T> = byKey['${span.from}:${span.to}'];
			if (match != null) body(match, span);
		}
	}

	/**
	 * One edit per spanned violation, in report order, skipping the ones `edit` declines with null — the
	 * shape of a fix whose every edit is derived from the finding's own span.
	 */
	public static function spanEdits(
		violations: Array<Violation>, edit: (violation:Violation, span:Span) -> Null<FixEdit>
	): Array<FixEdit> {
		final edits: Array<FixEdit> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final produced: Null<FixEdit> = edit(v, span);
			if (produced != null) edits.push(produced);
		}
		return edits;
	}

	/**
	 * The guard behind `oneFile`, for a fix that needs the assurance and not the name: `Check.fix` takes
	 * ONE file's findings, so an empty list or a mix is the caller's defect and throws under `ruleId`.
	 */
	public static function assertOneFile(violations: Array<Violation>, ruleId: String): Void {
		if (violations.length == 0) throw new Exception('$ruleId: fix() takes ONE file\'s violations, got none');
		final file: String = violations[0].file;
		for (violation in violations) if (violation.file != file)
			throw new Exception('$ruleId: fix() takes ONE file\'s violations, got $file and ${violation.file}');
	}

	/** The one file a `fix` call's violations belong to, after `assertOneFile`'s guard. */
	public static function oneFile(violations: Array<Violation>, ruleId: String): String {
		assertOneFile(violations, ruleId);
		return violations[0].file;
	}

}
