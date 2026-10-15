package anyparse.query;

import anyparse.check.CheckScan;
import anyparse.query.CallGraph.FnDeclaration;
import anyparse.query.CallGraph.FnNode;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;

using Lambda;

/**
 * The nodes of a `CallGraph`: every function-like declaration of a parsed file — a method, a module-level function, a
 * local function, a lambda — registered as a node, or folded into the node an earlier declaration of it made, with
 * what its declaration says about its type parameters, bounds and return type.
 */
@:nullSafety(Strict)
@:access(anyparse.query.CallGraph)
final class CallGraphNodes {

	/** Register the function-like declarations of `entry` as nodes of `g`. */
	public static function collect(g: CallGraph, entry: Entry): Void {
		// noqa: complexity
		final shape: RefShape = g._shape;
		final returnTypes: Map<Int, String> = g._provider == null ? [] : g._provider.returnTypes(entry.source);
		final typeParams: Map<Int, Array<String>> = g._provider == null ? [] : g._provider.typeParamNames(entry.source);
		final spanInfo: Null<SpanTypeInfoProvider> = g._plugin is SpanTypeInfoProvider ? cast g._plugin : null;
		final bounds: Map<Int, Map<String, Array<String>>> = spanInfo == null
			? []
			: spanInfo.spanTypeInfo(entry.source).typeParamConstraints;
		// a local `inline function` is a function of its own like any local one, though the grammar gives it a kind apart
		final fnKinds: Array<String> = (shape.functionKinds ?? []).concat(shape.inlineFunctionKinds ?? []);
		final lambdaKinds: Array<String> = shape.lambdaKinds ?? [];
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final macroKind: Null<String> = shape.macroModifierKind;
		final dynamicKind: Null<String> = shape.dynamicModifierKind;
		final noBodyKind: Null<String> = shape.noBodyKind;
		final moduleType: String = CallGraphNames.moduleTypeName(entry.file);
		var lambdaCounter: Int = 0;
		final modifierBoundary: QueryNode -> Bool = c -> c.children.length > 0 || c.name != null;

		final underlyingKinds: Array<String> = shape.underlyingThisTypeKinds ?? [];
		final annotationKinds: Array<String> = shape.typeAnnotationKinds ?? [];
		final runKinds: Array<String> = CheckScan.modifierKinds(shape).concat(g._plugin.metaShape().metaKinds);

		function walk(
			node: QueryNode, currentType: Null<String>, parentFn: Null<String>, isDynamic: Bool, ?overloads: Array<QueryNode>
		): Void {
			// a macro-reification subtree is generated-code emission, not runtime
			// calls — walking it would fabricate nodes and edges (mirrors Refs)
			if (opaqueKinds.contains(node.kind)) return;
			final declared: Null<String> = CallGraphNames.typeNameOf(node);
			final typeName: Null<String> = declared ?? currentType;
			if (declared != null && underlyingKinds.contains(node.kind)) {
				// the declared-type slot, never a child: a bounded `<T:B>` projects its bound among the children
				final under: Null<String> = node.type?.name;
				g._facts.abstracts[declared] = under;
			}
			// a `final class` declares its parameters on the inner form the wrapper holds, which is where they are keyed
			final declaredAt: Null<Span> = declared == null ? null : (RefactorSupport.typeDeclOf(node)?.nameNode ?? node).span;
			if (declared != null && declaredAt != null) {
				final own: Null<Map<String, Array<String>>> = bounds[declaredAt.from];
				if (own != null)
					g._facts.typeBounds[DeclarationFacts.boundsKey(entry.file, declared)] = own
				else
					g._facts.typeBounds.remove(DeclarationFacts.boundsKey(entry.file, declared));
			}

			var fnId: Null<String> = parentFn;
			final span: Null<Span> = node.span;
			final name: Null<String> = node.name;
			if (span != null && name != null && fnKinds.contains(node.kind)) {
				final owner: String = typeName ?? moduleType;
				fnId = parentFn == null ? '$owner.$name' : '$parentFn#$name';
				final id: String = fnId;
				final first: Bool = register(
					g, id, entry, parentFn == null ? owner : typeName, name, span, isDynamic && parentFn == null,
					noBodyKind != null && node.children.exists(c -> c.kind == noBodyKind)
				);
				if (parentFn == null) g.registerMember(owner, name, id);
				// what the declarations say is the node's where they all say it: a name any of them declares a type parameter is one
				final params: Array<String> = typeParams[span.from] ?? [];
				final held: Array<String> = g._facts.typeParams[id] ?? [];
				final declaredParams: Array<String> = held.concat([for (p in params) if (!held.contains(p)) p]);
				if (declaredParams.length > 0) g._facts.typeParams[id] = declaredParams;
				final bounded: Null<Map<String, Array<String>>> = bounds[span.from];
				if (first && bounded != null)
					g._facts.typeParamBounds[id] = bounded
				else if (!first && !DeclarationFacts.sameBounds(g._facts.typeParamBounds[id], bounded))
					g._facts.typeParamBounds.remove(id);
				DeclarationFacts.settle(g._facts.returns, id, returnTypes[span.from], first);
				DeclarationFacts.settle(
					g._facts.returnSources, id, CallGraphNames.returnSourceOf(node, entry.source, annotationKinds), first
				);
				if (overloads != null) overloaded(g, id, node, overloads, entry.source);
			} else if (span != null && lambdaKinds.contains(node.kind)) {
				lambdaCounter++;
				fnId = '${parentFn ?? (typeName ?? moduleType)}#$lambdaCounter';
				final id: String = fnId;
				DeclarationFacts.settle(
					g._facts.returns, id, returnTypes[span.from], register(g, id, entry, typeName, null, span, false, false)
				);
			}
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length) {
				final c: QueryNode = kids[i];
				if (macroKind != null && c.kind == macroKind) continue;
				if (fnKinds.contains(c.kind) && MemberKinds.macroModifierPrecedes(kids, i, macroKind, modifierBoundary)) {
					// `macro` function body — compile-time code, not runtime calls
					continue;
				}
				final dyn: Bool = fnKinds.contains(c.kind) && MemberKinds.macroModifierPrecedes(kids, i, dynamicKind, modifierBoundary);
				walk(
					c, typeName, fnId, dyn,
					fnKinds.contains(c.kind) ? signaturesOffered(MemberKinds.precedingModifiers(c, node, runKinds), shape) : null
				);
			}
		}
		walk(entry.tree, null, null, false);
	}

	/**
	 * The other signatures the modifier run `run` of a function declaration offers: the function each `@:overload`
	 * (`signatureOverloadMetaName`) holds; null for none.
	 */
	private static function signaturesOffered(run: Array<QueryNode>, shape: RefShape): Null<Array<QueryNode>> {
		final meta: Null<String> = shape.signatureOverloadMetaName;
		final out: Array<QueryNode> = [
			for (m in run) if (meta != null && m.name == meta) for (c in m.children) if ((shape.lambdaKinds ?? []).contains(c.kind)) c
		];
		return out.length == 0 && !run.exists(m -> meta != null && m.name == meta) ? null : out;
	}

	/**
	 * Mark the node `id`, declared by `fn` (in `source`) offering the signatures `others`, as one whose return type or
	 * parameters a call cannot read off its declaration: some other signature writes them differently. An offered
	 * signature that does not read as a function differs in both.
	 */
	private static function overloaded(g: CallGraph, id: String, fn: QueryNode, others: Array<QueryNode>, source: String): Void {
		final shape: RefShape = g._shape;
		final annotationKinds: Array<String> = shape.typeAnnotationKinds ?? [];
		final paramKinds: Array<String> = shape.paramKinds ?? [];
		function params(f: QueryNode): String {
			return [
				for (p in f.children)
					if (paramKinds.contains(p.kind)) {
						final at: Null<Span> = p.type?.span;
						'${p.kind}:${at == null ? '' : source.substring(at.from, at.to)}';
					}
			].join(',');
		}
		final returned: Null<String> = CallGraphNames.returnSourceOf(fn, source, annotationKinds);
		final written: String = params(fn);
		// an `@:overload` holding no function expression offers a signature nothing reads
		final unread: Bool = others.length == 0;
		if (unread || others.exists(o -> CallGraphNames.returnSourceOf(o, source, annotationKinds) != returned)) {
			g._facts.overloadedReturns[id] = true;
			g._facts.returns.remove(id);
			g._facts.returnSources.remove(id);
		}
		if (unread || others.exists(o -> params(o) != written)) g._facts.overloadedParams[id] = true;
	}

	/**
	 * Register the declaration at `span` of `entry` as the node `id` of `g` — a new node, the one replacing the placeholder
	 * an earlier file's call left for it, or a further declaration the node folds in (`CallGraph.declarationsOf`). True when
	 * it is the node's first declaration.
	 */
	private static function register(
		g: CallGraph, id: String, entry: Entry, typeName: Null<String>, name: Null<String>, span: Span, isDynamic: Bool, isBodyless: Bool
	): Bool {
		final held: Null<FnNode> = g.nodes[id];
		if (held != null && !held.isExternal) {
			// a further declaration runs as the node: one the program may replace makes the node so, one with a body gives it one
			if (isDynamic) held.isDynamic = true;
			if (!isBodyless) held.isBodyless = false;
			// facts read before it arrived describe the others alone: the node's syntax reads it now
			g.facts?.faceted.remove(id);
		}
		// a declaration replaces the placeholder an earlier file's call left for it
		if (held == null || held.isExternal) {
			final created: FnNode = {
				id: id,
				file: entry.file,
				typeName: typeName,
				name: name,
				span: span,
				isExternal: false,
				isDynamic: isDynamic,
				isBodyless: isBodyless
			};
			g.nodes[id] = created;
			if (typeName != null && !g._grownTypes.contains(typeName)) g._grownTypes.push(typeName);
			final key: String = CallGraphNames.normalizePath(entry.file);
			final inFile: Array<FnNode> = g._fileNodes[key] ?? [];
			inFile.push(created);
			g._fileNodes[key] = inFile;
		}
		entry.fnBySpanFrom[span.from] = id;
		final key: String = CallGraphNames.normalizePath(entry.file);
		final declared: Array<FnDeclaration> = g._declarations[id] ?? [];
		final first: Bool = declared.length == 0;
		final declaration: FnDeclaration = { id: id, file: entry.file, span: span };
		declared.push(declaration);
		g._declarations[id] = declared;
		final inFile: Array<FnDeclaration> = g._fileDeclarations[key] ?? [];
		inFile.push(declaration);
		g._fileDeclarations[key] = inFile;
		if (name != null) {
			final ids: Array<String> = g._byMember[name] ?? [];
			if (!ids.contains(id)) ids.push(id);
			g._byMember[name] = ids;
		}
		return first;
	}

}

/** The parts of a parsed file the nodes are collected from. */
private typedef Entry = {
	var file: String;
	var source: String;
	var tree: QueryNode;
	var fnBySpanFrom: Map<Int, String>;
}
