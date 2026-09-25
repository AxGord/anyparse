package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.MemberReach.ReachAccess;
import anyparse.query.MemberReach.ReachStep;
import anyparse.query.MemberReach.ReachUnknown;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.query.ValueCarriers.CarryRelation;
import anyparse.runtime.Span;

using Lambda;

/**
 * The toucher half of `MemberReach`: every access of a member BY BINDING across the project files a
 * call graph holds, what each access does for a `ReachAccess` question (a touch, an escape of the
 * member's value, or a harmless read), and whether a LOCAL's value ever escapes before a region ends.
 */
@:nullSafety(Strict)
final class MemberTouchScan {

	private final _scope: ReachProject;
	private final _hazards: ReachHazards;

	/** Whether code at a span of a file may run in some configured build (`ReachLiveness.live`): what may not touches nothing. */
	private final _live: (String, Span) -> Bool;

	/** Whether a receiver's value may carry the member (`ValueCarriers.relation`). */
	private final _carriers: ValueCarriers;

	public function new(scope: ReachProject, hazards: ReachHazards, carriers: ValueCarriers, live: (String, Span) -> Bool) {
		_carriers = carriers;
		_live = live;
		_scope = scope;
		_hazards = hazards;
	}

	/**
	 * Every access of `name` that binds to the member `declaring` declares, over the project files the
	 * graph holds: the functions that TOUCH it for `access`, the sites where its value escapes, and the
	 * touch (if any) inside `region` of `regionFile` itself. Any project file that did not
	 * parse, and a raw conditional region spelling the name, is recorded as a blind spot.
	 */
	public function scan(
		g: CallGraph, name: String, declaring: String, access: ReachAccess, arrayTyped: Bool, regionFile: String, region: Null<Span>
	): MemberTouches {
		final out: MemberTouches = {
			touchers: [],
			notOnSelf: [],
			escapes: [],
			hidden: null,
			inRegion: null
		};
		// a project file that did not parse may declare an override, a subclass, a function value — any code a dispatch
		// or an admission can enter — without spelling the member at all: its mere presence is a blind spot
		for (file in g.skippedFiles) if (_scope.sources.exists(file)) {
			out.hidden = SkipParse(file);
			break;
		}
		for (f in _scope.files) {
			final tree: Null<QueryNode> = g.treeOf(f.file);
			if (tree == null || !RawSourceScan.mentionsWord(f.source, name)) continue;
			final opaque: Null<Span> = CondRegionScan.opaqueCondRegionMentioning(tree, f.source, name, _scope.shape);
			// a raw region no configured build compiles hides nothing
			final hides: Bool = opaque != null && _live(f.file, opaque);
			if (opaque != null && hides && out.hidden == null) out.hidden = OpaqueCond(f.file, opaque);
			scanFile(g, f.file, f.source, tree, name, declaring, access, arrayTyped, out, f.file == regionFile ? region : null);
		}
		// a field initializer that is not freshly built shares its value from the start
		if (access == Mutate) {
			final site: Null<{ file: String, span: Span }> = sharedInitializer(g, declaring, name);
			if (site != null) out.escapes.push({ file: site.file, span: site.span });
		}
		return out;
	}

