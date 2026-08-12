package anyparse.query;

import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * One existing import-family statement as the ordering machinery reads it: the module path it
 * names and the byte offsets it STARTS and ENDS at. Both are negative when the grammar recorded no
 * span — such a statement cannot be placed on a line, so it ENDS the run it sits in (see `runsOf`).
 *
 * A plain `import` is the ordinary case, and `slotsOf` reads only those. `usingLinesOf` reads a
 * `using` through the same shape for its POSITION alone: a `using` slot never joins a run and
 * never reaches the ordering surface.
 */
typedef ImportSlot = {
	final path: String;
	final from: Int;
	final to: Int;
}

/**
 * One import as a whole LINE — the unit a RUN is built from, an inserter anchors on and the
 * `import-order` autofix permutes. `chunkFrom` … `chunkTo` is the region that MOVES with the
 * statement: it reaches backward over the whole-line `//` comments written directly above it and
 * forward over the rest of its own line, that line's newline included. `declFrom` is the
 * statement's own start — the anchor an INSERT uses, so a fresh line landing on a statement that
 * carries a whole-line comment SPLITS the two, taking the slot between the comment and its
 * import. Callers whose runs carry such comments should expect it; the alternative — anchoring on
 * `chunkFrom` — puts the fresh import above the comment instead, which is the same misattribution
 * seen from the other side.
 */
typedef ImportLine = {
	final path: String;
	final declFrom: Int;
	final chunkFrom: Int;
	final chunkTo: Int;
}

/** One run weighed as a host for a fresh import: the run, whether an order explains it, its dotted-prefix affinity, and the index the path sorts before (-1 = append at the run's end). */
private typedef RunChoice = {
	final run: Array<ImportLine>;
	final ordered: Bool;
	final affinity: Int;
	final slot: Int;
}

