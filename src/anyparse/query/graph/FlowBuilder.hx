package anyparse.query.graph;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.SourceComments;
import anyparse.query.graph.FlowGraph.FlowKind;
import anyparse.query.graph.FlowGraph.FlowNode;
import anyparse.runtime.Span;

using Lambda;

/** How one statement of a body shapes the chart. */
private enum FlowStatement {

	Block;
	Branch;
	WhileLoop;
	DoLoop;
	Select;
	Guarded;
	Leave;
	Raise;
	Cut;
	Next;
	Other;

}

/** Where control stands after a statement: the node it left and the label of the edge it leaves by. */
private typedef FlowTail = {
	final node: FlowNode;
	final label: Null<String>;
}

/** A loop being drawn: the node `continue` returns to and the tails `break` leaves by. */
private typedef FlowLoop = {
	/**
	 * The node `continue` returns to; null for a `do … while`, whose
	 * test is drawn after its body: `continues` collects what reaches it.
	 */
	final head: Null<FlowNode>;
	final exits: Array<FlowTail>;

	/** The `continue` nodes of a `do … while` body, which reach its test once it is drawn. */
	final continues: Array<FlowNode>;
}

/**
 * The one answer to "what is the control-flow chart of this function body": a `FlowGraph` of its decisions, loops,
 * switches, try / catch and exits, read off the AST through the grammar's `RefShape` vocabulary (`ShapeVocab`) and
 * never a node kind spelled here.
 *
 * A run of consecutive declarations, or of consecutive plain statements, is ONE node. A `break` and a `continue` are
 * edges to the loop's exit and head, a `return` an edge to the end, and a `throw` an edge to the catches of the
 * innermost `try` around it, else to the end; a `try` also reaches each of its catches, since any call may throw.
 * Statements after one that leaves are not drawn (`dead-code` owns them), and a `switch` with no catch-all
 * arm (no `default`, no unguarded wildcard) also leaves by `no match`. A statement under conditional
 * compilation is one plain statement; an arm under it leaves the switch by an edge of its own text.
 */
@:nullSafety(Strict)
final class FlowBuilder {

	/** The width past which a node's text is cut. */
	private static inline final TEXT_WIDTH: Int = 48;

	/** How many statements of a folded run a node names before counting the rest. */
	private static inline final RUN_LINES: Int = 3;

	/** What may follow a comment inside a header, a pattern or a call without a blank between. */
	private static inline final CLOSERS: String = ')],;:';

	private static final WHITESPACE: EReg = ~/\s+/g;

	/** The class of each statement kind the grammar names; any other kind is `Other`. */
	private final _classes: Map<String, FlowStatement> = [];

	/** The loops being drawn, innermost last. */
	private final _loops: Array<FlowLoop> = [];

	/** The catch nodes of each `try` whose body is being drawn, innermost last. */
	private final _handlers: Array<Array<FlowNode>> = [];

	/** The nodes that reach the end: every `return`, and every `throw` no `try` around it catches. */
	private final _exits: Array<FlowNode> = [];

	/** The statements a folded node holds, by node id. */
	private final _runs: Map<String, Array<String>> = [];

	private final _shape: RefShape;
	private final _source: String;

	/** The comment spans of the source, in order: no label holds one. */
	private final _comments: Array<Span>;

	private final _chart: FlowGraph;
	private final _blocks: Array<String>;
	private final _declarations: Array<String>;

	private function new(name: String, shape: RefShape, source: String, regions: Array<LexRegion>) {
		_shape = shape;
		_source = source;
		_comments = SourceComments.collectCommentRegions(regions);
		_chart = new FlowGraph(name);
		_blocks = [for (kind in [shape.blockStmtKind, shape.blockBodyKind]) if (kind != null) kind];
		_declarations = (shape.localDeclKinds ?? []).concat(ShapeVocab.localFunctionScopeKinds(shape));
		register(_blocks, Block);
		register(ShapeVocab.ifKinds(shape), Branch);
		register(shape.loopStatementKinds, WhileLoop);
		register(shape.doWhileLoopKinds, DoLoop);
		register(shape.switchKinds, Select);
		register(ShapeVocab.tryKinds(shape), Guarded);
		register(ShapeVocab.returnKinds(shape), Leave);
		register(shape.throwKinds, Raise);
		register([shape.breakStatementKind, shape.breakExpressionKind], Cut);
		register([shape.continueStatementKind, shape.continueExpressionKind], Next);
	}

	private function register(kinds: Null<Array<Null<String>>>, cls: FlowStatement): Void {
		for (kind in kinds ?? []) if (kind != null && !_classes.exists(kind)) _classes[kind] = cls;
	}