	/**
	 * The first site at which the local `name` stops being provably unshared before the region can run for the
	 * last time, or null when it never does. The scan runs to the end of `region` — or, when a loop of `fn`
	 * encloses it and so re-runs it, to the end of the OUTERMOST such loop: an escape later in one iteration
	 * precedes the region in the next. A declaration that is not a local, or whose initializer is not freshly
	 * built, escapes at once.
	 */
	public function localEscape(
		tree: QueryNode, source: String, fn: QueryNode, declaration: QueryNode, name: String, region: Span
	): Null<Span> {
		final shape: RefShape = _scope.shape;
		final declSpan: Null<Span> = declaration.span;
		if (declSpan == null) return fn.span ?? region;
		if (!(shape.localDeclKinds ?? []).contains(declaration.kind)) return declSpan;
		final init: Null<QueryNode> = CtorFieldFold.declInitializer(declaration, shape);
		if (init == null || !isFresh(init, { tree: tree, source: source })) return init?.span ?? declSpan;
		final closures: Array<String> = (shape.lambdaKinds ?? []).concat(shape.localFunctionKinds ?? []);
		final end: Int = rerunEnd(fn, region);
		var found: Null<Span> = null;
		final declFrom: Int = declSpan.from;
		function walk(
			node: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>, index: Int, parentIndex: Int, inClosure: Bool
		): Void {
			final at: Null<Span> = node.span;
			if (found != null || at == null) return;
			final span: Span = at;
			if (span.from >= end) return;
			final closure: Bool = inClosure || closures.contains(node.kind);
			if (node.kind == shape.identKind && node.name == name && span.from > declFrom) {
				final verdict: Verdict = classify(node, parent, grand, index, parentIndex, Mutate, true);
				if (closure || verdict.escape) found = span;
			}
			for (i in 0...node.children.length) walk(node.children[i], node, parent, i, index, closure);
		}
		walk(fn, null, null, 0, 0, false);
		return found;
	}

	/** Where code that can run before `region` runs again ends: `region.to`, or the end of the outermost loop of `fn` enclosing it. */
	public function rerunEnd(fn: QueryNode, region: Span): Int {
		final loops: Array<String> = (_scope.shape.loopStatementKinds ?? []).concat(_scope.shape.doWhileLoopKinds ?? []);
		var end: Int = region.to;
		function walk(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			if (span == null || span.from > region.from || span.to < region.to) return;
			if (loops.contains(node.kind) && (span.from < region.from || span.to > region.to) && span.to > end) end = span.to;
			for (c in node.children) walk(c);
		}
		walk(fn);
		return end;
	}

	/**
	 * Whether `value` builds a fresh object nothing else holds: an array literal or comprehension, `null`, `new`
	 * of an array type, or — with `ctx` to type the receiver — a call of a method the receiver's built-in array
	 * or string type declares as returning a new object (`xs.copy()`, `'a,b'.split(',')`, `freshResult`).
	 */
	public function isFresh(raw: QueryNode, ctx: Null<FreshContext>): Bool {
		final value: QueryNode = BoolExprShape.unwrapParens(raw, _scope.shape.parenKind);
		if (value.kind == _scope.shape.arrayLiteralKind || value.kind == _scope.shape.nullLiteralKind) return true;
		if (value.kind == _scope.shape.newExprKind) return (_scope.shape.arrayTypeNames ?? []).contains(lastSegment(value.name ?? ''));
		return ctx != null && freshResult(value, ctx);
	}

