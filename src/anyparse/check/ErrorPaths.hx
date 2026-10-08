package anyparse.check;

import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.runtime.LineIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * Where a call runs only on an error path: its site sits inside the body of a `catch` clause of its file — of its own
 * function, or of the one a lambda or local function it sits in is written in, which exists only once that `catch` ran.
 * Read off the branch-aware tree (`FunctionTrees`), each site placed once.
 */
@:nullSafety(Strict)
final class ErrorPaths {

	/** `<file>:<offset>` -> the `catch` clause around that site; null when none is. */
	private final _catches: Map<String, Null<Span>> = [];

	/** Each file's line index, built the first time a catch of it is named. */
	private final _lines: Map<String, LineIndex> = [];

	private final _graph: CallGraph;
	private final _trees: FunctionTrees;
	private final _catchKind: Null<String>;

	public function new(graph: CallGraph, trees: FunctionTrees, shape: RefShape) {
		_graph = graph;
		_trees = trees;
		_catchKind = shape.catchClauseKind;
	}

	/** The `catch` clause whose body holds the site of `edge`, the innermost one; null for a site outside every one, or unplaced. */
	public function catchOf(edge: CallEdge): Null<Span> {
		final at: Null<Span> = edge.span;
		if (at == null) return null;
		final key: String = '${edge.file}:${at.from}';
		if (_catches.exists(key)) return _catches[key];
		final tree: Null<QueryNode> = _trees.ofFile(edge.file);
		final found: Null<Span> = tree == null || _catchKind == null ? null : catchTo(tree, at);
		_catches[key] = found;
		return found;
	}

	/** What a finding long only where a `catch` runs adds to its message, `place` the `file:line` of that catch. */
	public static inline function note(place: String): String {
		return ' — only on an error path (catch at $place): long through no call outside a catch, so reported as info';
	}

	/** Whether `edge` runs only on an error path (`catchOf`). */
	public inline function inCatch(edge: CallEdge): Bool {
		return catchOf(edge) != null;
	}

	/** The first call of `edges` that runs only on an error path, as `file:line` of its `catch`; null when none does. */
	public function placeOf(edges: Array<CallEdge>): Null<String> {
		for (e in edges) {
			final span: Null<Span> = catchOf(e);
			if (span != null) return '${e.file}:${lineOf(e.file, span.from)}';
		}
		return null;
	}

	/** The innermost `catch` clause from the root of `tree` down to the node spanning `at`. */
	private function catchTo(tree: QueryNode, at: Span): Null<Span> {
		var found: Null<Span> = null;
		var node: QueryNode = tree;
		while (true) {
			final child: Null<QueryNode> = node.children.find(c -> c.span != null && c.span.from <= at.from && c.span.to >= at.to);
			if (child == null) return found;
			if (child.kind == _catchKind) found = child.span;
			node = child;
		}
	}

	/** The 1-based line of `offset` in `file`. */
	private function lineOf(file: String, offset: Int): Int {
		var index: Null<LineIndex> = _lines[file];
		if (index == null) {
			index = new LineIndex(_graph.sourceOf(file) ?? '');
			_lines[file] = index;
		}
		return index.lineColAt(offset).line;
	}

}

/** The taint asking which calls block LONG (`all`), the same over the normal paths only (`normal`), and what tells them apart. */
typedef PathCosts = {
	final all: LockTaint;
	final normal: LockTaint;
	final errors: ErrorPaths;
}
