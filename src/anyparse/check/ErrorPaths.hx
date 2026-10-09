package anyparse.check;

import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.runtime.LineIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * Where a call runs only on an error path: its site sits inside the body of a `catch` clause of its file that no loop of its
 * function holds (every turn of a loop may fail: such a `catch` runs on the normal path) — of its own function, or of the one a
 * lambda or local function it sits in is written in, when that nested function runs only through calls made inside the `catch`
 * (a reference to it may be stored and called anywhere). Read off the branch-aware tree (`FunctionTrees`), each site placed once.
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
	private final _nestedFnKinds: Array<String>;

	/** The loops: a `catch` inside one runs once per failing turn, which nothing bounds. */
	private final _loopKinds: Array<String>;

	public function new(graph: CallGraph, trees: FunctionTrees, shape: RefShape) {
		_graph = graph;
		_trees = trees;
		_catchKind = shape.catchClauseKind;
		_nestedFnKinds = MemberKinds.nestedFunctionKinds(shape);
		_loopKinds = CallRepetition.loopKindsOf(shape);
	}

	/** The `catch` clause whose body holds the site of `edge`, the innermost one; null for a site outside every one, or unplaced. */
	public inline function catchOf(edge: CallEdge): Null<Span> {
		final at: Null<Span> = edge.span;
		return at == null ? null : catchAt(edge.file, at);
	}

	/** Whether `edge` runs only on an error path (`catchOf`). */
	public inline function inCatch(edge: CallEdge): Bool {
		return catchOf(edge) != null;
	}

	/** The `catch` clause whose body holds the site `at` of `file`, the innermost one; null for none, or an unplaced site. */
	public function catchAt(file: String, at: Span): Null<Span> {
		final key: String = '$file:${at.from}';
		if (_catches.exists(key)) return _catches[key];
		final tree: Null<QueryNode> = _trees.ofFile(file);
		final found: Null<Span> = tree == null || _catchKind == null ? null : catchTo(tree, file, at);
		_catches[key] = found;
		return found;
	}

	/** The first call of `edges` that runs only on an error path, as `file:line` of its `catch`; null when none does. */
	public function placeOf(edges: Array<CallEdge>): Null<String> {
		for (e in edges) {
			final at: Null<Span> = e.span;
			final place: Null<String> = at == null ? null : placeAt(e.file, at);
			if (place != null) return place;
		}
		return null;
	}

	/** The `catch` around the site `at` of `file` as `file:line`; null when no catch holds it. */
	public function placeAt(file: String, at: Span): Null<String> {
		final span: Null<Span> = catchAt(file, at);
		return span == null ? null : '$file:${lineOf(file, span.from)}';
	}

	/**
	 * The innermost `catch` clause from the root of `tree` (of `file`) down to the node spanning `at` that runs only on
	 * an error path: one no loop of the way down holds — a loop's every turn may fail, so its `catch` is a path of the
	 * normal run — and, for a site inside a nested function, one that function runs only inside (`runsOnlyIn`).
	 */
	private function catchTo(tree: QueryNode, file: String, at: Span): Null<Span> {
		var found: Null<Span> = null;
		var looped: Bool = false;
		var node: QueryNode = tree;
		while (true) {
			final child: Null<QueryNode> = node.children.find(c -> c.span != null && c.span.from <= at.from && c.span.to >= at.to);
			if (child == null) return found;
			final span: Null<Span> = child.span;
			looped = looped || _loopKinds.contains(child.kind);
			if (child.kind == _catchKind && !looped) found = span;
			// a nested function runs where it is called: under the catch only when every way into it is a call there
			if (_nestedFnKinds.contains(child.kind) && found != null && !(span != null && runsOnlyIn(file, span, found))) found = null;
			node = child;
		}
	}

	/**
	 * Whether the nested function spanning `fnSpan` in `file` runs only inside the `catch` clause spanning `clause`: the
	 * graph holds a way into it besides its enclosing function's containment, and every one is an invocation made there —
	 * never a reference, whose value may be stored and called anywhere.
	 */
	private function runsOnlyIn(file: String, fnSpan: Span, clause: Span): Bool {
		final id: Null<String> = _graph.functionAt(file, fnSpan.from);
		final ways: Array<CallEdge> = id == null ? [] : _graph.inEdges(id).filter(e -> e.kind != Contains);
		return ways.length > 0
			&& ways.foreach(
				e -> e.kind.isInvocation() && e.file == file && e.span != null && e.span.from >= clause.from && e.span.to <= clause.to
			);
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

	/** What a finding long only where a `catch` runs adds to its message, `place` the `file:line` of that catch. */
	public static inline function note(place: String): String {
		return ' — only on an error path (catch at $place): long through no call outside a catch, so reported as info';
	}

}

/** The taint asking which calls block LONG (`all`), the same over the normal paths only (`normal`), and what tells them apart. */
typedef PathCosts = {
	final all: LockTaint;
	final normal: LockTaint;
	final errors: ErrorPaths;
}
