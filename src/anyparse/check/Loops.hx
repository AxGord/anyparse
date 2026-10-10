package anyparse.check;

import anyparse.check.LockTaint.ChainLists;
import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;

/**
 * The loops of a file's tree: the one definition of a loop every check of repetition and control flow reads
 * (`kindsOf`), the loops around a position (`around`), and what names a loop (`label`).
 *
 * A loop is a kind the grammar names: `loopStatementKinds`, `doWhileLoopKinds`, `iterationBindingKinds` and
 * `whileExprKind`. Of a loop binding a name (`for`), only the body repeats — the iterable runs once; of any other, every
 * part does (a `while` condition runs once per turn). A function or lambda around a position starts the count afresh,
 * its body running where it is invoked.
 */
@:nullSafety(Strict)
final class Loops {

	/** The loop kinds of the grammar (`kindsOf`); empty for a grammar naming none. */
	public final kinds: Array<String>;

	/** The functions a call of which may block: one calling a sink its call's chain names, and every one calling or handing on such a one. */
	private var _sinkward: Null<Map<String, Bool>> = null;

	private final _graph: CallGraph;
	private final _listsOf: (String) -> ChainLists;
	private final _bindingKinds: Array<String>;
	private final _doWhileKinds: Array<String>;

	/** The kinds whose body is a function of its own: a position inside one sits in no loop around it. */
	private final _functionKinds: Array<String>;

	public function new(graph: CallGraph, shape: RefShape, listsOf: (String) -> ChainLists) {
		_graph = graph;
		_listsOf = listsOf;
		kinds = kindsOf(shape);
		_bindingKinds = shape.iterationBindingKinds ?? [];
		_doWhileKinds = shape.doWhileLoopKinds ?? [];
		_functionKinds = (shape.functionKinds ?? []).concat(MemberKinds.nestedFunctionKinds(shape));
	}

	/**
	 * The loops of `shape` — `loopStatementKinds`, `doWhileLoopKinds`, `iterationBindingKinds` and `whileExprKind`, each
	 * once: the one definition of a loop every check of repetition and control flow reads (`CallRepetition`,
	 * `ErrorPaths`, `LockWindow`).
	 */
	public static function kindsOf(shape: RefShape): Array<String> {
		final out: Array<String> = [];
		final all: Array<String> = (shape.loopStatementKinds ?? []).concat(shape.doWhileLoopKinds ?? [])
			.concat(shape.iterationBindingKinds ?? [])
			.concat(shape.whileExprKind == null ? [] : [shape.whileExprKind]);
		for (k in all) if (!out.contains(k)) out.push(k);
		return out;
	}

	/** A loop header as a label spells it (`label`, a `boundedRepeats` entry's `loop`): each run of whitespace one space, none at the ends. */
	public static function spelled(text: String): String {
		return StringTools.trim(~/\s+/g.replace(text, ' '));
	}

	/**
	 * The header of the innermost loop around the offset `at` of the file whose tree is `tree` — `for (s in sessions)`,
	 * `while (pending())`, `do … while (more)` — counted from the innermost function around it, its whitespace collapsed,
	 * and a rank (`#2`) for a second loop of the same header in that function that repeats a call which may block
	 * (`repeatsSink`): what names the loop whatever else its body holds, whatever moves around it, and whatever loop that
	 * blocks nothing is added beside it. Null when no loop is placed there.
	 */
	public function label(file: String, tree: QueryNode, at: Int): Null<String> {
		final loop: Null<QueryNode> = kinds.length == 0 ? null : around(tree, at).pop()?.node;
		return loop == null ? null : labelOf(file, tree, loop, at);
	}

	/** The label (`label`) of the loop node `loop` around the offset `at` of `file`, whose tree is `tree`. */
	public function labelOf(file: String, tree: QueryNode, loop: QueryNode, at: Int): Null<String> {
		final header: Null<String> = headerOf(file, loop);
		if (header == null) return null;
		// a second loop of one header in one function is told apart by its rank among those that may block, never by its offset
		final same: Array<QueryNode> = [
			for (l in within(scopeOf(tree, at), true)) if (headerOf(file, l) == header && (l == loop || repeatsSink(file, l))) l
		];
		final rank: Int = same.indexOf(loop);
		return rank > 0 ? '$header #${rank + 1}' : header;
	}

