package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.WriteSites.WriteSite;
import anyparse.runtime.Span;

using Lambda;

/**
 * Whether a local keeps its value while code runs: the one answer to "can a call, or a region of code, change what this
 * identifier reads". A local or a parameter — a binding declared inside a function — survives a call when no function
 * literal or local function other than the ones declaring it writes it (a call may run one); it holds across a region
 * when it survives calls and no write in the region may change it. A write is matched by storage (`WriteSites.mayOverlap`
 * with the whole storage read), and one whose target no path names counts as a write of everything. One file's writes
 * and function spans, collected when built; instance state of one scan, never shared.
 */
@:nullSafety(Strict)
final class UnchangedLocal {

	/** Every write of the tree (`WriteSites.of`), in pre-order. */
	public final writes: Array<WriteSite>;

	private final _tree: QueryNode;
	private final _shape: RefShape;
	private final _functions: Array<Span>;

	public function new(tree: QueryNode, shape: RefShape) {
		_tree = tree;
		_shape = shape;
		writes = WriteSites.of(tree, shape);
		final kinds: Array<String> = ShapeVocab.functionLikeKinds(shape);
		final functions: Array<Span> = [];
		function walk(n: QueryNode): Void {
			final span: Null<Span> = n.span;
			if (span != null && kinds.contains(n.kind)) functions.push(span);
			for (c in n.children) walk(c);
		}
		walk(tree);
		_functions = functions;
	}

	/** Whether `ident` reads a local or a parameter no function literal or local function but its declaring ones writes. */
	public function survivesCalls(ident: QueryNode): Bool {
		final local: Null<LocalRead> = localRead(ident);
		return local != null && !writtenByLiteral(local);
	}

	/** Whether `ident` survives calls and no write in `region` may change it. */
	public function holds(ident: QueryNode, region: Span): Bool {
		final local: Null<LocalRead> = localRead(ident);
		if (local == null || writtenByLiteral(local)) return false;
		for (w in writes) {
			final at: Null<Span> = w.node.span;
			if (at != null && region.from <= at.from && at.to <= region.to && overlaps(w, local.key)) return false;
		}
		return true;
	}

	/** The storage key and binding offset `ident` reads when it is an identifier bound inside a function; else null. */
	private function localRead(ident: QueryNode): Null<LocalRead> {
		final name: Null<String> = ident.name;
		final span: Null<Span> = ident.span;
		if (ident.kind != _shape.identKind || name == null || span == null || name == _shape.selfReferenceText) return null;
		final binding: Null<Int> = Refs.bindingAt(name, span.from, _tree, _shape);
		final key: Null<String> = WriteSites.accessPath(ident, _tree, _shape);
		return binding == null || key == null || !_functions.exists(f -> f.from < binding && binding < f.to)
			? null
			: { key: key, binding: binding };
	}

	/** Whether a function literal or local function that does not declare the local writes it: a call may run it. */
	private function writtenByLiteral(local: LocalRead): Bool {
		for (w in writes) {
			final at: Null<Span> = w.node.span;
			if (at == null || !overlaps(w, local.key)) continue;
			if (_functions.exists(f -> f.from <= at.from && at.from < f.to && (f.from > local.binding || local.binding >= f.to)))
				return true;
		}
		return false;
	}

	private static function overlaps(w: WriteSite, key: String): Bool {
		final written: Null<String> = w.path;
		return written == null || WriteSites.mayOverlap(written, key, false);
	}

}

/** What a local identifier reads: its storage key (`WriteSites.accessPath`) and the offset of the declaration it binds. */
private typedef LocalRead = {
	final key: String;
	final binding: Int;
};
