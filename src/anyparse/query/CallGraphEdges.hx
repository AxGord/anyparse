package anyparse.query;

import anyparse.query.CallGraph.ArgumentPosition;
import anyparse.query.CallGraph.FnNode;
import anyparse.query.CallGraph.ParsedEntry;
import anyparse.query.CallGraph.UnresolvedReason;
import anyparse.query.CallGraphImports.WrittenIn;
import anyparse.query.CallGraphTypes.HeldFile;
import anyparse.query.ExpectedTypes.ExpectationHost;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.TypeSyntax;
import anyparse.query.TypingService.TypingHost;
import anyparse.query.ValueNameBinding.ImportedStatics;
import anyparse.query.ValueNameBinding.ModuleValues;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/**
 * The edges of a `CallGraph`, collected per file once its nodes are (`CallGraphNodes`): one walk over a parsed file
 * records every call, construction, accessor run, function value and containment it makes as an edge of the graph, and
 * every site it cannot resolve as an unresolved call or access. What the walk keeps while it runs — the frames of the
 * functions it is inside, the call sites it resolved, the types it gave the values it read — lives for that one file.
 */
@:nullSafety(Strict)
@:access(anyparse.query.CallGraph)
final class CallGraphEdges {

	/** The scope of a type written on a MEMBER: only the parameters of the type declaring it are in scope there. */
	private static inline final MEMBER_SCOPE: Int = -1;