/**
 * Where a FRESH `import` line belongs inside a file's EXISTING import block — the single seat
 * every inserting fixer shares, so one answer serves `TypeRefPrinter` (the `explicit-local-type`
 * / `shorten-type-ref` / `prefer-typed-throw` materialisers), `AddImport` (the `add-import` CLI
 * op) and `MoveSymbol` (the reference-carrying inserts of `move-symbol` / `move-member`) — and
 * the RUN model the `import-order` rule judges a file by, so the seat and the rule read one
 * shape rather than two that disagree.
 *
 * The contract is PRESERVE, never impose: a run already carrying an order keeps it, and a run
 * carrying none is APPENDED to. Nothing here ever rewrites an import the caller did not add —
 * reordering an existing block is a `import-order` lint fix, an opt-in the user asks for, not a
 * side effect of adding one line.
 *
 * ## RUNS
 *
 * A file's plain imports are NOT one list. They are maximal runs of statements whose whole-line
 * regions are directly adjacent, so anything between two of them ends the run: a blank line, a
 * `using`, a wildcard / alias import, a `#if` region, a block comment, an import sharing its
 * source line with other code. Each run carries its OWN order and is inserted into on its own.
 *
 * This is what a whole-list reading got wrong. A block split by a `using` into two individually
 * sorted runs reads as unsorted when concatenated, so every fresh import was appended past the
 * whole file's last import — landing in the LAST run regardless of where it sorts, and inverting
 * that run whenever it belonged earlier. The `import-order` rule then flagged the line the
 * inserter had just placed: two waves of edits where zero were needed.
 *
 * A `#if`-guarded import is not a slot at all (`slotsOf` reads top-level statements, and the
 * guarded ones live inside the `Conditional`), so no anchor can ever fall inside a guarded
 * region — the region only ever ENDS the runs around it.
 *
 * ORDERS, tried in this sequence:
 *
 *  1. `ascii` — plain codepoint order, the strict reading. Tried first, so every run a
 *     previous release already read as sorted keeps the exact slot it had.
 *  2. `case-insensitive` — codepoint order with case FOLDED, ties broken by the exact
 *     comparison. This is the reading an IDE's own "organize imports" produces and the one an
 *     ascii-only test misses: `pkg.mid.events.Alpha` precedes `pkg.mid.SetBeta` for a human and
 *     for every case-folding sorter, yet `'e' > 'S'` in codepoint order. A block sorted this way
 *     was read as UNSORTED and every fresh import was appended past the whole block — the
 *     defect this class exists to close.
 *
 * ## Which run a fresh path joins
 *
 * Every run is a candidate; they are ranked by:
 *
 *  1. ORDERED over not. A run whose order is preserved by the insert is always the better host
 *     than one already explained by neither reading.
 *  2. AFFINITY — the longest leading dotted prefix any of the run's imports shares with `path`.
 *     A fresh `app.C` belongs with the `app.*` imports even when a later run would also take it
 *     in order.
 *  3. A slot INSIDE the run over one the path could only be appended to. This is the whole-list
 *     reading of a blank-line-grouped block, kept: a path sorting past every member of the first
 *     group and before the second's opens that second group rather than closing the first.
 *  4. EARLIEST — a file whose runs say nothing about the path has no reason to grow at its far
 *     end, which is the last-run-blind append this class exists to stop.
 *
 * Inside the chosen run the slot is the start of the first import that sorts AFTER `path`, or —
 * when `path` sorts after all of them — the offset just past the run's last line, which appends
 * WITHIN the run instead of past the file's whole import block. An UNORDERED run has no position
 * to compute, so it is only ever appended to: guessing a slot inside a chaotic run buys nothing.
 *
 * Rank 1 reaches further than it reads, because `orderOf` calls a ONE-import run ordered. A file
 * whose imports are followed by a `using` and a single import past it therefore offers that lone
 * import as an ordered candidate, and a fresh path joins it rather than the larger unordered run
 * before the `using` — even a path that shares that run's package. It is order-preserving and it
 * EXTENDS a run the file already had; opening one past the `using` is the incident this closes.
 *
 * -1 — "the caller must append past everything" — is left for the two cases where no run may be
 * joined at all: a file with no plain import runs, and a path whose SIMPLE NAME an existing
 * import already binds. The latter is for the same reason `using` is exempt below: Haxe accepts
 * two imports of one simple name and lets the LAST one win, so any slot AHEAD of the incumbent
 * would leave the fresh import bound to nothing while the caller writes the short name for it.
 * Appending past every run keeps the pre-order guarantee — a caller that adds an import gets the
 * name it asked for.
 *
 * `using` is deliberately NOT ordered here. Haxe resolves a static extension through the `using`
 * statements in REVERSE declaration order, so a `using`'s POSITION is semantics, not layout:
 * sliding a fresh one into the middle of a sorted `using` group would silently rank it below
 * extensions declared after it. Every caller therefore appends a `using` after the last one, and
 * the `import-order` rule never reorders the group.
 *
 * LIMIT — this seat is config-blind while the rule is config-aware. Under a non-default
 * `"import-order": { "order": … }` a run the seat reads as ordered (the first order that explains
 * it) may not be ordered under the REQUESTED one, and an insert preserving the former can still
 * be flagged by the latter. The two agree on the run SHAPE, which is what closed the incident;
 * agreeing on the ORDER would mean plumbing the lint config into every inserting fixer.
 */
@:nullSafety(Strict)
final class ImportOrder {

	/** The order names, indexed by the order id `orderOf` returns — the `import-order` rule's `order` option values. */
	public static final ORDER_NAMES: Array<String> = ['ascii', 'case-insensitive'];

	/** The id of the order NAMED `name` (an `import-order` `order` option value), or -1 when it names none. */
	public static inline function orderNamed(name: String): Int {
		return ORDER_NAMES.indexOf(name);
	}

	/**
	 * Every PLAIN `import` statement of `root`'s top level as a slot, in source order — the block
	 * shape `runsOf` and `insertOffset` read. A statement the grammar recorded no span for carries
	 * negative offsets: it cannot be placed on a line, so it ENDS the run it sits in rather than
	 * joining it — the run around a line the machinery cannot see must not be read as one block.
	 */
	public static inline function slotsOf(root: QueryNode): Array<ImportSlot> {
		return slotsOfKind(root, 'ImportDecl');
	}

	/** The paths of `run`, in run order — the list every order question is asked about. */
	public static inline function pathsOf(run: Array<ImportLine>): Array<String> {
		return [for (line in run) line.path];
	}

