package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.Refs.RefHit;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/**
 * One function-like unit in the graph: a method, a module-level function, a
 * local function, a lambda, or an EXTERNAL member (a call target outside the
 * scanned scope — `Sys.sleep`, an openfl method — that has no body here).
 * External nodes carry a null `span` and an empty `file`.
 */
typedef FnNode = {
	var id: String;
	var file: String;
	var typeName: Null<String>;
	var name: Null<String>;
	var span: Null<Span>;
	var isExternal: Bool;
}

/**
 * One directed edge. `via` is set on `Ref` edges only: the id of the call
 * TARGET that received the callback (`Worker.spawn` for a lambda passed
 * to it) — the seam a thread-context analysis needs to classify callback
 * execution contexts. `span` is the call / reference site in `file`.
 */
typedef CallEdge = {
	var from: String;
	var to: String;
	var kind: EdgeKind;
	var via: Null<String>;
	var file: String;
	var span: Null<Span>;
}

/**
 * A call whose target could not be resolved even approximately — an indirect
 * call through a function-valued local, a complex receiver expression, or an
 * unbound bare name. Kept per-site so consumers can report honest coverage.
 */
typedef UnresolvedCall = {
	var file: String;
	var span: Null<Span>;
	var reason: String;
}

/**
 * Edge classification. `Call` / `New` are direct invocations; `Virtual` is an
 * over-approximated dispatch to a subtype override; `Ref` is a function VALUE
 * reference (callback registration, `.bind`, lambda argument) — invoked later
 * by whoever received it; `Contains` links an enclosing function to a lambda /
 * local function declared inside it (lexical containment, not execution).
 */
enum abstract EdgeKind(Int) {

	final Call = 0;
	final Ref = 1;
	final New = 2;
	final Virtual = 3;
	final Contains = 4;

	public function label(): String {
		return switch (cast this: EdgeKind) {
			case Call: 'call';
			case Ref: 'ref';
			case New: 'new';
			case Virtual: 'virtual';
			case Contains: 'contains';
		};
	}

}

/**
 * Project-wide approximate call graph over the `QueryNode` projection — the
 * shared core of the `callees` / `callers` / `reach` subcommands and the
 * `thread-safety` check.
 *
 * Resolution is name-based (no typer): bare calls resolve through the `Refs`
 * scope resolver to same-file methods and local functions; `this.m()` and
 * inherited bare calls resolve through the member table + `SymbolIndex`
 * supertypes; `obj.m()` resolves when the receiver identifier carries an
 * explicit nominal type annotation (`TypeInfoProvider.declaredTypes`), with
 * `Null<T>` unwrapped to `T` via `declaredTypeSources`; `Type.m()` resolves as
 * a static member. Instance calls additionally emit `Virtual` edges to subtype
 * overrides. Everything unresolvable is recorded in `unresolved` — the graph
 * over-approximates but never silently drops a call it could name.
 *
 * Simple type names only (`SymbolIndex` models no packages): two types with
 * the same simple name merge into one graph node — acceptable for a finder,
 * listed as a known limit.
 */
@:nullSafety(Strict)
final class CallGraph {

	/**
	 * Type-decl kinds `RefactorSupport.typeDeclOf` does not cover: `abstract
	 * class` and `enum abstract` project as their own kinds with the name
	 * directly on the node. Without these the walks lose the enclosing type
	 * inside such bodies (members mis-registered under the module pseudo-type).
	 */
	private static final EXTRA_TYPE_DECL_KINDS: Array<String> = ['AbstractClassDecl', 'EnumAbstractDecl'];

	public final nodes: Map<String, FnNode> = [];
	public final edges: Array<CallEdge> = [];
	public final unresolved: Array<UnresolvedCall> = [];

	public final skippedFiles: Array<String> = [];
	private final _out: Map<String, Array<CallEdge>> = [];
	private final _in: Map<String, Array<CallEdge>> = [];
	private final _byMember: Map<String, Array<String>> = [];
	private final _members: Map<String, Map<String, String>> = [];
	private final _supers: Map<String, Array<String>> = [];

	private final _subs: Map<String, Array<String>> = [];

	private function new() {}

	public inline function node(id: String): Null<FnNode> {
		return nodes[id];
	}

