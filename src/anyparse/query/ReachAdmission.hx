package anyparse.query;

import anyparse.query.CallGraph.FnNode;
import anyparse.query.CallGraph.UnresolvedCall;
import anyparse.query.MemberTouchScan.Occurrence;

using Lambda;

/**
 * Which functions code a reach walk cannot follow — an unresolved call, an untyped access, library code it has
 * not read — may enter: those that can themselves reach a toucher of the member, through edges and through the
 * same channels (`MemberReach` admits at such sites).
 */
@:nullSafety(Strict)
final class ReachAdmission {

	private final _scope: ReachProject;
	private final _g: ReachGraph;

	public function new(scope: ReachProject, g: ReachGraph) {
		_scope = scope;
		_g = g;
	}

	/**
	 * The functions an unresolved site may enter, narrowed to those that can reach a toucher. `closure` is the
	 * backward closure of the touchers over invocations and function-value hand-offs AND over the channels
	 * the walk admits through: once it holds a function code the graph cannot follow may call (`value`), every
	 * function with an unresolved site and every library target whose body is not read joins it, since those
	 * can run such a function; a function with a site admitting by NAME joins once the closure holds a
	 * function of that name. `value` is the part of it such code may call — functions used as values,
	 * `dynamic` methods, lambdas, overrides of a method a LIBRARY type declares — and `constructors` the
	 * constructors in it, which reflective instantiation may run.
	 */
	public function of(g: CallGraph, touchers: Map<String, Occurrence>): Admission {
		final closure: Map<String, String> = [];
		final queue: Array<String> = [];
		final names: Map<String, Bool> = [];
		var valueReached: Bool = false;
		function add(id: String, via: String): Void {
			if (closure.exists(id)) return;
			closure[id] = via;
			queue.push(id);
		}
		for (id in touchers.keys()) add(id, id);
		var qi: Int = 0;
		while (true) {
			while (qi < queue.length) {
				final id: String = queue[qi++];
				final node: Null<FnNode> = g.node(id);
				final name: Null<String> = node?.name;
				if (name != null) names[name] = true;
				if (node != null && !valueReached && valueAdmitted(g, node)) valueReached = true;
				for (e in g.inEdges(id)) if (e.kind.isInvocation() || e.kind == Ref) add(e.from, id);
			}
			final before: Int = queue.length;
			joinThroughChannels(g, names, valueReached, add);
			if (queue.length == before) break;
		}
		final ctorName: String = _scope.shape.constructorName ?? 'new';
		final value: Array<String> = [];
		final constructors: Array<String> = [];
		for (id in closure.keys()) {
			final node: Null<FnNode> = g.node(id);
			if (node == null || node.isExternal) continue;
			if (node.name == ctorName) constructors.push(id);
			if (valueAdmitted(g, node)) value.push(id);
		}
		return { closure: closure, value: value, constructors: constructors };
	}

	/**
	 * Whether a function an admission site lets run without the walk entering it — one that reaches no toucher by an edge —
	 * may be read by its syntax rather than through its compiler facts, so may run an implicitly-called member no site of the
	 * facts names: always, unless the facts are the truth (`FactsView.truth`). Then only when the graph holds a function of the
	 * site's channels whose body is not faceted (`CallGraphFacts.faceted`) — a function value (`values`), a constructor or an
	 * initializer run (`constructors`), any function (`all`) — or library code it has not read and that may run user code
	 * (`runsUnseenCode`), for any channel.
	 */
	public function runsSyntaxRead(g: CallGraph, values: Bool, constructors: Bool, all: Bool): Bool {
		final facts: Null<CallGraphFacts> = g.facts;
		if (facts == null || !facts.view.truth) return true;
		final ctorName: String = _scope.shape.constructorName ?? 'new';
		final runs: Array<Null<String>> = [ctorName, CallGraph.INIT_NAME, CallGraph.STATIC_INIT_NAME];
		for (id => n in g.nodes) {
			// a project member with no body is a field holding a function value: what it runs is the value channel's
			if (runsUnseenCode(g, n) && !_scope.sources.exists(_scope.siteOf(n.typeName ?? '')?.file ?? '')) return true;
			if (n.isExternal || n.isBodyless || facts.faceted.exists(id)) continue;
			if (all || (values && valueAdmitted(g, n)) || (constructors && runs.contains(n.name))) return true;
		}
		return false;
	}

