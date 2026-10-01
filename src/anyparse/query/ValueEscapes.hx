package anyparse.query;

import anyparse.query.CallGraph.CallEdge;
import anyparse.query.CallGraph.FnNode;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/**
 * The run-time types whose instances may reach code with NO static type to say what they are — the other half of
 * `ValueCarriers.valueTypes`: a value statically typed `T` is `T` or one of its subtypes, OR any instance that once
 * flowed untyped, since an implicit conversion from a catch-all or an unchecked cast hands it to a `T` position on
 * targets where a member then resolves by name.
 *
 * An instance ESCAPES when project code lets a value of its type go where no nominal type follows it: the operand of an
 * unchecked cast or a type check, a thrown value, a value stored, passed or returned into a position whose declared type
 * is a catch-all, a type parameter, a structure, an abstract, a function-local or undeclared one (`typedPosition`),
 * anything handed to library code (its argument, receiver, field or overridden member — library code is not read here,
 * so what it does with a value is not known), the receiver of a method read as a value (a bound method carries it), and
 * every class that inherits library code, which runs with the instance as its own `this`. What an escaped value holds
 * escapes with it: its fields, static and instance, its type arguments and its enum arguments, since code holding an
 * object without a type reaches those by name. A class whose name code passes to the class-value producer
 * (`Type.resolveClass`) may be instantiated untyped too, and a computed name there may name any class.
 *
 * `null` means any instance may be anywhere: the project holds target-language, untyped, unmodelled or unparsed code,
 * a raw conditional region some build compiles, an escaping value whose type the declarations do not say, or the run
 * does not hold every project file.
 *
 * Under the truth (`FactsView.truth`) the escapes are read off the compiler's facts instead (`FactsEscapes`): every
 * function every build typed, library code included, so a value handed to library code escapes only where that code
 * lets it go, and the run's scope says nothing the facts do not.
 */
@:nullSafety(Strict)
final class ValueEscapes {

	/** Called whenever the answer rests on a raw conditional region, which the configured builds may decide. */
	public var onRaw: () -> Void = () -> {};

	private final _scope: ReachProject;
	private final _shape: RefShape;
	private final _g: ReachGraph;
	private final _hazards: ReachHazards;
	private final _live: ReachLiveness;
	private final _carriers: ValueCarriers;
	private final _scopeKnown: Bool;

	/** The answer, once computed: the escaped types (null for any), and whether a raw region decided it. */
	private var _answer: Null<{ types: Null<Array<String>>, raw: Bool }> = null;

	/** What `memberFacts` read off the index. */
	private var _facts: Null<MemberFacts> = null;

	public function new(
		scope: ReachProject, graph: ReachGraph, hazards: ReachHazards, live: ReachLiveness, carriers: ValueCarriers, scopeKnown: Bool
	) {
		_scope = scope;
		_shape = scope.shape;
		_g = graph;
		_hazards = hazards;
		_live = live;
		_carriers = carriers;
		_scopeKnown = scopeKnown;
	}

	/** The types whose instances may have escaped (see the type doc), or null when any may have; computed once. */
	public function escaped(): Null<Array<String>> {
		var answer: Null<{ types: Null<Array<String>>, raw: Bool }> = _answer;
		if (answer == null) {
			answer = compute();
			_answer = answer;
		}
		if (answer.raw) onRaw();
		return answer.types;
	}

	/** Drop the answer: the project's text changed. */
	public function forget(): Void {
		_answer = null;
	}

	/** Whether a value stored in a position declared `type` keeps a nominal type the analysis follows (`ValueCarriers.typedNominal`). */
	private inline function typedPosition(type: String): Bool {
		return _carriers.typedNominal(type);
	}