	/** Whether `body` holds bodies to choose between (a conditional-compilation body) rather than statements to run in turn. */
	private function holdsAlternatives(body: QueryNode): Bool {
		final bodies: Array<String> = _shape.functionBodyKinds ?? [];
		return body.children.exists(c -> bodies.contains(c.kind));
	}

	private function draw(fn: QueryNode, body: QueryNode): FlowGraph {
		final start: FlowNode = _chart.add(Start, 'start', lineOf(fn.span?.from));
		final tails: Array<FlowTail> = statements(holdsAlternatives(body) ? [body] : body.children, [tail(start, null)]);
		final end: FlowNode = _chart.add(End, 'end', lineOf(fn.span?.to));
		connectAll(tails, end);
		for (exit in _exits) _chart.connect(exit, end, null);
		return _chart;
	}

	/** Draw `list` one statement after another from `tails`; the tails after the last. */
	private function statements(list: Array<QueryNode>, tails: Array<FlowTail>): Array<FlowTail> {
		var current: Array<FlowTail> = tails;
		for (s in list) {
			if (current.length == 0) break;
			current = statement(s, current);
		}
		return current;
	}

	private function statement(s: QueryNode, tails: Array<FlowTail>): Array<FlowTail> {
		return switch classify(s) {
			case Block: statements(s.children, tails);
			case Branch: branch(s, tails);
			case WhileLoop: whileLoop(s, tails);
			case DoLoop: doLoop(s, tails);
			case Select: select(s, tails);
			case Guarded: guarded(s, tails);
			case Leave: leave(s, Return, tails);
			case Raise: leave(s, Throw, tails);
			case Cut: cut(s, tails);
			case Next: next(s, tails);
			case Other: plain(s, tails);
		};
	}

	/** The class of `s`, a statement written without its semicolon (`ExprStmt(ThrowExpr)`) read as the jump or exit it holds. */
	private function classify(s: QueryNode): FlowStatement {
		final cls: FlowStatement = classOf(s);
		if (cls != Other || s.kind != _shape.exprStatementKind || s.children.length != 1) return cls;
		return switch classOf(s.children[0]) {
			case Leave: Leave;
			case Raise: Raise;
			case Cut: Cut;
			case Next: Next;
			case _: Other;
		};
	}

	private function classOf(s: QueryNode): FlowStatement {
		final cls: FlowStatement = _classes[s.kind] ?? Other;
		final needed: Int = switch cls {
			case Branch, DoLoop: 2;
			case WhileLoop, Guarded: 1;
			case _: 0;
		};
		return s.children.length < needed || ((cls == Cut || cls == Next) && _loops.length == 0) ? Other : cls;
	}

	private function branch(s: QueryNode, tails: Array<FlowTail>): Array<FlowTail> {
		final decision: FlowNode = _chart.add(Decision, conditionText(s.children[0]), lineOf(s.span?.from));
		connectAll(tails, decision);
		final taken: Array<FlowTail> = statements(listOf(s.children[1]), [tail(decision, 'yes')]);
		final otherwise: Array<FlowTail> = [tail(decision, 'no')];
		return taken.concat(s.children.length > 2 ? statements(listOf(s.children[2]), otherwise) : otherwise);
	}

	/** A loop whose body is its last child, its header the text before it. */
	private function whileLoop(s: QueryNode, tails: Array<FlowTail>): Array<FlowTail> {
		final body: QueryNode = s.children[s.children.length - 1];
		final head: FlowNode = _chart.add(Loop, limit(textBefore(s, body)), lineOf(s.span?.from));
		connectAll(tails, head);
		final loop: FlowLoop = { head: head, exits: [], continues: [] };
		_loops.push(loop);
		final looped: Array<FlowTail> = statements(listOf(body), [tail(head, 'body')]);
		_loops.pop();
		connectAll(looped, head);
		return [tail(head, 'done')].concat(loop.exits);
	}

	/** A loop whose body is its first child and whose condition, the last, is tested after it. */
	private function doLoop(s: QueryNode, tails: Array<FlowTail>): Array<FlowTail> {
		final entry: FlowNode = _chart.add(Loop, 'do', lineOf(s.span?.from));
		connectAll(tails, entry);
		final loop: FlowLoop = { head: null, exits: [], continues: [] };
		_loops.push(loop);
		final looped: Array<FlowTail> = statements(listOf(s.children[0]), [tail(entry, null)]);
		_loops.pop();
		// a body that always leaves never reaches the test, which is then not drawn
		if (looped.length == 0 && loop.continues.length == 0) return loop.exits;
		final test: FlowNode = _chart.add(Decision, 'while ${conditionText(s.children[s.children.length - 1])}', lineOf(s.span?.to));
		connectAll(looped, test);
		for (c in loop.continues) _chart.connect(c, test, null);
		_chart.connect(test, entry, 'again');
		return [tail(test, 'done')].concat(loop.exits);
	}

