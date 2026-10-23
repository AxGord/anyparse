package anyparse.query;

/** A line of the OLD text that is gone, and the index of the NEW line it sat before. */
typedef DeletedLine = {
	final line: Int;
	final before: Int;
};

/**
 * The lines one text changed against another: every line of the NEW text that is not part of the
 * common subsequence, and every line of the OLD text that is gone, with the new line it sat before.
 */
typedef LineEdits = {
	final inserted: Array<Int>;
	final deleted: Array<DeletedLine>;
};

/**
 * A line-granular diff — Myers' shortest edit script over the lines between the common head and
 * tail. Pure and stateless; indices are 0-based.
 *
 * Bounded by `maxEdits`: past it the region between the head and the tail is reported changed
 * whole, which is the hull a caller would otherwise have had — wider than the truth, never narrower.
 */
@:nullSafety(Strict)
final class LineDiff {

	/** The lines `now` changed against `old`. */
	public static function edits(old: Array<String>, now: Array<String>, maxEdits: Int): LineEdits {
		final limit: Int = old.length < now.length ? old.length : now.length;
		var head: Int = 0;
		while (head < limit && old[head] == now[head]) head++;
		var tail: Int = 0;
		while (tail < limit - head && old[old.length - 1 - tail] == now[now.length - 1 - tail]) tail++;
		final a: Array<String> = old.slice(head, old.length - tail);
		final b: Array<String> = now.slice(head, now.length - tail);
		final found: Null<LineEdits> = shortestScript(a, b, maxEdits);
		final middle: LineEdits = found ?? {
			inserted: [for (i in 0...b.length) i],
			deleted: [for (i in 0...a.length) { line: i, before: 0 }]
		};
		return {
			inserted: [for (i in middle.inserted) i + head],
			deleted: [for (d in middle.deleted) { line: d.line + head, before: d.before + head }]
		};
	}

	/**
	 * Myers' greedy forward search with one snapshot of the frontier per edit distance, walked back
	 * from the end to recover the script; null once the distance passes `maxEdits`.
	 */
	private static function shortestScript(a: Array<String>, b: Array<String>, maxEdits: Int): Null<LineEdits> {
		final n: Int = a.length;
		final m: Int = b.length;
		final offset: Int = n + m + 1;
		final v: Array<Int> = [for (_ in 0...2 * offset + 1) 0];
		final trace: Array<Array<Int>> = [];
		for (d in 0...n + m + 1) {
			if (d > maxEdits) return null;
			var k: Int = -d;
			while (k <= d) {
				final down: Bool = k == -d || k != d && v[offset + k - 1] < v[offset + k + 1];
				var x: Int = down ? v[offset + k + 1] : v[offset + k - 1] + 1;
				var y: Int = x - k;
				while (x < n && y < m && a[x] == b[y]) {
					x++;
					y++;
				}
				v[offset + k] = x;
				k += 2;
			}
			trace.push([for (j in -d ... d + 1) v[offset + j]]);
			if (v[offset + n - m] >= n && (n - m) % 2 == d % 2 && n - m >= -d && n - m <= d) return backtrack(trace, n, m);
		}
		return null;
	}

	/** The script the frontier snapshots in `trace` recorded, from the end of both texts back. */
	private static function backtrack(trace: Array<Array<Int>>, n: Int, m: Int): LineEdits {
		final inserted: Array<Int> = [];
		final deleted: Array<DeletedLine> = [];
		var x: Int = n;
		var y: Int = m;
		var d: Int = trace.length - 1;
		while (d > 0) {
			final previous: Array<Int> = trace[d - 1];
			final k: Int = x - y;
			final down: Bool = k == -d || k != d && previous[k - 1 + d - 1] < previous[k + 1 + d - 1];
			final priorK: Int = down ? k + 1 : k - 1;
			final priorX: Int = previous[priorK + d - 1];
			final priorY: Int = priorX - priorK;
			if (down)
				inserted.unshift(priorY);
			else
				deleted.unshift({ line: priorX, before: priorY });
			x = priorX;
			y = priorY;
			d--;
		}
		return { inserted: inserted, deleted: deleted };
	}

}
