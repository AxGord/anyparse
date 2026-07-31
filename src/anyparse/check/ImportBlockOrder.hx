package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.ImportOrder;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import haxe.ds.ArraySort;

using Lambda;

/** One plain `import` line of a block: the path it names, its declaration start, and the WHOLE-LINE region that moves with it. */
private typedef ImportLine = {
	var path: String;
	var declFrom: Int;
	var chunkFrom: Int;
	var chunkTo: Int;
}

/**
 * Flags a contiguous block of plain `import` statements that carries NO recognisable order —
 * neither plain codepoint order nor the case-folded one an IDE's "organize imports" produces
 * (`ImportOrder`). The typical shape is one import appended past a block that was otherwise in
 * order, which is what an inserting fixer leaves behind when it cannot read the block's order.
 *
 * DEFAULT OFF (`DefaultOff`) — import layout is a project convention, not a defect: opt in with
 * `"import-order": { "enabled": true }`.
 *
 * ## What counts as a block
 *
 * A maximal run of TOP-LEVEL plain `import` statements on consecutive lines. A run ENDS at:
 *
 *  - a blank line (the visual groups a project separates its imports into are preserved —
 *    each group is ordered on its own, and no line ever crosses a group boundary);
 *  - any other top-level declaration between two imports — a `using`, a wildcard `import
 *    pkg.*;`, an aliased `import a.B as C;`, a `#if` region, a type declaration;
 *  - a BLOCK comment between two imports (only whole-line `//` comments are pinned; see below).
 *
 * `using` is never part of a run and is never reordered: Haxe ranks static extensions in
 * REVERSE declaration order, so a `using`'s position is semantics rather than layout. A
 * wildcard and an alias split a run for the same reason in miniature — both bind names the
 * ordering cannot see.
 *
 * ## Autofix
 *
 * A pure REORDER of complete lines: each import moves as its own whole line, together with the
 * whole-line `//` comments directly above it and any trailing `// …` on its own line. Nothing
 * is reflowed, rewritten, added or deleted — the fix's output is a permutation of the block's
 * own lines, so it cannot change what the file means beyond the order of the imports.
 *
 * The reorder is REFUSED (finding stays report-only) when order is load-bearing or the lines
 * are not cleanly separable:
 *
 *  - two imports in the run bind the same SIMPLE name (`a.Widget` + `b.Widget`): Haxe accepts
 *    both and lets the LAST one win, so their relative order decides which type the short name
 *    means;
 *  - two imports name the same path (a duplicate — `duplicate-import`'s finding, not this
 *    rule's, and deleting is its call);
 *  - an import shares its source line with anything but a trailing `//` comment.
 *
 * ## Options
 *
 *  - `order` — the order a block must carry: `any` (default) accepts EITHER recognised order
 *    and reports only a block explained by neither; `ascii` requires plain codepoint order;
 *    `case-insensitive` requires the case-folded one. The autofix sorts under the named order,
 *    and under `any` sorts a block under whichever order it breaks LEAST often — the convention
 *    it was nearly following, so one appended line moves instead of the whole block.
 */
@:nullSafety(Strict)
final class ImportBlockOrder implements Check implements DefaultOff implements ConfigAware {

	private static inline final RULE_ID: String = 'import-order';