	private function scanFile(
		g: CallGraph, file: String, source: String, tree: QueryNode, name: String, declaring: String, access: ReachAccess,
		arrayTyped: Bool, out: MemberTouches, region: Null<Span>
	): Void {
		// noqa: complexity
		final shape: RefShape = _scope.shape;
		final identKind: String = shape.identKind;
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final bindings: Map<Int, Int> = [];
		for (h in Refs.findMulti([name], tree, shape)[name] ?? []) bindings[h.span.from] = h.bindingSpan?.from ?? -1;
		final provider: Null<TypeInfoProvider> = _scope.plugin is TypeInfoProvider ? cast _scope.plugin : null;
		var declaredTypes: Null<Map<Int, String>> = null;
		final stringFold: Null<StringFoldSupport> = _scope.plugin.stringFoldSupport();

		function receiverOwns(receiver: QueryNode): Bool {
			// a receiver naming a TYPE (`Store.items`) reaches that type's static member, not an instance one
			if (TypeResolver.receiverRootIsUnboundType(receiver, tree, shape)) {
				final path: String = RefactorSupport.flattenPath(receiver);
				final typeName: String = path.substring(path.lastIndexOf('.') + 1);
				if (g.types.declarationCount(typeName) > 0) return g.types.declaringTypeOf(typeName, name) == declaring;
			}
			// the compiler's type of the receiver, where its facts replace the syntax of the code holding it
			final at: Null<Span> = receiver.span;
			final typed: Null<String> = at == null ? null : g.facts?.view.typeSourceAt(g, file, at);
			if (typed != null)
				return _carriers.relation(
					NominalTypes.unwrapNullable(typed, shape.memberTransparentWrapperTypeNames ?? []), declaring
				) != CannotCarry;
			final types: Map<Int, String> = declaredTypes ?? typesOf(provider, source);
			declaredTypes = types;
			final nominal: Null<String> = NominalTypes.expressionTypeNominal(receiver, tree, shape, types, _scope.index, file, null, true);
			// a nullable wrapper holds the value it wraps: which one is not known here
			final known: Null<String> = nominal == null || (shape.nullableWrapperTypeNames ?? []).contains(nominal) ? null : nominal;
			return _carriers.relation(known, declaring) != CannotCarry;
		}

		function record(node: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>, index: Int, parentIndex: Int): Void {
			final at: Null<Span> = node.span;
			if (at == null) return;
			final span: Span = at;
			if (!_live(file, span)) return;
			final verdict: Verdict = classify(node, parent, grand, index, parentIndex, access, arrayTyped);
			if (verdict.escape) out.escapes.push({ file: file, span: span });
			if (!verdict.touch) return;
			if (within(span, region) && out.inRegion == null) out.inRegion = {
				from: 'entry',
				to: name,
				kind: 'touch',
				file: file,
				span: span
			};
			final onSelf: Bool = node.kind == shape.identKind || (
				node.children.length > 0 && node.children[0].kind == shape.identKind && node.children[0].name == shape.selfReferenceText
			);
			for (id in touchingNodes(g, file, span.from)) {
				out.touchers[id] = { file: file, span: span };
				if (!onSelf && !out.notOnSelf.exists(id)) out.notOnSelf[id] = { file: file, span: span };
			}
		}

		function walk(
			node: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>, index: Int, parentIndex: Int, type: Null<String>
		): Void {
			if (opaqueKinds.contains(node.kind)) return;
			final current: Null<String> = CallGraphNames.typeNameOf(node) ?? type;
			final span: Null<Span> = node.span;
			if (node.name == name && span != null) {
				if (node.kind == identKind) {
					final bound: Null<Int> = bindings[span.from];
					final local: Bool = bound != null && bound >= 0 && g.functionAt(file, bound) != null;
					final owner: Null<String> = current == null ? null : g.types.declaringTypeOf(current, name);
					if (!local && (owner == null || owner == declaring)) record(node, parent, grand, index, parentIndex);
				} else if (_hazards.isAccess(node.kind) && node.children.length > 0 && receiverOwns(node.children[0])) {
					record(node, parent, grand, index, parentIndex);
				}
			}
			final reflected: Null<String> = _hazards.reflectiveNameWith(node, source, stringFold);
			if (reflected == name && span != null && _live(file, span)) {
				final site: Span = span;
				for (id in touchingNodes(g, file, site.from)) {
					out.touchers[id] = { file: file, span: site };
					out.notOnSelf[id] = { file: file, span: site };
				}
				if (within(site, region) && out.inRegion == null) out.inRegion = {
					from: 'entry',
					to: name,
					kind: 'reflection',
					file: file,
					span: site
				};
			}
			for (i in 0...node.children.length) walk(node.children[i], node, parent, i, index, current);
		}
		walk(tree, null, null, 0, 0, null);
	}

	/**
	 * The graph nodes an occurrence at `offset` of `file` belongs to: its innermost
	 * function, or the type's initializer pseudo-nodes outside every function.
	 */
	private function touchingNodes(g: CallGraph, file: String, offset: Int): Array<String> {
		final fn: Null<String> = g.functionAt(file, offset);
		if (fn != null) return [fn];
		final tree: Null<QueryNode> = g.treeOf(file);
		final type: Null<String> = tree == null ? null : typeAt(tree, offset);
		return type == null ? [] : ['$type.${CallGraph.INIT_NAME}', '$type.${CallGraph.STATIC_INIT_NAME}'];
	}