	/**
	 * The FIRST order in `ORDER_NAMES` that explains `paths` (non-decreasing under it), or -1
	 * when none does. An empty list is -1 — there is no run to preserve the order of, and every
	 * caller's fallback already handles the no-run case. A ONE-path list is order 0: a second
	 * import still lands in a defensible slot rather than being appended by definition.
	 */
	public static function orderOf(paths: Array<String>): Int {
		if (paths.length == 0) return -1;
		for (order in 0...ORDER_NAMES.length) if (sortedUnder(paths, order)) return order;
		return -1;
	}

	/** Whether `paths` is non-decreasing under `order`. */
	public static function sortedUnder(paths: Array<String>, order: Int): Bool {
		return inversions(paths, order) == 0;
	}

	/** How many ADJACENT pairs of `paths` sit the wrong way round under `order` — 0 exactly when the list is sorted under it. */
	public static function inversions(paths: Array<String>, order: Int): Int {
		var count: Int = 0;
		for (i in 1...paths.length) if (compare(order, paths[i - 1], paths[i]) > 0) count++;
		return count;
	}

	/**
	 * The order that best EXPLAINS `paths` — the one it breaks least often, ties going to the
	 * earlier (stricter) order. This is the reading to REPAIR a run under: a run ordered
	 * case-insensitively except for one appended line breaks the folded order once and the
	 * codepoint order at every upper/lower boundary, so sorting it under the codepoint reading
	 * would rewrite the whole run to move one line. Never a verdict on whether the run is
	 * ordered — `orderOf` answers that.
	 */
	public static function bestOrder(paths: Array<String>): Int {
		var best: Int = 0;
		var fewest: Int = inversions(paths, 0);
		for (order in 1...ORDER_NAMES.length) {
			final count: Int = inversions(paths, order);
			if (count >= fewest) continue;
			best = order;
			fewest = count;
		}
		return best;
	}

	/**
	 * `a` against `b` under `order`: plain codepoint order for `ascii`, case-FOLDED order for
	 * `case-insensitive` with the exact comparison breaking a fold tie (so the result is a total
	 * order and a sort under it is deterministic). An unknown order id falls back to codepoint,
	 * the strict reading.
	 */
	public static function compare(order: Int, a: String, b: String): Int {
		if (order == 1) {
			final fa: String = a.toLowerCase();
			final fb: String = b.toLowerCase();
			if (fa != fb) return fa < fb ? -1 : 1;
		}
		return if (a < b)
			-1
		else if (a > b)
			1
		else
			0;
	}

	/**
	 * `block` split into contiguous RUNS of whole lines, in source order — the shape both the
	 * inserter and the `import-order` rule read a file by. A statement is dropped, and ENDS the
	 * run it would have joined, when it is not separable as a line: its own line carries code
	 * before it, something other than a trailing `//` comment after it, no terminating newline at
	 * all, or the grammar recorded no span for it. Anything else between two statements — a blank
	 * line, a `using`, a wildcard / alias import, a `#if` region, a block comment — breaks the
	 * chunk adjacency and so ends the run by construction.
	 *
	 * Runs of ONE are returned like any other: an insert may join a single-import run, while the
	 * rule (which has nothing to report about one line) filters them out itself.
	 */
	public static function runsOf(source: String, block: Array<ImportSlot>): Array<Array<ImportLine>> {
		final out: Array<Array<ImportLine>> = [];
		var current: Array<ImportLine> = [];
		inline function flush(): Void {
			if (current.length > 0) out.push(current);
			current = [];
		}
		for (slot in block) {
			final line: Null<ImportLine> = lineOf(source, slot);
			if (line == null) {
				flush();
				continue;
			}
			// Directly adjacent = nothing at all between the previous line's end and this one's
			// start; a blank line or any other text is what ends the run.
			if (current.length > 0 && current[current.length - 1].chunkTo != line.chunkFrom) flush();
			current.push(line);
		}
		flush();
		return out;
	}

	/**
	 * The offset at which `path` joins the run it belongs to (see the class doc for the choice of
	 * run and of slot inside it), or -1 when the caller must append past every run: a file with no
	 * runs at all, or a simple name an existing import already binds.
	 *
	 * `block` is the file's PLAIN import statements in source order and `source` the text they
	 * were read from — the run split is a question about the text BETWEEN two statements, which
	 * the slots alone cannot answer. The returned offset is always a LINE START, so a caller
	 * splices `'import <path>;\n'` at it.
	 */
	public static function insertOffset(source: String, block: Array<ImportSlot>, path: String): Int {
		final simple: String = RefactorSupport.lastSegment(path);
		if (block.exists(slot -> RefactorSupport.lastSegment(slot.path) == simple)) return -1;
		final chosen: Null<RunChoice> = chooseRun(runsOf(source, block), path);
		if (chosen == null) return -1;
		final run: Array<ImportLine> = chosen.run;
		return chosen.slot < 0 ? run[run.length - 1].chunkTo : RefactorSupport.startOfLine(source, run[chosen.slot].declFrom);
	}

