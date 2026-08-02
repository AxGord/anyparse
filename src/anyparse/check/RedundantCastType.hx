package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Flags a runtime-CHECKED cast `cast(e, T)` sitting in a position whose expected type is
 * EXPLICITLY annotated exactly `T` — the annotation already pins the type, so the checked
 * form's type argument only restates it. The fix rewrites to the UNCHECKED `cast e`:
 * `final s:Sprite = cast(x, Sprite);` becomes `final s:Sprite = cast x;`. `Severity.Info`.
 *
 * ## Four positions, direct child only
 *
 * Only `RefShape.checkedCastKind` (Haxe `TypedCastExpr`) with exactly one child is inspected;
 * the unchecked `cast e` and the `(e : T)` ascription are different kinds and are never
 * touched. The cast must be a DIRECT child of the position node — a cast nested inside a
 * larger expression (a ternary branch, an operand) is out of scope:
 *
 *  - (a) a declaration initializer with its OWN written annotation — `localDeclKinds`
 *    (`VarStmt` / `FinalStmt` / `VarMore`) or `fieldDeclKinds` (`VarMember` / `FinalMember`);
 *  - (b) a `return` (`valueReturnKinds`) under a function carrying an explicit return
 *    annotation. The enclosing function is threaded down the walk: a node that OWNS a function
 *    body sets it (`ownsFunctionBody`, derived from a direct `functionBodyKinds` child, so the
 *    nested forms no seam names — `LocalInlineFnStmt`, `NamedFnExpr` — resolve against their own
 *    annotation), a `lambdaKinds` node CLEARS it, so a lambda return always bails. The annotation
 *    itself is told from a type-parameter CONSTRAINT — same node kind, same child slot — by
 *    position relative to the parameter list (`afterParamList`);
 *  - (c) a call-argument slot whose parameter is written `T`, and only when the callee is a
 *    bare identifier resolving to a function DECLARED in this file, EVERY parameter up to and
 *    including the slot is plain required with no default value, and the parameter's type is a
 *    plain nominal DECLARED in the `SymbolIndex`.
 *  - (d) a plain ASSIGNMENT to an already-declared, explicitly annotated lvalue —
 *    `_cp = cast(_mc.getChildByName('centerPoint'), MovieClip);` where `_cp` is declared
 *    `private var _cp:MovieClip;`.
 *
 * Macro-reification subtrees (`RefShape.opaqueKinds`) are never descended into.
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
 * container is threaded down the walk exactly as the enclosing function is), and more than one
 * match refuses. Direct-children-only does TWO jobs at once — a `#if`-guarded member is nested in
 * a `Conditional` rather than being a direct child, so it is invisible and the position is
 * skipped; and an INHERITED field is not a member of this container at all, so a superclass's
 * annotation is never read for a subclass's `this.f`. A field access on any OTHER receiver
 * (`o.a = …`) would need `o`'s own type resolved first and is refused outright.
 *
 * The (c) GENERICS veto does NOT apply to (d), for the same reason it does not apply to (a) or
 * (b): the lvalue's annotation FIXES the type rather than being driven by the value assigned.
 *
 * ## SEMANTIC NOTE - the trade-off this rule makes (user-approved)
 *
 * Measured on Haxe 4 (`--interp`): `cast(null, Foo)` and `cast null` BOTH yield `null` and
 * neither throws, so a null value behaves identically. But `cast(<a Bar instance>, Foo)`
 * THROWS while `cast <a Bar instance>` silently yields the `Bar`. The rewrite therefore trades
 * a runtime type check for brevity, and the trade-off is confined to a NON-NULL type mismatch.
 * That is exactly WHY the rule fires only on provably-annotated positions - the annotation is
 * the static guarantee standing in for the discarded runtime one - and why it is DEFAULT OFF.
 *
 * ## Default off
 *
 * Implements `DefaultOff`: opt in per project via `apqlint.json`
 * `"rules": { "redundant-cast-type": { "enabled": true } }`, or select it with `--rule`.
 *
 * ## Generics veto on the argument slot
 *
 * A parameter type must be a plain nominal that some indexed file DECLARES. A type PARAMETER
 * (`function pick<T>(v:T):T`) is declared nowhere, so the gate vetoes the one shape where the
 * argument's type would DRIVE inference rather than be constrained by it. Positions (a), (b) and
 * (d) need no such veto - their annotation FIXES the type. Consequence: a builtin-typed parameter
 * (`p:Int`) resolves only when the std / configured libraries are in the resolution scope, and
 * is a safe miss otherwise.
 *
 * ## Type identity and the comment guard
 *
 * `TypeResolver.sameTypeSource` compares the two WRITTEN forms whitespace-insensitively, plus
 * FQN reconciliation through the file's imports for plain nominals - so a generic matches only
 * its own token-identical spelling (`canonicalTypeName` refuses anything containing `<`). A
 * target whose outer nominal is a `RefShape.nullableWrapperTypeNames` entry (`Null` / `Dynamic`
 * / `Any`) is vetoed: such a check never throws, so there is no runtime check to trade away.
 * The fix deletes exactly the `cast(` head and the `, T)` tail, so a comment in either region
 * suppresses the finding outright (comments INSIDE the operand survive verbatim).
 *
 * Overlap with the sibling `redundant-cast` / `redundant-upcast` needs no gate:
 * `Cli.computeFileLintEdits` defers a later check whose edits overlap an earlier one, and those
 * siblings delete the cast entirely — a strictly better fix that converges on the next pass.
 */
