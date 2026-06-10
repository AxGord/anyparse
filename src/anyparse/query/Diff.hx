package anyparse.query;

import anyparse.runtime.Span;
import anyparse.runtime.Span.Position;

/**
 * Structural AST diff for `apq diff <a> <b>` — paired walk over two
 * `QueryNode` trees emitting hits where the trees disagree.
 *
 * Use case: strip-test reconciliation. After editing a single .hx
 * fixture and wanting to know what changed STRUCTURALLY (vs a byte
 * diff cluttered with whitespace), `apq diff` reduces the answer to
 * "node Foo(x) at L:C in A is Bar(y) at L:C in B" — collapsing reorder
 * of unrelated children and whitespace into nothing.
 *
 * Algorithm: top-down recursive paired walk. For each pair `(a, b)`:
 *   - If both null → no hit.
 *   - If one side null → `Added` / `Removed` hit, do not recurse.
 *   - If `a.kind` or `a.name` differs from `b` → `Differs` hit, do
 *     not recurse (everything underneath is below a changed subtree
 *     and would just generate cascading noise).
 *   - Otherwise zip children by index and recurse. Imbalanced child
 *     count surfaces the surplus as Added/Removed on the longer side.
 *
 * Limitation: there is no LCS realignment of children. A single
 * INSERT in the middle of a long Star (e.g. one new enum ctor inserted
 * mid-list) cascades every following sibling as a `Differs` hit.
 * Adequate for the common case (one edit, end-of-list change, full
 * subtree replacement) which is what strip-test recon needs; insert
 * cases benefit from byte diff or `--limit`. The richer alignment is
 * a future iteration.
 */
@:nullSafety(Strict)
final class Diff {

	/**
	 * Walk `a` and `b` paired and collect divergence hits.
	 */
	public static function diff(a: QueryNode, b: QueryNode): Array<DiffHit> {
		final out: Array<DiffHit> = [];
		walk(a, b, out);
		return out;
	}

	private static function walk(a: Null<QueryNode>, b: Null<QueryNode>, out: Array<DiffHit>): Void {
		if (a == null && b == null) return;
		if (a == null) {
			out.push(new DiffHit(DiffKind.Added, null, b));
			return;
		}
		if (b == null) {
			out.push(new DiffHit(DiffKind.Removed, a, null));
			return;
		}
		// Same-position pair: compare ctor shape (kind + name slot).
		// If either differs, the subtrees are not corresponding — emit
		// a single Differs hit and stop recursing.
		if (a.kind != b.kind || (a.name != b.name)) {
			out.push(new DiffHit(DiffKind.Differs, a, b));
			return;
		}
		// Same shape — zip children by index. Imbalanced tail surfaces
		// as Added/Removed on the longer side.
		final la: Int = a.children.length;
		final lb: Int = b.children.length;
		final shared: Int = la < lb ? la : lb;
		for (i in 0...shared) walk(a.children[i], b.children[i], out);
		if (la > lb)
			for (i in lb...la) walk(a.children[i], null, out);
		else if (lb > la) for (i in la...lb) walk(null, b.children[i], out);
	}

	public static function render(
		fileA: String, sourceA: String, fileB: String, sourceB: String, hits: Array<DiffHit>, flat: Bool = false
	): String {
		final buf: StringBuf = new StringBuf();
		if (hits.length == 0) {
			buf.add('apq diff: trees identical ($fileA == $fileB)\n');
			return buf.toString();
		}
		if (!flat) buf.add('$fileA ↔ $fileB:\n');
		for (h in hits) {
			final indent: String = flat ? '' : '  ';
			switch h.kind {
				case Differs:
					final leftN: Null<QueryNode> = h.left;
					final rightN: Null<QueryNode> = h.right;
					if (leftN == null || rightN == null) continue;
					final a: QueryNode = leftN;
					final b: QueryNode = rightN;
					final pa: Null<Position> = a.span == null ? null : (a.span: Span).lineCol(sourceA);
					final pb: Null<Position> = b.span == null ? null : (b.span: Span).lineCol(sourceB);
					if (flat)
						buf.add('$fileA:${posOrZero(pa)} ↔ $fileB:${posOrZero(pb)}: differs: ${nodeLabel(a)} ↔ ${nodeLabel(b)}\n');
					else
						buf.add('$indent${posOrZero(pa)} ↔ ${posOrZero(pb)}: differs: ${nodeLabel(a)} ↔ ${nodeLabel(b)}\n');
				case Added:
					final rightN: Null<QueryNode> = h.right;
					if (rightN == null) continue;
					final b: QueryNode = rightN;
					final pb: Null<Position> = b.span == null ? null : (b.span: Span).lineCol(sourceB);
					if (flat)
						buf.add('$fileB:${posOrZero(pb)}: added: ${nodeLabel(b)}\n');
					else
						buf.add('$indent       ↔ ${posOrZero(pb)}: added: ${nodeLabel(b)}\n');
				case Removed:
					final leftN: Null<QueryNode> = h.left;
					if (leftN == null) continue;
					final a: QueryNode = leftN;
					final pa: Null<Position> = a.span == null ? null : (a.span: Span).lineCol(sourceA);
					if (flat)
						buf.add('$fileA:${posOrZero(pa)}: removed: ${nodeLabel(a)}\n');
					else
						buf.add('$indent${posOrZero(pa)} ↔        : removed: ${nodeLabel(a)}\n');
			}
		}
		return buf.toString();
	}

	private static inline function posOrZero(p: Null<Position>): String {
		return p == null ? '?:?' : '${p.line}:${p.col}';
	}

	private static inline function nodeLabel(n: QueryNode): String {
		return n.name == null ? n.kind : '${n.kind} \'${n.name}\'';
	}

}

@:nullSafety(Strict)
enum DiffKind {

	Differs;
	Added;
	Removed;

}

@:nullSafety(Strict)
final class DiffHit {

	public final kind: DiffKind;
	public final left: Null<QueryNode>;
	public final right: Null<QueryNode>;

	public function new(kind: DiffKind, left: Null<QueryNode>, right: Null<QueryNode>) {
		this.kind = kind;
		this.left = left;
		this.right = right;
	}

}
