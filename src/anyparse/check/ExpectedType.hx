package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using Lambda;

/**
 * The written type source a cast's POSITION demands — the shared gate chain behind every check
 * that asks whether a cast restates something the surrounding code already pins.
 *
 * Two checks ask it, from opposite sides. `redundant-cast-type` compares the answer against the
 * cast's OWN target type (`cast(e, T)` in a slot already written `T` — the type argument only
 * restates the annotation, so the checked form collapses to the unchecked one).
 * `redundant-unchecked-cast` compares it against the OPERAND's declared type (`cast e` in a slot
 * written exactly what `e` already is — the cast converts nothing and is deleted). The positions,
 * their gates and their bails are identical; only the two sides of the final comparison differ,
 * which is why this lives here rather than once per check.
 *
 * ## Four positions, direct child only
 *
 * The cast must be a DIRECT child of the position node — one nested inside a larger expression
 * (a ternary branch, an operand) is out of scope:
 *
 *  - (a) a declaration initializer with its OWN written annotation — `localDeclKinds`
 *    (`VarStmt` / `FinalStmt` / `VarMore`) or `fieldDeclKinds` (`VarMember` / `FinalMember`);
 *  - (b) a `return` (`valueReturnKinds`) under a function carrying an explicit return
 *    annotation. The enclosing function is threaded down the CALLER's walk: a node that OWNS a
 *    function body sets it (`ownsFunctionBody`, derived from a direct `functionBodyKinds` child,
 *    so the nested forms no seam names — `LocalInlineFnStmt`, `NamedFnExpr` — resolve against
 *    their own annotation), a `lambdaKinds` node CLEARS it, so a lambda return always bails. The
 *    annotation itself is told from a type-parameter CONSTRAINT — same node kind, same child slot
 *    — by position relative to the parameter list (`CheckScan.returnAnnotationText`, shared with
 *    `guard-return`'s Void proof);
 *  - (c) a call-argument slot whose parameter is written `T`, and only when the callee is a bare
 *    identifier resolving to a function DECLARED in this file, EVERY parameter up to and
 *    including the slot is plain required with no default value, and the parameter's type is a
 *    plain nominal DECLARED in the `SymbolIndex`;
 *  - (d) a plain ASSIGNMENT to an already-declared, explicitly annotated lvalue —
 *    `_cp = cast(_mc.getChildByName('centerPoint'), MovieClip);` where `_cp` is declared
 *    `private var _cp:MovieClip;`.
 *
 * Descending into macro-reification subtrees (`RefShape.opaqueKinds`) is the CALLER's walk to
 * refuse — this module only answers about a node it is handed.
 *
 * ## Position (d): the assignment arm's discipline
 *
 * Only the PLAIN `=` kind (`RefShape.assignKind`) qualifies. A compound assignment projects as a
 * DIFFERENT kind entirely (`x += e` is `AddAssign`, not `Assign`), so it never reaches the arm —
 * and rightly so: the expected type there is the OPERATOR's, not the lvalue's. The cast must be
 * the WHOLE right-hand side (`children[1]`), which keeps `a = cast(v, Foo).x` and
 * `a = c ? cast(v, Foo) : o` out of scope for the same direct-child reason (a)-(c) enforce.
 *
 * Two lvalue shapes are provable. A BARE identifier is resolved by
 * `TypeResolver.identDeclaredTypeSource`, which covers a local, a parameter and an OWN instance /
 * static field in ONE call and carries three bails for free — a name RE-SHADOWED in a visible
 * scope, an unresolved binding, and an INFERENCE-typed declaration with no written annotation. It
 * is called with `skipNullableOptionalParam = true` because an optional / `= null`-defaulted /
 * rest parameter's body type is `Null<T>` rather than its written `T`, which does not pin `T`.
 *
 * The second shape is an explicitly self-qualified `this.f`: the field name is looked up among the
 * enclosing `visibilityContainerKinds` container's DIRECT children of a `fieldDeclKinds` kind (the
 * container is threaded down the caller's walk exactly as the enclosing function is), and more
 * than one match refuses. Direct-children-only does TWO jobs at once — a `#if`-guarded member is
 * nested in a `Conditional` rather than being a direct child, so it is invisible and the position
 * is skipped; and an INHERITED field is not a member of this container at all, so a superclass's
 * annotation is never read for a subclass's `this.f`. A field access on any OTHER receiver
 * (`o.a = …`) would need `o`'s own type resolved first and is refused outright. So is an
 * `abstract`, whose `this` is the UNDERLYING value rather than an instance
 * (`underlyingThisTypeKinds`): `this.f` there reads the UNDERLYING type's field, never a member of
 * the container at all. An `enum abstract` never REACHES that gate — it is not a
 * `visibilityContainerKinds` node, so the container is null there and the null conjunct refuses
 * first; it stays in the gate so the answer survives that list growing.
 *
 * ## Generics veto on the argument slot
 *
 * A parameter type must be a plain nominal that some indexed file DECLARES. A type PARAMETER
 * (`function pick<T>(v:T):T`) is declared nowhere, so the gate vetoes the one shape where the
 * argument's type would DRIVE inference rather than be constrained by it. Positions (a), (b) and
 * (d) need no such veto — their annotation FIXES the type. Consequence: a builtin-typed parameter
 * (`p:Int`) resolves only when the std / configured libraries are in the resolution scope, and is
 * a safe miss otherwise.
 */