	public function outEdges(id: String): Array<CallEdge> {
		return _out[id] ?? [];
	}

	public function inEdges(id: String): Array<CallEdge> {
		return _in[id] ?? [];
	}

	/**
	 * Resolve a user-facing target query to nodes: `Type.method` (a qualified
	 * config entry `pkg.Type.method` matches by its last two segments), or a
	 * bare `method` name (every type's member with that name). More than one
	 * result means the query is ambiguous — the caller decides how to present
	 * the candidates.
	 */
	public function resolveTarget(query: String): Array<FnNode> {
		final simple: String = lastSegments(query, 2);
		final direct: Null<FnNode> = nodes[simple];
		if (direct != null) return [direct];
		if (simple.indexOf('.') != -1) return [];
		final ids: Array<String> = _byMember[simple] ?? [];
		return [
			for (id in ids) {
				final n: Null<FnNode> = nodes[id];
				if (n != null) n;
			}
		];
	}

	/**
	 * All node ids matching a config pattern: `pkg.Type.method` (last two
	 * segments), `Type.*` (every recorded member of `Type`, external nodes
	 * included), or a bare `method`. Missing types / members yield [].
	 */
	public function matchIds(pattern: String): Array<String> {
		if (StringTools.endsWith(pattern, '.*')) {
			final typeName: String = lastSegments(pattern.substring(0, pattern.length - 2), 1);
			return [for (id => n in nodes) if (n.typeName == typeName && n.name != null) id];
		}
		return [for (n in resolveTarget(pattern)) n.id];
	}

	private function collectNodes(entry: ParsedEntry, shape: RefShape): Void {
		final fnKinds: Array<String> = shape.functionKinds ?? [];
		final lambdaKinds: Array<String> = shape.lambdaKinds ?? [];
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final macroKind: Null<String> = shape.macroModifierKind;
		final moduleType: String = moduleTypeName(entry.file);
		var lambdaCounter: Int = 0;

		function walk(node: QueryNode, currentType: Null<String>, parentFn: Null<String>): Void {
			// a macro-reification subtree is generated-code emission, not runtime
			// calls — walking it would fabricate nodes and edges (mirrors Refs)
			if (opaqueKinds.contains(node.kind)) return;
			var typeName: Null<String> = currentType;
			final declName: Null<String> = typeNameOf(node);
			if (declName != null) typeName = declName;

			var fnId: Null<String> = parentFn;
			final span: Null<Span> = node.span;
			final name: Null<String> = node.name;
			if (span != null && name != null && fnKinds.contains(node.kind)) {
				final owner: String = typeName ?? moduleType;
				fnId = parentFn == null ? '$owner.$name' : '$parentFn#$name';
				registerNode(fnId, entry, parentFn == null ? owner : typeName, name, span);
				if (parentFn == null) registerMember(owner, name, fnId);
			} else if (span != null && lambdaKinds.contains(node.kind)) {
				lambdaCounter++;
				fnId = '${parentFn ?? (typeName ?? moduleType)}#$lambdaCounter';
				registerNode(fnId, entry, typeName, null, span);
			}
			var macroPending: Bool = false;
			for (c in node.children) {
				if (macroKind != null && c.kind == macroKind) {
					macroPending = true;
					continue;
				}
				if (macroPending && fnKinds.contains(c.kind)) {
					// `macro` function body — compile-time code, not runtime calls
					macroPending = false;
					continue;
				}
				if (c.children.length > 0 || c.name != null) macroPending = false;
				walk(c, typeName, fnId);
			}
		}
		walk(entry.tree, null, null);
	}

	private function registerNode(id: String, entry: ParsedEntry, typeName: Null<String>, name: Null<String>, span: Span): Void {
		if (!nodes.exists(id)) nodes[id] = {
			id: id,
			file: entry.file,
			typeName: typeName,
			name: name,
			span: span,
			isExternal: false
		};
		entry.fnBySpanFrom[span.from] = id;
		if (name != null) {
			final ids: Array<String> = _byMember[name] ?? [];
			if (!ids.contains(id)) ids.push(id);
			_byMember[name] = ids;
		}
	}

	private function registerMember(typeName: String, member: String, id: String): Void {
		final table: Map<String, String> = _members[typeName] ?? [];
		if (!table.exists(member)) table[member] = id;
		_members[typeName] = table;
	}