	/** Record the edges of `entry`, a file `g` holds whose nodes are collected, in `g`. */
	public static function collect(g: CallGraph, entry: ParsedEntry): Void {
		// noqa: complexity
		final shape: RefShape = g._shape;
		final provider: Null<TypeInfoProvider> = g._provider;
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
		final indexKind: Null<String> = shape.indexAccessKind;
		final assignKind: Null<String> = shape.assignKind;
		final writeParentKinds: Array<String> = shape.writeParentKinds;
		final macroKind: Null<String> = shape.macroModifierKind;
		// a local `inline function` is a function of its own like any local one, though the grammar gives it a kind apart
		final fnKinds: Array<String> = (shape.functionKinds ?? []).concat(shape.inlineFunctionKinds ?? []);
		final lambdaKinds: Array<String> = shape.lambdaKinds ?? [];
		final localFnKinds: Array<String> = ShapeVocab.localFunctionScopeKinds(shape);
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final nullableWrappers: Array<String> = shape.nullableWrapperTypeNames ?? [];
		final transparentWrappers: Array<String> = shape.memberTransparentWrapperTypeNames ?? [];
		final elementParams: Map<String, Int> = shape.indexedElementTypeParams ?? [];
		final iterationParams: Map<String, Int> = shape.iterationElementTypeParams ?? [];
		final standardContainers: Map<String, Array<String>> = shape.standardContainerPaths ?? [];
		final iterationKinds: Array<String> = shape.iterationBindingKinds ?? [];
		final valueBinderKinds: Array<String> = shape.iterationValueBinderKinds ?? [];
		final paramKinds: Array<String> = shape.paramKinds ?? [];
		final accessorPrefixes: Array<String> = shape.accessorMethodPrefixes ?? [];
		final ctorName: String = shape.constructorName ?? 'new';
		final objectLiteralKind: Null<String> = shape.objectLiteralKind;
		final fieldKinds: Array<String> = shape.fieldDeclKinds ?? [];
		// call / `new` site `span.from` -> the target it resolved to and the receiver it was made on, for typing its arguments
		final sites: Map<Int, CallSite> = [];
		// the ancestors of the node being walked, outermost first, and the child index leading down from each
		final lineage: Array<QueryNode> = [];
		final lineageIndex: Array<Int> = [];
		// the expectation ladder every typer shares, asked from `lineage` (`ExpectedTypes`)
		final expectation: ExpectedTypes = new ExpectedTypes(shape);
		final tree: QueryNode = entry.tree;
		final file: String = entry.file;
		final source: String = entry.source;
		final moduleType: String = CallGraphNames.moduleTypeName(file);
		// the file's declared types as the graph keys them (`CallGraphKeys`): a library type never merges into a project one
		final keys: CallGraphKeys = new CallGraphKeys(g.types.imports, file, g._plugin.typeSyntax, provider, source, tree, fnKinds);
		// the index entry the file was read from, whose `values` layer says what a bare name the module and its imports bind
		final held: Null<HeldFile> = g.types.heldFile(file);

		// the files whose declarations wrote the types read while typing a receiver (`readIn`), for the types a name there may be
		final readFrom: Array<String> = [];
		// each type a declaration typing a receiver names where another one of it names the type read (`readIn`): runs too
		final keyedApart: Array<{ from: String, to: String }> = [];
		final typeSources: Map<Int, String> = keys.typeSources;
		final consumedBindCalls: Array<Int> = [];
		final frames: Array<Frame> = [];
		final staticKind: Null<String> = shape.staticModifierKind;
		final modifierBoundary: QueryNode -> Bool = c -> c.children.length > 0 || c.name != null;
		// true while the walk is inside a STATIC member's initializer, whose calls land on `<static>`
		var inStaticInit: Bool = false;

		/** What the imports of the file supply under the bare name `name` read at `at` (`ValueNameBinding.importedStatics`). */
		function importedOf(name: String, ?at: Int): ImportedStatics {
			final holder: Null<HeldFile> = held;
			return holder == null ? { statics: [], unknown: false } : holder.index.values.importedStatics(holder.info, name, at);
		}

		/** What the bare value name `name` read at `at` means at module level (`ValueNameBinding.moduleValuesAt`). */
		function moduleValuesOf(name: String, at: Int): Null<ModuleValues> {
			final holder: Null<HeldFile> = held;
			return holder == null ? null : holder.index.values.moduleValuesAt(holder.info, name, at);
		}

		function frameId(currentType: Null<String>): String {
			return frames.length > 0 ? frames[frames.length - 1].id : g.initNode(currentType ?? moduleType, file, inStaticInit);
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

		/**
		 * The functions a bare use of `name` at `span` may run when the module declares a value of the name and no member of
		 * `currentType`'s chain may be meant (`CallGraphKeys.memberMayBind`; Haxe 4.3.7 `v-N11-hx/p1`): the body of each
		 * module-level function some build compiling the use declares (`ValueNameBinding.moduleValuesAt`) — its own node,
		 * never another build's (`bodiesOf`) — and, in the builds declaring none, each static an import binds the name to. A
		 * build declaring a module-level VALUE runs the function it holds, and one whose import the index cannot list may run
		 * any: `unresolved` says why. Null for a name the module declares no value of.
		 */
		function moduleBinding(name: String, span: Span, currentType: Null<String>): Null<ModuleBinding> {
			final values: Null<ModuleValues> = moduleValuesOf(name, span.from);
			if (values == null || values.decls.length == 0 || CallGraphKeys.memberMayBind(g, currentType, name)) return null;
			final out: ModuleBinding = { targets: [], unresolved: null };
			for (d in values.decls) {
				final body: Null<String> = entry.fnBySpanFrom[d.span.from];
				if (body == null)
					out.unresolved = FunctionValue(name)
				else if (!out.targets.contains(body))
					out.targets.push(body);
			}
			final imported: Null<ImportedStatics> = values.imported;
			if (imported != null) {
				for (s in imported.statics) {
					final target: String = g.memberOnChain(s.owner, s.member) ?? g.externalNode(s.owner, s.member);
					if (!out.targets.contains(target)) out.targets.push(target);
				}
				if (imported.unknown && out.unresolved == null) out.unresolved = UnboundName(name);
			}
			return out;
		}

		/** `moduleBinding` for a bare identifier `name` at `span` no local function, local or parameter binds first. */
		function bareModuleBinding(name: String, span: Null<Span>, currentType: Null<String>): Null<ModuleBinding> {
			if (span == null) return null;
			final bound: Null<Int> = Refs.bindingAt(name, span.from, tree, shape);
			return bound != null && bound >= 0 ? null : moduleBinding(name, span, currentType);
		}

		/** Whether `name` is a type parameter in scope — of a function on the frame stack or of `currentType` — naming no indexed type. */
		function isTypeParam(name: String, currentType: Null<String>): Bool {
			if (currentType != null && g.types.generics.declaresTypeParam(currentType, name)) return true;
			return frames.exists(f -> (g._facts.typeParams[f.id] ?? []).contains(name));
		}

		/** Whether a binding at `from` lies inside a function on the frame stack — a local or a parameter, not a member. */
		function bindsLocally(from: Int): Bool {
			return frames.exists(f -> from >= f.span.from && from < f.span.to);
		}

		function unwrap(node: QueryNode): QueryNode {
			return BoolExprShape.unwrapParens(node, parenKind);
		}

		function unresolvedAt(span: Null<Span>, reason: UnresolvedReason, currentType: Null<String>): Void {
			if (g.facts?.muted.exists(frameId(currentType)) == true) return;
			g.unresolved.push({
				file: file,
				span: span,
				from: frameId(currentType),
				reason: reason
			});
		}

		/** The result type a value of the function type `typeSource` (`Null<…>` peeled) returns when called; null for any other type. */
		function calledResult(typeSource: Null<String>): Null<String> {
			final written: Null<TypeSyntax> = typeSource == null ? null : g._plugin.typeSyntax(typeSource);
			return CallGraphNames.functionReturnSource(written?.wrapped(['Null']) ?? written);
		}

		/** True for every field-access spelling a callee can wear: plain, null-safe, force-unwrapped. */
		function isAccessKind(kind: String): Bool {
			return kind == fieldAccessKind || (safeAccessKind != null && kind == safeAccessKind)
				|| (forceAccessKind != null && kind == forceAccessKind);
		}


		/**
		 * The static function an import of the file binds `name` to (`import p.T.f;`, `import p.T.f as name;`, `import p.T.*;`),
		 * read as a value at `span`: the first, each further one a `Ref` edge of its own — a placeholder for one the graph has
		 * not loaded, or one a type whose chain the index does not hold may declare. A static that is no function is none.
		 */
		function importedFunction(name: String, span: Span, currentType: Null<String>): Null<String> {
			final targets: Array<String> = [];
			for (s in importedOf(name, span.from).statics) {
				final id: Null<String> = CallGraphKeys.staticTarget(g, s.owner, s.member);
				if (id != null && !targets.contains(id)) targets.push(id);
			}
			for (i in 1...targets.length) g.addEdge(frameId(currentType), targets[i], Ref, null, file, span);
			return targets.length == 0 ? null : targets[0];
		}

		/**
		 * Resolve an identifier that NAMES a function — a local one, a scope-bound declaration, or a member on the type chain —
		 * and, with `imported`, a static an import of the file binds the name to (`importedFunction`).
		 */
		function identTarget(name: String, span: Null<Span>, currentType: Null<String>, imported: Bool = false): Null<String> {
			if (span == null) return null;
			final local: Null<String> = localFn(name);
			if (local != null) return local;
			final bound: Null<Int> = Refs.bindingAt(name, span.from, tree, shape);
			// a lambda's first parameter starts where the lambda does: only a local function NAMED so is what the name binds
			final fn: Null<String> = bound == null ? null : entry.fnBySpanFrom[bound];
			// a function the module declares: the one every build compiling the use runs, else none is the function named
			final module: Null<ModuleBinding> = bound != null && bound >= 0 ? null : moduleBinding(name, span, currentType);
			return if (bound != null && bound >= 0)
				fn != null && g.nodes[fn]?.name == name ? fn : null
			else if (module != null)
				module.targets.length == 1 && module.unresolved == null ? module.targets[0] : null
			else if (currentType == null)
				// module-level code sees no class's members, the main class's included: the module's own names and its imports'
				imported ? importedFunction(name, span, currentType) : null
			else
				(CallGraphKeys.staticOfSupertype(g, currentType, name) ? null : g.memberOnChain(currentType, name)) ?? (
					imported ? importedFunction(name, span, currentType) : null
				);
		}

		/**
		 * `written`, a type `owner` (`fn`) declares in `files`, keyed there (`CallGraphKeys.firstKeying`) — or, when its
		 * declarations write it differently (`each`, one per declaration), each keyed where written, all of them dispatched on
		 * (`firstKeyingEach`); the files join `readFrom`.
		 */
		function readIn(
			files: Array<String>, written: Null<String>, owner: Null<String>, ?fn: String, ?each: Array<WrittenIn>
		): Null<String> {
			for (f in files) if (!readFrom.contains(f)) readFrom.push(f);
			final unkeyed: Array<String> = g.types.generics.typeParamsOf(owner ?? '')
				.concat(fn == null ? [] : g._facts.typeParams[fn] ?? []);
			return written == null && each != null && each.length > 1
				? CallGraphKeys.firstKeyingEach(g.types.imports, g._plugin.typeSyntax, each, unkeyed, keyedApart)
				: CallGraphKeys.firstKeying(g.types.imports, g._plugin.typeSyntax, files, written, unkeyed, keyedApart);
		}

		/** The written `:Type` of `member` on `typeName`'s chain, from the index, read where declared (`readIn`); else the std's. */
		function memberTypeSource(typeName: String, member: String): Null<String> {
			if (g.types.declarationCount(typeName) == 0) return StdTypes.fieldOf(g._plugin, typeName, member);
			final owner: Null<String> = g.types.declaringTypeOf(typeName, member);
			return owner == null
				? null
				: readIn(
					g.types.imports.memberFilesOf(owner, member), g.types.memberOnChain(owner, member)?.typeSource, owner, null,
					g.types.imports.memberTypesOf(owner, member)
				);
		}

		/** The written return type of the node `target`, read where declared (`readIn`) — each one where they differ; null for none. */
		function returnSourceOf(target: String): Null<String> {
			// another signature a call may select returns another type (`@:overload`)
			if (g._facts.overloadedReturns.exists(target)) return null;
			final files: Array<String> = [for (d in g.declarationsOf(target)) d.file];
			final settled: Null<String> = g._facts.returnSources[target];
			final each: Null<Array<WrittenIn>> = settled == null && files.length > 1 ? CallGraphKeys.returnsWritten(g, target) : null;
			return readIn(files, settled, g.nodes[target]?.typeName, target, each);
		}

		/**
		 * The type whose members a value of the type parameter `name` reaches `member` on, `name` looked up where the
		 * value's type was WRITTEN — `scope` (`typeScopeOf`): the functions on the frame stack enclosing that offset,
		 * innermost first, then the enclosing type; only the type for `MEMBER_SCOPE`. A function's own `<T>` therefore
		 * never captures the `T` a field or an outer parameter was declared with. The answer is the bound of that
		 * declaration of `name` that declares `member`, or the bound when it is the only one: the value's type
		 * argument is that bound or a subtype of it, so the bound's member and every override are what the call can
		 * run. Null when the scope is unknown, when `name` is no type parameter there, when it is unbounded, or when no
		 * single nominal bound answers — an anonymous-structure bound, another parameter, several none of which
		 * declares `member`.
		 */
		function boundType(name: String, currentType: Null<String>, member: String, scope: Null<Int>): Null<String> {
			if (scope == null) return null;
			final at: Int = scope;
			var written: Null<Array<String>> = null;
			var i: Int = frames.length - 1;
			while (i >= 0 && written == null) {
				final id: String = frames[i].id;
				final span: Span = frames[i].span;
				final encloses: Bool = at != MEMBER_SCOPE && at >= span.from && at < span.to;
				if (encloses && (g._facts.typeParams[id] ?? []).contains(name)) written = g._facts.typeParamBounds[id]?.get(name) ?? [];
				i--;
			}
			if (written == null && currentType != null && g.types.generics.declaresTypeParam(currentType, name))
				written = g._facts.typeBounds[DeclarationFacts.boundsKey(file, currentType)]?.get(name) ?? [];
			if (written == null) return null;
			final bounds: Array<String> = written;
			final nominals: Array<String> = [];
			for (w in bounds) {
				final outer: Null<String> = NominalTypes.outerNominalOf(w.trim(), g._plugin.typeSyntax);
				// a bound is written in this file, by the function or the type enclosing the value's type
				if (outer != null && !isTypeParam(outer, currentType))
					nominals.push(g.types.resolveAlias(g.types.imports.typeOf(file, outer)));
			}
			final declaring: Null<String> = nominals.find(n -> g.types.declaringTypeOf(n, member) != null);
			return declaring ?? (bounds.length == 1 && nominals.length == 1 ? nominals[0] : null);
		}

		/**
		 * The nominal a written type denotes in member-lookup position: a member-transparent wrapper peeled, a
		 * typedef alias followed, the outer name kept. A type parameter in scope denotes its bound (`boundType`)
		 * when `member` names the member looked up and `scope` where the type was written, and nothing otherwise —
		 * its members belong to whatever type argument the value carries, which a declared annotation does not name.
		 */
		function nominalOf(typeSource: String, currentType: Null<String>, ?member: String, ?scope: Int): Null<String> {
			// a dotted path names a type wherever it was written: the graph keys it as that path (`CallGraphImports.pathType`)
			final path: Null<String> = keys.outerPathOf(
				NominalTypes.unwrapNullable(typeSource.trim(), transparentWrappers, g._plugin.typeSyntax), false
			);
			final outer: Null<String> = path == null ? null : g.types.imports.pathType(path);
			return if (outer == null)
				null
			else if (!isTypeParam(outer, currentType))
				g.types.resolveAlias(outer)
			else if (member == null)
				null
			else
				boundType(outer, currentType, member, scope);
		}

		/**
		 * `inherited`, arguments written in `viewType`'s own terms, as a value of `viewType` sees them: `viewType`'s
		 * parameters take `valueArgs` (the value's written arguments), stay when `viewType` is the enclosing type,
		 * and are unknown otherwise.
		 */
		function viewedArgs(
			inherited: Null<Array<String>>, viewType: String, valueArgs: Null<Array<String>>, currentType: Null<String>
		): Null<Array<String>> {
			final viewParams: Array<String> = g.types.generics.typeParamsOf(viewType);
			if (inherited == null || viewParams.length == 0 || viewType == currentType) return inherited;
			final bound: Array<String> = valueArgs != null && valueArgs.length >= viewParams.length
				? valueArgs
				: [for (_ in viewParams) CallGraph.UNKNOWN_TYPE];
			return [
				for (a in inherited) CallGraphNames.substituteTypeParams(a, viewParams, bound, g._plugin.typeSyntax)
			];
		}

		/**
		 * `written`, a type declared on `owner`, as a value of `receiverType` (written `receiverSource`) — or, for
		 * an inherited member read without a receiver, `currentType` — sees it: every type parameter of `owner` it
		 * spells, at any depth (`Array<T>` and `Null<T>` as much as `T`), replaced by the argument the receiver
		 * writes for it or the one the viewing type's `extends` chain passes (`Box<W>.item` declared `T` is `W`).
		 * Inside `owner` itself the parameters are in scope and stay, for `nominalOf` to refuse; anywhere else a
		 * parameter nothing binds becomes `UNKNOWN_TYPE`, which names no type — so a class that happens to be
		 * named like the parameter is never taken for it, while the written outer type still resolves.
		 */
		function throughParams(
			written: String, owner: Null<String>, receiverSource: Null<String>, receiverType: Null<String>, currentType: Null<String>
		): String {
			final params: Array<String> = owner == null ? [] : g.types.generics.typeParamsOf(owner);
			if (owner == null || !CallGraphNames.mentionsTypeName(written, params, g._plugin.typeSyntax)) return written;
			final viewType: Null<String> = receiverType ?? currentType;
			final ownArgs: Null<Array<String>> = receiverSource == null
				? null
				: NominalTypes.typeArgumentSourcesOf(
					NominalTypes.unwrapNullable(receiverSource.trim(), transparentWrappers, g._plugin.typeSyntax), g._plugin.typeSyntax
				);
			final args: Null<Array<String>> = if (owner == receiverType)
				ownArgs
			else if (viewType == null || viewType == owner)
				null
			else
				viewedArgs(
					g.types.generics.argumentsFor(owner, viewType, g._plugin.typeSyntax, (f, a, linking) -> readIn([f], a, linking) ?? a),
					viewType, viewType == receiverType ? ownArgs : null, currentType
				);
			return if (args != null && args.length >= params.length)
				CallGraphNames.substituteTypeParams(written, params, args, g._plugin.typeSyntax)
			else if (owner == currentType)
				written
			else
				CallGraphNames.substituteTypeParams(written, params, [for (_ in params) CallGraph.UNKNOWN_TYPE], g._plugin.typeSyntax);
		}

		/** `member`'s written type on `receiverType`'s chain as a value written `receiverSource` sees it (`throughParams`). */
		function memberTypeThrough(
			receiverSource: Null<String>, receiverType: String, member: String, currentType: Null<String>
		): Null<String> {
			final declared: Null<String> = memberTypeSource(receiverType, member);
			return declared == null
				? null
				: throughParams(declared, g.types.declaringTypeOf(receiverType, member), receiverSource, receiverType, currentType);
		}

		/**
		 * `written`, the declared return type of `target` the call `call` resolved to, as the value the call makes sees it: a
		 * type parameter of the function's type as the receiver binds it (`throughParams`), one the function declares itself
		 * (`function id<T>(x:T):T`) as the arguments bind it, the way the language infers it — the type `argType` gives every
		 * argument passed to a parameter written as that bare type parameter, when they all agree. One no argument binds, or
		 * arguments of different types bind, is `UNKNOWN_TYPE`: never the type an import of its name names (review R4 F7).
		 * Null when such a parameter shadows a type parameter of the function's type.
		 */
		function returnThrough(
			call: QueryNode, target: String, written: String, receiverSource: Null<String>, receiverType: Null<String>,
			currentType: Null<String>, argType: QueryNode -> Null<String>
		): Null<String> {
			final own: Array<String> = g._facts.typeParams[target] ?? [];
			final owner: Null<String> = g.nodes[target]?.typeName;
			final named: Bool = CallGraphNames.mentionsTypeName(written, own, g._plugin.typeSyntax);
			if (named && own.exists(p -> g.types.generics.declaresTypeParam(owner ?? '', p))) return null;
			final viewed: String = throughParams(written, owner, receiverSource, receiverType, currentType);
			if (!named) return viewed;
			final bound: Array<String> = CallGraphKeys.argumentBindings(g, target, call, argType);
			return CallGraphNames.substituteTypeParams(viewed, own, bound, g._plugin.typeSyntax);
		}

		/**
		 * The element type an index access into a value of `container`'s written type yields, per `indexedElementTypeParams` —
		 * or, with `params` handed, the one a loop over it binds per `iterationElementTypeParams` — when the container is the
		 * standard type those maps describe (`standardContainerPaths`) — the type text spells it as the file that wrote it binds it
		 * (`CallGraphImports.writtenAs`), so a project type bearing the name, or one at a std path, yields what its own members
		 * say wherever the text is read (review R5 F2, L3 G2 and G6).
		 */
		function elementTypeSource(container: String, ?params: Map<String, Int>): Null<String> {
			final path: Null<String> = NominalTypes.outerPathOf(container, transparentWrappers, g._plugin.typeSyntax);
			final element: Null<String> = NominalTypes.elementTypeSourceOf(
				container, params ?? elementParams, transparentWrappers, g._plugin.typeSyntax
			);
			return if (path == null || element == null)
				null
			else if (g.types.imports.isStandard(file, path, standardContainers[SourceText.lastSegment(path)] ?? []))
				element
			else
				null;
		}

		/**
		 * The written return type of the function `member` a value written `valueSource` declares on its type's chain, as that value
		 * sees it (`throughParams`), with the one file declaring it (null when several do); null for a member that is no
		 * function the graph holds, or one declaring type parameters.
		 */
		function memberReturn(
			valueSource: String, member: String, currentType: Null<String>
		): Null<{ written: String, file: Null<String> }> {
			final type: Null<String> = nominalOf(valueSource, currentType);
			final target: Null<String> = type == null ? null : g.memberOnChain(type, member);
			final written: Null<String> = target == null || (g._facts.typeParams[target] ?? []).length > 0 ? null : returnSourceOf(target);
			if (target == null || written == null) return null;
			final files: Array<String> = [];
			for (d in g.declarationsOf(target)) if (!files.contains(d.file)) files.push(d.file);
			return {
				written: throughParams(written, g.nodes[target]?.typeName, valueSource, type, currentType),
				file: files.length == 1 ? files[0] : null
			};
		}

		/**
		 * The type a loop over a value written `container` binds its element to: the argument a standard container names
		 * (`iterationElementTypeParams`), and for a key-value loop's value binder nothing else; otherwise what the `next()` of
		 * the iterator its `iterator()` returns yields — a standard iterator read where that `iterator()` is declared — or its
		 * own `next()`: null when neither is declared, or both disagree.
		 */
		function iterationElement(container: String, keyValue: Bool, currentType: Null<String>): Null<String> {
			final listed: Null<String> = elementTypeSource(container, iterationParams);
			if (listed != null || keyValue) return listed;
			final iterator: Null<{ written: String, file: Null<String> }> = memberReturn(container, 'iterator', currentType);
			// a return several files declare may be a standard type in one of them only: not provable
			final viaIterator: Null<String> = iterator == null
				? null
				: (iterator.file == null ? null : elementTypeSource(iterator.written, iterationParams)) ?? memberReturn(
					iterator.written, 'next', currentType
				)?.written;
			final own: Null<String> = memberReturn(container, 'next', currentType)?.written;
			return viaIterator == null || own == null || viaIterator == own ? viaIterator ?? own : null;
		}


		/**
		 * What `this` denotes inside `currentType`: the type itself, or — inside an abstract — its UNDERLYING type,
		 * seen through a typedef alias, whose members a `this.m()` there reaches — read through this file's imports, where the
		 * abstract writes it. Null for an abstract whose underlying type is unreadable.
		 */
		function selfTypeOf(currentType: Null<String>): Null<String> {
			if (currentType == null || !g._facts.abstracts.exists(currentType)) return currentType;
			final underlying: Null<String> = g._facts.abstracts[currentType];
			return underlying == null || g.types.generics.declaresTypeParam(currentType, underlying)
				? underlying
				: g.types.resolveAlias(g.types.imports.typeOf(file, underlying));
		}

		/** The type `recvRaw` names when it is a bare type-like identifier that binds to nothing (as the graph keys it), else null. */
		function typeNameReceiver(recvRaw: QueryNode): Null<String> {
			final recv: QueryNode = unwrap(recvRaw);
			final raw: Null<String> = recv.name;
			final span: Null<Span> = recv.span;
			if (recv.kind != identKind || raw == null || span == null) return null;
			final name: String = raw;
			if (!CallGraphNames.isTypeLike(name)) return null;
			final bound: Null<Int> = Refs.bindingAt(name, span.from, tree, shape);
			return bound == null || bound < 0 ? g.types.imports.typeOf(file, name) : null;
		}

		// an identifier other than `this` that binds to nothing: the root of a package path, say
		final unboundIdent: QueryNode -> Bool = n ->
			n.kind == identKind && n.name != selfText && (Refs.bindingAt(n.name ?? '', n.span?.from ?? -1, tree, shape) ?? -1) < 0;

		// bound once `receiverType` exists (below): the target of a call and the receiver it was made on
		var callTargetOf: (QueryNode, Null<String>) -> Null<CallTarget> = (call, currentType) -> null;

		/**
		 * Where the DECLARED type `typeSourceOf` reads for `exprRaw` was written, for looking up a type parameter it
		 * names (`boundType`): the binding offset of a local or a parameter, `MEMBER_SCOPE` for `this` and a member
		 * (read bare, and every link of a field path, an element or a call result rooted at one, which takes its
		 * arguments from that root's type), a local function's own declaration for a call to it. Null where that is
		 * unknown — a static read off a type, any other shape.
		 */
		function typeScopeOf(exprRaw: QueryNode, currentType: Null<String>): Null<Int> {
			final expr: QueryNode = unwrap(exprRaw);
			final name: Null<String> = expr.name;
			final span: Null<Span> = expr.span;
			if (expr.kind == identKind && name != null) {
				if (name == selfText) return MEMBER_SCOPE;
				if (span == null) return null;
				final bound: Null<Int> = Refs.bindingAt(name, span.from, tree, shape);
				return if (bound != null && bound >= 0)
					bindsLocally(bound) ? bound : MEMBER_SCOPE
				else if (CallGraphNames.isTypeLike(name))
					null
				else
					MEMBER_SCOPE;
			}
			if (isAccessKind(expr.kind) && name != null && expr.children.length > 0)
				return typeNameReceiver(expr.children[0]) != null ? null : typeScopeOf(expr.children[0], currentType);
			if (indexKind != null && expr.kind == indexKind && expr.children.length > 0) return typeScopeOf(expr.children[0], currentType);
			if (expr.kind != callKind || expr.children.length <= 0) return null;
			final callee: QueryNode = unwrap(expr.children[0]);
			if (isAccessKind(callee.kind) && callee.children.length > 0) return typeScopeOf(callee.children[0], currentType);
			final target: Null<String> = callTargetOf(expr, currentType)?.target;
			final declaredAt: Null<Span> = target == null ? null : g.nodes[target]?.span;
			return if (target == null || declaredAt == null)
				null
			// a local function's return type is written inside the functions enclosing it; a member's, on the member
			else if (target.contains('#'))
				declaredAt.from
			else
				MEMBER_SCOPE;
		}

		// the graph's resolution for the ONE structural walk (`TypingService.typeWalk`), set right below `typeSourceOf`'s arms
		var graphTyping: Null<TypingHost<String, Null<String>>> = null;
		// the bindings whose unannotated type the walk is reading, against a cycle (`TypingHost.reading`)
		final unannotatedReads: Array<Int> = [];

		/**
		 * The DECLARED type source of a value expression the receiver arms below do not name, as the graph keys it — the
		 * shared walk (`TypingService.typeWalk`) over the graph's resolution (`graphTyping`): an identifier's own annotation
		 * (or, for a local written with none, the call initialising it), an inherited field read without `this` (through the
		 * index), each link of a field path, an element `a[i]` of a container whose written type names its element, a call's
		 * declared return and a construction. Never an inferred type: an unannotated link answers null.
		 */
		function typeSourceOf(exprRaw: QueryNode, currentType: Null<String>): Null<String> {
			final host: Null<TypingHost<String, Null<String>>> = graphTyping;
			if (host == null) throw new Exception('the graph typing host is set before the walk types anything');
			return TypingService.typeWalk(exprRaw, shape, host, currentType);
		}

		/**
		 * `typeSourceOf` for an identifier that binds no value: a member of the enclosing type's chain read bare — never a
		 * supertype's static —, else the module-level value every build compiling the read declares (one only some declare: null,
		 * `moduleReceivers`), else a static an import binds by its own name; never a type-like name.
		 */
		function unboundTypeSource(ident: QueryNode, currentType: Null<String>): Null<String> {
			final name: Null<String> = ident.name;
			final span: Null<Span> = ident.span;
			if (name == null || span == null) return null;
			if (CallGraphNames.isTypeLike(name)) return null;
			final values: Null<ModuleValues> = moduleValuesOf(name, span.from);
			if (values != null && values.decls.length > 0 && !CallGraphKeys.memberMayBind(g, currentType, name))
				return values.decls.length == 1 && values.imported == null ? typeSources[values.decls[0].span.from] : null;
			// a static an import binds by its own name (`import p.T.*;`): its type, read where it is declared
			final imported: Null<{ owner: String, member: String }> = CallGraphKeys.importedStatic(
				g, importedOf(name, span.from), name, currentType
			);
			return if (imported != null)
				memberTypeSource(imported.owner, imported.member)
			// a supertype's static is not in scope bare
			else if (currentType == null || CallGraphKeys.staticOfSupertype(g, currentType, name))
				null
			else
				memberTypeThrough(null, currentType, name, currentType);
		}

		/** `typeSourceOf` for a field access: a static member read off a type name no local shadows, else the receiver's member. */
		function accessTypeSource(expr: QueryNode, currentType: Null<String>): Null<String> {
			final name: Null<String> = expr.name;
			if (name == null) return null;
			final staticOwner: Null<String> = typeNameReceiver(expr.children[0]);
			if (staticOwner != null && g.types.isStatic(staticOwner, name)) return memberTypeSource(staticOwner, name);
			final inner: Null<String> = typeSourceOf(expr.children[0], currentType);
			if (inner == null) return null;
			final innerSource: String = inner;
			final innerType: Null<String> = nominalOf(innerSource, currentType, name, typeScopeOf(expr.children[0], currentType));
			return innerType == null ? null : memberTypeThrough(innerSource, innerType, name, currentType);
		}

		/**
		 * The written return type of the target `call` resolved `expr` to, as the receiver it was made on sees it (`returnThrough`);
		 * null when the DECLARED return's outer type is one of `refused` — before its type parameters are bound, so a `T` a call
		 * binds to `Null<X>` is no refusal.
		 */
		function targetReturnSource(expr: QueryNode, call: CallTarget, currentType: Null<String>, ?refused: Array<String>): Null<String> {
			final returned: Null<String> = returnSourceOf(call.target) ?? StdTypes.returnOf(g._plugin, g.nodes[call.target]);
			final outer: Null<String> = returned == null ? null : NominalTypes.outerNominalOf(returned.trim(), g._plugin.typeSyntax);
			return returned == null || outer != null && (refused ?? []).contains(outer)
				? null
				: returnThrough(
					expr, call.target, returned, call.receiverSource, call.onType, currentType, a -> typeSourceOf(a, currentType)
				);
		}
		/**
		 * `typeSourceOf` for a call: its target's written return type, as the receiver it was made on sees it; for a value no
		 * function declaration names — a field, a parameter, a call's result — what its function type says.
		 */
		function callTypeSource(expr: QueryNode, currentType: Null<String>): Null<String> {
			final call: Null<CallTarget> = callTargetOf(expr, currentType);
			return call == null ? calledResult(typeSourceOf(expr.children[0], currentType)) : targetReturnSource(expr, call, currentType);
		}

		graphTyping = {
			peel: (node, _) -> unwrap(node),
			isAccess: (kind, _) -> isAccessKind(kind),
			literal: null,
			self: (_, currentType) -> selfTypeOf(currentType),
			binding: (ident, _) -> {
				final name: Null<String> = ident.name;
				final span: Null<Span> = ident.span;
				final bound: Null<Int> = name == null || span == null ? null : Refs.bindingAt(name, span.from, tree, shape);
				bound != null && bound >= 0 ? bound : null;
			},
			bound: (from, _) -> typeSources[from],
			// a local written with no type holds its initializer's type (`NominalTypes.localInitializer`)
			initializer: (_, use, _) -> NominalTypes.localInitializer(use, tree, shape, typeSources),
			loopElement: (_, _) -> null,
			// a lambda's untyped parameter is typed into `typeSources` as the walk reaches the lambda (`typeLambdaParams`), so `bound`
			// answers it
			parameter: null,
			unbound: unboundTypeSource,
			access: accessTypeSource,
			element: (container, _) -> elementTypeSource(container),
			call: callTypeSource,
			// a value a `new` makes is of the type it names, read where written — its type arguments left to what the language infers
			construction: (made, _) -> {
				final at: Null<Span> = made.span;
				final name: Null<String> = made.name;
				at == null || name == null ? null : keys.keyed(name, at.from);
			},
			arithmetic: null,
			reading: _ -> unannotatedReads
		};

		/**
		 * Receiver classification: the simple type name plus whether the
		 * receiver is a VALUE (instance dispatch — virtual expansion applies)
		 * or a TYPE (static dispatch), and whether it is declared `Dynamic` /
		 * `Any` (dispatch by name). Null when unrecoverable. `member` is the member looked up on the receiver:
		 * a receiver typed by a type parameter in scope is typed by its bound only when it is given (`nominalOf`).
		 */
		function receiverType(recvRaw: QueryNode, currentType: Null<String>, ?member: String): Null<Receiver> {
			final recv: QueryNode = unwrap(recvRaw);
			final name: Null<String> = recv.name;
			// a receiver that is itself a CALL takes the callee's DECLARED return type —
			// an annotation the source carries, never an inferred one; a nullable /
			// dynamic wrapper names no dispatchable type and stays unresolved
			// a call of a value no function declaration names is typed by the value's function type, below
			final call: Null<CallTarget> = recv.kind == callKind && recv.children.length > 0 ? callTargetOf(recv, currentType) : null;
			if (call != null) {
				// a nullable / dynamic wrapper the declaration returns names no dispatchable type
				final written: Null<String> = targetReturnSource(recv, call, currentType, nullableWrappers);
				final returned: Null<String> = written == null
					? null
					: nominalOf(written, currentType, member, typeScopeOf(recv, currentType));
				return returned == null || nullableWrappers.contains(returned) ? null : {
					typeName: returned,
					isValue: true,
					isDynamic: false
				};
			}
			if (recv.kind == identKind && name != null) {
				final span: Null<Span> = recv.span;
				if (name == selfText) {
					final underlying: Null<String> = selfTypeOf(currentType);
					// an abstract over one of its own type parameters (`abstract W<T:A>(T)`) is a value of that bound
					final self: Null<String> = underlying != null && currentType != null
						&& g.types.generics.declaresTypeParam(currentType, underlying)
						? (member == null ? null : boundType(underlying, currentType, member, MEMBER_SCOPE))
						: underlying;
					return self == null ? null : {
						typeName: self,
						isValue: true,
						isDynamic: false
					};
				}
				if (name == 'super') {
					final superclass: Null<String> = currentType == null ? null : g.types.superclassOf(currentType);
					return superclass == null ? null : {
						typeName: superclass,
						isValue: false,
						isDynamic: false
					};
				}
				// a value's declared type is the walk's (below); a bare type-like name binding nothing is a TYPE receiver
				if (span != null) {
					final bound: Null<Int> = Refs.bindingAt(name, span.from, tree, shape);
					if ((bound == null || bound < 0) && CallGraphNames.isTypeLike(name)) return {
						typeName: g.types.imports.typeOf(file, name),
						isValue: false,
						isDynamic: false
					};
				}
			} else if (
				isAccessKind(recv.kind) && name != null && CallGraphNames.isTypeLike(name) && typeSourceOf(recv, currentType) == null
			) {
				return {
					typeName: g.types.imports.pathType(CallGraphKeys.packagePathOf(recv, n -> isAccessKind(n.kind), unboundIdent) ?? name),
					isValue: false,
					isDynamic: false
				};
			}
			final written: Null<String> = typeSourceOf(recv, currentType);
			final nominal: Null<String> = written == null ? null : nominalOf(written, currentType, member, typeScopeOf(recv, currentType));
			return nominal == null ? null : {
				typeName: nominal,
				isValue: true,
				isDynamic: nullableWrappers.contains(nominal)
			};
		}

		/**
		 * Each receiver the bare name `recvRaw` a call of `member` is made on may be when only some builds compiling it declare
		 * the module-level value of the name and no member may be meant (`unboundTypeSource`): each declaration's written type,
		 * and the imported static's in the builds declaring none (no such build compiles when no import binds it). Null for any
		 * other receiver, or when one is untyped or the imports may bind more than one: the receiver is then unresolved.
		 */
		function moduleReceivers(recvRaw: QueryNode, currentType: Null<String>, member: String): Null<Array<Receiver>> {
			final recv: QueryNode = unwrap(recvRaw);
			final rawName: Null<String> = recv.name;
			final span: Null<Span> = recv.span;
			if (recv.kind != identKind || rawName == null || span == null || rawName == selfText) return null;
			final name: String = rawName;
			if (CallGraphNames.isTypeLike(name) || (Refs.bindingAt(name, span.from, tree, shape) ?? -1) >= 0) return null;
			final values: Null<ModuleValues> = moduleValuesOf(name, span.from);
			final imported: Null<ImportedStatics> = values?.imported;
			if (values == null || imported == null || values.decls.length == 0 || CallGraphKeys.memberMayBind(g, currentType, name))
				return null;
			if (imported.unknown || imported.statics.length > 1) return null;
			final written: Array<Null<String>> = [for (d in values.decls) typeSources[d.span.from]];
			for (s in imported.statics) written.push(memberTypeSource(s.owner, s.member));
			final out: Array<Receiver> = [];
			for (w in written) {
				final nominal: Null<String> = w == null ? null : nominalOf(w, currentType, member, typeScopeOf(recv, currentType));
				if (nominal == null || nullableWrappers.contains(nominal)) return null;
				final typeName: String = nominal;
				if (!out.exists(r -> r.typeName == typeName)) out.push({ typeName: typeName, isValue: true, isDynamic: false });
			}
			return out;
		}

		/**
		 * `receiverRaw` as the member it names — a bare field, or a field read off a receiver whose type the graph
		 * recovers (`this.f`, a static `T.f`, `o.f` on a typed `o`) — spelled `Owner.f`; null for anything else.
		 */
		function receiverField(receiverRaw: QueryNode, currentType: Null<String>): Null<String> {
			final receiver: QueryNode = unwrap(receiverRaw);
			final name: Null<String> = receiver.name;
			if (name == null) return null;
			var owner: Null<String> = null;
			if (receiver.kind == identKind) {
				final span: Null<Span> = receiver.span;
				if (span == null || name == selfText) return null;
				final bound: Null<Int> = Refs.bindingAt(name, span.from, tree, shape);
				// a local or a parameter is a value some other binding may alias: no member names it
				if (bound != null && bound >= 0 && bindsLocally(bound)) return null;
				owner = currentType;
			} else if (isAccessKind(receiver.kind) && receiver.children.length > 0) {
				final base: Null<Receiver> = receiverType(receiver.children[0], currentType, name);
				owner = base == null || base.isDynamic ? null : base.typeName;
			}
			// a property with an accessor hands back whatever its getter returns, not one stored object
			return owner == null || !g.types.fieldOnChain(owner, name) || g.types.propertyOnChain(owner, name) != null
				? null
				: '${g.types.declaringTypeOf(owner, name) ?? owner}.$name';
		}

		/**
		 * Type the binder of the loop `loop` by what its iterable yields (`iterationElement`): the element binder of a plain
		 * loop, the VALUE binder of a key-value one — never its key binder, which binds the container's key or an index.
		 */
		function typeLoopBinder(loop: QueryNode, currentType: Null<String>): Void {
			final valueBinder: Null<QueryNode> = NominalTypes.iterationValueBinder(loop, valueBinderKinds);
			final binder: Null<Span> = valueBinder == null ? loop.span : valueBinder.span;
			final iterable: Null<QueryNode> = NominalTypes.iterationIterable(loop, valueBinderKinds);
			if (binder == null || iterable == null || typeSources.exists(binder.from)) return;
			final container: Null<String> = typeSourceOf(iterable, currentType);
			final element: Null<String> = container == null ? null : iterationElement(container, valueBinder != null, currentType);
			if (element != null) typeSources[binder.from] = element;
		}

		callTargetOf = (call, currentType) -> {
			final inner: QueryNode = unwrap(call.children[0]);
			final innerName: Null<String> = inner.name;
			if (innerName == null) return null;
			if (inner.kind == identKind) {
				final target: Null<String> = identTarget(innerName, inner.span, currentType);
				if (target != null) return { target: target, receiverSource: null, onType: currentType };
				// a static function an import binds by its own name, called bare
				final imported: Null<{ owner: String, member: String }> = unboundIdent(inner)
					? CallGraphKeys.importedStatic(g, importedOf(innerName, inner.span?.from), innerName, currentType)
					: null;
				final made: Null<String> = imported == null ? null : CallGraphKeys.staticTarget(g, imported.owner, imported.member);
				return imported == null || made == null ? null : { target: made, receiverSource: null, onType: imported.owner };
			}
			if (!isAccessKind(inner.kind) || inner.children.length == 0) return null;
			final innerRecv: Null<Receiver> = receiverType(inner.children[0], currentType, innerName);
			// a member of a type no indexed declaration bears is a placeholder, whose std signature `StdTypes` may read
			final target: Null<String> = innerRecv == null || innerRecv.isDynamic
				? null
				: g.memberOnChain(innerRecv.typeName, innerName) ?? (
					g.types.declarationCount(innerRecv.typeName) == 0 ? g.externalNode(innerRecv.typeName, innerName) : null
				);
			return target == null ? null : {
				target: target,
				receiverSource: typeSourceOf(inner.children[0], currentType),
				onType: innerRecv?.typeName
			};
		};

		/**
		 * Resolve a method referenced as a VALUE (`handler`, `this.m`, `obj?.m`) to its node — an external
		 * placeholder when the declaring type's body is not loaded yet, upgraded if it arrives — together with
		 * the receiver type an instance reference dispatches on.
		 */
		function methodRef(argRaw: QueryNode, currentType: Null<String>): Null<MethodRef> {
			final arg: QueryNode = unwrap(argRaw);
			final name: Null<String> = arg.name;
			if (name == null) return null;
			if (arg.kind == identKind) {
				final module: Null<ModuleBinding> = bareModuleBinding(name, arg.span, currentType);
				if (module != null)
					return module.targets.length == 0 ? null : { id: module.targets[0], dispatch: null, bodies: module.targets };
				final target: Null<String> = identTarget(name, arg.span, currentType, true);
				if (target == null) return null;
				final member: Bool = currentType != null && g.memberOnChain(currentType, name) == target;
				final dispatch: Null<String> = member && !g.types.isStatic(g.nodes[target]?.typeName ?? '', name) ? currentType : null;
				return { id: target, dispatch: dispatch };
			}
			if (!isAccessKind(arg.kind) || arg.children.length <= 0) return null;
			final recv: Null<Receiver> = receiverType(arg.children[0], currentType, name);
			if (recv == null || recv.isDynamic) return null;
			final resolved: Null<String> = g.memberOnChain(recv.typeName, name);
			final dispatch: Null<String> = recv.isValue ? recv.typeName : null;
			return if (resolved != null)
				{ id: resolved, dispatch: dispatch }
			else if (g.types.functionOnChain(recv.typeName, name) || !g.types.chainFullyIndexed(recv.typeName))
				{ id: g.externalNode(g.types.declaringTypeOf(recv.typeName, name) ?? recv.typeName, name), dispatch: dispatch }
			else
				null;
		}

		function methodValue(argRaw: QueryNode, currentType: Null<String>): Null<String> {
			return methodRef(argRaw, currentType)?.id;
		}

		/**
		 * A `Ref` edge to the method `ref` names, plus one to each override an instance reference may dispatch to; each
		 * marked with the `dynamic` member `storedInto` when the value is assigned to one, and with where the call `via`
		 * writes it (`argument`) when it is an argument.
		 */
		function refEdges(
			from: String, ref: MethodRef, via: Null<String>, span: Null<Span>, ?storedInto: String, ?viaMember: String,
			?argument: ArgumentPosition
		): Void {
			// a module-level function's use bound per build names exactly the bodies it may run
			final bodies: Null<Array<String>> = ref.bodies;
			if (bodies != null) {
				for (body in bodies)
					g.addEdge(from, body, Ref, via, file, span, null, null, null, null, storedInto, viaMember, argument, true);
				return;
			}
			g.addEdge(from, ref.id, Ref, via, file, span, ref.dispatch, null, null, null, storedInto, viaMember, argument);
			final dispatch: Null<String> = ref.dispatch;
			final name: Null<String> = g.nodes[ref.id]?.name;
			if (dispatch != null && name != null) for (v in g.virtualTargets(dispatch, name))
				g.addEdge(from, v, Ref, via, file, span, dispatch, null, null, null, storedInto, viaMember, argument);
		}

		/** The `dynamic` method the assignment target `target` names, when the graph holds its body; null for any other target. */
		function dynamicSlot(target: QueryNode, currentType: Null<String>): Null<String> {
			final ref: Null<MethodRef> = methodRef(target, currentType);
			final slot: Null<FnNode> = ref == null ? null : g.nodes[ref.id];
			return slot != null && slot.isDynamic && !slot.isExternal ? slot.id : null;
		}

		function resolveBareCallee(name: String, span: Null<Span>, currentType: Null<String>): Null<String> {
			if (name == 'super') {
				final found: Null<String> = currentType == null ? null : g.types.superclassOf(currentType);
				if (found == null) return null;
				final superclass: String = found;
				// two declarations of the name: which one the header means is not provable by simple name
				if (g.types.declarationCount(superclass) > 1) {
					unresolvedAt(span, UnresolvedReceiver(ctorName), currentType);
					return null;
				}
				final target: Null<String> = g.constructorTarget(superclass, ctorName);
				g._wiring.record({
					typeName: superclass,
					from: frameId(currentType),
					kind: Call,
					file: file,
					span: span,
					chainGrew: false,
					target: target
				});
				return target;
			}
			final local: Null<String> = localFn(name);
			if (local != null) return local;
			if (span != null) {
				final bound: Null<Int> = Refs.bindingAt(name, span.from, tree, shape);
				if (bound != null && bound >= 0) {
					final fn: Null<String> = entry.fnBySpanFrom[bound];
					if (fn != null) return fn;
					unresolvedAt(span, FunctionValue(name), currentType);
					return null;
				}
			}
			// a supertype's static is not in scope bare: the name is the module's or an import's; and module-level code sees no
			// class's members at all — the module's main class shares the module's name, never its scope (review L3 G5)
			final hidden: Bool = currentType != null && CallGraphKeys.staticOfSupertype(g, currentType, name);
			final inherited: Null<String> = currentType == null || hidden ? null : g.memberOnChain(currentType, name);
			if (inherited != null) return inherited;
			// a module-level function is registered under the module pseudo-type,
			// which the enclosing-type chain does not reach from inside a class
			if (currentType != null) {
				// the module's pseudo-type shares its main class's name: only what it declares itself, never its supertypes' members
				final moduleFn: Null<String> = CallGraphKeys.declaredOn(g, moduleType, name);
				if (moduleFn != null) return moduleFn;
				// an inherited FIELD called as a function: its value is a function the program stored
				if (!hidden && g.types.fieldOnChain(currentType, name)) {
					unresolvedAt(span, FunctionValue(name), currentType);
					return null;
				}
				// a method a supertype the graph has not loaded declares: a placeholder, upgraded when that file arrives
				final declaring: Null<String> = !hidden && g.types.functionOnChain(currentType, name)
					? g.types.declaringTypeOf(currentType, name)
					: null;
				if (declaring != null) return g.externalNode(declaring, name);
			}
			// an imported static: `import p.T.f;` or `import p.T.*;` — every type that may be meant, a placeholder for one the
			// index does not list
			final imported: ImportedStatics = importedOf(name, span?.from);
			final targets: Array<String> = [
				for (s in imported.statics) g.memberOnChain(s.owner, s.member) ?? g.externalNode(s.owner, s.member)
			];
			if (targets.length > 0) {
				for (i in 1...targets.length) g.addEdge(frameId(currentType), targets[i], Call, null, file, span);
				// a build that declares a module-level value of the name calls the function it holds
				final declared: Bool = span != null && (moduleValuesOf(name, span.from)?.decls.length ?? 0) > 0;
				if (imported.unknown || declared) unresolvedAt(span, UnboundName(name), currentType);
				return targets[0];
			}
			// an enum constructor builds a value and runs nothing — the language finds one by the expected type, imported or
			// not — but only when nothing else can supply the name: a static function the index holds, or a wildcard import
			// of a type whose statics it cannot list; any other unbound bare call may be a function the graph did not see
			if (imported.unknown || !g.types.imports.isEnumConstructor(name) || g.types.hasStaticFunctionNamed(name))
				unresolvedAt(span, UnboundName(name), currentType);
			return null;
		}

		/**
		 * Whether `field` read off `recv` is a stored value that can never be a method: `recv` is written as an
		 * anonymous structure (inline or through a typedef) whose `field` is declared with a type no function has.
		 */
		function storedField(recv: QueryNode, field: String, currentType: Null<String>): Bool {
			final declared: Null<String> = typeSourceOf(recv, currentType);
			if (declared == null) return false;
			final peeled: String = NominalTypes.unwrapNullable(declared.trim(), transparentWrappers, g._plugin.typeSyntax);
			final outer: Null<String> = NominalTypes.outerNominalOf(peeled, g._plugin.typeSyntax);
			final anon: Null<String> = outer == null ? peeled : g.types.resolveAlias(outer);
			final fieldType: Null<String> = if (anon == peeled)
				CallGraphNames.anonFieldTypeSource(g._plugin.typeSyntax(peeled), field)
			else if (anon != null && g.types.holdsNoFunction(anon) && g.types.declarationCount(anon) > 0)
				g.types.memberOnChain(anon, field)?.typeSource
			else
				null;
			if (fieldType == null || g._plugin.typeSyntax(fieldType)?.holdsFunction() != false) return false;
			final nominal: Null<String> = nominalOf(fieldType, currentType);
			return nominal != null && g.types.holdsNoFunction(nominal);
		}

		/** A method read off a receiver the graph cannot type: whatever runs the value later may run any function so named. */
		function untypedMethodRead(node: QueryNode, currentType: Null<String>): Void {
			final rawName: Null<String> = node.name;
			if (rawName == null || !isAccessKind(node.kind) || node.children.length == 0) return;
			final name: String = rawName;
			if (!(g._byMember.exists(name) || g.types.hasFunctionNamed(name))) return;
			if (storedField(node.children[0], name, currentType)) return;
			final recv: Null<Receiver> = receiverType(node.children[0], currentType, name);
			if ((recv == null || recv.isDynamic) && g.facts?.muted.exists(frameId(currentType)) != true) g.unresolvedAccess.push({
				file: file,
				span: node.span,
				from: frameId(currentType),
				member: name,
				write: false,
				dynamicReceiver: recv != null
			});
		}

		/**
		 * The function values `args` (from `first` on) hand the callee
		 * `calleeId`, written `calleeName`: lambdas, method values, `.bind` results, both ternary arms — each marked with where
		 * the call writes it (`ArgumentPosition`, counted from `first`).
		 */
		function scanArgs(
			args: Array<QueryNode>, first: Int, calleeId: Null<String>, calleeName: Null<String>, currentType: Null<String>
		): Void {
			final from: String = frameId(currentType);
			function refArg(argRaw: QueryNode, at: ArgumentPosition): Void {
				final arg: QueryNode = unwrap(argRaw);
				// a ternary-valued argument hands BOTH branch function-values to
				// the callee — each branch is a callback in its own right
				if (ternaryKind != null && arg.kind == ternaryKind && arg.children.length == 3) {
					refArg(arg.children[1], at);
					refArg(arg.children[2], at);
					return;
				}
				final argSpan: Null<Span> = arg.span;
				if (argSpan != null && lambdaKinds.contains(arg.kind)) {
					final lambdaId: Null<String> = entry.fnBySpanFrom[argSpan.from];
					if (lambdaId != null)
						g.addEdge(from, lambdaId, Ref, calleeId, file, argSpan, null, null, null, null, null, calleeName, at);
					return;
				}
				if (arg.kind == callKind && arg.children.length > 0) {
					final inner: QueryNode = unwrap(arg.children[0]);
					if (isAccessKind(inner.kind) && inner.name == 'bind' && inner.children.length > 0) {
						final ref: Null<MethodRef> = methodRef(inner.children[0], currentType);
						if (ref != null && argSpan != null) {
							refEdges(from, ref, calleeId, argSpan, null, calleeName, at);
							consumedBindCalls.push(argSpan.from);
						}
					}
					return;
				}
				if (arg.kind != identKind && !isAccessKind(arg.kind)) return;
				final ref: Null<MethodRef> = methodRef(arg, currentType);
				if (ref != null)
					refEdges(from, ref, calleeId, argSpan, null, calleeName, at);
				else
					untypedMethodRead(arg, currentType);
			}
			for (i in first ... args.length) refArg(args[i], { index: i - first, count: args.length - first });
		}

		/**
		 * Virtual dispatch targets for a BARE call inside `typeName` — the implicit-`this` case,
		 * where `resolved` is the node the bare name already resolved to. Empty unless that node
		 * is a NON-STATIC member on the type's own chain: a local function, a module-level
		 * function and `super` each yield an id `memberOnChain` never returns, and Haxe neither
		 * inherits nor overrides a static, so a same-named static on a subtype is a DIFFERENT
		 * function that dispatch can never reach.
		 */
		function implicitThisTargets(typeName: Null<String>, member: String, resolved: String): Array<String> {
			if (typeName == null || g.memberOnChain(typeName, member) != resolved) return [];
			final owner: String = g.nodes[resolved]?.typeName ?? typeName;
			return g.types.isStatic(owner, member) ? [] : g.virtualTargets(typeName, member);
		}

		/**
		 * The edges of a call of `calleeName` at `span` on a receiver of the type `written` (`field` the member the receiver
		 * reads, if any): the member the chain declares, or the one a `@:forward` abstract routes it to, with every override a
		 * value dispatches to; a static extension a `using` brings in when no indexed type on the chain declares it; nothing
		 * for a field, whose function value the call runs. The node the call names, or null.
		 */
		function dispatchOn(
			written: Receiver, calleeName: String, span: Null<Span>, field: Null<String>, currentType: Null<String>
		): Null<String> {
			final from: String = frameId(currentType);
			// a `@:forward` abstract routes a member it does not declare to its underlying value: the type the abstract's own file
			// names, seen through an alias — none for a type parameter of the abstract, whose members are the type argument's
			final simple: Null<String> = g.memberOnChain(written.typeName, calleeName) == null
				&& g.types.memberOnChain(written.typeName, calleeName) == null
				? g.types.meta.forwardedTo(written.typeName, calleeName)
				: null;
			final forwarded: Null<String> = simple == null || g.types.generics.declaresTypeParam(written.typeName, simple)
				? null
				: g.types.resolveAlias(g.types.imports.keyedWhereWritten(g.types.meta.forwardsWritten(written.typeName), simple));
			final recv: Receiver = forwarded == null ? written : { typeName: forwarded, isValue: true, isDynamic: false };
			final resolved: Null<String> = g.memberOnChain(recv.typeName, calleeName);
			if (resolved == null && g.types.fieldOnChain(recv.typeName, calleeName)) {
				unresolvedAt(span, FunctionValue(calleeName), currentType);
				return null;
			}
			if (
				resolved == null && recv.isValue && g.types.chainFullyIndexed(recv.typeName)
				&& g.types.memberOnChain(recv.typeName, calleeName) == null
			) {
				// no indexed type on the chain declares it: a static extension a `using` brings in, else unresolved
				final extensions: Array<String> = g.types.imports.staticExtensionsOf(file, calleeName);
				// a type on the chain that brings extensions in itself (`@:using`) may supply one no import names
				final bringing: Null<String> = g.types.firstOnChain(recv.typeName, t -> g.types.meta.bringsExtensions(t));
				if (bringing != null)
					unresolvedAt(span, Unseen('the static extension `$calleeName` the extensions of `$bringing` may supply'), currentType)
				else if (extensions.length == 0)
					unresolvedAt(span, UnresolvedReceiver(calleeName), currentType);
				var extended: Null<String> = null;
				for (extension in extensions) {
					final target: String = g.memberOnChain(extension, calleeName) ?? g.externalNode(extension, calleeName);
					g.addEdge(from, target, Call, null, file, span);
					extended = target;
				}
				return extended;
			}
			// a placeholder names the type the index says declares it, which is the node its file upgrades
			final target: String = resolved ?? g.externalNode(
				g.types.declaringTypeOf(recv.typeName, calleeName) ?? recv.typeName, calleeName
			);
			g.addEdge(from, target, Call, null, file, span, recv.isValue ? recv.typeName : null, field);
			if (recv.isValue) for (v in g.virtualTargets(recv.typeName, calleeName))
				g.addEdge(from, v, Virtual, null, file, span, recv.typeName, field);
			if (g.nodes[target]?.isDynamic == true) unresolvedAt(span, FunctionValue(calleeName), currentType);
			return target;
		}

		function handleCall(call: QueryNode, currentType: Null<String>): Void {
			final from: String = frameId(currentType);
			final span: Null<Span> = call.span;
			final callee: QueryNode = unwrap(call.children[0]);
			final calleeName: Null<String> = callee.name;
			var calleeId: Null<String> = null;
			final module: Null<ModuleBinding> = callee.kind == identKind && calleeName != null
				? bareModuleBinding(calleeName, callee.span, currentType)
				: null;
			if (module != null) {
				// a module-level function's call bound per build runs exactly the bodies its builds compile
				for (target in module.targets) g.addEdge(from, target, Call, null, file, span, null, null, null, null, null, null, true);
				final reason: Null<UnresolvedReason> = module.unresolved;
				if (reason != null) unresolvedAt(span, reason, currentType);
				calleeId = module.targets.length == 1 && reason == null ? module.targets[0] : null;
			} else if (callee.kind == identKind && calleeName != null) {
				calleeId = resolveBareCallee(calleeName, callee.span, currentType);
				if (calleeId != null) {
					final implicitThis: Array<String> = implicitThisTargets(currentType, calleeName, calleeId);
					// a placeholder for a member a supertype not loaded yet declares is on the chain too
					final placeholder: Bool = g.nodes[calleeId]?.isExternal == true && currentType != null
						&& g.types.declaringTypeOf(currentType, calleeName) == g.nodes[calleeId]?.typeName;
					final dispatched: Bool = currentType != null && (g.memberOnChain(currentType, calleeName) == calleeId || placeholder)
						&& !g.types.isStatic(g.nodes[calleeId]?.typeName ?? currentType, calleeName);
					g.addEdge(from, calleeId, Call, null, file, span, dispatched ? currentType : null);
					// a bare call to an instance member IS `this.m()` — same dispatch, same edges
					for (v in implicitThis) g.addEdge(from, v, Virtual, null, file, span, currentType);
					if (g.nodes[calleeId]?.isDynamic == true) unresolvedAt(span, FunctionValue(calleeName), currentType);
				}
			} else if (isAccessKind(callee.kind)) {
				if (calleeName != null && callee.children.length > 0) {
					if (calleeName == 'bind') {
						final callSpan: Null<Span> = call.span;
						if (callSpan == null || !consumedBindCalls.contains(callSpan.from)) {
							final ref: Null<MethodRef> = methodRef(callee.children[0], currentType);
							if (ref != null) refEdges(from, ref, null, span);
						}
					} else {
						readFrom.resize(0);
						keyedApart.resize(0);
						final written: Null<Receiver> = receiverType(callee.children[0], currentType, calleeName);
						// a module-level value only some builds declare is one receiver per build
						final each: Array<Receiver> = written == null
							? moduleReceivers(callee.children[0], currentType, calleeName) ?? []
							: [written];
						if (each.length == 0) {
							unresolvedAt(span, UnresolvedReceiver(calleeName), currentType);
						} else if (written != null && written.isDynamic) {
							unresolvedAt(span, DynamicReceiver(calleeName), currentType);
						} else {
							final field: Null<String> = receiverField(callee.children[0], currentType);
							for (recv in each) {
								// each type the receiver may be — a name this file or one
								// whose declaration typed it wrote (`readFrom`) may be
								// another type there — resolves the call on its own, whatever the others declare
								final alternates: Array<String> = g.types.imports.alternateTypesIn([file].concat(readFrom), recv.typeName);
								for (t in CallGraphKeys.apartFrom(g.types.imports, keyedApart, recv.typeName)) if (!alternates.contains(t))
									alternates.push(t);
								for (type in [recv.typeName].concat(alternates)) {
									final target: Null<String> = dispatchOn(
										{ typeName: type, isValue: recv.isValue, isDynamic: false }, calleeName, span, field, currentType
									);
									if (calleeId == null) calleeId = target;
								}
							}
						}
					}
				} else {
					unresolvedAt(span, ComplexCallee(callee.kind), currentType);
				}
			} else if (callee.kind == callKind || (newExprKind != null && callee.kind == newExprKind)) {
				unresolvedAt(span, FunctionValue('expression result'), currentType);
			} else {
				unresolvedAt(span, ComplexCallee(callee.kind), currentType);
			}
			if (span != null) sites[span.from] = {
				target: calleeId,
				receiver: isAccessKind(callee.kind) && callee.children.length > 0 ? callee.children[0] : null
			};
			scanArgs(call.children, 1, calleeId, calleeName, currentType);
		}

		/** A constructor run on `typeName` at `span`: the `New` edge to the constructor it names, and the wiring to its initializers. */
		function constructionRun(typeName: String, span: Null<Span>, currentType: Null<String>): Null<String> {
			final from: String = frameId(currentType);
			final target: Null<String> = g.constructorTarget(typeName, ctorName);
			if (target != null) g.addEdge(from, target, New, null, file, span);
			g._wiring.record({
				typeName: typeName,
				from: from,
				kind: New,
				file: file,
				span: span,
				chainGrew: false,
				target: target
			});
			return target;
		}

		function handleNew(node: QueryNode, currentType: Null<String>): Void {
			final rawName: Null<String> = node.name;
			if (rawName == null) return;
			final typeName: String = g.types.imports.typeOf(file, rawName);
			final target: Null<String> = constructionRun(typeName, node.span, currentType);
			for (alternate in g.types.imports.alternateTypes(file, typeName)) constructionRun(alternate, node.span, currentType);
			final span: Null<Span> = node.span;
			if (span != null) sites[span.from] = { target: target, receiver: null };
			// constructor args can carry callbacks / lambdas too; the leading `typeArgCount` children are type arguments
			scanArgs(node.children, node.typeArgCount, target, null, currentType);
		}

		/**
		 * The written type of the parameter the argument `index` of a call passing `count` arguments binds, of the target `site`
		 * resolved to, as its receiver sees it; null where an argument before it may have been skipped (`mayShift`).
		 */
		function argumentTypeSource(site: CallSite, index: Int, count: Int, currentType: Null<String>): Null<String> {
			final target: Null<String> = site.target;
			final params: Null<Array<Null<String>>> = target == null ? null : CallGraphKeys.paramTypesOf(g, target);
			if (target != null && CallGraphKeys.mayShift(g, target, index, count)) return null;
			// a rest parameter takes every argument from its position on
			final at: Int = params != null && target != null && g._facts.restParams.exists(target)
				? Std.int(Math.min(index, params.length - 1))
				: index;
			final param: Null<String> = params == null || at >= params.length ? null : params[at];
			if (target == null || param == null) return null;
			final written: String = param;
			if (CallGraphNames.mentionsTypeName(written, g._facts.typeParams[target] ?? [], g._plugin.typeSyntax)) return null;
			final receiver: Null<QueryNode> = site.receiver;
			final receiverSource: Null<String> = receiver == null ? null : typeSourceOf(receiver, currentType);
			final onType: Null<String> = receiver == null ? null : receiverType(receiver, currentType, g.nodes[target]?.name)?.typeName;
			return throughParams(written, g.nodes[target]?.typeName, receiverSource, onType, currentType);
		}

		/**
		 * The written type of field `field` of a value written `outer`: an
		 * inline anonymous structure's, or a typedef's or class's member.
		 */
		function fieldTypeSource(outer: String, field: String, currentType: Null<String>): Null<String> {
			final peeled: String = NominalTypes.unwrapNullable(outer.trim(), transparentWrappers, g._plugin.typeSyntax);
			final written: Null<String> = CallGraphNames.anonFieldTypeSource(g._plugin.typeSyntax(peeled), field);
			if (written != null) return written;
			final nominal: Null<String> = nominalOf(peeled, currentType);
			return nominal == null ? null : memberTypeThrough(peeled, nominal, field, currentType);
		}

		// the graph's answers to the ONE expected-type engine (`ExpectedTypes`), in the graph's currency
		final graphExpectation: ExpectationHost<String, Null<String>> = {
			declared: (holder, _) -> {
				final at: Null<Span> = holder.span;
				at == null ? null : typeSources[at.from];
			},
			assigned: typeSourceOf,
			returned: (fn, _) -> {
				final at: Null<Span> = fn.span;
				final id: Null<String> = at == null ? null : entry.fnBySpanFrom[at.from];
				id == null ? null : g._facts.returns[id];
			},
			argument: (call, at, count, currentType) -> {
				final span: Null<Span> = call.span;
				final site: Null<CallSite> = span == null ? null : sites[span.from];
				site == null ? null : argumentTypeSource(site, at, count, currentType);
			},
			element: (literal, _) -> elementTypeSource(literal),
			field: fieldTypeSource,
			read: (written, _) -> g._plugin.typeSyntax(written),
			part: (_, text, _) -> text
		};

		/**
		 * Type the parameters the lambda `lambda`, walked at the top of `lineage`, writes with no type by the function type it is
		 * expected to be (`ExpectedTypes.lambdaParamTypes`): a call's parameter as the callee's own file writes it, a declaration's
		 * or an assignment's type — one of the same arity.
		 */
		function typeLambdaParams(lambda: QueryNode, currentType: Null<String>): Void {
			final params: Array<QueryNode> = [for (c in lambda.children) if (paramKinds.contains(c.kind)) c];
			final bare: Array<QueryNode> = [
				for (p in params) if (p.span != null && !typeSources.exists(p.span?.from ?? -1)) p
			];
			if (bare.length == 0) return;
			final written: Null<Array<String>> = expectation.lambdaParamTypes(lambda, lineage, lineageIndex, graphExpectation, currentType);
			if (written == null) return;
			for (i in 0...params.length) {
				final at: Null<Span> = params[i].span;
				if (at != null && bare.contains(params[i])) typeSources[at.from] = written[i];
			}
		}

		/**
		 * An object literal whose expected type (`ExpectedTypes.expectedAt`) is a class the language CONSTRUCTS from a literal
		 * (`ExecutionShape.implicitConstructionTypeMetaNames`): the `New` edge and constructor run a `new` would carry.
		 */
		function handleConstructionLiteral(node: QueryNode, currentType: Null<String>): Void {
			final written: Null<String> = expectation.expectedAt(lineage, lineageIndex, lineage.length - 1, graphExpectation, currentType);
			final found: Null<String> = written == null ? null : nominalOf(written, currentType);
			if (found != null && g.types.meta.constructsFromLiteral(found)) constructionRun(found, node.span, currentType);
		}

		/**
		 * Whether the innermost frame is the accessor `accessor` itself: inside a getter, reading its property
		 * on `this` reads the stored field; inside a setter, WRITING it writes the field — but a read there still
		 * runs the getter.
		 */
		function insideAccessor(accessor: String): Bool {
			return frames.length > 0 && g.nodes[frames[frames.length - 1].id]?.name == accessor;
		}

		/**
		 * A read or write of a property whose accessor runs code: an `Accessor` edge to `get_x` /
		 * `set_x` (plus the overrides an instance dispatch reaches), resolved through the receiver's
		 * static type. A name no indexed type declares as such a property is skipped outright; one
		 * whose receiver cannot be typed is recorded in `unresolvedAccess`.
		 */
		function handleAccess(node: QueryNode, parent: Null<QueryNode>, childIndex: Int, currentType: Null<String>): Void {
			final rawName: Null<String> = node.name;
			final span: Null<Span> = node.span;
			if (rawName == null || span == null || accessorPrefixes.length < 2) return;
			final name: String = rawName;
			final writeSlot: Bool = parent != null && childIndex == 0 && writeParentKinds.contains(parent.kind);
			final reads: Bool = !(writeSlot && parent?.kind == assignKind);
			/** The accessors a std property of `stdOwner` runs here (`StdTypes.accessorsOf`). */
			function stdAccessors(stdOwner: String): Void {
				final accessors: Array<String> = StdTypes.accessorsOf(g._plugin, stdOwner, name, reads, writeSlot, accessorPrefixes);
				for (a in accessors) g.addEdge(frameId(currentType), g.externalNode(stdOwner, a), Accessor, null, file, span, stdOwner);
			}
			if (!g.types.hasPropertyNamed(name)) {
				// a property no indexed type declares may be a std one, on a value the graph types as a std type
				final recv: QueryNode = unwrap(node.children.length > 0 ? node.children[0] : node);
				final written: Null<String> = recv.kind != identKind ? null : typeSourceOf(recv, currentType);
				final declared: Null<String> = written == null ? null : nominalOf(written, currentType);
				if (
					isAccessKind(node.kind) && declared != null && !nullableWrappers.contains(declared)
					&& g.types.declarationCount(declared) == 0
				)
					stdAccessors(declared);
				return;
			}
			var owner: Null<String> = null;
			var isValue: Bool = true;
			// the stored field is what the name can mean inside its own accessor — on `this`, never on another object
			var ownStorage: Bool = false;
			if (node.kind == identKind) {
				final bound: Null<Int> = Refs.bindingAt(name, span.from, tree, shape);
				if (bound != null && bound >= 0 && bindsLocally(bound)) return;
				owner = currentType;
				ownStorage = true;
			} else if (isAccessKind(node.kind) && node.children.length > 0) {
				ownStorage = unwrap(node.children[0]).kind == identKind && unwrap(node.children[0]).name == selfText;
				final recv: Null<Receiver> = receiverType(node.children[0], currentType, name);
				if (recv == null || recv.isDynamic) {
					if (g.facts?.muted.exists(frameId(currentType)) == true) return;
					g.unresolvedAccess.push({
						file: file,
						span: span,
						from: frameId(currentType),
						member: name,
						write: writeSlot,
						dynamicReceiver: recv != null
					});
					return;
				}
				owner = recv.typeName;
				isValue = recv.isValue;
				// an abstract's `this` is the value it wraps: that value's property is no storage of the accessor's own
				if (recv.typeName != currentType) ownStorage = false;
			}
			if (owner == null) return;
			final ownerType: String = owner;
			final found: Null<{ info: MemberInfo, owner: String }> = g.types.propertyOnChain(ownerType, name);
			if (found == null && g.types.declarationCount(ownerType) == 0) stdAccessors(ownerType);
			if (found == null) return;
			final prop: { info: MemberInfo, owner: String } = found;
			final from: String = frameId(currentType);
			final dispatch: Null<String> = isValue ? ownerType : null;
			function accessorEdge(prefix: String): Void {
				final accessor: String = prefix + name;
				final declared: Null<String> = g.memberOnChain(ownerType, accessor);
				// an interface declares the property but no accessor body: the edge names a body-less declaration,
				// which a consumer follows for dispatch to the implementations only
				final target: String = if (declared != null)
					declared
				else if (g.types.isInterface(prop.owner))
					g.externalNode(prop.owner, accessor, true)
				else
					g.externalNode(prop.owner, accessor);
				g.addEdge(from, target, Accessor, null, file, span, dispatch);
				if (isValue) for (v in g.virtualTargets(ownerType, accessor)) g.addEdge(from, v, Virtual, null, file, span, ownerType);
			}
			if (reads && prop.info.hasGetter && !(ownStorage && insideAccessor(accessorPrefixes[0] + name)))
				accessorEdge(accessorPrefixes[0]);
			if (writeSlot && prop.info.hasSetter && !(ownStorage && insideAccessor(accessorPrefixes[1] + name)))
				accessorEdge(accessorPrefixes[1]);
		}

		/**
		 * Whether an import of the file may bind `name`, read at `at`, to a static function (`ValueNameBinding.importedStatics`):
		 * one whose name some indexed type gives a function, or one the index cannot list.
		 */
		function importsFunction(name: String, at: Int): Bool {
			final imported: ImportedStatics = importedOf(name, at);
			return imported.unknown || imported.statics.exists(s -> g.types.hasFunctionNamed(s.member));
		}

		/**
		 * A function used as a VALUE anywhere a call argument does not already cover — an assignment
		 * right-hand side, a `return`, an array or object literal, a local initializer: the `Ref` edge
		 * a later invocation of that value needs. Callee, argument, constructor-argument and receiver
		 * positions are skipped; their own handlers own them.
		 */
		function handleValueUse(node: QueryNode, parent: Null<QueryNode>, childIndex: Int, currentType: Null<String>): Void {
			if (parent != null) {
				final pk: String = parent.kind;
				if ((pk == callKind && childIndex == 0) || isAccessKind(pk)) return;
				if (childIndex == 0 && writeParentKinds.contains(pk)) return;
			}
			final span: Null<Span> = node.span;
			if (span == null) return;
			// a value assigned to a `dynamic` method is stored there, and runs only where the member is invoked
			inline function storedInto(): Null<String> {
				return parent != null && parent.kind == assignKind && childIndex == 1 ? dynamicSlot(parent.children[0], currentType) : null;
			}
			if (lambdaKinds.contains(node.kind)) {
				final lambdaId: Null<String> = entry.fnBySpanFrom[span.from];
				if (lambdaId != null)
					g.addEdge(frameId(currentType), lambdaId, Ref, null, file, span, null, null, null, null, storedInto());
				return;
			}
			final rawName: Null<String> = node.name;
			if (
				rawName == null || !(
					g._byMember.exists(rawName) || localFn(rawName) != null || g.types.hasFunctionNamed(rawName)
					|| importsFunction(rawName, span.from)
				)
			)
				return;
			final ref: Null<MethodRef> = methodRef(node, currentType);
			if (ref != null)
				refEdges(frameId(currentType), ref, null, span, storedInto());
			else
				untypedMethodRead(node, currentType);
		}


		/** Whether child `i` of `node` is a call / constructor ARGUMENT value slot, which `scanArgs` / `handleNew` own. */
		function argumentSlot(node: QueryNode, i: Int, inArgument: Bool): Bool {
			return (node.kind == callKind && i >= 1) || (newExprKind != null && node.kind == newExprKind && i >= node.typeArgCount)
				|| (inArgument && (node.kind == parenKind || (node.kind == ternaryKind && i >= 1)));
		}

		function walk(
			node: QueryNode, currentType: Null<String>, parent: Null<QueryNode>, childIndex: Int, inArgument: Bool
		): Void {
			// symmetric with `CallGraphNodes.collect`: reified code is not runtime calls
			if (opaqueKinds.contains(node.kind)) return;
			final typeName: Null<String> = RefactorSupport.typeDeclOf(node)?.name ?? currentType;

			if (!inArgument && (node.kind == identKind || isAccessKind(node.kind) || lambdaKinds.contains(node.kind)))
				handleValueUse(node, parent, childIndex, typeName);

			final span: Null<Span> = node.span;
			// a lambda's untyped parameters take the function type it is expected to be, before its body reads them
			if (lambdaKinds.contains(node.kind)) typeLambdaParams(node, typeName);
			var pushed: Bool = false;
			if (span != null && (fnKinds.contains(node.kind) || lambdaKinds.contains(node.kind))) {
				final id: Null<String> = entry.fnBySpanFrom[span.from];
				if (id != null) {
					final ownId: String = id;
					final declared: Span = span;
					final name: Null<String> = node.name;
					if (name != null && localFnKinds.contains(node.kind) && frames.length > 0)
						frames[frames.length - 1].localFns[name] = ownId;
					if (frames.length > 0)
						g.addEdge(frames[frames.length - 1].id, ownId, Contains, null, file, span);
					else if (lambdaKinds.contains(node.kind))
						// a member-initializer lambda (`final onTick = () -> ...`) has no
						// enclosing frame — anchor it to the type's <init> pseudo-node so
						// reach/callers can still traverse into its body
						g.addEdge(g.initNode(typeName ?? moduleType, file, inStaticInit), ownId, Contains, null, file, span);
					frames.push({ id: ownId, localFns: [], span: declared });
					pushed = true;
				}
			}

			// a loop's binder is typed before the body that reads it is walked
			if (iterationKinds.contains(node.kind)) typeLoopBinder(node, typeName);
			if (node.kind == callKind && node.children.length > 0)
				handleCall(node, typeName);
			else if (newExprKind != null && node.kind == newExprKind)
				handleNew(node, typeName);
			if (node.kind == identKind || isAccessKind(node.kind)) handleAccess(node, parent, childIndex, typeName);
			if (objectLiteralKind != null && node.kind == objectLiteralKind) handleConstructionLiteral(node, typeName);

			var macroPending: Bool = false;
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length) {
				final c: QueryNode = kids[i];
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
				final savedStatic: Bool = inStaticInit;
				if (frames.length == 0 && MemberKinds.macroModifierPrecedes(kids, i, staticKind, modifierBoundary)) inStaticInit = true;
				// an initializer runs whatever it holds — a conversion, a touch, target code — though it calls nothing
				if (frames.length == 0 && fieldKinds.contains(c.kind) && CtorFieldFold.declInitializer(c, shape) != null)
					g.initNode(typeName ?? moduleType, file, inStaticInit); // noqa: unused-return-value
				lineage.push(node);
				lineageIndex.push(i);
				walk(c, typeName, node, i, argumentSlot(node, i, inArgument));
				lineage.pop();
				lineageIndex.pop();
				inStaticInit = savedStatic;
			}
			if (pushed) frames.pop();
		}
		walk(tree, null, null, 0, false);
	}

}