	/**
	 * The order carried by the run the offset `at` anchors into — the reading several fresh lines
	 * sharing one anchor must be sorted under, so they do not leave that run explained by neither
	 * order. -1 when `at` anchors no run, which `compare` reads as the deterministic codepoint
	 * default; every offset `insertOffset` returns does anchor one.
	 *
	 * Two paths that produced the same anchor are in the same run by construction: runs occupy
	 * disjoint offset ranges, since a run's own end is what separates it from the next.
	 */
	public static function orderAt(source: String, block: Array<ImportSlot>, at: Int): Int {
		for (run in runsOf(source, block)) {
			final anchored: Bool = run[run.length - 1].chunkTo == at
				|| run.exists(line -> RefactorSupport.startOfLine(source, line.declFrom) == at);
			if (anchored) return orderOf(pathsOf(run));
		}
		return -1;
	}

	/**
	 * Every top-level `using` statement of `root` as a movable whole LINE, in source order, or null
	 * when ANY of them is not liftable as a line (`lineOf` — its line carries other code, a block
	 * comment follows it, the file ends without a newline, the grammar recorded no span). Null is
	 * "this file's `using` group cannot be moved intact", the answer the `import-order` wedge merge
	 * needs before it relocates the group below the imports; a file with no top-level `using` is an
	 * EMPTY array, not null.
	 *
	 * A guarded `using` lives inside its `Conditional` and is not a top-level child, so it is never
	 * seen here — which is right for the merge: the guarded region ENDS the import runs around it,
	 * so no wedge ever spans one.
	 *
	 * The lines returned describe POSITION, never order. They must not reach `compare` / `orderOf`
	 * / `slotIn` and the rest of the ordering surface: Haxe ranks static extensions in REVERSE
	 * declaration order, so sorting a `using` group is a semantic rewrite, not a relayout.
	 */
	public static function usingLinesOf(source: String, root: QueryNode): Null<Array<ImportLine>> {
		return linesOfKinds(source, root, ['UsingDecl']);
	}

	/**
	 * Every declaration of `root` whose kind is in `kinds`, as a movable whole LINE, in SOURCE
	 * order — the generalisation `usingLinesOf` is now one call of. Null when ANY of them is not
	 * liftable as a line (`lineOf` — its line carries other code, a block comment follows it, the
	 * file ends without a newline, the grammar recorded no span), which is the answer a caller
	 * RELOCATING the set needs before it moves anything; a `root` declaring none is an EMPTY array.
	 *
	 * `root` is any node whose children carry the declarations — the module for a file's own
	 * header, a `#if … #end` region node for the header nested inside one.
	 *
	 * The lines describe POSITION, never order (see `usingLinesOf`): a `using` group's internal
	 * order is what Haxe reads in reverse, so these must not reach `compare` / `orderOf` / `slotIn`.
	 */
	public static function linesOfKinds(source: String, root: QueryNode, kinds: Array<String>): Null<Array<ImportLine>> {
		final slots: Array<ImportSlot> = [for (kind in kinds) for (slot in slotsOfKind(root, kind)) slot];
		slots.sort((a, b) -> a.from - b.from);
		final out: Array<ImportLine> = [];
		for (slot in slots) {
			final line: Null<ImportLine> = lineOf(source, slot);
			if (line == null) return null;
			out.push(line);
		}
		return out;
	}

	/** Whether `candidate` outranks `incumbent` under the class doc's ordered / affinity / slot-inside criteria. */
	private static inline function beats(candidate: RunChoice, incumbent: RunChoice): Bool {
		return if (candidate.ordered != incumbent.ordered)
			candidate.ordered
		else if (candidate.affinity != incumbent.affinity)
			candidate.affinity > incumbent.affinity
		else
			candidate.slot >= 0 && incumbent.slot < 0;
	}

