package anyparse.query;

import anyparse.runtime.Span;

using Lambda;

/**
 * One existing import line as the ordering machinery reads it: the module path the statement
 * names, and the byte offset the statement STARTS at (negative when the grammar recorded no
 * span — the slot still counts for the order scan, it just cannot be anchored on).
 */
typedef ImportSlot = {
	final path: String;
	final from: Int;
}

/**
 * Where a FRESH `import` line belongs inside a file's EXISTING import block — the single seat
 * every inserting fixer shares, so one answer serves `TypeRefPrinter` (the `explicit-local-type`
 * / `shorten-type-ref` / `prefer-typed-throw` materialisers), `AddImport` (the `add-import` CLI
 * op) and `MoveSymbol` (the reference-carrying inserts of `move-symbol` / `move-member`).
 *
 * The contract is PRESERVE, never impose: a block already carrying an order keeps it, and a
 * block carrying none is APPENDED to. Nothing here ever rewrites an import the caller did not
 * add — reordering an existing block is a `import-order` lint fix, an opt-in the user asks for,
 * not a side effect of adding one line.
 *
 * ORDERS, tried in this sequence:
 *
 *  1. `ascii` — plain codepoint order, the strict reading. Tried first, so every block a
 *     previous release already read as sorted keeps the exact slot it had.
 *  2. `case-insensitive` — codepoint order with case FOLDED, ties broken by the exact
 *     comparison. This is the reading an IDE's own "organize imports" produces and the one an
 *     ascii-only test misses: `pkg.mid.events.Alpha` precedes `pkg.mid.SetBeta` for a human and
 *     for every case-folding sorter, yet `'e' > 'S'` in codepoint order. A block sorted this way
 *     was read as UNSORTED and every fresh import was appended past the whole block — the
 *     defect this class exists to close.
 *
 * A block explained by NEITHER order is the documented FALLBACK: the caller appends at the
 * block's end. Guessing a slot inside a chaotic block buys nothing and moving its lines to
 * create one is out of scope for an insert.
 *
 * A path whose SIMPLE NAME an existing import already binds is the second fallback, for the same
 * reason `using` is exempt below: Haxe accepts two imports of one simple name and lets the LAST
 * one win, so an ordered slot AHEAD of the incumbent would leave the fresh import bound to
 * nothing while the caller writes the short name for it. Appending keeps the pre-order guarantee
 * — a caller that adds an import gets the name it asked for.
 *
 * `using` is deliberately NOT ordered here. Haxe resolves a static extension through the `using`
 * statements in REVERSE declaration order, so a `using`'s POSITION is semantics, not layout:
 * sliding a fresh one into the middle of a sorted `using` group would silently rank it below
 * extensions declared after it. Every caller therefore appends a `using` after the last one, and
 * the `import-order` rule never reorders the group.
 *
 * LIMIT — the block is the file's WHOLE plain-import list, while the `import-order` rule judges
 * each contiguous RUN on its own. A file whose runs are individually ordered but whose
 * concatenation is not reads as unordered here and is appended to; the rule may then flag the
 * appended line. The conservative direction (append) is the one that never rewrites what the
 * caller did not add.
 */
@:nullSafety(Strict)
final class ImportOrder {

	/** The order names, indexed by the order id `orderOf` returns — the `import-order` rule's `order` option values. */
	public static final ORDER_NAMES: Array<String> = ['ascii', 'case-insensitive'];

	/**
	 * The FIRST order in `ORDER_NAMES` that explains `paths` (non-decreasing under it), or -1
	 * when none does. An empty list is -1 — there is no block to preserve the order of, and every
	 * caller's fallback already handles the no-block case. A ONE-path list is order 0: a second
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
	 * earlier (stricter) order. This is the reading to REPAIR a block under: a block ordered
	 * case-insensitively except for one appended line breaks the folded order once and the
	 * codepoint order at every upper/lower boundary, so sorting it under the codepoint reading
	 * would rewrite the whole block to move one line. Never a verdict on whether the block is
	 * ordered — `orderOf` answers that.
	 */
	public static function bestOrder(paths: Array<String>): Int {
		var best: Int = 0;
		var fewest: Int = inversions(paths, 0);
		for (order in 1...ORDER_NAMES.length) {
			final count: Int = inversions(paths, order);
			if (count < fewest) {
				best = order;
				fewest = count;
			}
		}
		return best;
	}

	/** The id of the order NAMED `name` (an `import-order` `order` option value), or -1 when it names none. */
	public static inline function orderNamed(name: String): Int {
		return ORDER_NAMES.indexOf(name);
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
		return a < b ? -1 : a > b ? 1 : 0;
	}

	/**
	 * The offset at which `path` keeps `block` in the order `block` already carries — the start
	 * of the first import that sorts AFTER it — or -1 when the caller must append: an empty or
	 * unexplained block, a simple name an existing import already binds (see the class doc), a
	 * `path` belonging at the block's end, or an anchor slot the grammar gave no span for.
	 *
	 * `block` is the file's PLAIN import statements in source order. A blank line splitting the
	 * block into visual groups needs no special handling: the anchor is an existing statement's
	 * own start, so a path sorting into a group lands inside it, and one sorting between two
	 * groups opens the later one.
	 *
	 * The anchor is the existing statement's OWN start, so a fresh line landing between a
	 * whole-line comment and the import that comment was written for splits the two. Callers
	 * whose blocks carry such comments should expect it; the alternative — anchoring on the
	 * comment — strands the comment above the fresh import instead.
	 */
	public static function insertOffset(block: Array<ImportSlot>, path: String): Int {
		final order: Int = orderOf([for (slot in block) slot.path]);
		if (order < 0) return -1;
		final simple: String = lastSegment(path);
		if (block.exists(slot -> lastSegment(slot.path) == simple)) return -1;
		for (slot in block) if (compare(order, path, slot.path) < 0) return slot.from;
		return -1;
	}

	/**
	 * Every PLAIN `import` statement of `root`'s top level as a slot, in source order — the block
	 * shape `insertOffset` reads. A statement the grammar recorded no span for keeps its place in
	 * the ORDER scan (dropping it would read a block as ordered on the strength of a line it
	 * cannot see) and carries a negative offset, so it is never anchored on.
	 */
	public static function slotsOf(root: QueryNode): Array<ImportSlot> {
		return [
			for (c in root.children) if (c.kind == 'ImportDecl' && c.name != null) {
				// Re-bind: narrowing does not propagate into an anonymous-structure literal.
				final path: String = c.name ?? '';
				final span: Null<Span> = c.span;
				{ path: path, from: span == null ? -1 : span.from };
			}
		];
	}

	/** The last dotted segment of `dotted` — the simple name a plain import binds. */
	private static inline function lastSegment(dotted: String): String {
		final dot: Int = dotted.lastIndexOf('.');
		return dot == -1 ? dotted : dotted.substring(dot + 1);
	}

}