	private function externalNode(typeName: String, member: String): String {
		final id: String = '$typeName.$member';
		if (!nodes.exists(id)) nodes[id] = {
			id: id,
			file: '',
			typeName: typeName,
			name: member,
			span: null,
			isExternal: true
		};
		return id;
	}

	/** Pseudo-node holding calls made from field initializers of `typeName`. */
	private function initNode(typeName: String, file: String): String {
		final id: String = '$typeName.<init>';
		if (!nodes.exists(id)) nodes[id] = {
			id: id,
			file: file,
			typeName: typeName,
			name: '<init>',
			span: null,
			isExternal: false
		};
		return id;
	}

	private function addEdge(from: String, to: String, kind: EdgeKind, via: Null<String>, file: String, span: Null<Span>): Void {
		final edge: CallEdge = {
			from: from,
			to: to,
			kind: kind,
			via: via,
			file: file,
			span: span
		};
		edges.push(edge);
		final out: Array<CallEdge> = _out[from] ?? [];
		out.push(edge);
		_out[from] = out;
		final into: Array<CallEdge> = _in[to] ?? [];
		into.push(edge);
		_in[to] = into;
	}

	/** Member lookup on `typeName` walking the supertype chain (BFS, cycle-safe). */
	private function memberOnChain(typeName: String, member: String): Null<String> {
		final queue: Array<String> = [typeName];
		final visited: Array<String> = [];
		var qi: Int = 0;
		while (qi < queue.length) {
			final t: String = queue[qi++];
			if (visited.contains(t)) continue;
			visited.push(t);
			final table: Null<Map<String, String>> = _members[t];
			final hit: Null<String> = table == null ? null : table[member];
			if (hit != null) return hit;
			for (s in _supers[t] ?? []) queue.push(s);
		}
		return null;
	}

	/** Transitive subtypes of `typeName` that declare `member` — virtual dispatch targets. */
	private function virtualTargets(typeName: String, member: String): Array<String> {
		final result: Array<String> = [];
		final queue: Array<String> = [typeName];
		final visited: Array<String> = [];
		var qi: Int = 0;
		while (qi < queue.length) {
			final t: String = queue[qi++];
			if (visited.contains(t)) continue;
			visited.push(t);
			for (sub in _subs[t] ?? []) {
				queue.push(sub);
				final table: Null<Map<String, String>> = _members[sub];
				final hit: Null<String> = table == null ? null : table[member];
				if (hit != null && !result.contains(hit)) result.push(hit);
			}
		}
		return result;
	}