	/** A `switch`: one edge per arm, labelled by the arm's own text. */
	private function select(s: QueryNode, tails: Array<FlowTail>): Array<FlowTail> {
		final subject: String = s.children.length > 0 ? ' ${conditionText(s.children[0])}' : '';
		final node: FlowNode = _chart.add(Switch, 'switch$subject', lineOf(s.span?.from));
		connectAll(tails, node);
		var left: Array<FlowTail> = [];
		var covered: Bool = false;
		for (arm in s.children.slice(1)) {
			if (arm.kind != _shape.caseBranchKind && arm.kind != _shape.defaultBranchKind) {
				// an arm under conditional compilation is no arm node: the text it holds is one statement of its own
				left = left.concat(statements([arm], [tail(node, limit(textOf(arm)))]));
				continue;
			}
			covered = covered || catchesAll(arm);
			left = left.concat(statements(armBody(arm), [tail(node, armLabel(arm))]));
		}
		// without a catch-all arm control may match none of them and go on
		if (!covered) left.push(tail(node, 'no match'));
		return left;
	}

	/** The statements of a `case` or `default` arm: its children past the patterns and the guard. */
	private function armBody(arm: QueryNode): Array<QueryNode> {
		return arm.children.slice(bodyStart(arm));
	}

	/** The index of the first statement of an arm: past its patterns and its guard, a parenthesized child right after them. */
	private function bodyStart(arm: QueryNode): Int {
		var from: Int = 0;
		final pattern: Null<String> = _shape.plainCasePatternKind;
		if (arm.kind != _shape.defaultBranchKind && pattern != null) {
			while (from < arm.children.length && arm.children[from].kind == pattern) from++;
			if (from > 0 && from < arm.children.length && arm.children[from].kind == _shape.parenKind) from++;
		}
		return from;
	}

	/** Whether `arm` matches whatever reaches it: a `default`, or an unguarded case whose one pattern is the wildcard. */
	private function catchesAll(arm: QueryNode): Bool {
		if (arm.kind == _shape.defaultBranchKind) return true;
		final wildcard: Null<String> = _shape.wildcardPatternName;
		final first: Null<QueryNode> = arm.children[0];
		if (wildcard == null || first == null || first.kind != _shape.plainCasePatternKind || first.children.length != 1) return false;
		final guarded: Bool = bodyStart(arm) > 1 && arm.children[1].kind == _shape.parenKind;
		return !guarded && first.children[0].kind == _shape.identKind && first.children[0].name == wildcard;
	}

	private function armLabel(arm: QueryNode): String {
		final span: Null<Span> = arm.span;
		if (span == null) return arm.kind;
		final first: Null<Span> = arm.children[bodyStart(arm)]?.span;
		return limit(trimmed(spanText(span.from, first == null ? span.to : first.from), ':'));
	}

	/** A `try`: its body from the `try` node, each catch from its own node, which the `try` and every `throw` in the body reach. */
	private function guarded(s: QueryNode, tails: Array<FlowTail>): Array<FlowTail> {
		final node: FlowNode = _chart.add(Try, 'try', lineOf(s.span?.from));
		connectAll(tails, node);
		final catches: Array<QueryNode> = s.children.slice(1).filter(c -> c.kind == _shape.catchClauseKind);
		final handlers: Array<FlowNode> = [
			for (c in catches) _chart.add(Catch, limit(textBefore(c, c.children[c.children.length - 1])), lineOf(c.span?.from))
		];
		for (h in handlers) _chart.connect(node, h, 'error');
		_handlers.push(handlers);
		var left: Array<FlowTail> = statements(listOf(s.children[0]), [tail(node, null)]);
		_handlers.pop();
		for (i => c in catches) left = left.concat(statements(listOf(c.children[c.children.length - 1]), [tail(handlers[i], null)]));
		return left;
	}

	/** A `return` or a `throw`: control does not go on from it. */
	private function leave(s: QueryNode, kind: FlowKind, tails: Array<FlowTail>): Array<FlowTail> {
		final node: FlowNode = _chart.add(kind, limit(textOf(s)), lineOf(s.span?.from));
		connectAll(tails, node);
		final handlers: Array<FlowNode> = kind == Throw && _handlers.length > 0 ? _handlers[_handlers.length - 1] : [];
		if (handlers.length == 0) _exits.push(node);
		for (h in handlers) _chart.connect(node, h, null);
		return [];
	}

	private function cut(s: QueryNode, tails: Array<FlowTail>): Array<FlowTail> {
		final node: FlowNode = _chart.add(Break, 'break', lineOf(s.span?.from));
		connectAll(tails, node);
		_loops[_loops.length - 1].exits.push(tail(node, null));
		return [];
	}