	/** The `order` option value accepting EITHER recognised order — the default, and the least opinionated reading. */
	private static inline final ORDER_ANY: String = 'any';

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a block of plain imports carrying no recognisable order';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final config: LintConfig = LintConfig.resolveWith(_resolveConfig, entry.file);
			final requested: Int = requestedOrder(config);
			for (block in blocksOf(entry.source, tree)) {
				final paths: Array<String> = [for (line in block) line.path];
				if (acceptable(paths, requested)) continue;
				final offender: ImportLine = firstOutOfPlace(block, fixOrder(requested, paths));
				violations.push({
					file: entry.file,
					span: new Span(offender.declFrom, offender.declFrom + 'import'.length),
					rule: RULE_ID,
					severity: Severity.Warning,
					message: 'import \'${offender.path}\' is out of order in its block'
				});
			}
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		if (violations.length == 0) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final config: LintConfig = LintConfig.resolveWith(_resolveConfig, violations[0].file);
		final requested: Int = requestedOrder(config);
		final flagged: Array<Int> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push(span.from);
		}
		final edits: Array<{ span: Span, text: String }> = [];
		for (block in blocksOf(source, tree)) {
			if (!block.exists(line -> flagged.contains(line.declFrom))) continue;
			if (!reorderable(block)) continue;
			final order: Int = fixOrder(requested, [for (line in block) line.path]);
			final sorted: Array<ImportLine> = block.copy();
			ArraySort.sort(sorted, (a, b) -> ImportOrder.compare(order, a.path, b.path));
			final from: Int = block[0].chunkFrom;
			final to: Int = block[block.length - 1].chunkTo;
			final text: String = [for (line in sorted) source.substring(line.chunkFrom, line.chunkTo)].join('');
			if (text != source.substring(from, to)) edits.push({ span: new Span(from, to), text: text });
		}
		return edits;
	}

	/** The `order` option as an `ImportOrder` id, or -1 for `any` (the default, and any unrecognised value). */
	private function requestedOrder(config: LintConfig): Int {
		final name: Null<String> = config.stringOption(RULE_ID, 'order');
		return name == null || name == ORDER_ANY ? -1 : ImportOrder.orderNamed(name);
	}

	/**
	 * The order the autofix sorts a block under: the REQUESTED one, or — under `any` — the order
	 * that best explains the block already. Sorting an appended-to case-folded block under the
	 * codepoint reading would rewrite every one of its upper/lower boundaries to move the one
	 * line that is actually out of place, which is not the repair the finding described.
	 */
	private static function fixOrder(requested: Int, paths: Array<String>): Int {
		return requested < 0 ? ImportOrder.bestOrder(paths) : requested;
	}

	/** Whether `paths` satisfies the requested order — either recognised order when none was requested. */
	private static function acceptable(paths: Array<String>, requested: Int): Bool {
		return requested < 0 ? ImportOrder.orderOf(paths) >= 0 : ImportOrder.sortedUnder(paths, requested);
	}

	/** The first block member that sorts BEFORE its predecessor under `order` — the line the finding points at. */
	private static function firstOutOfPlace(block: Array<ImportLine>, order: Int): ImportLine {
		for (i in 1...block.length) if (ImportOrder.compare(order, block[i - 1].path, block[i].path) > 0) return block[i];
		// Unreachable for a reported block (it is out of order under the fix order too, since the
		// requested order is what judged it); the first member is the safe coordinate regardless.
		return block[0];
	}

	/**
	 * Whether the block's lines may be permuted at all — see the class doc's refusal list. Order
	 * is load-bearing when two imports bind one simple name (Haxe lets the LAST win) and a
	 * duplicated path belongs to `duplicate-import`, not to a reorder.
	 */
	private static function reorderable(block: Array<ImportLine>): Bool {
		final names: Array<String> = [];
		final paths: Array<String> = [];
		for (line in block) {
			final simple: String = lastSegment(line.path);
			if (names.contains(simple) || paths.contains(line.path)) return false;
			names.push(simple);
			paths.push(line.path);
		}
		return true;
	}

	/**
	 * The file's plain-import BLOCKS: maximal runs of top-level `ImportDecl` statements whose
	 * whole-line regions are directly adjacent, so anything between two of them — a blank line, a
	 * `using`, a wildcard / alias import, a `#if` region, a block comment — ends the run.
	 */
	private static function blocksOf(source: String, tree: QueryNode): Array<Array<ImportLine>> {
		final out: Array<Array<ImportLine>> = [];
		var current: Array<ImportLine> = [];
		for (c in tree.children) {
			final line: Null<ImportLine> = c.kind == 'ImportDecl' ? importLineOf(source, c) : null;
			if (line == null) {
				if (current.length > 1) out.push(current);
				current = [];
				continue;
			}
			// Directly adjacent = nothing at all between the previous line's end and this one's
			// start; a blank line or any other text is what ends the run.
			if (current.length > 0 && current[current.length - 1].chunkTo != line.chunkFrom) {
				if (current.length > 1) out.push(current);
				current = [];
			}
			current.push(line);
		}
		if (current.length > 1) out.push(current);
		return out;
	}

	/**
	 * The whole-line region that moves with the import `node`, or null when the statement is not
	 * cleanly separable: its line carries code before it, or something other than a `//` comment
	 * after it. The region extends BACKWARD over the whole-line `//` comments directly above the
	 * statement (a comment written for an import travels with it) and FORWARD over the rest of
	 * the statement's own line, its newline included.
	 */
	private static function importLineOf(source: String, node: QueryNode): Null<ImportLine> {
		final path: Null<String> = node.name;
		final span: Null<Span> = node.span;
		if (path == null || span == null) return null;
		final lineStart: Int = startOfLine(source, span.from);
		if (StringTools.trim(source.substring(lineStart, span.from)) != '') return null;
		final newline: Int = source.indexOf('\n', span.to);
		final tail: String = StringTools.trim(newline < 0 ? source.substring(span.to) : source.substring(span.to, newline));
		if (tail != '' && !StringTools.startsWith(tail, '//')) return null;
		// Re-bind: strict null-safety does not narrow a field read inside a structure literal.
		final named: String = path;
		return {
			path: named,
			declFrom: span.from,
			chunkFrom: withLeadingComments(source, lineStart),
			chunkTo: newline < 0 ? source.length : newline + 1
		};
	}

	/**
	 * `lineStart` extended backward over every directly preceding line that is a WHOLE-LINE `//`
	 * comment. A line carrying a block-comment delimiter stops the walk: a `//` inside a `/* … *\/`
	 * region is comment TEXT, and absorbing it into a movable chunk would tear the region apart.
	 */
	private static function withLeadingComments(source: String, lineStart: Int): Int {
		var from: Int = lineStart;
		while (from > 0) {
			final previousStart: Int = startOfLine(source, from - 1);
			final previous: String = StringTools.trim(source.substring(previousStart, from - 1));
			if (!StringTools.startsWith(previous, '//')) break;
			if (previous.indexOf('/*') >= 0 || previous.indexOf('*/') >= 0) break;
			from = previousStart;
		}
		return from;
	}

	/** The offset of the start of the line `at` sits on. */
	private static function startOfLine(source: String, at: Int): Int {
		var from: Int = at;
		while (from > 0 && StringTools.fastCodeAt(source, from - 1) != '\n'.code) from--;
		return from;
	}

	/** The last dotted segment of `dotted` — the simple name an import binds. */
	private static function lastSegment(dotted: String): String {
		final dot: Int = dotted.lastIndexOf('.');
		return dot == -1 ? dotted : dotted.substring(dot + 1);
	}

}