	private function collectEdges(entry: ParsedEntry, shape: RefShape, provider: Null<TypeInfoProvider>): Void {
		final callKind: Null<String> = shape.callKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (callKind == null || fieldAccessKind == null) return;
		final identKind: String = shape.identKind;
		final selfText: Null<String> = shape.selfReferenceText;
		final safeAccessKind: Null<String> = shape.nullSafeAccessKind;
		final forceAccessKind: Null<String> = shape.forceFieldAccessKind;
		final newExprKind: Null<String> = shape.newExprKind;
		final parenKind: Null<String> = shape.parenKind;
		final ternaryKind: Null<String> = shape.ternaryKind;
		final macroKind: Null<String> = shape.macroModifierKind;
		final fnKinds: Array<String> = shape.functionKinds ?? [];
		final lambdaKinds: Array<String> = shape.lambdaKinds ?? [];
		final localFnKinds: Array<String> = shape.localFunctionKinds ?? [];
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final nullableWrappers: Array<String> = shape.nullableWrapperTypeNames ?? [];
		final tree: QueryNode = entry.tree;
		final file: String = entry.file;
		final source: String = entry.source;
		final moduleType: String = moduleTypeName(file);
		final declaredTypes: Map<Int, String> = provider == null ? [] : provider.declaredTypes(source);
		final typeSources: Map<Int, String> = provider == null ? [] : provider.declaredTypeSources(source);
		final bindCache: Map<String, Map<Int, Int>> = [];
		final consumedBindCalls: Array<Int> = [];
		final frames: Array<Frame> = [];

		// one Refs pass for EVERY identifier name in the file — per-name find()
		// walks made the graph build quadratic on large files
		final identNames: Array<String> = [];
		function scanIdents(node: QueryNode): Void {
			final name: Null<String> = node.name;
			if (node.kind == identKind && name != null) identNames.push(name);
			for (c in node.children) scanIdents(c);
		}
		scanIdents(tree);
		final multiHits: Map<String, Array<RefHit>> = Refs.findMulti(identNames, tree, shape);

		function bindFor(name: String): Map<Int, Int> {
			final hit: Null<Map<Int, Int>> = bindCache[name];
			if (hit != null) return hit;
			final map: Map<Int, Int> = [];
			for (h in multiHits[name] ?? []) {
				final b: Null<Span> = h.bindingSpan;
				map[h.span.from] = b == null ? -1 : b.from;
			}
			bindCache[name] = map;
			return map;
		}

		function frameId(currentType: Null<String>): String {
			return frames.length > 0 ? frames[frames.length - 1].id : initNode(currentType ?? moduleType, file);
		}

		function localFn(name: String): Null<String> {
			var i: Int = frames.length - 1;
			while (i >= 0) {
				final hit: Null<String> = frames[i].localFns[name];
				if (hit != null) return hit;
				i--;
			}
			return null;
		}

		function unwrap(node: QueryNode): QueryNode {
			return parenKind != null && node.kind == parenKind && node.children.length == 1 ? unwrap(node.children[0]) : node;
		}

		/** Declared simple type of a value identifier, `Null<T>` unwrapped to `T`. */
		function identDeclaredType(name: String, span: Span): Null<String> {
			final bindingFrom: Null<Int> = bindFor(name)[span.from];
			if (bindingFrom == null || bindingFrom < 0) return null;
			final typeName: Null<String> = declaredTypes[bindingFrom];
			return typeName == null
				? null
				: typeName == 'Null' ? unwrapNullable(typeSources[bindingFrom]) : nullableWrappers.contains(typeName) ? null : typeName;
		}

		/**
		 * Receiver classification: the simple type name plus whether the
		 * receiver is a VALUE (instance dispatch — virtual expansion applies)
		 * or a TYPE (static dispatch). Null when unrecoverable.
		 */
		function receiverType(recvRaw: QueryNode, currentType: Null<String>): Null<Receiver> {
			final recv: QueryNode = unwrap(recvRaw);
			final name: Null<String> = recv.name;
			if (recv.kind == identKind && name != null) {
				final span: Null<Span> = recv.span;
				if (name == selfText) return currentType == null ? null : { typeName: currentType, isValue: true };
				if (name == 'super') {
					final supers: Array<String> = currentType == null ? [] : (_supers[currentType] ?? []);
					return supers.length > 0 ? { typeName: supers[0], isValue: false } : null;
				}
				if (span != null) {
					final declared: Null<String> = identDeclaredType(name, span);
					if (declared != null) return { typeName: declared, isValue: true };
					final bound: Null<Int> = bindFor(name)[span.from];
					if ((bound == null || bound < 0) && isTypeLike(name)) return { typeName: name, isValue: false };
				}
				return null;
			}
			if (
				(recv.kind == fieldAccessKind || (safeAccessKind != null && recv.kind == safeAccessKind)) && name != null
				&& isTypeLike(name)
			)
				return { typeName: name, isValue: false };
			return null;
		}

		/** Resolve a method referenced as a VALUE (`handler`, `this.m`, `obj.m`) to an internal node. */
		function methodValue(argRaw: QueryNode, currentType: Null<String>): Null<String> {
			final arg: QueryNode = unwrap(argRaw);
			final name: Null<String> = arg.name;
			if (name == null) return null;
			if (arg.kind == identKind) {
				final span: Null<Span> = arg.span;
				if (span == null) return null;
				final local: Null<String> = localFn(name);
				if (local != null) return local;
				final bound: Null<Int> = bindFor(name)[span.from];
				if (bound != null && bound >= 0) return entry.fnBySpanFrom[bound];
				return currentType == null ? null : memberOnChain(currentType, name);
			}
			if (arg.kind == fieldAccessKind && arg.children.length > 0) {
				final recv: Null<Receiver> = receiverType(arg.children[0], currentType);
				return recv == null ? null : memberOnChain(recv.typeName, name);
			}
			return null;
		}

		function resolveBareCallee(name: String, span: Null<Span>, currentType: Null<String>): Null<String> {
			if (name == 'super') {
				final supers: Array<String> = currentType == null ? [] : (_supers[currentType] ?? []);
				return supers.length == 0 ? null : memberOnChain(supers[0], 'new') ?? externalNode(supers[0], 'new');
			}
			final local: Null<String> = localFn(name);
			if (local != null) return local;
			if (span != null) {
				final bound: Null<Int> = bindFor(name)[span.from];
				if (bound != null && bound >= 0) {
					final fn: Null<String> = entry.fnBySpanFrom[bound];
					if (fn != null) return fn;
					unresolved.push({ file: file, span: span, reason: 'indirect call through value "$name"' });
					return null;
				}
			}
			final inherited: Null<String> = memberOnChain(currentType ?? moduleType, name);
			if (inherited != null) return inherited;
			// a module-level function is registered under the module pseudo-type,
			// which the enclosing-type chain does not reach from inside a class
			if (currentType != null) {
				final moduleFn: Null<String> = memberOnChain(moduleType, name);
				if (moduleFn != null) return moduleFn;
			}
			// a bare capitalized call is almost always an enum constructor — not
			// a function target; recording each would flood the unresolved list
			if (!isTypeLike(name)) unresolved.push({ file: file, span: span, reason: 'unresolved bare call "$name"' });
			return null;
		}

		function scanArgs(call: QueryNode, calleeId: Null<String>, currentType: Null<String>): Void {
			final from: String = frameId(currentType);
			function refArg(argRaw: QueryNode): Void {
				final arg: QueryNode = unwrap(argRaw);
				// a ternary-valued argument hands BOTH branch function-values to
				// the callee — each branch is a callback in its own right
				if (ternaryKind != null && arg.kind == ternaryKind && arg.children.length == 3) {
					refArg(arg.children[1]);
					refArg(arg.children[2]);
					return;
				}
				final argSpan: Null<Span> = arg.span;
				if (argSpan != null && lambdaKinds.contains(arg.kind)) {
					final lambdaId: Null<String> = entry.fnBySpanFrom[argSpan.from];
					if (lambdaId != null) addEdge(from, lambdaId, Ref, calleeId, file, argSpan);
					return;
				}
				if (arg.kind == callKind && arg.children.length > 0) {
					final inner: QueryNode = unwrap(arg.children[0]);
					if (inner.kind == fieldAccessKind && inner.name == 'bind' && inner.children.length > 0) {
						final target: Null<String> = methodValue(inner.children[0], currentType);
						if (target != null && argSpan != null) {
							addEdge(from, target, Ref, calleeId, file, argSpan);
							consumedBindCalls.push(argSpan.from);
						}
					}
					return;
				}
				if (arg.kind == identKind || arg.kind == fieldAccessKind) {
					final target: Null<String> = methodValue(arg, currentType);
					final node: Null<FnNode> = target == null ? null : nodes[target];
					if (target != null && node != null && !node.isExternal) addEdge(from, target, Ref, calleeId, file, argSpan);
				}
			}
			for (i in 1...call.children.length) refArg(call.children[i]);
		}

		function handleCall(call: QueryNode, currentType: Null<String>): Void {
			final from: String = frameId(currentType);
			final span: Null<Span> = call.span;
			final callee: QueryNode = unwrap(call.children[0]);
			final calleeName: Null<String> = callee.name;
			var calleeId: Null<String> = null;
			if (callee.kind == identKind && calleeName != null) {
				calleeId = resolveBareCallee(calleeName, callee.span, currentType);
				if (calleeId != null) addEdge(from, calleeId, Call, null, file, span);
			} else if (
				callee.kind == fieldAccessKind || (safeAccessKind != null && callee.kind == safeAccessKind)
				|| (forceAccessKind != null && callee.kind == forceAccessKind)
			) {
				if (calleeName != null && callee.children.length > 0) {
					if (calleeName == 'bind') {
						final callSpan: Null<Span> = call.span;
						if (callSpan == null || !consumedBindCalls.contains(callSpan.from)) {
							final target: Null<String> = methodValue(callee.children[0], currentType);
							if (target != null) addEdge(from, target, Ref, null, file, span);
						}
					} else {
						final recv: Null<Receiver> = receiverType(callee.children[0], currentType);
						if (recv == null) {
							unresolved.push({ file: file, span: span, reason: 'unresolved receiver for ".$calleeName(...)"' });
						} else {
							final resolved: Null<String> = memberOnChain(recv.typeName, calleeName);
							calleeId = resolved ?? externalNode(recv.typeName, calleeName);
							addEdge(from, calleeId, Call, null, file, span);
							if (recv.isValue) for (v in virtualTargets(recv.typeName, calleeName))
								addEdge(from, v, Virtual, null, file, span);
						}
					}
				} else {
					unresolved.push({ file: file, span: span, reason: 'unresolved field-access callee' });
				}
			} else if (callee.kind == callKind || (newExprKind != null && callee.kind == newExprKind)) {
				unresolved.push({ file: file, span: span, reason: 'indirect call through expression result' });
			} else {
				unresolved.push({ file: file, span: span, reason: 'unresolved callee (${callee.kind})' });
			}
			scanArgs(call, calleeId, currentType);
		}

		function handleNew(node: QueryNode, currentType: Null<String>): Void {
			final from: String = frameId(currentType);
			final rawName: Null<String> = node.name;
			if (rawName == null) return;
			final typeName: String = lastSegments(rawName, 1);
			final ctor: Null<String> = memberOnChain(typeName, 'new');
			final target: String = ctor ?? externalNode(typeName, 'new');
			addEdge(from, target, New, null, file, node.span);
			// constructor args can carry callbacks / lambdas too
			final pseudo: QueryNode = node;
			for (i in 0...pseudo.children.length) {
				final arg: QueryNode = unwrap(pseudo.children[i]);
				final argSpan: Null<Span> = arg.span;
				if (argSpan != null && lambdaKinds.contains(arg.kind)) {
					final lambdaId: Null<String> = entry.fnBySpanFrom[argSpan.from];
					if (lambdaId != null) addEdge(from, lambdaId, Ref, target, file, argSpan);
				} else if (arg.kind == identKind || arg.kind == fieldAccessKind) {
					final mv: Null<String> = methodValue(arg, currentType);
					final mvNode: Null<FnNode> = mv == null ? null : nodes[mv];
					if (mv != null && mvNode != null && !mvNode.isExternal) addEdge(from, mv, Ref, target, file, argSpan);
				}
			}
		}

		function walk(node: QueryNode, currentType: Null<String>): Void {
			// symmetric with collectNodes: reified code is not runtime calls
			if (opaqueKinds.contains(node.kind)) return;
			var typeName: Null<String> = currentType;
			final declName: Null<String> = typeNameOf(node);
			if (declName != null) typeName = declName;

			final span: Null<Span> = node.span;
			var pushed: Bool = false;
			if (span != null && (fnKinds.contains(node.kind) || lambdaKinds.contains(node.kind))) {
				final id: Null<String> = entry.fnBySpanFrom[span.from];
				if (id != null) {
					final ownId: String = id;
					final name: Null<String> = node.name;
					if (name != null && localFnKinds.contains(node.kind) && frames.length > 0)
						frames[frames.length - 1].localFns[name] = ownId;
					if (frames.length > 0)
						addEdge(frames[frames.length - 1].id, ownId, Contains, null, file, span);
					else if (lambdaKinds.contains(node.kind))
						// a member-initializer lambda (`final onTick = () -> ...`) has no
						// enclosing frame — anchor it to the type's <init> pseudo-node so
						// reach/callers can still traverse into its body
						addEdge(initNode(typeName ?? moduleType, file), ownId, Contains, null, file, span);
					frames.push({ id: ownId, localFns: [] });
					pushed = true;
				}
			}

			if (node.kind == callKind && node.children.length > 0)
				handleCall(node, typeName);
			else if (newExprKind != null && node.kind == newExprKind)
				handleNew(node, typeName);

			var macroPending: Bool = false;
			for (c in node.children) {
				if (macroKind != null && c.kind == macroKind) {
					macroPending = true;
					continue;
				}
				if (macroPending && fnKinds.contains(c.kind)) {
					// `macro` function body — compile-time code, not runtime calls
					macroPending = false;
					continue;
				}
				if (c.children.length > 0 || c.name != null) macroPending = false;
				walk(c, typeName);
			}
			if (pushed) frames.pop();
		}
		walk(tree, null);
	}