@:nullSafety(Strict)
final class RedundantCastType implements Check implements DefaultOff {

	/** The rule's stable identifier — the `apqlint.json` key and the `--rule` selector. */
	private static inline final RULE_ID: String = 'redundant-cast-type';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a checked cast whose target type restates the declared type of its position';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final checkedCastKind: Null<String> = shape.checkedCastKind;
		if (checkedCastKind == null) return [];
		final castKind: String = checkedCastKind;
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (provider == null) return [];
		final typed: TypeInfoProvider = provider;
		// Built on the FIRST (c) candidate only — the argument slot is the sole position needing it,
		// and the whole run shares one index, so a file of pure (a) findings never pays for it.
		var index: Null<SymbolIndex> = null;
		function resolutionIndex(): SymbolIndex {
			final cached: Null<SymbolIndex> = index;
			if (cached != null) return cached;
			final built: SymbolIndex = RefactorSupport.resolutionIndexOf(plugin) ?? SymbolIndex.build(files, plugin);
			index = built;
			return built;
		}
		final violations: Array<Violation> = [];
		for (entry in files) scanFile(entry, plugin, shape, typed, castKind, violations, resolutionIndex);
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final checkedCastKind: Null<String> = plugin.refShape().checkedCastKind;
		return checkedCastKind == null
			? []
			: CheckScan.applyBySpan(plugin, source, violations, [checkedCastKind], (node, span) -> {
				if (node.children.length != 1) return null;
				final operandSpan: Null<Span> = node.children[0].span;
				return operandSpan == null ? null : {
					span: span,
					text: 'cast ${source.substring(operandSpan.from, operandSpan.to)}'
				};
			});
	}

	/**
	 * Append every finding in ONE file to `violations`. Split out of `run` so the tree walk's
	 * branching is its own unit and `run` owns only the seam resolution plus the shared lazy index.
	 * The walk threads the cast's PARENT, its enclosing function and its enclosing visibility
	 * CONTAINER down instead of building a parent map: each position gate needs exactly one step of
	 * context, a lambda has to CLEAR the enclosing function rather than be looked up through, and the
	 * container is what position (d)'s `this.f` arm scans for the field's own declaration.
	 */
	private static function scanFile(
		entry: { file: String, source: String }, plugin: GrammarPlugin, shape: RefShape, typed: TypeInfoProvider, castKind: String,
		violations: Array<Violation>, resolutionIndex: () -> SymbolIndex
	): Void {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
		if (tree == null) return;
		final root: QueryNode = tree;
		final source: String = entry.source;
		final types: FileTypes = {
			shape: shape,
			source: source,
			declaredTypeSources: typed.declaredTypeSources(source),
			castTargets: typed.castTargetSources(source),
			importMap: typed.importMap(source),
			wrapperNames: shape.nullableWrapperTypeNames ?? []
		};
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final functionKinds: Array<String> = shape.functionKinds ?? [];
		final lambdaKinds: Array<String> = shape.lambdaKinds ?? [];
		final bodyKinds: Array<String> = shape.functionBodyKinds ?? [];
		final containerKinds: Array<String> = shape.visibilityContainerKinds ?? [];
		function walk(
			node: QueryNode, parent: Null<QueryNode>, enclosingFn: Null<QueryNode>, enclosingType: Null<QueryNode>
		): Void {
			if (opaqueKinds.contains(node.kind)) return;
			final nextFn: Null<QueryNode> = lambdaKinds.contains(node.kind)
				? null
				: ownsFunctionBody(node, functionKinds, bodyKinds) ? node : enclosingFn;
			final nextType: Null<QueryNode> = containerKinds.contains(node.kind) ? node : enclosingType;
			final span: Null<Span> = node.span;
			if (node.kind == castKind && span != null && parent != null) {
				final targetSource: Null<String> = redundantTargetSource(
					node, span, parent, enclosingFn, enclosingType, root, types, resolutionIndex
				);
				if (targetSource != null) violations.push({
					file: entry.file,
					span: span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: 'redundant cast type - the position is already typed $targetSource'
				});
			}
			for (c in node.children) walk(c, node, nextFn, nextType);
		}
		walk(root, null, null, null);
	}

	/**
	 * The target type source of `castNode` when EVERY gate passes — the cast has exactly one
	 * operand, a recoverable target that is not a nullable wrapper, no comment in either region
	 * the fix deletes, and a position whose expected type is written identically. Null at the
	 * first gate that fails. Type identity is `TypeResolver.sameTypeSource`, so a PARAMETERISED
	 * target matches only its own token-identical spelling - a linter-level distinction rather
	 * than a shape real code carries, since Haxe itself rejects a parameterised checked cast
	 * ("Cast type parameters must be Dynamic").
	 */
	private static function redundantTargetSource(
		castNode: QueryNode, castSpan: Span, parent: QueryNode, enclosingFn: Null<QueryNode>, enclosingType: Null<QueryNode>,
		root: QueryNode, types: FileTypes, resolutionIndex: () -> SymbolIndex
	): Null<String> {
		if (castNode.children.length != 1) return null;
		final operandSpan: Null<Span> = castNode.children[0].span;
		final rawTarget: Null<String> = TypeResolver.castTargetWithin(castSpan, types.castTargets);
		if (operandSpan == null || rawTarget == null) return null;
		final targetSource: String = rawTarget;
		if (isNullableWrapper(targetSource, types.wrapperNames)) return null;
		if (deletedRegionHasComment(types.source, castSpan, operandSpan)) return null;
		final expected: Null<String> = expectedTypeSource(castNode, parent, enclosingFn, enclosingType, root, types, resolutionIndex);
		return expected != null && TypeResolver.sameTypeSource(expected, targetSource, types.importMap) ? targetSource : null;
	}

	/**
	 * The written type source the POSITION of `castNode` demands, or null when the position is not
	 * one of the four provable shapes. Dispatches on `parent`: an annotated declaration whose
	 * initializer is the cast, a `return` under an annotated function, a plain `=` assignment whose
	 * WHOLE right-hand side is the cast, or a call-argument slot.
	 */
	private static function expectedTypeSource(
		castNode: QueryNode, parent: QueryNode, enclosingFn: Null<QueryNode>, enclosingType: Null<QueryNode>, root: QueryNode,
		types: FileTypes, resolutionIndex: () -> SymbolIndex
	): Null<String> {
		final shape: RefShape = types.shape;
		final declKinds: Array<String> = (shape.localDeclKinds ?? []).concat(shape.fieldDeclKinds ?? []);
		final isFirstChild: Bool = parent.children.length > 0 && parent.children[0] == castNode;
		if (declKinds.contains(parent.kind) && isFirstChild) return declAnnotation(parent, castNode, types.declaredTypeSources);
		if ((shape.valueReturnKinds ?? []).contains(parent.kind) && isFirstChild)
			return enclosingFn == null ? null : returnAnnotation(enclosingFn, shape, types.source);
		if (parent.kind == shape.assignKind && parent.children.length == 2 && parent.children[1] == castNode)
			return assignTargetAnnotation(parent.children[0], enclosingType, root, types);
		return parent.kind == shape.callKind ? paramAnnotation(castNode, parent, root, types, resolutionIndex) : null;
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
	 * Position (b): the enclosing function's RETURN annotation — the SOLE `typeAnnotationKinds`
	 * direct child that starts AFTER the parameter list's closing `)`. Position is the whole gate:
	 * a type-parameter CONSTRAINT (`function f<T:Foo>()`) projects the very same `Named` node in
	 * the very same child slot, always BEFORE the parameter list, so trusting "exactly one
	 * annotation child" made a constrained function with NO return type read as annotated `Foo`.
	 * The `)` is searched from the last parameter's end (or the function's start when it declares
	 * none), which puts a default value's parentheses behind the cursor; metadata projects as a
	 * sibling node outside the function span. A parameter's own annotation nests UNDER the
	 * parameter node, never as a direct child of the function, so it is never a candidate.
	 */
	private static function returnAnnotation(fn: QueryNode, shape: RefShape, source: String): Null<String> {
		final fnSpan: Null<Span> = fn.span;
		if (fnSpan == null) return null;
		final paramsEnd: Int = lastParamEnd(fn, shape.paramKinds ?? []);
		final annotationKinds: Array<String> = shape.typeAnnotationKinds ?? [];
		var found: Null<Span> = null;
		var prevEnd: Int = fnSpan.from;
		for (child in fn.children) {
			final childSpan: Null<Span> = child.span;
			if (childSpan == null) return null;
			if (annotationKinds.contains(child.kind) && afterParamList(childSpan, prevEnd, paramsEnd, source)) {
				if (found != null) return null;
				found = childSpan;
			}
			prevEnd = childSpan.to;
		}
		return found == null ? null : source.substring(found.from, found.to);
	}

	/**
	 * The end offset of `fn`'s LAST declared parameter, or -1 when it declares none.
	 */
	private static function lastParamEnd(fn: QueryNode, paramKinds: Array<String>): Int {
		var end: Int = -1;
		for (child in fn.children) if (paramKinds.contains(child.kind)) {
			final paramSpan: Null<Span> = child.span;
			if (paramSpan != null && paramSpan.to > end) end = paramSpan.to;
		}
		return end;
	}

	/**
	 * Whether the annotation at `annotationSpan` sits AFTER the parameter list — the test that tells a
	 * RETURN type from a type-parameter CONSTRAINT, which projects the same node kind in the same child
	 * slot but always precedes the parameter list.
	 *
	 * With at least one declared parameter the answer is purely structural: every constraint precedes
	 * the first parameter, so starting after the LAST one settles it, whatever the header contains.
	 * A parameterless function has no such landmark, so the empty list's `)` is located in the text
	 * between the preceding sibling and the annotation. That window is guarded: a `)` may also sit
	 * inside a structural constraint (`<A:{ function n():Void; }, B:Foo>`), which is why the search
	 * starts at `prevEnd` rather than at the function's start, and a comment in the window refuses
	 * outright rather than letting a `)` inside it stand in for the parameter list.
	 */
	private static function afterParamList(annotationSpan: Span, prevEnd: Int, lastParamEnd: Int, source: String): Bool {
		if (lastParamEnd >= 0) return annotationSpan.from > lastParamEnd;
		if (CheckScan.hasCommentMarker(source, prevEnd, annotationSpan.from)) return false;
		final close: Int = source.indexOf(')', prevEnd);
		return close != -1 && close < annotationSpan.from;
	}

	/**
	 * Position (c): the written type of the parameter `cast` fills, or null at the first gate
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
		for (child in param.children) if (!annotationKinds.contains(child.kind)) return true;
		return false;
	}

	/**
	 * Position (d): the written annotation of the assignment TARGET, or null when the lvalue is not one of
	 * the two provable shapes. A BARE identifier goes through `TypeResolver.identDeclaredTypeSource`, which
	 * resolves a local, a parameter or an OWN instance / static field in ONE call and carries three bails
	 * for free - a name RE-SHADOWED in a visible scope (the resolved binding is then untrustworthy), an
	 * unresolved binding, and an INFERENCE-typed declaration with no written annotation to compare against.
	 * `skipNullableOptionalParam` is passed true because an optional / `= null`-defaulted / rest parameter's
	 * body type is `Null<T>` rather than its written `T`, which does NOT pin `T` - the runtime check there
	 * is not redundant.
	 *
	 * The second shape is an EXPLICITLY self-qualified `this.f` - a `fieldAccessKind` node whose single
	 * child is the `selfReferenceText` identifier - resolved against the enclosing container's OWN members.
	 * Any other receiver (`o.a = ...`) would need `o`'s own type resolved first and is refused.
	 */
	private static function assignTargetAnnotation(
		target: QueryNode, enclosingType: Null<QueryNode>, root: QueryNode, types: FileTypes
	): Null<String> {
		final shape: RefShape = types.shape;
		if (target.kind == shape.identKind)
			return TypeResolver.identDeclaredTypeSource(target, shape, root, () -> types.declaredTypeSources, true);
		final self: Null<String> = shape.selfReferenceText;
		final fieldName: Null<String> = target.name;
		if (
			target.kind != shape.fieldAccessKind || target.children.length != 1 || self == null || fieldName == null
			|| enclosingType == null
		)
			return null;
		final receiver: QueryNode = target.children[0];
		return receiver.kind == shape.identKind && receiver.name == self
			? ownFieldAnnotation(enclosingType, fieldName, shape, types.declaredTypeSources)
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
	 *
	 * Direct children only is deliberate and does TWO jobs at once: a `#if`-guarded member is nested in a
	 * `Conditional` rather than being a direct child, so it is invisible here and the position is skipped;
	 * and an INHERITED field is not a member of this container at all, so a superclass annotation is never
	 * read for this class's `this.f`.
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
	 * Whether `node` OWNS a function body — a `functionKinds` declaration, or ANY node carrying a
	 * direct `functionBodyKinds` child. The second arm is what reaches the nested function forms no
	 * seam names (Haxe `LocalInlineFnStmt` — the `inline function h():T {}` local-helper idiom — and
	 * `NamedFnExpr`): each carries its OWN return annotation in the same child slot a `FnMember`
	 * does, so a `return` inside one must resolve against IT, never against the outer function.
	 * Deriving the boundary from the body child rather than enumerating kind literals is what keeps
	 * a form the seam set does not list from silently inheriting the enclosing annotation.
	 */
	private static function ownsFunctionBody(node: QueryNode, functionKinds: Array<String>, bodyKinds: Array<String>): Bool {
		if (functionKinds.contains(node.kind)) return true;
		for (child in node.children) if (bodyKinds.contains(child.kind)) return true;
		return false;
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

	/**
	 * Whether the target type's OUTER nominal (the text before its first `<`) is a
	 * `RefShape.nullableWrapperTypeNames` entry — `Null` / `Dynamic` / `Any`, whose runtime
	 * check never throws, so the rewrite would trade away nothing and the finding is noise.
	 */
	private static function isNullableWrapper(targetSource: String, wrapperNames: Array<String>): Bool {
		final lt: Int = targetSource.indexOf('<');
		final outer: Null<String> = TypeResolver.simpleNominalName(lt == -1 ? targetSource : targetSource.substring(0, lt));
		return outer != null && wrapperNames.contains(outer);
	}

	/**
	 * Whether a comment marker sits in either region the fix DELETES — the `cast(` head
	 * `[cast.from, operand.from)` or the `, T)` tail `[operand.to, cast.to)`. Comments inside the
	 * operand are preserved verbatim by the fix and are fine.
	 */
	private static function deletedRegionHasComment(source: String, castSpan: Span, operandSpan: Span): Bool {
		return CheckScan.hasCommentMarker(source, castSpan.from, operandSpan.from)
			|| CheckScan.hasCommentMarker(source, operandSpan.to, castSpan.to);
	}

}

/**
 * ONE file's type information plus the grammar seams the position gates read: the shape, the
 * source text, the two span-indexed type maps (`declaredTypeSources` / `castTargetSources`), the
 * import map used for FQN reconciliation, and the nullable-wrapper names. Bundled because the
 * gate chain threads all six through four helpers unchanged.
 */
private typedef FileTypes = {
	final shape: RefShape;
	final source: String;
	final declaredTypeSources: Map<Int, String>;
	final castTargets: Map<Int, String>;
	final importMap: Map<String, String>;
	final wrapperNames: Array<String>;
};