@:nullSafety(Strict)
final class ExpectedType {

	/**
	 * The written type source the POSITION of `castNode` demands, or null when the position is not
	 * one of the four provable shapes. Dispatches on `parent`: an annotated declaration whose
	 * initializer is the cast, a `return` under an annotated function, a plain `=` assignment whose
	 * WHOLE right-hand side is the cast, or a call-argument slot.
	 */
	public static function expectedTypeSource(
		site: CastSite, root: QueryNode, types: FileTypes, resolutionIndex: () -> SymbolIndex
	): Null<String> {
		final shape: RefShape = types.shape;
		final castNode: QueryNode = site.node;
		final parent: QueryNode = site.parent;
		final enclosingFn: Null<QueryNode> = site.enclosingFn;
		final declKinds: Array<String> = (shape.localDeclKinds ?? []).concat(shape.fieldDeclKinds ?? []);
		final isFirstChild: Bool = parent.children.length > 0 && parent.children[0] == castNode;
		return if (declKinds.contains(parent.kind) && isFirstChild)
			declAnnotation(parent, castNode, types.declaredTypeSources)
		else if ((shape.valueReturnKinds ?? []).contains(parent.kind) && isFirstChild)
			enclosingFn == null ? null : CheckScan.returnAnnotationText(enclosingFn, shape, types.source)
		else if (parent.kind == shape.assignKind && parent.children.length == 2 && parent.children[1] == castNode)
			assignTargetAnnotation(parent.children[0], site.enclosingContainer, root, types)
		else if (parent.kind == shape.callKind)
			paramAnnotation(castNode, parent, root, types, resolutionIndex)
		else
			null;
	}

	/**
	 * Visit every `castKind` node in `root` that sits in a POSITION at all — one with a parent —
	 * handing each the three context nodes `expectedTypeSource` reads.
	 *
	 * The enclosing function and the enclosing visibility container are threaded DOWN rather than
	 * looked up per site: each position gate needs exactly one step of context, and a `lambdaKinds`
	 * node has to CLEAR the enclosing function rather than be looked through, so a lambda `return`
	 * never resolves against its host's annotation. Macro-reification subtrees
	 * (`RefShape.opaqueKinds`) are never descended into.
	 */
	public static function eachCastInPosition(root: QueryNode, castKind: String, shape: RefShape, visit: CastSite -> Void): Void {
		final kinds: WalkKinds = {
			opaque: shape.opaqueKinds ?? [],
			functions: shape.functionKinds ?? [],
			lambdas: shape.lambdaKinds ?? [],
			bodies: shape.functionBodyKinds ?? [],
			containers: shape.visibilityContainerKinds ?? []
		};
		walkCasts(root, null, null, null, castKind, kinds, visit);
	}

