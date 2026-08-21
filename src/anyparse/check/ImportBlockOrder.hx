package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.ImportOrder;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.SymbolIndexHost;
import anyparse.runtime.Span;
import haxe.ds.ArraySort;

using Lambda;

/**
 * One `using` WEDGE: the import runs a `using` group sits between, read as the ONE block they
 * would be with the group moved below them. `imports` is every merged line in SOURCE order (the
 * list the merge sorts), `heads` the FIRST line of each chained run (each was a block head of its
 * own, and each carries the leading-comment refusal that comes with being one), `usings` the
 * wedged `using` lines in their own source order (the group moves whole, so that order is
 * preserved verbatim), and `from` … `to` the region the fix rewrites: the first merged import's
 * line start through the last one's line end.
 */
private typedef UsingWedge = {
	final imports: Array<ImportLine>;
	final heads: Array<ImportLine>;
	final usings: Array<ImportLine>;
	final from: Int;
	final to: Int;
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
 * A `using` is never part of a run and its ordering WITHIN the `using` group is never touched:
 * Haxe ranks static extensions in REVERSE declaration order, so one `using`'s position relative
 * to another is semantics rather than layout. A wildcard and an alias split a run for the same
 * reason in miniature — both bind names the ordering cannot see.
 *
 * ## The `using` WEDGE
 *
 * That a `using` ENDS a run does not mean the runs around it are two blocks. A `using` group
 * wedged between two import runs leaves a file whose imports read as one sorted block only if you
 * skip over the middle — and, because each run is ordered on its own, NO finding is produced and
 * no fix ever runs: the shape is a fixed point. It is what an older inserting fixer left behind,
 * and what a hand edit leaves whenever a fresh import is appended past the `using`.
 *
 * So a wedge is reported and, by default, repaired: the runs merge into ONE sorted block and the
 * wedged `using` lines move BELOW it, keeping their own relative order. This is layout, not
 * semantics — a `using`'s rank against another `using` is what Haxe reads in reverse, and moving
 * the group as a whole preserves it exactly. The one semantic edge is NAME BINDING: a `using`
 * also imports its module's types, so overtaking an import that binds one of those names would
 * flip which declaration the short name means. That is a refusal (see below), not a rewrite.
 *
 * A merge requires the gap between two runs to hold NOTHING but `using` lines and blank lines. A
 * wildcard, an alias, a `#if` region, a block comment or a type declaration in the gap keeps the
 * runs separate exactly as before, and a gap with no `using` at all is a blank-line GROUP, which
 * is preserved. A `using` sitting before every import, or after every import, wedges nothing and
 * is left alone.
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
 * A WEDGE merge answers to both of those — over the UNION of the merged runs, and with the
 * comment refusal applied to every chained run's head rather than only the union's first — plus
 * two of its own. A wedged `using` may not OVERTAKE an import it currently loses a simple name
 * to: the `using` imports its module's types, so with the import below it that import wins the
 * name today and the `using` would win it after the move. And the `using`'s module must be one
 * the index KNOWS, because that refusal is computed from its type names and the last-segment
 * fallback would answer "no collision" on no evidence — which is the answer for exactly the
 * multi-type facade modules `using` is written for. The index consulted is the RESOLUTION-scoped
 * one, so the Haxe std is always readable and a project unlocks its own libraries by declaring
 * them in `resolutionLibs`.
 *
 * ## The rule reports far more often than it rewrites — measured, 2026-08-21
 *
 * A caller who runs `--fix`, reads `fixed 0 issue(s)` beside a nonzero `import-order` count and
 * concludes the rule has NO autofix is reading the refusals above. Three did. On Pony (851 files,
 * `import-order` enabled in its own `apqlint.json`) all FOUR findings stayed report-only, and
 * every one of the four was a correct refusal:
 *
 *  - `TouchableMouse.hx` — `import flash.events.MouseEvent;` beside `import pony.ui.touch.Mouse;`,
 *    whose module declares a SECONDARY `typedef MouseEvent`. Two imports, one simple name, and
 *    nothing in the two paths says so: precisely the collision the index lookup exists to see.
 *  - `StarlingTouchInput.hx` — the same shape one library over, `TouchManager`'s secondary
 *    `class Touch` against `starling.events.Touch`.
 *  - `Tooltip.hx` — three spellings of `Rect` in one block (`pony.geom.Rect`,
 *    `pony.geom.Rect.Rect`, `unityengine.Rect`).
 *  - `StaticAccess.hx` — the run's first import carries two commented-out imports above it: the
 *    absorbed-leading-comment refusal.
 *
 * So a zero fix count here is the guard working, not a missing fixer. What the run does NOT do is
 * SAY which refusal fired — the finding message reads the same whether the reorder is available
 * or refused. The `prefer-typed-throw` treatment (a second, report-only message once its
 * whole-scope gate closes) is the shape to copy, and the reason it has not been copied is a
 * LENS mismatch, not effort: `run` has no `index` parameter, and answering the refusal from the
 * resolution-scoped index would predict MORE collisions than the report-scoped one `fix` is
 * handed, so the report would claim report-only on findings the fixer then rewrites. Give the two
 * seats one index before giving the message two spellings.
 *
 * ## Options
 *
 *  - `order` — the order a block must carry: `any` (default) accepts EITHER recognised order
 *    and reports only a block explained by neither; `ascii` requires plain codepoint order;
 *    `case-insensitive` requires the case-folded one. The autofix sorts under the named order,
 *    and under `any` sorts a block under whichever order it breaks LEAST often — the convention
 *    it was nearly following, so one appended line moves instead of the whole block.
 *  - `usingAfterImports` — whether a `using` WEDGE is a finding at all. `true` (default) merges
 *    the runs and moves the wedged `using` lines below them; `false` restores the pre-wedge
 *    reading, where a `using` is an immovable run boundary and the runs around it are judged
 *    separately.
 */
@:nullSafety(Strict)
final class ImportBlockOrder implements Check implements DefaultOff implements ConfigAware {

	private static inline final RULE_ID: String = 'import-order';

	/** The `order` option value accepting EITHER recognised order — the default, and the least opinionated reading. */
	private static inline final ORDER_ANY: String = 'any';

	/** The option gating the `using` WEDGE merge — on unless a project opts out. */
	private static inline final OPTION_USING_AFTER: String = 'usingAfterImports';

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
		return 'a block of plain imports carrying no recognisable order, or split by a `using`';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final config: LintConfig = LintConfig.resolveWith(_resolveConfig, entry.file);
			final requested: Int = requestedOrder(config);
			// A module whose whole body is `#if`-guarded keeps its import block inside the region, so the
			// blocks are read from the HEADER root — at the top level such a file offers none at all.
			final header: QueryNode = ImportOrder.headerRootOf(tree, entry.source, plugin);
			for (wedge in wedgesOf(entry.source, header, config)) {
				final first: ImportLine = wedge.usings[0];
				violations.push({
					file: entry.file,
					span: new Span(first.declFrom, first.declFrom + 'using'.length),
					rule: RULE_ID,
					severity: Severity.Warning,
					message: 'using \'${first.path}\' splits the import block; using statements belong after every import'
				});
			}
			for (block in blocksOf(entry.source, header)) {
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
		final header: QueryNode = ImportOrder.headerRootOf(tree, source, plugin);
		final flagged: Array<Int> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push(span.from);
		}
		final moduleTypes: Map<String, Array<String>> = moduleTypesOf(index);
		final edits: Array<{ span: Span, text: String }> = [];
		// A merged wedge REWRITES the region its runs live in, so a run it takes over must not also
		// get the per-run reorder edit below: the two spans overlap and the caller batches both.
		final merged: Array<Int> = [];
		final wedges: Array<UsingWedge> = wedgesOf(source, header, config);
		final scopeTypes: Map<String, Array<String>> = wedges.length == 0 ? moduleTypes : moduleTypesOf(widestIndex(plugin, index));
		for (wedge in wedges) {
			if (!flagged.contains(wedge.usings[0].declFrom)) continue;
			if (!mergeable(wedge, source, scopeTypes)) continue;
			final order: Int = fixOrder(requested, ImportOrder.pathsOf(wedge.imports));
			final sorted: Array<ImportLine> = wedge.imports.copy();
			ArraySort.sort(sorted, (a, b) -> ImportOrder.compare(order, a.path, b.path));
			final block: String = [for (line in sorted) source.substring(line.chunkFrom, line.chunkTo)].join('');
			final group: String = [for (line in wedge.usings) source.substring(line.chunkFrom, line.chunkTo)].join('');
			final text: String = '$block\n$group';
			for (line in wedge.imports) merged.push(line.declFrom);
			edits.push({ span: new Span(wedge.from, wedge.to), text: text });
		}
		for (block in blocksOf(source, header)) {
			if (block.exists(line -> merged.contains(line.declFrom))) continue;
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
	 * The file's `using` WEDGES — see the class doc. A run pair joins one wedge when the GAP between
	 * them holds nothing but `using` lines and whitespace; anything else (a wildcard, an alias, a
	 * `#if` region, a block comment, a type declaration) ends the chain there, and so does a gap
	 * with no `using` in it at all, which is a blank-line GROUP the rule preserves.
	 *
	 * Empty under the `usingAfterImports` opt-out, for a file with fewer than two runs or no
	 * top-level `using`, and — wholesale — when ANY top-level `using` is not liftable as a line
	 * (`ImportOrder.usingLinesOf`): a file carrying one such statement is one whose `using` group cannot
	 * be moved intact, so no wedge in it may be repaired.
	 */
	private static function wedgesOf(source: String, tree: QueryNode, config: LintConfig): Array<UsingWedge> {
		if (config.boolOption(RULE_ID, OPTION_USING_AFTER) == false) return [];
		final runs: Array<Array<ImportLine>> = ImportOrder.runsOf(source, ImportOrder.slotsOf(tree));
		if (runs.length < 2) return [];
		final usings: Null<Array<ImportLine>> = ImportOrder.usingLinesOf(source, tree);
		if (usings == null || usings.length == 0) return [];
		final out: Array<UsingWedge> = [];
		var imports: Array<ImportLine> = runs[0].copy();
		var heads: Array<ImportLine> = [runs[0][0]];
		var wedged: Array<ImportLine> = [];
		inline function flush(): Void {
			if (wedged.length > 0) out.push({
				imports: imports,
				heads: heads,
				usings: wedged,
				from: imports[0].chunkFrom,
				to: imports[imports.length - 1].chunkTo
			});
		}
		for (i in 1...runs.length) {
			final gapFrom: Int = imports[imports.length - 1].chunkTo;
			final gapTo: Int = runs[i][0].chunkFrom;
			final inGap: Array<ImportLine> = usings.filter(line -> line.chunkFrom >= gapFrom && line.chunkTo <= gapTo);
			if (inGap.length == 0 || !gapHoldsOnly(source, gapFrom, gapTo, inGap)) {
				flush();
				imports = runs[i].copy();
				heads = [runs[i][0]];
				wedged = [];
				continue;
			}
			for (line in inGap) wedged.push(line);
			for (line in runs[i]) imports.push(line);
			heads.push(runs[i][0]);
		}
		flush();
		return out;
	}

	/** Whether `[from, to)` is `lines` (in that order) and whitespace, and nothing else. */
	private static function gapHoldsOnly(source: String, from: Int, to: Int, lines: Array<ImportLine>): Bool {
		var rest: String = '';
		var at: Int = from;
		for (line in lines) {
			if (line.chunkFrom < at) return false;
			rest += source.substring(at, line.chunkFrom);
			at = line.chunkTo;
		}
		return StringTools.trim(rest + source.substring(at, to)) == '';
	}

	/**
	 * Whether `wedge` may be merged. Four refusals:
	 *
	 *  - the two `reorderable` makes over the merged import union — an absorbed leading comment on
	 *    the block's first line, and two of the merged imports binding one simple name (the gate
	 *    only a MERGE can trip: the colliding pair lives in two different runs);
	 *  - every chained run HEAD must be comment-free too, not only the union's first. A head's
	 *    absorbed comment labelled that run while the run was its own block, and the merge would
	 *    either carry the label into the block's middle or strand it above a different import —
	 *    the same misattribution `reorderable` refuses at the block's top, one run down;
	 *  - a wedged `using` may not OVERTAKE an import that binds a name its module also declares.
	 *    Below that import today the import wins the name; above it the `using` would, so the move
	 *    is a silent rebind rather than a relayout;
	 *  - the wedged `using`'s own module must be KNOWN to the index. Its type names are what the
	 *    previous refusal is computed from, and `boundNames`' last-segment fallback would answer
	 *    "no collision" on no evidence — precisely for the multi-type facade modules a project
	 *    writes `using` for (`tink.CoreApi` re-exports `Error`, `Future`, `Outcome`, …). Declare
	 *    the library in `resolutionLibs` and the merge unlocks; the Haxe std is always in scope, so
	 *    `using StringTools` / `using Lambda` need no declaration.
	 */
	private static function mergeable(wedge: UsingWedge, source: String, moduleTypes: Map<String, Array<String>>): Bool {
		if (!reorderable(wedge.imports, source, moduleTypes)) return false;
		for (head in wedge.heads) if (head.chunkFrom != RefactorSupport.startOfLine(source, head.declFrom)) return false;
		for (statement in wedge.usings) {
			final names: Null<Array<String>> = moduleTypes[statement.path];
			if (names == null || names.length == 0) return false;
			for (line in wedge.imports) {
				if (line.declFrom > statement.declFrom && boundNames(line.path, moduleTypes).exists(name -> names.contains(name)))
					return false;
			}
		}
		return true;
	}

	/**
	 * The WIDEST module index a fix may reason about: the resolution-scoped one (report files UNION
	 * the declared libraries, plus the implicit Haxe std) when the host offers it, else the
	 * report-scoped one the caller passed.
	 *
	 * The wedge merge asks what a `using`'s MODULE declares — a resolution question, not a
	 * confinement one, so the report scope is the wrong lens for it: it is exactly the scope that
	 * cannot see `StringTools`, `Lambda` or any library module a project actually writes `using`
	 * for. Every extra file can only make the refusal gates FIRE MORE, never less.
	 */
	private static function widestIndex(plugin: GrammarPlugin, index: Null<SymbolIndex>): Null<SymbolIndex> {
		final host: Null<SymbolIndexHost> = plugin is SymbolIndexHost ? cast plugin : null;
		if (host != null && host.hasAnyResolutionScope()) {
			final wider: Null<SymbolIndex> = host.resolutionIndex();
			if (wider != null) return wider;
		}
		return index;
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
		return types == null || types.length == 0 ? [RefactorSupport.lastSegment(path)] : types;
	}

	/**
	 * The file's plain-import BLOCKS — `ImportOrder.runsOf` minus the runs of ONE, which have no
	 * order to be out of and nothing to permute.
	 */
	private static function blocksOf(source: String, tree: QueryNode): Array<Array<ImportLine>> {
		return ImportOrder.runsOf(source, ImportOrder.slotsOf(tree)).filter(run -> run.length > 1);
	}

}
