package anyparse.check;

import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex.MemberInfo;

using Lambda;

/**
 * The catch-all branch (`case _`, `default`) of a `switch` over an `enum abstract` whose every value an earlier case
 * names: no value reaches it. A positive whitelist on every count — the subject a member of the running type read bare
 * or off `this`, declared as the abstract itself (not `Null<…>`); the abstract with no `from` clause, and every function
 * of it that hands back the abstract (`@:from` ones included) handing back only its values, through `switch` arms,
 * `?:`, parentheses and blocks. The one hole the source cannot show is a `cast` into the abstract elsewhere, taken as
 * absent: the project's word that it builds the abstract's values only through its constants.
 */
@:nullSafety(Strict)
final class ExhaustiveSwitches {

	/** Each abstract's name -> its values, when it is closed (`closedValues`); null when not. */
	private final _values: Map<String, Null<Array<String>>> = [];

	private final _graph: CallGraph;
	private final _shape: RefShape;
	private final _nestedFnKinds: Array<String>;

	public function new(graph: CallGraph, plugin: GrammarPlugin) {
		_graph = graph;
		_shape = plugin.refShape();
		_nestedFnKinds = MemberKinds.nestedFunctionKinds(_shape);
	}

	/**
	 * Whether `branch`, a branch of the `switch` node `switchNode` in the function `fnId`, is a catch-all no value
	 * reaches: the subject is of a closed enum abstract and the cases before it name every value.
	 */
	public function dead(fnId: String, switchNode: QueryNode, branch: QueryNode): Bool {
		final kids: Array<QueryNode> = switchNode.children;
		final at: Int = kids.indexOf(branch);
		if (at < 1 || !catchAll(branch)) return false;
		final type: Null<String> = subjectType(fnId, kids[0]);
		final values: Null<Array<String>> = type == null ? null : closedValues(type);
		if (values == null) return false;
		final named: Array<String> = [];
		for (k in kids.slice(1, at)) if (k.kind == _shape.caseBranchKind) for (v in plainValues(k)) named.push(v);
		return values.foreach(v -> named.contains(v));
	}

	/** Whether `branch` matches whatever is left: a default branch, or a case whose one pattern is `_`. */
	private function catchAll(branch: QueryNode): Bool {
		if (branch.kind == _shape.defaultBranchKind) return true;
		final pattern: Null<QueryNode> = branch.kind == _shape.caseBranchKind && branch.children.length > 0 ? branch.children[0] : null;
		return pattern != null && pattern.kind == _shape.plainCasePatternKind && pattern.children.length == 1
			&& pattern.children[0].kind == _shape.identKind && pattern.children[0].name == '_';
	}

	/** The bare names the patterns of the case `branch` match, its guard-free `Plain` patterns only. */
	private function plainValues(branch: QueryNode): Array<String> {
		return [
			for (p in branch.children) if (
				p.kind == _shape.plainCasePatternKind && p.children.length == 1 && p.children[0].kind == _shape.identKind
			)
				p.children[0].name ?? ''
		];
	}

	/** The declared type of the subject `subject` in `fnId`: a member of the running type read bare or off `this`, by its written type. */
	private function subjectType(fnId: String, subject: QueryNode): Null<String> {
		final read: QueryNode = subject.kind == _shape.parenKind && subject.children.length == 1 ? subject.children[0] : subject;
		final own: Bool = read.kind == _shape.identKind || read.kind == _shape.fieldAccessKind && read.children.length == 1
			&& read.children[0].kind == _shape.identKind && read.children[0].name == _shape.selfReferenceText;
		final type: Null<String> = _graph.node(fnId)?.typeName;
		final name: Null<String> = read.name;
		if (!own || type == null || name == null) return null;
		final info: Null<MemberInfo> = _graph.types.memberOnChain(type, name);
		// a written type naming no enum abstract — `Null<T>` among them — is no closed one (`closedValues`)
		return info?.typeSource;
	}

	/** The values of the enum abstract named `type` when it is closed (see the class doc); null otherwise. */
	private function closedValues(type: String): Null<Array<String>> {
		if (_values.exists(type)) return _values[type];
		var found: Null<Array<String>> = null;
		for (held in _graph.heldFiles()) {
			final decl: Null<QueryNode> = held.tree.children.find(c -> c.kind == _shape.enumAbstractDeclKind && c.name == type);
			if (decl != null) {
				found = valuesOf(decl, type);
				break;
			}
		}
		_values[type] = found;
		return found;
	}

	/** The values the enum abstract `decl` (named `type`) declares, when nothing of it builds any other; null otherwise. */
	private function valuesOf(decl: QueryNode, type: String): Null<Array<String>> {
		final from: Null<String> = _shape.abstractFromClauseKind;
		if (from == null) return null;
		final values: Array<String> = [];
		var staticNext: Bool = false;
		for (k in decl.children) {
			if (k.kind == from) return null;
			if ((_shape.fieldDeclKinds ?? []).contains(k.kind) && !staticNext && k.name != null) values.push(k.name ?? '');
			staticNext = k.kind == _shape.staticModifierKind;
		}
		final functions: Array<String> = _shape.functionKinds ?? [];
		for (fn in decl.children) if (functions.contains(fn.kind) && returnsType(fn, type) && !handsBackValuesOnly(fn, values)) return null;
		return values.length == 0 ? null : values;
	}

	/** Whether the function `fn` declares the return type `type`. */
	private function returnsType(fn: QueryNode, type: String): Bool {
		return fn.children.exists(c -> (_shape.typeAnnotationKinds ?? []).contains(c.kind) && c.name == type);
	}

	/** Whether every `return` of the function `fn`, outside a function nested in it, hands back one of `values`. */
	private function handsBackValuesOnly(fn: QueryNode, values: Array<String>): Bool {
		final returns: Array<QueryNode> = [];
		collectReturns(fn, returns, true);
		return returns.length > 0 && returns.foreach(r -> r.children.length == 1 && valueOnly(r.children[0], values));
	}

	private function collectReturns(node: QueryNode, into: Array<QueryNode>, top: Bool): Void {
		if (!top && (_nestedFnKinds.contains(node.kind) || (_shape.functionKinds ?? []).contains(node.kind))) return;
		if ((_shape.valueReturnKinds ?? []).contains(node.kind)) into.push(node);
		for (c in node.children) collectReturns(c, into, false);
	}

	/** Whether `expr` evaluates to one of `values`: a bare value, or arms of a `switch` / `?:` / block / parentheses that do. */
	private function valueOnly(expr: QueryNode, values: Array<String>): Bool {
		final kids: Array<QueryNode> = expr.kind == _shape.exprStatementKind && expr.children.length == 1 ? expr.children : [expr];
		final e: QueryNode = kids[0];
		if (e.kind == _shape.identKind) return values.contains(e.name ?? '');
		if (e.kind == _shape.parenKind && e.children.length == 1) return valueOnly(e.children[0], values);
		if (e.kind == _shape.ternaryKind && e.children.length == 3)
			return valueOnly(e.children[1], values) && valueOnly(e.children[2], values);
		if ((_shape.switchKinds ?? []).contains(e.kind)) {
			final branches: Array<QueryNode> = [for (b in e.children.slice(1)) b];
			return branches.length > 0
				&& branches.foreach(b -> b.children.length > 0 && valueOnly(b.children[b.children.length - 1], values));
		}
		return false;
	}

}