	private function next(s: QueryNode, tails: Array<FlowTail>): Array<FlowTail> {
		final node: FlowNode = _chart.add(Continue, 'continue', lineOf(s.span?.from));
		connectAll(tails, node);
		final loop: FlowLoop = _loops[_loops.length - 1];
		final head: Null<FlowNode> = loop.head;
		if (head == null)
			loop.continues.push(node)
		else
			_chart.connect(node, head, null);
		return [];
	}

	/** A plain statement, folded into the node of the run it continues. */
	private function plain(s: QueryNode, tails: Array<FlowTail>): Array<FlowTail> {
		final kind: FlowKind = _declarations.contains(s.kind) ? Declarations : Steps;
		final text: String = limit(textOf(s));
		if (tails.length == 1 && tails[0].label == null && tails[0].node.kind == kind) {
			final run: Null<Array<String>> = _runs[tails[0].node.id];
			if (run != null) {
				run.push(text);
				tails[0].node.label = runLabel(run);
				return tails;
			}
		}
		final node: FlowNode = _chart.add(kind, text, lineOf(s.span?.from));
		_runs[node.id] = [text];
		connectAll(tails, node);
		return [tail(node, null)];
	}

	private function listOf(n: QueryNode): Array<QueryNode> {
		return _blocks.contains(n.kind) ? n.children : [n];
	}

	private function connectAll(tails: Array<FlowTail>, to: FlowNode): Void {
		for (t in tails) _chart.connect(t.node, to, t.label);
	}

	private function lineOf(offset: Null<Int>): Int {
		return offset == null ? 0 : new Span(offset, offset).lineCol(_source).line;
	}

	/** The source of `n` on one line, a trailing `;` dropped. */
	private function textOf(n: QueryNode): String {
		final span: Null<Span> = n.span;
		return span == null ? n.kind : trimmed(spanText(span.from, span.to), ';');
	}

	/** The source from the start of `n` up to `stop`: the header of a loop or a catch. */
	private function textBefore(n: QueryNode, stop: QueryNode): String {
		final span: Null<Span> = n.span;
		final until: Null<Span> = stop.span;
		return span == null || until == null ? n.kind : trimmed(spanText(span.from, until.from), '');
	}

	/** A condition's text, the parentheses the grammar projects around it dropped. */
	private function conditionText(n: QueryNode): String {
		final text: String = limit(textOf(n));
		return n.kind == _shape.parenKind && text.charAt(0) == '(' && text.charAt(text.length - 1) == ')'
			? text.substring(1, text.length - 1)
			: text;
	}

	/** `[from, to)` of the source without the comments inside it. */
	private function spanText(from: Int, to: Int): String {
		final out: StringBuf = new StringBuf();
		var at: Int = from;
		for (c in _comments) if (c.to > at) {
			if (c.from >= to) break;
			final before: String = _source.substring(at, c.from < at ? at : c.from);
			// the blank left of a comment goes with it when the comment ends against a closer
			out.add(CLOSERS.indexOf(_source.charAt(c.to)) >= 0 ? before.rtrim() : before);
			at = c.to < to ? c.to : to;
		}
		out.add(_source.substring(at, to));
		return out.toString();
	}

	/**
	 * The chart of the function `fn` named `name`, its statements read from `source`; null when the function has no body.
	 * Only the body is drawn: a lambda or a local function inside it is one statement of it.
	 */
	public static function build(fn: QueryNode, name: String, shape: RefShape, source: String, regions: Array<LexRegion>): Null<FlowGraph> {
		final body: Null<QueryNode> = bodyOf(fn, shape);
		return body == null ? null : new FlowBuilder(name, shape, source, regions).draw(fn, body);
	}

	private static inline function tail(node: FlowNode, label: Null<String>): FlowTail {
		return { node: node, label: label };
	}

	private static function bodyOf(fn: QueryNode, shape: RefShape): Null<QueryNode> {
		final bodies: Array<String> = shape.functionBodyKinds ?? [];
		for (c in fn.children) if (bodies.contains(c.kind)) return c.kind == shape.noBodyKind ? null : c;
		return null;
	}

	private static function runLabel(run: Array<String>): String {
		final shown: Array<String> = run.slice(0, RUN_LINES);
		if (run.length > RUN_LINES) shown.push('… +${run.length - RUN_LINES} more');
		return shown.join('\n');
	}

	/** `text` on one line, without a trailing `edge` character and the blanks around it. */
	private static function trimmed(text: String, edge: String): String {
		final line: String = WHITESPACE.replace(text, ' ').trim();
		return edge != '' && line.endsWith(edge) ? line.substr(0, line.length - edge.length).trim() : line;
	}

	private static function limit(text: String): String {
		return text.length > TEXT_WIDTH ? '${text.substr(0, TEXT_WIDTH - 1)}…' : text;
	}

}
