package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * Flags a key-value `for` loop that discards its key with `_` — `for (_ => v in m)`
 * — which reads as `for (v in m)`, since Haxe iterates values by default. `Info` (a
 * modernization matching the idiom), with an autofix that drops the `_ => ` prefix where the iterable is provably an
 * `Array` or `List` (`UnusedLoopBinder.valueIterationProvable`); elsewhere the finding is report-only, since a `Map`
 * re-reads each value by key in `keyValueIterator` and so diverges from `iterator()` once the body removes an entry.
 *
 * A value-discarding `for (_ in m)` (no `=>`) is a legitimate "iterate, ignore the
 * value" loop and is NOT flagged — only the key-value form with a discarded key is.
 *
 * ## Grammar-agnostic
 *
 * The loop kind comes from `RefShape.forStmtKind` (unset → no-op), the discarded KEY
 * from the node's `name`, and the key-value shape from the presence of a
 * `RefShape.iterationValueBinderKinds` child — the VALUE binder node, whose span is
 * the value variable itself. The fix deletes `[key start, value start)`.
 *
 * The key token has no node of its own (it is the loop's `name`), so its start is
 * still located in the source, bounded by the binder's start; a decoy `(` inside a
 * comment between `for` and the real header leaves a slice that is not `_`, which
 * bails. Nothing else is read from the text — the `=>`-in-the-header scan this
 * replaced is what the value binder's node made unnecessary, together with the class
 * of bug where a `=>` inside a header comment decided the shape.
 */
@:nullSafety(Strict)
final class RedundantMapIterKey implements Check {

	/** This check's stable id. */
	private static inline final RULE_ID: String = 'redundant-map-iter-key';

	/** Why a finding over an iterable of unproven type carries no edit. */
	private static inline final UNPROVEN_DECLINE: String =
		'the iterable is not provably an Array or List, whose iterator() yields exactly the values keyValueIterator() does';

	/** The finding where the key provably can go. */
	private static inline final PROVEN_MESSAGE: String = 'this loop discards its key — iterate the values directly: for (v in …)';

	/** The finding where it cannot be proved to — described, not prescribed. */
	private static inline final UNPROVEN_MESSAGE: String =
		'this loop discards its key, but dropping it is not proved to iterate the same values for this iterable';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a key-value for loop that discards its key (for (_ => v in m))';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin);
		return RunScan.collectWith(
			files, plugin, readSeams(plugin.refShape()),
			(entry, tree, s, violations) ->
				walk(violations, entry.file, entry.source, tree, s, proofOf(tree, entry.source, entry.file, plugin, index))
		);
	}

	/**
	 * Drop the `_ => ` discarded-key prefix from each flagged loop header — only where the iterable
	 * provably iterates the same values through `iterator()` as through `keyValueIterator()`
	 * (`NominalTypes.valueIterationProvable`), both when the finding was reported and now. Elsewhere
	 * the finding stays report-only with a
	 * `declineReason`: a `Map`'s two iterators diverge once the body removes an entry, and a type of
	 * unknown shape may have no `iterator()` at all.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		if (violations.length == 0) return [];
		final file: String = RunScan.oneFile(violations, RULE_ID);
		return RunScan.editsWith(plugin, source, readSeams(plugin.refShape()), (tree, s) -> {
			final nodeByKey: Map<String, QueryNode> = [];
			indexFor(tree, s.forStmtKind, nodeByKey);
			final provable: (
				loop:QueryNode, valueBinderKinds:Array<String>
			) -> Bool = proofOf(
				tree, source, file, plugin,
				RefactorSupport.lazySymbolIndex(
					[{ file: file, source: source }], plugin, RefactorSupport.resolutionIndexOf(plugin) ?? index
				)
			);
			final edits: Array<{ span: Span, text: String }> = [];
			for (v in violations) {
				final span: Null<Span> = v.span;
				final node: Null<QueryNode> = span == null ? null : nodeByKey['${span.from}:${span.to}'];
				if (node == null) continue;
				final cut: Null<Span> = keyPrefixSpan(node, source, s.valueBinderKinds);
				if (cut == null) continue;
				if (v.message != PROVEN_MESSAGE || !provable(node, s.valueBinderKinds)) {
					v.declineReason = UNPROVEN_DECLINE;
					continue;
				}
				edits.push({ span: cut, text: '' });
			}
			return edits;
		});
	}

	/** The loop kind and the value-binder kinds, or null when the grammar names no `for` statement (the check is then a no-op). */
	private static function readSeams(shape: RefShape): Null<Seams> {
		final forStmtKind: Null<String> = shape.forStmtKind;
		return forStmtKind == null ? null : { forStmtKind: forStmtKind, valueBinderKinds: shape.iterationValueBinderKinds ?? [] };
	}

	/**
	 * Whether a loop's key may be dropped — `NominalTypes.valueIterationProvable` over its iterable,
	 * with the file's declared types and import map read on first demand.
	 */
	private static function proofOf(
		tree: QueryNode, source: String, file: String, plugin: GrammarPlugin, index: () -> Null<SymbolIndex>
	): (loop:QueryNode, valueBinderKinds:Array<String>) -> Bool {
		final typed: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		final facts: Array<{ types: Map<Int, String>, imports: Map<String, String> }> = [];
		return (loop, valueBinderKinds) -> {
			final iterable: Null<QueryNode> = NominalTypes.iterationIterable(loop, valueBinderKinds);
			if (iterable == null) return false;
			if (facts.length == 0) facts.push(factsOf(typed, source, file));
			return NominalTypes.valueIterationProvable(iterable, tree, plugin.refShape(), facts[0].types, index(), file, facts[0].imports);
		};
	}

	/** The file's declared types and import map, both empty without type information. */
	private static function factsOf(
		typed: Null<TypeInfoProvider>, source: String, file: String
	): { types: Map<Int, String>, imports: Map<String, String> } {
		return typed == null ? { types: [], imports: [] } : { types: typed.declaredTypes(source), imports: typed.importMap(source, file) };
	}

	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, s: Seams,
		provable: (loop:QueryNode, valueBinderKinds:Array<String>) -> Bool
	): Void {
		if (node.kind == s.forStmtKind && node.name == '_' && keyPrefixSpan(node, source, s.valueBinderKinds) != null) {
			final span: Null<Span> = node.span;
			if (span != null) out.push({
				file: file,
				span: span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: provable(node, s.valueBinderKinds) ? PROVEN_MESSAGE : UNPROVEN_MESSAGE
			});
		}
		// Descend regardless of a match: a discarded-key loop can nest inside another
		// (`for (_ => v in m) for (_ => w in v) …`), and the two are independent — fixing
		// the outer header does nothing for the inner — so both must be reported.
		for (c in node.children) walk(out, file, source, c, s, provable);
	}

	/**
	 * The span `[keyStart, valueStart)` to delete for a `for (_ => v in …)` loop whose
	 * key is `_` — null when the loop binds no value (a value-only `for (_ in m)`) or the
	 * key token cannot be located.
	 */
	private static function keyPrefixSpan(node: QueryNode, source: String, valueBinderKinds: Array<String>): Null<Span> {
		final forSpan: Null<Span> = node.span;
		final binder: Null<QueryNode> = NominalTypes.iterationValueBinder(node, valueBinderKinds);
		final valueSpan: Null<Span> = binder?.span;
		if (forSpan == null || valueSpan == null) return null;
		final open: Int = source.indexOf('(', forSpan.from);
		if (open < 0 || open >= valueSpan.from) return null;
		final arrow: Int = source.lastIndexOf('=>', valueSpan.from);
		if (arrow < open) return null;
		final keyStart: Int = skipSpace(source, open + 1, valueSpan.from);
		// Guard the source scan: the text from the key start to the `=>` must be exactly
		// the discarded key `_`. If the located `(` was a decoy (e.g. one inside a comment
		// between `for` and the real header), this slice is not `_`, so bail — no bogus
		// finding, no corrupt fix.
		return if (source.substring(keyStart, arrow).trim() != '_')
			null
		else if (keyStart < valueSpan.from)
			new Span(keyStart, valueSpan.from)
		else
			null;
	}

	/** First index at or after `from` (bounded by `stop`) that is not ASCII whitespace. */
	private static function skipSpace(source: String, from: Int, stop: Int): Int {
		var i: Int = from;
		while (i < stop) {
			final c: Int = source.fastCodeAt(i);
			if (c != ' '.code && c != '\t'.code && c != '\n'.code && c != '\r'.code) break;
			i++;
		}
		return i;
	}

	/** Index every for-loop node by its `from:to` span key. */
	private static function indexFor(node: QueryNode, forStmtKind: String, out: Map<String, QueryNode>): Void {
		if (node.kind == forStmtKind) {
			final span: Null<Span> = node.span;
			if (span != null) out['${span.from}:${span.to}'] = node;
		}
		for (c in node.children) indexFor(c, forStmtKind, out);
	}

}

/** The grammar seams `redundant-map-iter-key` reads: the loop kind it flags, and the kinds its VALUE binder projects as. */
private typedef Seams = {
	var forStmtKind: String;
	var valueBinderKinds: Array<String>;
};