	/**
	 * Whether `node` of `tree` (the text of `file`) is a macro function: its body runs while compiling, in no program.
	 * Asked of the index, not the graph, which leaves a macro function out altogether.
	 */
	private function macroMember(file: String, tree: QueryNode, node: QueryNode): Bool {
		final name: Null<String> = node.name;
		final at: Null<Span> = node.span;
		final kinds: Array<String> = [
			for (k in _shape.functionKinds ?? []) if (!(_shape.localFunctionKinds ?? []).contains(k)) k
		];
		if (!kinds.contains(node.kind) || name == null || at == null) return false;
		final type: Null<String> = MemberTouchScan.typeAt(tree, at.from);
		final declared: Null<TypeDeclInfo> = type == null ? null : _scope.index.fileInfo(file)?.types.find(t -> t.name == type);
		// this declaration's own record: a twin in another branch of a conditional region may be a runtime one
		return declared != null && declared.members.exists(m -> m.name == name && m.isMacro && m.declFrom == at.from);
	}

	/** The spans of the macro functions of `tree` (the text of `file`: `macroMember`). */
	private function macroSpans(file: String, tree: QueryNode): Array<Span> {
		final out: Array<Span> = [];
		function walk(node: QueryNode): Void {
			final at: Null<Span> = node.span;
			if (at != null && macroMember(file, tree, node)) {
				out.push(at);
				return;
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return out;
	}

	private function compute(): { types: Null<Array<String>>, raw: Bool } {
		final out: Array<String> = [];
		final seen: Map<String, Bool> = [];
		// under the truth every function the builds typed is read, the libraries' as much as the project's
		final view: Null<FactsView> = _scope.facts;
		if (view != null && view.truth) return { types: new FactsEscapes(view, _scope).compute(), raw: false };
		if (!_scopeKnown) return { types: null, raw: false };
		final g: CallGraph = _g.graph();
		for (skipped in g.skippedFiles) if (_scope.sources.exists(skipped)) return { types: null, raw: false };
		final escape: String -> Bool = escapeType.bind(g, out, seen);
		// a file no build runs lets nothing escape, and the graph holds no tree of it
		for (f in _scope.files) if (!_scope.runsInNoBuild(f.file)) {
			final fi: Null<FileInfo> = _scope.index.fileInfo(f.file);
			final tree: Null<QueryNode> = g.treeOf(f.file);
			if (fi == null || tree == null) return { types: null, raw: false };
			// a class inheriting library code runs it with the instance as `this`
			for (t in fi.types) if (inheritsLibrary(g, t.name) && !escape(t.name)) return { types: null, raw: false };
			final compileTime: Array<Span> = macroSpans(f.file, tree);
			for (h in _hazards.hazardsIn(f.file, tree, f.source, new Span(0, f.source.length))) {
				// code no build compiles, and a macro function with its modifier, run in no program
				if (!_live.live(f.file, f.source, h.span) || h.node.kind == _shape.macroModifierKind) continue;
				if (compileTime.exists(sp -> h.span.from >= sp.from && h.span.to <= sp.to)) continue;
				switch h.kind {
					case Native, Untyped, Unmodelled(_):
						return { types: null, raw: false };
					case Opaque:
						if (_live.holdsLiveCode(f.file, f.source, h.span)) return { types: null, raw: true };
					case ReflectiveName(_), ArrayChange:
				}
			}
			if (!scanFile(g, f.file, tree, f.source, escape)) return { types: null, raw: false };
		}
		if (!namedClasses(g, escape)) return { types: null, raw: false };
		return { types: out, raw: false };
	}

	/**
	 * Record `typeSource` and everything a value of it holds as escaped (see the type doc): false when what it holds is
	 * not known. A catch-all holds a value that escaped already, a function value's bound receiver escaped where the
	 * method was read, and a value that runs no code carries no member.
	 */
	private function escapeType(g: CallGraph, out: Array<String>, seen: Map<String, Bool>, typeSource: String): Bool {
		// noqa: complexity
		final wrappers: Array<String> = _shape.memberTransparentWrapperTypeNames ?? [];
		final typeSyntax: TypeSyntaxReader = _scope.plugin.typeSyntax;
		final catchAll: Array<String> = _shape.catchAllTypeNames ?? [];
		final fieldKinds: Array<String> = _shape.fieldDeclKinds ?? [];
		final functionKinds: Array<String> = _shape.functionKinds ?? [];
		final ctorKinds: Array<String> = _shape.execution?.enumConstructorKinds ?? [];
		final work: Array<String> = [typeSource];
		var wi: Int = 0;
		while (wi < work.length) {
			final source: String = NominalTypes.unwrapNullable(StringTools.trim(work[wi++]), wrappers, typeSyntax);
			if (typeSyntax(source)?.holdsFunction() == true) continue;
			final nominal: Null<String> = NominalTypes.outerNominalOf(source, typeSyntax);
			if (nominal == null) return false;
			if (catchAll.contains(nominal) || _g.inertType(source)) continue;
			final args: Null<Array<String>> = NominalTypes.typeArgumentSourcesOf(source, typeSyntax);
			// a container written without its arguments holds what nothing here says: `Array` is any `Array<T>`
			if ((args ?? []).length < g.types.generics.typeParamsOf(nominal).length) return false;
			for (arg in args ?? []) work.push(arg);
			if (seen.exists(source)) continue;
			seen[source] = true;
			final values: Null<Array<String>> = _carriers.declaredValueTypes(source);
			if (values == null) return false;
			final holders: Array<String> = values.copy();
			var hi: Int = 0;
			while (hi < holders.length) for (s in g.types.supertypesOf(holders[hi++])) if (!holders.contains(s)) holders.push(s);
			for (v in values) if (!out.contains(v)) out.push(v);
			for (t in holders) {
				final decl: Null<TypeDeclInfo> = declarationOf(t);
				if (decl == null) return false;
				final ownParams: Array<String> = decl.typeParamNames;
				for (m in decl.members) {
					final held: Array<Null<String>> = if (functionKinds.contains(m.kind))
						[];
					else if (fieldKinds.contains(m.kind))
						[m.typeSource];
					else if (ctorKinds.contains(m.kind))
						m.paramTypeSources;
					else
						return false;
					for (heldType in held) {
						if (heldType == null) return false;
						final at: Int = ownParams.indexOf(NominalTypes.outerNominalOf(StringTools.trim(heldType), typeSyntax) ?? '');
						if (at < 0) {
							work.push(heldType);
							continue;
						}
						// a value typed by the type's own parameter holds what the written argument says
						final written: Null<Array<String>> = t == nominal ? args : null;
						if (written == null || at >= written.length) return false;
						work.push(written[at]);
					}
				}
			}
		}
		return true;
	}

	/** Whether `type` or a supertype of it is declared outside the project, or not declared at all. */
	private function inheritsLibrary(g: CallGraph, type: String): Bool {
		final queue: Array<String> = g.types.supertypesOf(type).copy();
		var qi: Int = 0;
		while (qi < queue.length) {
			final t: String = queue[qi++];
			if (!_scope.sources.exists(_scope.siteOf(t)?.file ?? '')) return true;
			for (s in g.types.supertypesOf(t)) if (!queue.contains(s)) queue.push(s);
		}
		return false;
	}

	/**
	 * Hand every escaping value of the project file `file` to `escape` (see the type doc); false when one escapes with
	 * a type the declarations do not say.
	 */
	private function scanFile(g: CallGraph, file: String, tree: QueryNode, source: String, escape: String -> Bool): Bool {
		// noqa: complexity
		final shape: RefShape = _shape;
		final provider: Null<TypeInfoProvider> = _scope.plugin is TypeInfoProvider ? cast _scope.plugin : null;
		final annotations: Map<Int, String> = provider == null ? [] : provider.declaredTypeSources(source);
		final declKinds: Array<String> = (shape.localDeclKinds ?? []).concat(shape.fieldDeclKinds ?? []);
		final memberFunctions: Array<String> = [
			for (k in shape.functionKinds ?? []) if (!(shape.localFunctionKinds ?? []).contains(k)) k
		];
		final functions: Array<String> = (shape.functionKinds ?? []).concat(shape.lambdaKinds ?? []);
		final assignKinds: Array<String> = [for (k in [shape.assignKind, shape.nullCoalAssignKind]) if (k != null) k];
		// a lambda whose body is an expression yields it; a `function` lambda returns only through `return`
		final arrowKinds: Array<String> = [
			for (k in shape.lambdaKinds ?? []) if (k != shape.fnExprKind && k != shape.namedFnExprKind) k
		];
		// statements that yield no value as a block's last one
		final silentKinds: Array<String> = (shape.localDeclKinds ?? []).concat(shape.loopStatementKinds ?? [])
			.concat(shape.doWhileLoopKinds ?? [])
			.concat(shape.localFunctionKinds ?? [])
			.concat(shape.valueReturnKinds ?? [])
			.concat(shape.throwKinds ?? [])
			.concat([for (k in [shape.voidReturnKind]) if (k != null) k]);
		final statementKinds: Array<String> = silentKinds.concat([for (k in [shape.exprStatementKind]) if (k != null) k]);
		final edges: Map<String, Array<CallEdge>> = [];
		for (e in g.edges) {
			final at: Null<Span> = e.span;
			if (e.file != file || at == null || !(e.kind == Call || e.kind == New)) continue;
			final key: String = '${at.from}:${at.to}';
			final list: Array<CallEdge> = edges[key] ?? [];
			list.push(e);
			edges[key] = list;
		}
		var ok: Bool = true;
		function typeOf(raw: QueryNode): Null<String> {
			final node: QueryNode = BoolExprShape.unwrapParens(raw, shape.parenKind);
			// the compiler's type, where its facts replace the syntax of the code holding the value
			final span: Null<Span> = node.span;
			final typed: Null<String> = span == null ? null : _scope.facts?.typeSourceAt(g, file, span);
			if (typed != null) return typed;
			final constructed: Null<String> = node.name;
			if (node.kind != shape.newExprKind || constructed == null) {
				// what the declarations say, and for an unannotated local its initializer's type: the one Haxe infers for it
				final said: Null<String> = _g.sites.typeOf(file, tree, source, node);
				final name: Null<String> = node.name;
				final at: Null<Span> = node.span;
				if (said != null || node.kind != shape.identKind || name == null || at == null) return said;
				final decl: Null<QueryNode> = TypeResolver.bindingNodeFrom(name, at, tree, shape);
				if (decl == null || !(shape.localDeclKinds ?? []).contains(decl.kind)) return null;
				final declAt: Null<Span> = decl.span;
				if (declAt == null || annotations.exists(declAt.from)) return null;
				final init: Null<QueryNode> = CtorFieldFold.declInitializer(decl, shape);
				if (init == null) return null;
				// an initializer ending before the use: a self-reference would not terminate
				final initAt: Null<Span> = init.span;
				return initAt == null || initAt.to > at.from ? null : typeOf(init);
			}
			// a construction is of the type it names, with the arguments it writes
			final typeKinds: Array<String> = shape.typeAnnotationKinds ?? [];
			final args: Array<String> = [
				for (c in node.children) if (typeKinds.contains(c.kind) && c.span != null)
					source.substring(c.span?.from ?? 0, c.span?.to ?? 0)
			];
			return args.length == 0 ? constructed : '$constructed<${args.join(', ')}>';
		}
		// an operator whose operands no abstract overloads it for yields a primitive or one of its operands
		function plainOperation(node: QueryNode): Bool {
			if (!(shape.pureOperatorKinds ?? []).contains(node.kind)) return false;
			if (!overloaded(node.kind)) return true;
			for (c in node.children) {
				final operand: QueryNode = BoolExprShape.unwrapParens(c, shape.parenKind);
				if ((shape.literalTypeNames ?? []).exists(operand.kind) || operand.kind == shape.nullLiteralKind || plainOperation(operand))
					continue;
				final type: Null<String> = typeOf(operand);
				if (type == null || !(_g.inertType(type) || typedPosition(type) || (shape.catchAllTypeNames ?? []).contains(type)))
					return false;
			}
			return true;
		}
		function isTypeName(receiver: QueryNode): Bool {
			final self: Bool = receiver.kind == shape.identKind
				&& (receiver.name == shape.selfReferenceText || receiver.name == shape.superReferenceText);
			return !self && TypeResolver.receiverRootIsUnboundType(receiver, tree, shape);
		}
		// a bare name no local binds names a member of the enclosing type chain
		function bindsNoLocal(name: String, at: Span): Bool {
			final decl: Null<QueryNode> = TypeResolver.bindingNodeFrom(name, at, tree, shape);
			return decl == null || memberFunctions.contains(decl.kind) || (shape.fieldDeclKinds ?? []).contains(decl.kind);
		}
		// the written type of the place `target` names: a local's or a member's annotation, or for an element the
		// container's, whose arguments then say what the element is; null when nothing written says
		function declaredSourceOf(target: QueryNode): Null<String> {
			final name: Null<String> = target.name;
			final at: Null<Span> = target.span;
			if (target.kind == shape.indexAccessKind && target.children.length > 0) return declaredSourceOf(target.children[0]);
			if (target.kind == shape.identKind && name != null && at != null) {
				final decl: Null<QueryNode> = TypeResolver.bindingNodeFrom(name, at, tree, shape);
				final declAt: Null<Span> = decl?.span;
				if (decl != null && declAt != null && !(shape.fieldDeclKinds ?? []).contains(decl.kind)) return annotations[declAt.from];
				final enclosing: Null<String> = MemberTouchScan.typeAt(tree, at.from);
				return enclosing == null ? null : g.types.memberOnChain(enclosing, name)?.typeSource;
			}
			if (_hazards.isAccess(target.kind) && target.children.length > 0 && name != null) {
				final receiver: QueryNode = target.children[0];
				final owner: Null<String> = isTypeName(receiver) ? lastSegment(RefactorSupport.flattenPath(receiver)) : typeOf(receiver);
				return owner == null ? null : g.types.memberOnChain(owner, name)?.typeSource;
			}
			return null;
		}
		function value(raw: QueryNode): Void {
			if (!ok) return;
			final node: QueryNode = BoolExprShape.unwrapParens(raw, shape.parenKind);
			final kind: String = node.kind;
			if ((shape.literalTypeNames ?? []).exists(kind) || kind == shape.nullLiteralKind || (shape.lambdaKinds ?? []).contains(kind))
				return;
			// a reification builds a syntax tree at compile time: no object of the program
			if ((shape.opaqueKinds ?? []).contains(kind)) return;
			// a literal holds what its elements are; an operator nothing overloads yields a primitive of its operands
			final container: Bool = kind == shape.arrayLiteralKind || kind == shape.objectLiteralKind || kind == shape.mapLiteralEntryKind;
			final operation: Bool = plainOperation(node);
			if (container || operation || kind == shape.exprStatementKind || kind == shape.objectFieldKind) {
				for (c in node.children) value(c);
				return;
			}
			// an assignment yields what it stores, an if-expression one of its branches, a block its last statement
			if (assignKinds.contains(kind) && node.children.length == 2) {
				value(node.children[1]);
				return;
			}
			if ((shape.ifExpressionKinds ?? []).contains(kind)) {
				for (c in node.children.slice(1)) value(c);
				return;
			}
			final last: Null<QueryNode> = node.children.length > 0 ? node.children[node.children.length - 1] : null;
			if (last != null && statementKinds.contains(last.kind)) {
				if (!silentKinds.contains(last.kind)) value(last);
				return;
			}
			// a method read as a value is a function bound to the object it was read from
			final name: Null<String> = node.name;
			final at: Null<Span> = node.span;
			if (_hazards.isAccess(kind) && node.children.length > 0 && name != null) {
				final receiver: QueryNode = node.children[0];
				if (isTypeName(receiver)) {
					if (g.types.functionOnChain(RefactorSupport.flattenPath(receiver), name)) return;
				} else {
					final owner: Null<String> = typeOf(receiver);
					if (owner == null ? declaresFunctionNamed(name) : g.types.functionOnChain(owner, name)) {
						value(receiver);
						return;
					}
				}
			} else if (kind == shape.identKind && name != null && at != null && name != shape.selfReferenceText && bindsNoLocal(name, at)) {
				final enclosing: Null<String> = MemberTouchScan.typeAt(tree, at.from);
				if (enclosing != null && g.types.functionOnChain(enclosing, name)) {
					if (g.types.memberOnChain(enclosing, name)?.isStatic != true && !escape(enclosing)) ok = false;
					return;
				}
			}
			// the written type carries the arguments a declaration spells, which the value's contents are
			final type: Null<String> = declaredSourceOf(node) ?? typeOf(node);
			if (type != shape.voidTypeName && (type == null || !escape(type))) ok = false;
		}
		// the value an arrow lambda's body yields: an expression, or a block's last statement unless that one yields none
		function bodyValue(body: QueryNode): Void {
			final last: Null<QueryNode> = body.children.length > 0 ? body.children[body.children.length - 1] : null;
			final block: Bool = body.kind == shape.blockBodyKind || body.kind == shape.blockStmtKind
				|| statementKinds.contains(last?.kind ?? '');
			if (!block)
				value(body);
			else if (last != null && !silentKinds.contains(last.kind))
				value(last);
		}
		function libraryMember(type: Null<String>, name: String): Bool {
			if (type == null) return true;
			final declaring: String = g.types.declaringTypeOf(type, name) ?? type;
			return !_scope.sources.exists(_scope.siteOf(declaring)?.file ?? '');
		}
		function call(node: QueryNode): Void {
			final isNew: Bool = node.kind == shape.newExprKind;
			final typeKinds: Array<String> = shape.typeAnnotationKinds ?? [];
			final args: Array<QueryNode> = isNew ? [for (c in node.children) if (!typeKinds.contains(c.kind)) c] : node.children.slice(1);
			final callee: Null<QueryNode> = isNew || node.children.length == 0 ? null : node.children[0];
			final head: Null<QueryNode> = callee != null && _hazards.isAccess(callee.kind) && callee.children.length > 0
				? callee.children[0]
				: null;
			final receiver: Null<QueryNode> = head == null || isTypeName(head) || head.name == shape.superReferenceText ? null : head;
			final at: Null<Span> = node.span;
			final targets: Array<CallEdge> = at == null ? [] : edges['${at.from}:${at.to}'] ?? [];
			function handAll(): Void {
				for (a in args) value(a);
				final held: Null<QueryNode> = receiver;
				if (held != null) value(held);
			}
			// a call the graph did not resolve still resolves through its receiver's static type, when that is known
			final calleeName: Null<String> = callee?.name;
			final owner: Null<String> = receiver == null || calleeName == null ? null : typeOf(receiver);
			final declared: Null<MemberInfo> = owner == null || calleeName == null ? null : g.types.memberOnChain(owner, calleeName);
			if (
				targets.length == 0 && owner != null && calleeName != null && declared != null && !declared.isStatic
				&& g.types.functionOnChain(owner, calleeName) && !libraryMember(owner, calleeName)
			) {
				for (i in 0...args.length) if (!paramsTyped(declared.paramTypeSources, i)) value(args[i]);
				return;
			}
			if (targets.length == 0) {
				handAll();
				return;
			}
			for (e in targets) {
				final target: Null<FnNode> = g.node(e.to);
				final type: Null<String> = target?.typeName;
				final name: Null<String> = target?.name;
				final info: Null<MemberInfo> = type == null || name == null ? null : g.types.memberOnChain(type, name);
				if (type == null || name == null || info == null) {
					handAll();
					continue;
				}
				final member: String = name;
				if (libraryMember(type, member)) {
					// library code is not read, so whatever it is handed may go anywhere — except a value of a primitive
					// type, which no object is
					for (i in 0...args.length) if (!paramsPrimitive(info.paramTypeSources, i)) value(args[i]);
					final held: Null<QueryNode> = receiver;
					if (held != null) value(held);
					continue;
				}
				// a static function reached through a value is an extension: the value is its first argument
				final extended: Null<QueryNode> = info.isStatic ? receiver : null;
				final actual: Array<QueryNode> = extended == null ? args : [extended].concat(args);
				for (i in 0...actual.length) if (!paramsTyped(info.paramTypeSources, i)) value(actual[i]);
			}
		}
		function assignedTypedly(target: QueryNode): Bool {
			final name: Null<String> = target.name;
			final at: Null<Span> = target.span;
			if (_hazards.isAccess(target.kind) && target.children.length > 0 && name != null) {
				final receiver: QueryNode = target.children[0];
				final owner: Null<String> = isTypeName(receiver) ? RefactorSupport.flattenPath(receiver) : typeOf(receiver);
				if (owner == null || libraryMember(lastSegment(owner), name)) return false;
			} else if (
				target.kind == shape.identKind && name != null && at != null && TypeResolver.bindingNodeFrom(name, at, tree, shape) == null
				&& libraryMember(MemberTouchScan.typeAt(tree, at.from), name)
			)
				return false;
			final declared: Null<String> = declaredSourceOf(target);
			return declared != null && typedPosition(declared);
		}
		function returnsTypedly(fn: Null<QueryNode>): Bool {
			if (fn == null || !memberFunctions.contains(fn.kind)) return false;
			final at: Null<Span> = fn.span;
			final name: Null<String> = fn.name;
			final type: Null<String> = at == null ? null : MemberTouchScan.typeAt(tree, at.from);
			if (type == null || name == null) return false;
			// the written return type: the function's own type annotation child, its parameters' being inside them
			final written: Null<QueryNode> = fn.children.find(c -> (shape.typeAnnotationKinds ?? []).contains(c.kind));
			final span: Null<Span> = written?.span;
			if (span == null || !typedPosition(source.substring(span.from, span.to))) return false;
			// an override of a library member returns into the library code that calls it
			for (s in g.types.supertypesOf(type)) if (g.types.memberOnChain(s, name) != null && libraryMember(s, name)) return false;
			return true;
		}
		function walk(node: QueryNode, fn: Null<QueryNode>): Void {
			if (!ok) return;
			final kind: String = node.kind;
			// code no build compiles, a reification and a macro's body run in no program
			if ((shape.opaqueKinds ?? []).contains(kind) || !_live.live(file, source, node.span) || macroMember(file, tree, node)) return;
			final first: Null<QueryNode> = node.children.length > 0 ? node.children[0] : null;
			if (first != null && (kind == shape.uncheckedCastKind || kind == shape.checkTypeKind))
				value(first);
			else if (first != null && (shape.throwKinds ?? []).contains(kind))
				// a catch may bind what is thrown as a catch-all
				value(first);
			else if (declKinds.contains(kind)) {
				final init: Null<QueryNode> = CtorFieldFold.declInitializer(node, shape);
				final annotated: Null<String> = node.span == null ? null : annotations[node.span?.from ?? 0];
				if (init != null && annotated != null && !typedPosition(annotated)) value(init);
			} else if (assignKinds.contains(kind) && node.children.length == 2) {
				if (!assignedTypedly(node.children[0])) value(node.children[1]);
			} else if (kind == shape.callKind || kind == shape.newExprKind)
				call(node);
			else if ((shape.valueReturnKinds ?? []).contains(kind) && first != null) {
				if (!returnsTypedly(fn)) value(first);
			} else if (arrowKinds.contains(kind) && node.children.length > 0)
				// the body's result is returned into a position nothing here types
				bodyValue(node.children[node.children.length - 1]);
			final inner: Null<QueryNode> = functions.contains(kind) ? node : fn;
			for (c in node.children) walk(c, inner);
		}
		walk(tree, null);
		return ok;
	}

	/**
	 * Hand every class the class-value producers may name to `escape`: a producer is a member returning the class-value
	 * type from a string (`Type.resolveClass`), and a literal name there names one class, while a computed name, or the
	 * producer read as a value, may name any. False for any. Every indexed file counts, library code included.
	 */
	private function namedClasses(g: CallGraph, escape: String -> Bool): Bool {
		// noqa: complexity
		final classType: Null<String> = _shape.execution?.classValueTypeName;
		final stringType: Null<String> = _g.stringTypeName();
		if (classType == null || stringType == null) return true;
		final functionKinds: Array<String> = _shape.functionKinds ?? [];
		final producers: Array<String> = [];
		for (fi in _scope.index.allFiles())
			for (t in fi.types)
				for (m in t.members)
					if (functionKinds.contains(m.kind) && m.returnNominal == classType && m.paramTypeSources.exists(
						p -> p != null && NominalTypes.outerNominalOf(StringTools.trim(p), _scope.plugin.typeSyntax) == stringType
					) && !producers.contains(m.name))
						producers.push(m.name);
		if (producers.length == 0) return true;
		final folding: Null<StringFoldSupport> = _scope.plugin.stringFoldSupport();
		if (folding == null) return false;
		final stringFold: StringFoldSupport = folding;
		for (fi in _scope.index.allFiles()) {
			final source: Null<String> = _scope.sources[fi.file] ?? _scope.index.sourceOf(fi.file);
			if (source == null) return false;
			final text: String = source;
			if (!producers.exists(p -> RawSourceScan.mentionsWord(text, p))) continue;
			final tree: Null<QueryNode> = g.treeOf(fi.file) ?? (try _scope.plugin.parseFile(text) catch (exception: Exception) null);
			if (tree == null) return false;
			var ok: Bool = true;
			function walk(node: QueryNode, parent: Null<QueryNode>, index: Int): Void {
				if (!ok) return;
				final name: Null<String> = node.name;
				final named: Bool = name != null && producers.contains(name)
					&& (node.kind == _shape.identKind || _hazards.isAccess(node.kind));
				if (named && !(parent?.kind == _shape.callKind && index == 0)) ok = false;
				if (named && parent != null && parent.kind == _shape.callKind && index == 0) for (arg in parent.children.slice(1)) {
					final literal: Null<String> = stringFold.literalOf(arg, text)?.content;
					if (literal == null) {
						ok = false;
						return;
					}
					final type: String = lastSegment(literal);
					if (declarationOf(type) != null && !escape(type)) ok = false;
				}
				for (i in 0...node.children.length) walk(node.children[i], node, i);
			}
			walk(tree, null, 0);
			if (!ok) return false;
		}
		return true;
	}

	/**
	 * Whether every parameter from `from` on is declared with a type the analysis follows: an argument may bind to a
	 * later parameter when earlier optional ones are skipped, and one past the last is a rest argument.
	 */
	private function paramsTyped(params: Array<Null<String>>, from: Int): Bool {
		if (from >= params.length) return false;
		for (i in from ... params.length) {
			final p: Null<String> = params[i];
			if (p == null || !typedPosition(p)) return false;
		}
		return true;
	}

	/**
	 * Whether every parameter from `from` on is declared with a primitive type (`ValueCarriers.primitive`): an argument
	 * may bind to a later parameter when earlier optional ones are skipped, and one past the last is a rest argument.
	 */
	private function paramsPrimitive(params: Array<Null<String>>, from: Int): Bool {
		if (from >= params.length) return false;
		for (i in from ... params.length) {
			final p: Null<String> = params[i];
			if (p == null || !_carriers.primitive(p)) return false;
		}
		return true;
	}

	/** Whether some operator overload the index declares is of `kind`. */
	private function overloaded(kind: String): Bool {
		return memberFacts().operators.contains(kind);
	}

	/** Whether some indexed type declares a function called `name`. */
	private function declaresFunctionNamed(name: String): Bool {
		return memberFacts().functions.exists(name);
	}

	/**
	 * The operator kinds the index's members overload and the names of its functions, read once.
	 */
	private function memberFacts(): MemberFacts {
		final held: Null<MemberFacts> = _facts;
		if (held != null) return held;
		final kinds: Array<String> = _shape.functionKinds ?? [];
		final facts: MemberFacts = { operators: [], functions: [] };
		for (fi in _scope.index.allFiles()) for (t in fi.types) for (m in t.members) {
			if (kinds.contains(m.kind)) facts.functions[m.name] = true;
			for (k in m.operatorOverloads) if (!facts.operators.contains(k)) facts.operators.push(k);
		}
		_facts = facts;
		return facts;
	}

	/** The single indexed declaration of `type`, or null. */
	private function declarationOf(type: String): Null<TypeDeclInfo> {
		final site: Null<{ file: String, span: Span }> = _scope.siteOf(type);
		return site == null ? null : _scope.index.fileInfo(site.file)?.types.find(d -> d.name == type);
	}

	private static function lastSegment(path: String): String {
		return path.substr(path.lastIndexOf('.') + 1);
	}

}

/** What `ValueEscapes.memberFacts` reads off the index's members. */
private typedef MemberFacts = {
	var operators: Array<String>;
	var functions: Map<String, Bool>;
}