	/**
	 * The loops from the root of `tree` down to the node holding the offset `at`, counted from the innermost function
	 * around it, outermost first, each with its repeating part that holds `at` — a `for`'s body, any other loop whole.
	 */
	public function around(tree: QueryNode, at: Int): Array<{ node: QueryNode, repeating: Span }> {
		var loops: Array<{ node: QueryNode, repeating: Span }> = [];
		var node: QueryNode = tree;
		while (true) {
			final child: Null<QueryNode> = node.children.find(c -> c.span != null && c.span.from <= at && c.span.to > at);
			if (child == null) return loops;
			final span: Null<Span> = node.span;
			final repeating: Null<Span> = _bindingKinds.contains(node.kind) ? node.children[node.children.length - 1].span : span;
			// a function around the site starts it afresh; a lambda that IS the site is a value its own function registers there
			if (_functionKinds.contains(node.kind) && span != null && span.from != at)
				loops = []
			else if (kinds.contains(node.kind) && repeating != null && repeating.from <= at && at < repeating.to)
				loops.push({ node: node, repeating: repeating });
			node = child;
		}
	}

	/** The loop nodes under `node` in source order, a function nested in it aside (`top`: `node` itself is the function). */
	public function within(node: QueryNode, top: Bool): Array<QueryNode> {
		if (!top && _functionKinds.contains(node.kind)) return [];
		final out: Array<QueryNode> = kinds.contains(node.kind) ? [node] : [];
		for (c in node.children) for (l in within(c, false)) out.push(l);
		return out;
	}

	/** The innermost function node of `tree` around the offset `at`, counted as `around` counts; the root when none is. */
	private function scopeOf(tree: QueryNode, at: Int): QueryNode {
		var scope: QueryNode = tree;
		var node: QueryNode = tree;
		while (true) {
			final child: Null<QueryNode> = node.children.find(c -> c.span != null && c.span.from <= at && c.span.to > at);
			if (child == null) return scope;
			final span: Null<Span> = node.span;
			if (_functionKinds.contains(node.kind) && span != null && span.from != at) scope = node;
			node = child;
		}
	}

	/** The header of the loop node `loop` of `file` (`label`); null when the file has no source or the loop no parts. */
	private function headerOf(file: String, loop: QueryNode): Null<String> {
		final source: Null<String> = _graph.sourceOf(file);
		final span: Null<Span> = loop.span;
		if (source == null || span == null || loop.children.length == 0) return null;
		final first: Null<Span> = loop.children[0].span;
		final last: Null<Span> = loop.children[loop.children.length - 1].span;
		final text: Null<String> = if (_doWhileKinds.contains(loop.kind))
			first == null ? null : 'do … ' + source.substring(first.to, span.to)
		else
			last == null ? null : source.substring(span.from, last.from);
		return text == null ? null : spelled(text);
	}

	/**
	 * Whether the loop node `loop` of `file` repeats a call that may block: a call (or a value handed on) of the function
	 * around it, sitting in its repeating part, into a sink its chain names or a function from which a call may block
	 * (`sinkward`).
	 */
	private function repeatsSink(file: String, loop: QueryNode): Bool {
		final span: Null<Span> = _bindingKinds.contains(loop.kind) ? loop.children[loop.children.length - 1].span : loop.span;
		final fn: Null<String> = span == null ? null : _graph.functionAt(file, span.from);
		if (span == null || fn == null) return true;
		final reaching: Map<String, Bool> = sinkward();
		return _graph.outEdges(fn).exists(
			e ->
				e.kind != Contains && e.span != null && e.span.from >= span.from && e.span.to <= span.to
				&& (reaching.exists(e.to) || _listsOf(e.file).sinkIds.contains(e.to))
		);
	}

	/** Whether a call made from the function `id` may block: it calls a sink, or a function from which a call may (`sinkward`). */
	public inline function mayBlock(id: String): Bool {
		return sinkward().exists(id);
	}

	/** The functions from which a call may block (`_sinkward`), filled on first use. */
	private function sinkward(): Map<String, Bool> {
		final known: Null<Map<String, Bool>> = _sinkward;
		if (known != null) return known;
		final found: Map<String, Bool> = [];
		final queue: Array<String> = [];
		for (e in _graph.edges) if (e.kind.isInvocation() && !found.exists(e.from) && _listsOf(e.file).sinkIds.contains(e.to)) {
			found[e.from] = true;
			queue.push(e.from);
		}
		var qi: Int = 0;
		while (qi < queue.length) for (e in _graph.inEdges(queue[qi++])) if (e.kind != Contains && !found.exists(e.from)) {
			found[e.from] = true;
			queue.push(e.from);
		}
		_sinkward = found;
		return found;
	}

}