	/** Whether what follows the statement on its own line is nothing, or a `//` comment — the only two shapes a whole-line move may carry. */
	private static inline function isPureTail(tail: String): Bool {
		return tail == '' || tail.startsWith('//');
	}

	/** Every top-level statement of `root` whose node `kind` matches, as a slot, in source order. */
	private static function slotsOfKind(root: QueryNode, kind: String): Array<ImportSlot> {
		return [
			for (c in root.children) if (c.kind == kind && c.name != null) {
				// Re-bind: narrowing does not propagate into an anonymous-structure literal.
				final path: String = c.name ?? '';
				final span: Null<Span> = c.span;
				{ path: path, from: span == null ? -1 : span.from, to: span == null ? -1 : span.to };
			}
		];
	}

	/**
	 * The run of `runs` that hosts `path`, with the index inside it the path sorts before (-1 to
	 * append at the run's end), or null when there is no run at all. Ranks every run by the class
	 * doc's four criteria in one pass; a candidate that ties on all of them leaves the incumbent
	 * standing, which is what makes the EARLIEST run win.
	 */
	private static function chooseRun(runs: Array<Array<ImportLine>>, path: String): Null<RunChoice> {
		var best: Null<RunChoice> = null;
		for (run in runs) {
			final order: Int = orderOf(pathsOf(run));
			// An unordered run has no position to compute — it can only ever be appended to.
			final candidate: RunChoice = {
				run: run,
				ordered: order >= 0,
				affinity: affinityOf(run, path),
				slot: order < 0 ? -1 : slotIn(run, order, path)
			};
			if (best == null || beats(candidate, best)) best = candidate;
		}
		return best;
	}

	/** The index in `run` of the first import that sorts AFTER `path` under `order`, or -1 when `path` sorts past them all. */
	private static function slotIn(run: Array<ImportLine>, order: Int, path: String): Int {
		for (i in 0...run.length) if (compare(order, path, run[i].path) < 0) return i;
		return -1;
	}

	/** How closely `run`'s imports relate to `path`: the longest leading dotted prefix any one of them shares with it. */
	private static function affinityOf(run: Array<ImportLine>, path: String): Int {
		var affinity: Int = 0;
		for (line in run) {
			final shared: Int = sharedSegments(line.path, path);
			if (shared > affinity) affinity = shared;
		}
		return affinity;
	}

	/** How many leading dotted SEGMENTS `a` and `b` share — `pkg.a.T` and `pkg.a.U` share two. */
	private static function sharedSegments(a: String, b: String): Int {
		final left: Array<String> = a.split('.');
		final right: Array<String> = b.split('.');
		var shared: Int = 0;
		while (shared < left.length && shared < right.length && left[shared] == right[shared]) shared++;
		return shared;
	}

	/**
	 * `slot` as the whole LINE region that moves with it, or null when the statement is not
	 * cleanly separable: the grammar gave it no span, its line carries code before it, something
	 * other than a `//` comment follows it on that line, or the line has NO terminating newline
	 * (a chunk without one would glue the next import onto its line the moment it stops being
	 * last).
	 *
	 * Purely POSITIONAL, so it serves a `using` slot as faithfully as an import one (`usingLinesOf`):
	 * every deviant shape falls to the refusal side, never to a false lift.
	 */
	private static function lineOf(source: String, slot: ImportSlot): Null<ImportLine> {
		if (slot.from < 0 || slot.to < 0) return null;
		final lineStart: Int = RefactorSupport.startOfLine(source, slot.from);
		if (source.substring(lineStart, slot.from).trim() != '') return null;
		final newline: Int = source.indexOf('\n', slot.to);
		return if (newline < 0)
			null
		else if (!isPureTail(source.substring(slot.to, newline).trim()))
			null
		else
			{
				path: slot.path,
				declFrom: slot.from,
				chunkFrom: withLeadingComments(source, lineStart),
				chunkTo: newline + 1
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
			final previousStart: Int = RefactorSupport.startOfLine(source, from - 1);
			final previous: String = source.substring(previousStart, from - 1).trim();
			if (!previous.startsWith('//')) break;
			if (previous.indexOf('/*') >= 0 || previous.indexOf('*/') >= 0) break;
			from = previousStart;
		}
		return from;
	}

}