	/**
	 * What an occurrence of the member does for `access`: `touch` when it is the kind of access asked
	 * about, `escape` when (for `Mutate`) the member's value leaves for a place the analysis does not
	 * follow, or a value that was not freshly built is stored into it. A method call on the member is a
	 * read only when the member is an ARRAY (`arrayTyped`) and the method one of the array type's own
	 * readers; a method the array type does not declare may be a static extension handed the array itself.
	 */
	private function classify(
		node: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>, index: Int, parentIndex: Int, access: ReachAccess,
		arrayTyped: Bool
	): Verdict {
		// noqa: complexity
		final shape: RefShape = _scope.shape;
		if (parent == null) return { touch: access == Read, escape: access == Mutate };
		final pk: String = parent.kind;
		if (shape.writeParentKinds.contains(pk) && index == 0) {
			final plain: Bool = pk == shape.assignKind;
			return switch access {
				case Read: { touch: !plain, escape: false };
				case Write: { touch: true, escape: false };
				case Mutate: { touch: true, escape: plain && parent.children.length > 1 && !isFresh(parent.children[1], null) };
			};
		}
		if (access == Write) return { touch: false, escape: false };
		if (access == Read) return { touch: true, escape: false };
		final writes: Null<QueryNode> -> Int -> Bool = (n, i) -> n != null && shape.writeParentKinds.contains(n.kind) && i == 0;
		if (pk == shape.indexAccessKind && index == 0) return { touch: writes(grand, parentIndex), escape: false };
		if (_hazards.isAccess(pk) && index == 0) {
			if (grand != null && grand.kind == shape.callKind && parentIndex == 0) {
				final method: String = parent.name ?? '';
				final reads: Bool = arrayTyped && (shape.execution?.nonMutatingArrayMethods ?? []).contains(method);
				final own: Bool = arrayTyped && (reads || (shape.execution?.mutatingArrayMethods ?? []).contains(method));
				return { touch: !reads, escape: !own };
			}
			return { touch: writes(grand, parentIndex), escape: false };
		}
		if (pk == shape.forStmtKind && isIterableOf(parent, node)) return { touch: false, escape: false };
		if ((shape.equalityKinds ?? []).contains(pk)) return { touch: false, escape: false };
		if (pk == shape.parenKind) return classify(parent, grand, null, parentIndex, 0, access, arrayTyped);
		return { touch: false, escape: true };
	}

	/** Whether `node` is the ITERABLE of the `for` statement `loop`, not its body. */
	private function isIterableOf(loop: QueryNode, node: QueryNode): Bool {
		return NominalTypes.iterationIterable(loop, _scope.shape.iterationValueBinderKinds ?? []) == node;
	}

	/**
	 * Whether `value` is a call of a method its receiver's type ITSELF declares as returning a new object
	 * (`ExecutionShape.freshReturningMethods`, keyed by type) — a member always wins over a `using` extension of the
	 * same name, so only a receiver whose type is known counts: an array or string literal, an identifier
	 * declared of the type, or another such call, whose result is the array type. When the index holds the
	 * type's declaration, it must declare the method too.
	 */
	private function freshResult(value: QueryNode, ctx: FreshContext): Bool {
		if (value.kind != _scope.shape.callKind || value.children.length == 0) return false;
		final callee: QueryNode = value.children[0];
		final method: Null<String> = callee.name;
		if (!_hazards.isAccess(callee.kind) || callee.children.length != 1 || method == null) return false;
		final receiverType: Null<String> = builtinTypeOf(BoolExprShape.unwrapParens(callee.children[0], _scope.shape.parenKind), ctx);
		if (receiverType == null || !((_scope.shape.execution?.freshReturningMethods ?? [])[receiverType] ?? []).contains(method))
			return false;
		final declared: Null<FileInfo> = _scope.index.fileInfo(_scope.siteOf(receiverType)?.file ?? '');
		final decl: Null<TypeDeclInfo> = declared?.types.find(t -> t.name == receiverType);
		return decl == null || decl.members.exists(m -> m.name == method);
	}

