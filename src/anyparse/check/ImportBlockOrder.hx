package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.ImportOrder;
import anyparse.query.ImportOrder.ImportLine;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import haxe.ds.ArraySort;

using Lambda;

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
 * A maximal run of TOP-LEVEL plain `import` statements on consecutive lines — `ImportOrder.runsOf`,
 * the same split the inserting fixers place a fresh line by, so the seat and this rule cannot
 * disagree about what a block is. A run ENDS at:
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
 * whole-line `//` comments directly above it and any trailing `// …` on the same line. Nothing
 * is reflowed, rewritten, added or deleted — the fix's output is a permutation of the block's
 * own lines, so it cannot change what the file means beyond the order of the imports.
 *
 * An import sharing its source line with anything but a trailing `//` comment is not separable
 * as a line, so it ends a run too (and a run of one is never reported).
 *
 * The reorder is REFUSED (finding stays report-only) when order is load-bearing or a comment
 * cannot be attributed:
 *
 *  - two imports in the run bind the same SIMPLE name (`a.Widget` + `b.Widget`): Haxe accepts
 *    both and lets the LAST one win, so their relative order decides which type the short name
 *    means. A plain module import binds EVERY type its module declares, so the name set is read
 *    from the resolution index — this is what catches two modules that each declare a same-named
 *    SECONDARY type, which the module paths alone do not reveal. A duplicated path is the same
 *    refusal by construction (deleting it is `duplicate-import`'s call, not a reorder's);
 *  - the run's FIRST import carries a whole-line comment above it — that comment belongs to the
 *    block, not to one import (a header, a license banner, a `CHECKSTYLE:OFF` marker, a group
 *    label), and a reorder can neither move it nor leave it behind without saying something
 *    false.
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
				final paths: Array<String> = ImportOrder.pathsOf(block);
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
		final moduleTypes: Map<String, Array<String>> = moduleTypesOf(index);
		final edits: Array<{ span: Span, text: String }> = [];
		for (block in blocksOf(source, tree)) {
			if (!block.exists(line -> flagged.contains(line.declFrom))) continue;
			if (!reorderable(block, source, moduleTypes)) continue;
			final order: Int = fixOrder(requested, ImportOrder.pathsOf(block));
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

	/**
	 * The first block member that sorts BEFORE its predecessor under `order` — the line the
	 * finding points at. A reported block always has one (`acceptable` and `fixOrder` read the
	 * same order), and the block's own first line is the fallback coordinate should that ever
	 * stop holding: a finding with a slightly-off column beats a linter that throws mid-run.
	 */
	private static function firstOutOfPlace(block: Array<ImportLine>, order: Int): ImportLine {
		for (i in 1...block.length) if (ImportOrder.compare(order, block[i - 1].path, block[i].path) > 0) return block[i];
		return block[0];
	}

	/**
	 * Whether the block's lines may be permuted at all — see the class doc's refusal list.
	 *
	 * Two refusals. ORDER IS LOAD-BEARING when two imports bind one simple NAME: Haxe accepts
	 * both and lets the LAST win, so permuting them silently rebinds that name (a duplicated
	 * path is the same refusal by construction — it binds the same names twice — and deleting
	 * it is `duplicate-import`'s call, not a reorder's). The name set of a plain module import
	 * is EVERY type that module declares, not just its main one, so it is read from the
	 * resolution index; a module the index does not know contributes only its own last segment,
	 * which is the pre-index reading and the residual limit of this gate.
	 *
	 * The block's FIRST member must carry no absorbed leading comment. Such a comment sits above
	 * the whole block — a file header, a license banner, a `CHECKSTYLE:OFF` marker, a group label
	 * — and travelling with an import that sorts later would relocate it into the block's middle,
	 * while leaving it behind would strand it above a different import. Neither is a permutation
	 * of the block's meaning, so the block stays report-only.
	 */
	private static function reorderable(block: Array<ImportLine>, source: String, moduleTypes: Map<String, Array<String>>): Bool {
		if (block[0].chunkFrom != RefactorSupport.startOfLine(source, block[0].declFrom)) return false;
		final bound: Array<String> = [];
		for (line in block) for (name in boundNames(line.path, moduleTypes)) {
			if (bound.contains(name)) return false;
			bound.push(name);
		}
		return true;
	}

	/** Module path -> the simple names it declares, from the resolution index; empty without one. */
	private static function moduleTypesOf(index: Null<SymbolIndex>): Map<String, Array<String>> {
		final out: Map<String, Array<String>> = [];
		if (index != null) for (info in index.allFiles()) out[info.module] = [for (t in info.types) t.name];
		return out;
	}

	/**
	 * The simple names `import <path>;` binds: every type of the MODULE it names, or — for a
	 * sub-module path (`pkg.Mod.Sub`) and for a module the index never saw — its own last segment.
	 */
	private static function boundNames(path: String, moduleTypes: Map<String, Array<String>>): Array<String> {
		final types: Null<Array<String>> = moduleTypes[path];
		return types == null || types.length == 0 ? [lastSegment(path)] : types;
	}

	/**
	 * The file's plain-import BLOCKS — `ImportOrder.runsOf` minus the runs of ONE, which have no
	 * order to be out of and nothing to permute.
	 */
	private static function blocksOf(source: String, tree: QueryNode): Array<Array<ImportLine>> {
		return ImportOrder.runsOf(source, ImportOrder.slotsOf(tree)).filter(run -> run.length > 1);
	}

	/** The last dotted segment of `dotted` — the simple name an import binds. */
	private static function lastSegment(dotted: String): String {
		final dot: Int = dotted.lastIndexOf('.');
		return dot == -1 ? dotted : dotted.substring(dot + 1);
	}

}