private typedef Frame = {
	var id: String;
	var localFns: Map<String, String>;

	/** The declaration of `id` the walk is in: a node folding several has a frame per declaration. */
	var span: Span;
}

/** A method referenced as a value: its node, and the receiver type an instance reference dispatches on (null for a static one). */
private typedef MethodRef = {
	var id: String;
	var dispatch: Null<String>;

	/** For a module-level function's use bound per build, every function it may run (`moduleBinding`), `id` first; else null. */
	@:optional var bodies: Null<Array<String>>;
}

/**
 * What a bare use of a name its module declares a value of may run, by the builds compiling it (`moduleBinding`): each
 * function, and why a build's is not one the graph holds — a value it calls, or an import the index cannot list.
 */
private typedef ModuleBinding = {
	var targets: Array<String>;
	var unresolved: Null<UnresolvedReason>;
}

/** What a call or `new` site resolved to: the target, and the receiver expression a call through a field access was made on. */
private typedef CallSite = {
	var target: Null<String>;
	var receiver: Null<QueryNode>;
}

private typedef Receiver = {
	var typeName: String;
	var isValue: Bool;
	var isDynamic: Bool;
}

/** A call's resolved target, and the written type and type of the receiver it was made on (null for a bare call). */
private typedef CallTarget = {
	var target: String;
	var receiverSource: Null<String>;
	var onType: Null<String>;
}