	/**
	 * Build the graph over `files`. The plugin is wrapped in a
	 * `CachingGrammarPlugin` unless it already is one, so each file parses
	 * once; a prebuilt `SymbolIndex` is reused when supplied. A grammar
	 * without call/ident/field-access shape seams yields an empty graph.
	 */
	public static function build(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, ?index: SymbolIndex): CallGraph {
		final graph: CallGraph = new CallGraph();
		final cached: GrammarPlugin = (plugin is CachingGrammarPlugin) ? plugin : new CachingGrammarPlugin(plugin);
		final shape: RefShape = cached.refShape();
		if (shape.callKind == null || shape.fieldAccessKind == null) return graph;

		final idx: SymbolIndex = index ?? SymbolIndex.build(files, cached);
		for (fi in idx.allFiles()) for (t in fi.types) {
			graph._supers[t.name] = t.supertypes;
			for (s in t.supertypes) {
				final subs: Array<String> = graph._subs[s] ?? [];
				if (!subs.contains(t.name)) subs.push(t.name);
				graph._subs[s] = subs;
			}
		}

		final provider: Null<TypeInfoProvider> = (cached is TypeInfoProvider) ? cast cached : null;
		final parsed: Array<ParsedEntry> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try cached.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree == null) {
				graph.skippedFiles.push(entry.file);
				continue;
			}
			final parsedTree: QueryNode = tree;
			parsed.push({
				file: entry.file,
				source: entry.source,
				tree: parsedTree,
				fnBySpanFrom: []
			});
		}
		for (p in parsed) graph.collectNodes(p, shape);
		for (p in parsed) graph.collectEdges(p, shape, provider);
		return graph;
	}

	/** `a.b.C.m` → last `count` dot-segments joined (`C.m` for count 2). */
	private static function lastSegments(path: String, count: Int): String {
		final parts: Array<String> = path.split('.');
		return parts.length <= count ? path : parts.slice(parts.length - count).join('.');
	}

	private static function isTypeLike(name: String): Bool {
		final c: Int = StringTools.fastCodeAt(name, 0);
		return c >= 'A'.code && c <= 'Z'.code;
	}

	/** Inner simple name of a `Null<...>` annotation source, or null. */
	private static function unwrapNullable(typeSource: Null<String>): Null<String> {
		if (typeSource == null) return null;
		final trimmed: String = StringTools.trim(typeSource);
		final prefix: String = 'Null<';
		if (!StringTools.startsWith(trimmed, prefix) || !StringTools.endsWith(trimmed, '>')) return null;
		var inner: String = StringTools.trim(trimmed.substring(prefix.length, trimmed.length - 1));
		final lt: Int = inner.indexOf('<');
		if (lt != -1) inner = inner.substring(0, lt);
		final dot: Int = inner.lastIndexOf('.');
		if (dot != -1) inner = inner.substring(dot + 1);
		inner = StringTools.trim(inner);
		return inner.length > 0 && isTypeLike(inner) ? inner : null;
	}

	private static function moduleTypeName(file: String): String {
		var base: String = file;
		final slash: Int = base.lastIndexOf('/');
		if (slash != -1) base = base.substring(slash + 1);
		final backslash: Int = base.lastIndexOf('\\');
		if (backslash != -1) base = base.substring(backslash + 1);
		final dot: Int = base.indexOf('.');
		return dot == -1 ? base : base.substring(0, dot);
	}

	/** Simple name of the type declaration `node` introduces, or null. */
	private static function typeNameOf(node: QueryNode): Null<String> {
		final td: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
		if (td != null) return td.name;
		final name: Null<String> = node.name;
		return name != null && EXTRA_TYPE_DECL_KINDS.contains(node.kind) ? name : null;
	}

}

private typedef ParsedEntry = {
	var file: String;
	var source: String;
	var tree: QueryNode;
	var fnBySpanFrom: Map<Int, String>;
}

private typedef Frame = {
	var id: String;
	var localFns: Map<String, String>;
}

private typedef Receiver = {
	var typeName: String;
	var isValue: Bool;
}
