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
 * ## Three positions, direct child only
 *
 * Only `RefShape.checkedCastKind` (Haxe `TypedCastExpr`) with exactly one child is inspected;
 * the unchecked `cast e` and the `(e : T)` ascription are different kinds and are never
 * touched. The cast must be a DIRECT child of the position node — a cast nested inside a
 * larger expression (a ternary branch, an operand) is out of scope:
 *
 *  - (a) a declaration initializer with its OWN written annotation — `localDeclKinds`
 *    (`VarStmt` / `FinalStmt` / `VarMore`) or `fieldDeclKinds` (`VarMember` / `FinalMember`);
 *  - (b) a `return` (`valueReturnKinds`) under a function carrying an explicit return
 *    annotation. The enclosing function is threaded down the walk: a `functionKinds` node sets
 *    it, a `lambdaKinds` node CLEARS it, so a lambda return always bails;
 *  - (c) a call-argument slot whose parameter is written `T`, and only when the callee is a
 *    bare identifier resolving to a function DECLARED in this file, the slot maps to a
 *    `Required` parameter, and the parameter's type is a plain nominal DECLARED in the
 *    `SymbolIndex`.
 *
 * Macro-reification subtrees (`RefShape.opaqueKinds`) are never descended into.
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
 * argument's type would DRIVE inference rather than be constrained by it. Positions (a) and (b)
 * need no such veto - their annotation FIXES the type. Consequence: a builtin-typed parameter
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

	/**
	 * The one `RefShape.paramKinds` entry whose declared type IS the parameter's body type. The
	 * seam exposes the whole set (`Required` / `Optional` / `Rest`) with no way to tell them apart,
	 * and the other two are unusable here: an optional parameter's body type is `Null<T>`, and a
	 * rest parameter absorbs every remaining slot, breaking the argument-to-parameter mapping.
	 */
	private static inline final REQUIRED_PARAM_KIND: String = 'Required';

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
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final functionKinds: Array<String> = shape.functionKinds ?? [];
		final lambdaKinds: Array<String> = shape.lambdaKinds ?? [];
		// Built on the FIRST (c) candidate only — the argument slot is the sole position needing it.
		var index: Null<SymbolIndex> = null;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
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
			function resolutionIndex(): SymbolIndex {
				final cached: Null<SymbolIndex> = index;
				if (cached != null) return cached;
				final built: SymbolIndex = RefactorSupport.resolutionIndexOf(plugin) ?? SymbolIndex.build(files, plugin);
				index = built;
				return built;
			}
			function walk(node: QueryNode, parent: Null<QueryNode>, enclosingFn: Null<QueryNode>): Void {
				if (opaqueKinds.contains(node.kind)) return;
				final nextFn: Null<QueryNode> = lambdaKinds.contains(node.kind)
					? null
					: functionKinds.contains(node.kind) ? node : enclosingFn;
				final span: Null<Span> = node.span;
				if (node.kind == castKind && span != null && parent != null) {
					final targetSource: Null<String> = redundantTargetSource(node, span, parent, enclosingFn, root, types, resolutionIndex);
					if (targetSource != null) violations.push({
						file: entry.file,
						span: span,
						rule: RULE_ID,
						severity: Severity.Info,
						message: 'redundant cast type - the position is already typed $targetSource'
					});
				}
				for (c in node.children) walk(c, node, nextFn);
			}
			walk(root, null, null);
		}
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
	 * The target type source of `castNode` when EVERY gate passes — the cast has exactly one
	 * operand, a recoverable target that is not a nullable wrapper, no comment in either region
	 * the fix deletes, and a position whose expected type is written identically. Null at the
	 * first gate that fails. Type identity is `TypeResolver.sameTypeSource`, so a PARAMETERISED
	 * target matches only its own token-identical spelling - a linter-level distinction rather
	 * than a shape real code carries, since Haxe itself rejects a parameterised checked cast
	 * ("Cast type parameters must be Dynamic").
	 */
	private static function redundantTargetSource(
		castNode: QueryNode, castSpan: Span, parent: QueryNode, enclosingFn: Null<QueryNode>, root: QueryNode, types: FileTypes,
		resolutionIndex: () -> SymbolIndex
	): Null<String> {
		if (castNode.children.length != 1) return null;
		final operandSpan: Null<Span> = castNode.children[0].span;
		final rawTarget: Null<String> = TypeResolver.castTargetWithin(castSpan, types.castTargets);
		if (operandSpan == null || rawTarget == null) return null;
		final targetSource: String = rawTarget;
		if (isNullableWrapper(targetSource, types.wrapperNames)) return null;
		if (deletedRegionHasComment(types.source, castSpan, operandSpan)) return null;
		final expected: Null<String> = expectedTypeSource(castNode, parent, enclosingFn, root, types, resolutionIndex);
		return expected != null && TypeResolver.sameTypeSource(expected, targetSource, types.importMap) ? targetSource : null;
	}

	/**
	 * The written type source the POSITION of `castNode` demands, or null when the position is not
	 * one of the three provable shapes. Dispatches on `parent`: an annotated declaration whose
	 * initializer is the cast, a `return` under an annotated function, or a call-argument slot.
	 */
	private static function expectedTypeSource(
		castNode: QueryNode, parent: QueryNode, enclosingFn: Null<QueryNode>, root: QueryNode, types: FileTypes,
		resolutionIndex: () -> SymbolIndex
	): Null<String> {
		final shape: RefShape = types.shape;
		final declKinds: Array<String> = (shape.localDeclKinds ?? []).concat(shape.fieldDeclKinds ?? []);
		final isFirstChild: Bool = parent.children.length > 0 && parent.children[0] == castNode;
		if (declKinds.contains(parent.kind) && isFirstChild) return declAnnotation(parent, castNode, types.declaredTypeSources);
		if ((shape.valueReturnKinds ?? []).contains(parent.kind) && isFirstChild)
			return enclosingFn == null ? null : returnAnnotation(enclosingFn, shape, types.source);
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
	 * Position (b): the enclosing function's return annotation — its DIRECT child whose kind is
	 * in `RefShape.typeAnnotationKinds`, required to be EXACTLY ONE (else bail). A parameter's
	 * own annotation nests UNDER the parameter node, never as a direct child of the function, so
	 * the single direct annotation child IS the return type.
	 */
	private static function returnAnnotation(fn: QueryNode, shape: RefShape, source: String): Null<String> {
		final annotationKinds: Array<String> = shape.typeAnnotationKinds ?? [];
		var found: Null<QueryNode> = null;
		for (child in fn.children) if (annotationKinds.contains(child.kind)) {
			if (found != null) return null;
			found = child;
		}
		if (found == null) return null;
		final annotationSpan: Null<Span> = found.span;
		return annotationSpan == null ? null : source.substring(annotationSpan.from, annotationSpan.to);
	}

	/**
	 * Position (c): the written type of the parameter `cast` fills, or null at the first gate
	 * that fails. The callee (`call.children[0]`) must be a bare identifier resolving to a
	 * `functionKinds` declaration in this file (the INNERMOST one of that name covering the
	 * binding, so a nested local function wins over its host); the slot must map to a `Required`
	 * parameter (an optional param's body type is `Null<T>`, a rest param breaks slot mapping);
	 * and the parameter's type must be a plain nominal the index DECLARES (the generics veto).
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
		final param: Null<QueryNode> = nthParam(fn, shape.paramKinds ?? [], slot - 1);
		if (param == null || param.kind != REQUIRED_PARAM_KIND) return null;
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

	/** The `slot`-th (0-based) direct child of `fn` whose kind is in `paramKinds`, or null when there are fewer. */
	private static function nthParam(fn: QueryNode, paramKinds: Array<String>, slot: Int): Null<QueryNode> {
		var seen: Int = 0;
		for (child in fn.children) if (paramKinds.contains(child.kind)) {
			if (seen == slot) return child;
			seen++;
		}
		return null;
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