	/**
	 * Drive `report` over every positioned cast of `castKind` across `files` — the whole outer shell
	 * both cast checks used to spell for themselves: the provider handshake, the ONE lazy resolution
	 * index the run shares, the per-file parse, the per-file type gathering, and the walk.
	 *
	 * A null `castKind` (a grammar that does not name that cast form) or a plugin that is not a
	 * `TypeInfoProvider` makes this a no-op, which is how both checks answer "no findings" without a
	 * gate of their own. A file that fails to parse is skipped, never reported.
	 */
	public static function eachPositionedCast(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, castKind: Null<String>, report: (CastSite, CastScan) -> Void
	): Void {
		if (castKind == null) return;
		final kind: String = castKind;
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		if (provider == null) return;
		final typed: TypeInfoProvider = provider;
		final shape: RefShape = plugin.refShape();
		final resolutionIndex: () -> SymbolIndex = lazyResolutionIndex(files, plugin);
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final root: QueryNode = tree;
			final scan: CastScan = {
				file: entry.file,
				root: root,
				types: fileTypes(shape, typed, entry.source),
				resolutionIndex: resolutionIndex
			};
			eachCastInPosition(root, kind, shape, site -> report(site, scan));
		}
	}

	/**
	 * `site`'s single operand, or null when the cast node does not carry exactly one child — the
	 * shape every cast rule must establish before it can say anything about what is being cast.
	 */
	public static function soleOperand(site: CastSite): Null<QueryNode> {
		return site.node.children.length == 1 ? site.node.children[0] : null;
	}

	/** ONE file's type information, gathered from the provider the calling check already holds. */
	public static function fileTypes(shape: RefShape, typed: TypeInfoProvider, source: String): FileTypes {
		return {
			shape: shape,
			source: source,
			declaredTypeSources: typed.declaredTypeSources(source),
			castTargets: typed.castTargetSources(source),
			importMap: typed.importMap(source),
			wrapperNames: shape.nullableWrapperTypeNames ?? []
		};
	}

	/**
	 * A resolution index built at most ONCE per run, and only when a call-argument position asks
	 * for one — the other three positions never need it, so a run that finds none pays nothing.
	 */
	public static function lazyResolutionIndex(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): () -> SymbolIndex {
		var index: Null<SymbolIndex> = null;
		function resolve(): SymbolIndex {
			final cached: Null<SymbolIndex> = index;
			if (cached != null) return cached;
			final built: SymbolIndex = RefactorSupport.resolutionIndexOf(plugin) ?? SymbolIndex.build(files, plugin);
			index = built;
			return built;
		}
		return resolve;
	}

	/**
	 * Whether `typeSource`'s OUTER nominal (the text before its first `<`) is a
	 * `RefShape.nullableWrapperTypeNames` entry — `Null` / `Dynamic` / `Any`. Neither check has
	 * anything to say about such a position: the runtime check a `Null` / `Dynamic` / `Any` target
	 * performs never throws, so `redundant-cast-type` would trade away nothing, and a `cast` INTO
	 * one is what ERASES a type rather than restating it, so `redundant-unchecked-cast` would
	 * delete a conversion that is doing work.
	 */
	public static function isNullableWrapper(typeSource: String, wrapperNames: Array<String>): Bool {
		final lt: Int = typeSource.indexOf('<');
		final outer: Null<String> = TypeResolver.simpleNominalName(lt == -1 ? typeSource : typeSource.substring(0, lt));
		return outer != null && wrapperNames.contains(outer);
	}

	/** One step of `eachCastInPosition`'s descent, carrying the context the next step inherits. */
	private static function walkCasts(
		node: QueryNode, parent: Null<QueryNode>, enclosingFn: Null<QueryNode>, enclosingContainer: Null<QueryNode>, castKind: String,
		kinds: WalkKinds, visit: CastSite -> Void
	): Void {
		if (kinds.opaque.contains(node.kind)) return;
		final nextFn: Null<QueryNode> = if (kinds.lambdas.contains(node.kind))
			null
		else if (ownsFunctionBody(node, kinds.functions, kinds.bodies))
			node
		else
			enclosingFn;
		final nextContainer: Null<QueryNode> = kinds.containers.contains(node.kind) ? node : enclosingContainer;
		final span: Null<Span> = node.span;
		if (node.kind == castKind && span != null && parent != null) {
			// A narrowed local never reaches an anonymous-structure literal whose field is non-nullable,
			// so both narrowings are re-bound here rather than read through.
			final at: Span = span;
			final host: QueryNode = parent;
			visit({
				node: node,
				span: at,
				parent: host,
				enclosingFn: enclosingFn,
				enclosingContainer: enclosingContainer
			});
		}
		for (c in node.children) walkCasts(c, node, nextFn, nextContainer, castKind, kinds, visit);
	}

	/**
	 * Whether `node` OWNS a function body — a `functionKinds` declaration, or ANY node carrying a
	 * direct `functionBodyKinds` child. The second arm is what reaches the nested function forms no
	 * seam names (Haxe `LocalInlineFnStmt` — the `inline function h():T {}` local-helper idiom — and
	 * `NamedFnExpr`): each carries its OWN return annotation in the same child slot a `FnMember`
	 * does, so a `return` inside one must resolve against IT, never against the outer function.
	 * Deriving the boundary from the body child rather than enumerating kind literals is what keeps
	 * a form the seam set does not list from silently inheriting the enclosing annotation.
	 */
	private static function ownsFunctionBody(node: QueryNode, functionKinds: Array<String>, bodyKinds: Array<String>): Bool {
		return functionKinds.contains(node.kind) || node.children.exists(child -> bodyKinds.contains(child.kind));
	}

	/**
	 * Position (a): the declaration's OWN written annotation — the EARLIEST `declaredTypeSources`
	 * entry in `[decl.span.from, cast.span.from)`. That half-open range covers exactly
	 * `var name:Type = ` for this binding, and the map keys a declaration on its own start, so the
	 * first entry in range IS this declaration's type; the later entries the map carries for a
	 * generic / anonymous annotation's nested type arguments (`Map<String,Int>` also yields an
	 * `Int`) are skipped. It isolates the `VarMore` continuation of `var a:Foo = …, b:Bar = …`
	 * (projected as a CHILD of the `VarStmt`, with its own initializer as `children[0]`). No entry in
	 * range = no annotation = no finding.
	 */
	private static function declAnnotation(decl: QueryNode, castNode: QueryNode, declaredTypeSources: Map<Int, String>): Null<String> {
		final declSpan: Null<Span> = decl.span;
		final castSpan: Null<Span> = castNode.span;
		return declSpan == null || castSpan == null ? null : earliestTypeSourceIn(declSpan.from, castSpan.from, declaredTypeSources);
	}

	/**
	 * Position (c): the written type of the parameter the cast fills, or null at the first gate
	 * that fails. The callee (`call.children[0]`) must be a bare identifier resolving to a
	 * `functionKinds` declaration in this file (the INNERMOST one of that name covering the
	 * binding, so a nested local function wins over its host); EVERY parameter up to and including
	 * the slot must be a plain required one (`RefShape.optionalParamKind` / `restParamKind`); and
	 * the parameter's type must be a plain nominal the index DECLARES (the generics veto).
	 *
	 * The gate covers every EARLIER parameter, not just the matched one, because Haxe lets a call
	 * SKIP a non-trailing optional argument when the types disambiguate — `f(?a:Foo, b:Int)` accepts
	 * `f(1)` — so one optional ahead of the slot destroys positional argument-to-parameter mapping.
	 * A rest parameter absorbs every remaining slot and breaks it the same way; an optional
	 * parameter's body type is `Null<T>` rather than its written form.
	 */
	private static function paramAnnotation(
		castNode: QueryNode, call: QueryNode, root: QueryNode, types: FileTypes, resolutionIndex: () -> SymbolIndex
	): Null<String> {
		final shape: RefShape = types.shape;
		final slot: Int = call.children.indexOf(castNode);
		if (slot < 1) return null;
		final callee: QueryNode = call.children[0];
		final calleeName: Null<String> = callee.name;
		final calleeSpan: Null<Span> = callee.span;
		if (callee.kind != shape.identKind || calleeName == null || calleeSpan == null) return null;
		final bindingFrom: Null<Int> = TypeResolver.resolveBindingFrom(calleeName, calleeSpan, root, shape);
		if (bindingFrom == null) return null;
		final fn: Null<QueryNode> = innermostFunctionNamed(root, shape.functionKinds ?? [], calleeName, bindingFrom);
		if (fn == null) return null;
		final param: Null<QueryNode> = plainRequiredParam(fn, shape, slot - 1);
		if (param == null) return null;
		final paramType: Null<String> = earliestTypeSourceWithin(param, types.declaredTypeSources);
		final simple: Null<String> = TypeResolver.simpleNominalName(paramType);
		return simple != null && resolutionIndex().declaringFiles(simple).length > 0 ? paramType : null;
	}

	/**
	 * The INNERMOST (smallest-span) `functionKinds` node in `root` named `name` whose span covers
	 * `offset` — the declaration a resolved callee binding belongs to, or null when none does.
	 */
	private static function innermostFunctionNamed(
		root: QueryNode, functionKinds: Array<String>, name: String, offset: Int
	): Null<QueryNode> {
		var best: Null<QueryNode> = null;
		var bestWidth: Int = -1;
		function scan(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			if (functionKinds.contains(node.kind) && node.name == name && span != null && span.from <= offset && offset < span.to) {
				final width: Int = span.to - span.from;
				if (best == null || width < bestWidth) {
					best = node;
					bestWidth = width;
				}
			}
			for (c in node.children) scan(c);
		}
		scan(root);
		return best;
	}

	/**
	 * The `slot`-th (0-based) parameter of `fn`, or null when `fn` declares fewer, when either
	 * `RefShape` parameter seam is missing, or when ANY parameter up to and including `slot` is
	 * optional or rest — each of which breaks the positional argument-to-parameter mapping (see
	 * `paramAnnotation`). Answering null on a missing seam keeps the gate fail-closed for a grammar
	 * that cannot name its own optional / rest forms.
	 */
	private static function plainRequiredParam(fn: QueryNode, shape: RefShape, slot: Int): Null<QueryNode> {
		final optionalKind: Null<String> = shape.optionalParamKind;
		final restKind: Null<String> = shape.restParamKind;
		if (optionalKind == null || restKind == null) return null;
		final paramKinds: Array<String> = shape.paramKinds ?? [];
		var seen: Int = 0;
		final annotationKinds: Array<String> = shape.typeAnnotationKinds ?? [];
		for (child in fn.children) if (paramKinds.contains(child.kind)) {
			if (child.kind == optionalKind || child.kind == restKind || hasDefaultValue(child, annotationKinds)) return null;
			if (seen == slot) return child;
			seen++;
		}
		return null;
	}

	/**
	 * Whether `param` carries a DEFAULT VALUE — a direct child that is not its type annotation. Haxe
	 * makes `a:Int = 1` skippable at a call site exactly as `?a:Int` is, yet it projects as a plain
	 * required parameter, so the optional / rest kind test alone does not establish the positional
	 * mapping. The type annotation is the only other child a parameter can carry (an anonymous-struct
	 * type is the one that survives projection), so anything else is the default.
	 */
	private static function hasDefaultValue(param: QueryNode, annotationKinds: Array<String>): Bool {
		return param.children.exists(child -> !annotationKinds.contains(child.kind));
	}

	/**
	 * Position (d): the written annotation of the assignment TARGET, or null when the lvalue is not one of
	 * the two provable shapes — a BARE identifier resolved by `TypeResolver.identDeclaredTypeSource`, or an
	 * EXPLICITLY self-qualified `this.f` resolved against the enclosing container's OWN members. The class
	 * doc's "assignment arm's discipline" section records why each bail is where it is.
	 */
	private static function assignTargetAnnotation(
		target: QueryNode, enclosingContainer: Null<QueryNode>, root: QueryNode, types: FileTypes
	): Null<String> {
		final shape: RefShape = types.shape;
		if (target.kind == shape.identKind)
			return TypeResolver.identDeclaredTypeSource(target, shape, root, () -> types.declaredTypeSources, true);
		final self: Null<String> = shape.selfReferenceText;
		final fieldName: Null<String> = target.name;
		if (
			target.kind != shape.fieldAccessKind || target.children.length != 1 || self == null || fieldName == null
			|| enclosingContainer == null
		)
			return null;
		if ((shape.underlyingThisTypeKinds ?? []).contains(enclosingContainer.kind)) return null;
		final receiver: QueryNode = target.children[0];
		return receiver.kind == shape.identKind && receiver.name == self
			? ownFieldAnnotation(enclosingContainer, fieldName, shape, types.declaredTypeSources)
			: null;
	}

	/**
	 * The written annotation of the member named `field` among `container`'s DIRECT children of a
	 * `fieldDeclKinds` kind, or null when none - or more than one - carries that name. The lookup keys
	 * `declaredTypeSources` at the matched member's `span.from`: every modifier projects as a separate
	 * PRECEDING sibling node, so a member node starts at its own `var` / `final` keyword, which is exactly
	 * the offset that map keys a declaration on. Keying the declaration rather than scanning its whole span
	 * is what keeps an UNANNOTATED member with a type-bearing initializer (`var f = function(x:Int) {};`)
	 * from surrendering the nested `Int` as if it were the field's own type.
	 */
	private static function ownFieldAnnotation(
		container: QueryNode, field: String, shape: RefShape, declaredTypeSources: Map<Int, String>
	): Null<String> {
		final fieldKinds: Array<String> = shape.fieldDeclKinds ?? [];
		var found: Null<QueryNode> = null;
		for (child in container.children) if (fieldKinds.contains(child.kind) && child.name == field) {
			if (found != null) return null;
			found = child;
		}
		if (found == null) return null;
		final span: Null<Span> = found.span;
		return span == null ? null : declaredTypeSources[span.from];
	}

	/**
	 * The EARLIEST `declaredTypeSources` entry inside `param`'s span — the parameter's own
	 * written type. Earliest, so an anon-struct field nested inside the parameter never wins.
	 */
	private static function earliestTypeSourceWithin(param: QueryNode, declaredTypeSources: Map<Int, String>): Null<String> {
		final span: Null<Span> = param.span;
		return span == null ? null : earliestTypeSourceIn(span.from, span.to, declaredTypeSources);
	}

	/**
	 * The `declaredTypeSources` entry with the SMALLEST key in `[from, to)`. Earliest, because the
	 * map ALSO carries an entry per nested type argument of a generic / anonymous annotation
	 * (`m:Map<String,Int>` yields both the declaration entry and an `Int` one inside it), and only
	 * the outermost entry — the one at the range start — is the declaration or parameter type.
	 */
	private static function earliestTypeSourceIn(from: Int, to: Int, declaredTypeSources: Map<Int, String>): Null<String> {
		var best: Null<String> = null;
		var bestKey: Int = -1;
		for (key => ty in declaredTypeSources) if (key >= from && key < to && (best == null || key < bestKey)) {
			best = ty;
			bestKey = key;
		}
		return best;
	}

}