	/** The names the walk admits functions by at an untyped access of `member`: its accessors, and the member itself. */
	public function accessNames(member: String): Array<String> {
		final out: Array<String> = [for (p in _scope.shape.accessorMethodPrefixes ?? []) p + member];
		out.push(member);
		return out;
	}

	/**
	 * `add` every function that reaches the closure through a channel rather than an edge: one with an unresolved
	 * call once the closure holds a value-callable function (`valueReached`) or a function of a name the call
	 * admits (`names`) — and always one calling code the graph holds no node for (`Unseen`), which may touch the
	 * member itself — one with an untyped access naming such a function, — once `valueReached` — every library
	 * target whose code the graph has not read, and every extern member target code may hand a program object to,
	 * which reaches that object's members by name.
	 */
	private function joinThroughChannels(g: CallGraph, names: Map<String, Bool>, valueReached: Bool, add: (String, String) -> Void): Void {
		for (u in g.unresolved) if (valueReached || admittedNames(u).exists(n -> names.exists(n)) || u.reason.match(Unseen(_)))
			add(u.from, 'unresolved');
		for (a in g.unresolvedAccess) if (accessNames(a.member).exists(n -> names.exists(n))) add(a.from, 'unresolved access');
		if (valueReached) for (id => n in g.nodes) if (runsUnseenCode(g, n)) add(id, 'library');
		// target code handed a program object reaches its members by name, so it reaches the closure whatever it holds
		for (id => n in g.nodes) if (handedObjects(g, n)) add(id, 'extern object');
	}

	/** Whether `node` is a body-less extern member that runs target code and may be handed a program object. */
	private function handedObjects(g: CallGraph, node: FnNode): Bool {
		final type: Null<String> = node.typeName;
		final name: Null<String> = node.name;
		return type != null && name != null && node.isBodyless && g.types.meta.isExtern(type) && !_g.externQuiet(g, type, name)
			&& _g.externTakesObject(g, type, name);
	}

	/**
	 * Whether code the graph cannot follow may call `node` — a lambda, a `dynamic` method, a function used as
	 * a value, or an override of a method a library type declares (never a constructor).
	 */
	private function valueAdmitted(g: CallGraph, node: FnNode): Bool {
		if (node.isExternal) return false;
		final ctorName: String = _scope.shape.constructorName ?? 'new';
		return node.name == null || node.id.indexOf('#') >= 0 || node.isDynamic || g.inEdges(node.id).exists(e -> e.kind == Ref)
			|| (node.name != ctorName && overridesLibrary(g, node));
	}

	/**
	 * Whether `node` runs code the graph holds no body for — a library target not read yet, or a body-less extern
	 * member — and is not known to run no user code: such code may call any function value.
	 */
	private function runsUnseenCode(g: CallGraph, node: FnNode): Bool {
		final type: Null<String> = node.typeName;
		final name: Null<String> = node.name;
		if (type == null || name == null) return node.isExternal;
		if (!node.isExternal && !(node.isBodyless && g.types.meta.isExtern(type) && !_g.externQuiet(g, type, name))) return false;
		return !_g.runsNoUserCode(g, type, name, true);
	}

	/**
	 * Whether `node` overrides or implements a member a type declared OUTSIDE the project declares — library
	 * code can dispatch to it. A constructor is never such a target: no dispatch reaches a subtype's
	 * constructor, only a `new` naming it or reflective instantiation (`Admission.constructors`).
	 */
	private function overridesLibrary(g: CallGraph, node: FnNode): Bool {
		final name: Null<String> = node.name;
		final type: Null<String> = node.typeName;
		if (name == null || type == null) return false;
		for (s in g.types.supertypesOf(type)) {
			final owner: Null<String> = g.types.declaringTypeOf(s, name);
			if (owner != null && !_scope.sources.exists(_scope.siteOf(owner)?.file ?? '')) return true;
		}
		return false;
	}

	/** The names the walk admits functions by at the unresolved call `u`. */
	public static function admittedNames(u: UnresolvedCall): Array<String> {
		return switch u.reason {
			case DynamicReceiver(m), UnresolvedReceiver(m), UnboundName(m): [m];
			case FunctionValue(_), ComplexCallee(_), Unseen(_): [];
		};
	}

}

/** The functions an admission site may enter: the closure over touchers, its value-callable part, its constructors. */
typedef Admission = {
	var closure: Map<String, String>;
	var value: Array<String>;
	var constructors: Array<String>;
}
