package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import anyparse.check.Check.ConfigAware;

/**
 * Flags a type declaration that has grown past a member-count or line-extent
 * threshold — a decomposition candidate the micro-level checks (per-function
 * complexity, style) cannot see. The first TYPE-level metric check: a ratchet
 * that makes god-file debt visible and keeps types from silently growing;
 * report-only, so `fix` produces no edits (splitting a type is `hxq
 * move-member` / `clusters` territory, not a mechanical autofix).
 *
 * ## The metric
 *
 * Two independent thresholds, either one trips the finding (ONE `Warning` per
 * type, reported on the type header):
 *
 * - **member count** — the type body's children whose kind the grammar lists in
 *   `RefShape.memberDeclKinds`, recursing into `#if` conditional-compilation
 *   blocks (`RefShape.conditionalMemberKind`) so guarded members count too;
 *   modifier siblings are not members and are not counted.
 * - **line extent** — the number of source lines the type's span covers.
 *
 * ## Grammar-agnostic
 *
 * Type bodies are the plugin's `RefShape.visibilityContainerKinds` — for Haxe the class-like declarations (class / abstract class / abstract); an interface, enum, enum abstract or typedef is deliberately out of scope (a grammar-sized enum is a definition table, not a decomposition candidate). A grammar that declares no containers or no member kinds makes the check a no-op. The
 * thresholds are the built-in defaults unless a discovered `apqlint.json`
 * configures `maxMembers` / `maxLines` on the `oversized-type` rule.
 */
@:nullSafety(Strict)
final class OversizedType implements Check implements ConfigAware {

	/**
	 * The member count above which a type is flagged — generous enough that only
	 * genuine god-types trip it; used unless an `apqlint.json` configures `maxMembers`.
	 */
	private static inline final DEFAULT_MAX_MEMBERS: Int = 50;

	/**
	 * The line extent above which a type is flagged — generous enough that only
	 * genuine god-files trip it; used unless an `apqlint.json` configures `maxLines`.
	 */
	private static inline final DEFAULT_MAX_LINES: Int = 2000;

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return 'oversized-type';
	}

	public function description(): String {
		return 'a type with too many members or lines — a decomposition candidate';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final containerKinds: Array<String> = shape.visibilityContainerKinds ?? [];
		final memberKinds: Array<String> = shape.memberDeclKinds ?? [];
		if (containerKinds.length == 0 || memberKinds.length == 0) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) {
				final config: LintConfig = LintConfig.resolveWith(_resolveConfig, entry.file);
				final cfg: OversizedCfg = {
					containerKinds: containerKinds,
					memberKinds: memberKinds,
					conditionalKind: shape.conditionalMemberKind,
					maxMembers: config.intOption('oversized-type', 'maxMembers') ?? DEFAULT_MAX_MEMBERS,
					maxLines: config.intOption('oversized-type', 'maxLines') ?? DEFAULT_MAX_LINES
				};
				walk(violations, entry.file, entry.source, tree, cfg);
			}
		}
		return violations;
	}

	/** Splitting a type is a design decision, not a mechanical autofix — report-only. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/**
	 * Walk `node`; for every type-body descendant emit a `Warning` when either
	 * size threshold is exceeded.
	 */
	private static function walk(out: Array<Violation>, file: String, source: String, node: QueryNode, cfg: OversizedCfg): Void {
		if (cfg.containerKinds.contains(node.kind)) checkType(out, file, source, node, cfg);
		for (c in node.children) walk(out, file, source, c, cfg);
	}

	/**
	 * Append ONE `Warning` naming every exceeded threshold when `type` is over either limit. The reported span is the type's HEADER LINE only, NOT the whole body: inline suppression clears a finding whose span covers the `// noqa` line, so a whole-body span would let any unrelated bare `// noqa` deep inside the type silently swallow the type-level finding — and the god-files this check targets are exactly the ones that accumulate those. Suppressing this rule is deliberate: `// noqa: oversized-type` on the header line. Bails (no finding) when the node has no span.
	 */
	private static function checkType(out: Array<Violation>, file: String, source: String, type: QueryNode, cfg: OversizedCfg): Void {
		final span: Null<Span> = type.span;
		if (span == null) return;
		final members: Int = countMembers(type, cfg);
		final lines: Int = lineExtent(source, span);
		final over: Array<String> = [];
		if (members > cfg.maxMembers) over.push('$members members (max ${cfg.maxMembers})');
		if (lines > cfg.maxLines) over.push('$lines lines (max ${cfg.maxLines})');
		if (over.length == 0) return;
		final name: String = type.name ?? '<anonymous>';
		final headerEnd: Int = source.indexOf('\n', span.from);
		out.push({
			file: file,
			span: new Span(span.from, headerEnd == -1 ? span.to : headerEnd),
			rule: 'oversized-type',
			severity: Severity.Warning,
			message: 'type \'$name\' has ${over.join(' and ')} — a decomposition candidate (see hxq clusters)'
		});
	}

	/**
	 * The number of member declarations among `parent`'s children, recursing into `#if` conditional-compilation blocks so guarded members count too — an `#if` and its `#else` branches ALL count (a source-size metric measures what is written, not one compiled configuration). Modifier
	 * siblings (visibility / static runs preceding a member) are separate nodes
	 * whose kinds are not in `memberKinds`, so they are never counted.
	 */
	private static function countMembers(parent: QueryNode, cfg: OversizedCfg): Int {
		var count: Int = 0;
		for (child in parent.children) {
			if (cfg.conditionalKind != null && child.kind == cfg.conditionalKind)
				count += countMembers(child, cfg);
			else if (cfg.memberKinds.contains(child.kind))
				count++;
		}
		return count;
	}

	/** The number of source lines `span` covers — newlines in the slice + 1. */
	private static function lineExtent(source: String, span: Span): Int {
		var lines: Int = 1;
		for (i in span.from ... span.to) if (StringTools.fastCodeAt(source, i) == '\n'.code) lines++;
		return lines;
	}

}

/**
 * Resolved kind-sets and thresholds for the oversized-type walk, built once per
 * file so the recursion threads one struct.
 */
private typedef OversizedCfg = {
	final containerKinds: Array<String>;
	final memberKinds: Array<String>;
	final conditionalKind: Null<String>;
	final maxMembers: Int;
	final maxLines: Int;
};