/**
 * ONE file's type information plus the grammar seams the position gates read: the shape, the
 * source text, the two span-indexed type maps (`declaredTypeSources` / `castTargetSources`), the
 * import map used for FQN reconciliation, and the nullable-wrapper names. Bundled because the
 * gate chain threads all six through four helpers unchanged.
 */
typedef FileTypes = {
	final shape: RefShape;
	final source: String;
	final declaredTypeSources: Map<Int, String>;
	final castTargets: Map<Int, String>;
	final importMap: Map<String, String>;
	final wrapperNames: Array<String>;
};
/**
 * One cast node the walk found in a position, with the three context nodes the position gates
 * read: its PARENT (which position it is in at all), the enclosing function (position (b)'s
 * return annotation) and the enclosing visibility container (position (d)'s `this.f` arm).
 */
typedef CastSite = {
	final node: QueryNode;
	final span: Span;
	final parent: QueryNode;
	final enclosingFn: Null<QueryNode>;
	final enclosingContainer: Null<QueryNode>;
}

/**
 * ONE file's context for a positioned-cast report: which file it came from, its parsed tree, its
 * type information, and the resolution index the whole run shares.
 */
typedef CastScan = {
	final file: String;
	final root: QueryNode;
	final types: FileTypes;
	final resolutionIndex: () -> SymbolIndex;
}
/**
 * The kind lists `walkCasts` tests per node, resolved ONCE per walk. Read from the shape at every
 * step instead, each `?? []` fallback would allocate a fresh array per node of the tree.
 */
typedef WalkKinds = {
	final opaque: Array<String>;
	final functions: Array<String>;
	final lambdas: Array<String>;
	final bodies: Array<String>;
	final containers: Array<String>;
}