	/**
	 * The built-in array or string type `node` is known to hold — a literal, an identifier declared of the
	 * type, or a fresh-returning call (whose result is an array) — or null.
	 */
	private function builtinTypeOf(node: QueryNode, ctx: FreshContext): Null<String> {
		final arrays: Array<String> = _scope.shape.arrayTypeNames ?? [];
		final strings: Array<String> = stringTypeNames();
		if (node.kind == _scope.shape.arrayLiteralKind) return arrays[0];
		if ((_scope.shape.stringLiteralKinds ?? []).contains(node.kind)) return strings[0];
		if (freshResult(node, ctx)) return arrays[0];
		final provider: Null<TypeInfoProvider> = _scope.plugin is TypeInfoProvider ? cast _scope.plugin : null;
		final bound: Null<Int> = TypeResolver.identBindingFrom(node, ctx.tree, _scope.shape);
		final written: Null<String> = bound == null || provider == null ? null : provider.declaredTypeSources(ctx.source)[bound];
		final outer: Null<String> = written == null ? null : NominalTypes.outerNominalOf(written);
		return outer != null && (arrays.contains(outer) || strings.contains(outer)) ? outer : null;
	}

	/** The type names the grammar's string literals denote (`RefShape.literalTypeNames`). */
	private function stringTypeNames(): Array<String> {
		final literalTypes: Map<String, String> = _scope.shape.literalTypeNames ?? [];
		return [
			for (kind in _scope.shape.stringLiteralKinds ?? []) if (literalTypes.exists(kind)) literalTypes[kind] ?? ''
		];
	}

	/** The initializer of member `name` on `declaring` when it is not freshly built — its value is shared from the start. */
	private function sharedInitializer(g: CallGraph, declaring: String, name: String): Null<{ file: String, span: Span }> {
		final site: Null<{ file: String, span: Span }> = _scope.siteOf(declaring);
		if (site == null) return null;
		final tree: Null<QueryNode> = g.treeOf(site.file);
		final info: Null<MemberInfo> = g.types.memberOnChain(declaring, name);
		if (tree == null || info == null) return null;
		final decl: Null<QueryNode> = RefactorSupport.nodeAtFrom(tree, info.declFrom);
		if (decl == null || decl.name != name) return null;
		final init: Null<QueryNode> = CtorFieldFold.declInitializer(decl, _scope.shape);
		final span: Null<Span> = init?.span;
		return init == null || span == null || isFresh(init, null) ? null : { file: site.file, span: span };
	}

	/** The innermost type declaration of `tree` enclosing `offset`. */
	public static function typeAt(tree: QueryNode, offset: Int): Null<String> {
		var found: Null<String> = null;
		function walk(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			if (span != null && (offset < span.from || offset >= span.to)) return;
			final name: Null<String> = CallGraphNames.typeNameOf(node);
			if (name != null) found = name;
			for (c in node.children) walk(c);
		}
		walk(tree);
		return found;
	}

	/** Whether `span` lies inside `region`; false when there is no region. */
	private static function within(span: Span, region: Null<Span>): Bool {
		return region != null && span.from >= region.from && span.to <= region.to;
	}

	private static function typesOf(provider: Null<TypeInfoProvider>, source: String): Map<Int, String> {
		return provider == null ? [] : provider.declaredTypes(source);
	}

	private static function lastSegment(path: String): String {
		final dot: Int = path.lastIndexOf('.');
		return dot < 0 ? path : path.substring(dot + 1);
	}

}

/** A site of a member occurrence. */
typedef Occurrence = {
	var file: String;
	var span: Span;
}

/**
 * The scan's result: toucher node id -> its touch site, the escape sites,
 * a blind spot in the project, and a touch inside the entry region.
 */
typedef MemberTouches = {
	var touchers: Map<String, Occurrence>;

	/** Toucher id -> a touch it makes on an object other than its own `this` (absent when every touch is on `this`). */
	var notOnSelf: Map<String, Occurrence>;

	var escapes: Array<Occurrence>;
	var hidden: Null<ReachUnknown>;
	var inRegion: Null<ReachStep>;
}

/** What `MemberTouchScan.isFresh` needs to type a method call's receiver: the file's tree and text. */
typedef FreshContext = {
	var tree: QueryNode;
	var source: String;
}

private typedef Verdict = {
	var touch: Bool;
	var escape: Bool;
}
