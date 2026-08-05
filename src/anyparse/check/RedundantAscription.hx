package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Flags a parenthesised ascription `(new T(...) : T)` whose ascribed type restates the
 * constructed class name — the construction already has type `T`, so the ascription is a
 * no-op. `Severity.Info`; `fix` unwraps it to the bare `new T(...)`.
 *
 * ## HARD BOUNDARY: only the `new T(...)` operand shape
 *
 * The ascription's operand must be a direct `RefShape.newExprKind` node — an identifier, a
 * call, a field access, or any OTHER expression is never touched, no matter how its written
 * type compares to the ascribed one. This is deliberate, not merely conservative: an
 * identifier ascription can be load-bearing null-safety narrowing that the construction shape
 * can never need (a `new T(...)` result is never null, so nothing to narrow). Proven on real
 * code — a `(x : Int)` ascribing a `Null<Int>` local to the non-null `Int` an object-literal
 * field demands fails to COMPILE once the ascription is removed. Comparing an identifier's
 * declared type source against the ascribed one (the way `redundant-cast` treats
 * `cast(x, T)` / `(x : T)` uniformly) would flag exactly that shape and silently break the
 * build — so this check does not generalize `redundant-cast`'s operand handling and stays
 * scoped to constructions only.
 *
 * ## Byte-equal, not FQN-reconciled
 *
 * Comparison is `TypeResolver.stripWs` equality on the two WRITTEN forms — whitespace
 * differences fold, nothing else does. Unlike `redundant-cast` / `redundant-cast-type`, a
 * bare name is NOT reconciled against its qualified spelling through the file's imports:
 * `(new haxe.ds.StringMap() : StringMap)` is a safe miss even though both name the same
 * type. The narrower contract matches the task's proof obligation (byte-equal, whitespace-
 * insensitive) without inheriting `TypeResolver.sameTypeSource`'s import-aware canonicalization,
 * which this check has no fixture requiring.
 *
 * ## No type parameters, either side
 *
 * The ascribed type must carry NO type parameters (`indexOf('<') == -1`) — a defense-in-depth
 * gate kept explicit even though a parameterised ascribed type could not byte-equal an
 * unparameterised constructor name anyway (`HxNewExpr.type` never carries `<...>`; its type
 * arguments are a separate `params` field). Keeping the gate explicit documents the boundary
 * independently of how the equality check is implemented, and refuses outright rather than
 * relying on the comparison to reject it as a side effect.
 *
 * ## Comment guard
 *
 * The fix deletes exactly the ascription's `(` head `[node.from, operand.from)` and the
 * ` : T)` tail `[operand.to, node.to)`, so a comment marker in either region suppresses the
 * finding outright — the same discipline `RedundantCastType` uses for its own two deleted
 * regions. A comment INSIDE the operand (the constructor call's own arguments) survives
 * verbatim, since the fix's replacement text is the operand's substring unchanged.
 *
 * ## Default off
 *
 * Implements `DefaultOff`: opt in per project via `apqlint.json`
 * `"rules": { "redundant-ascription": { "enabled": true } }`, or select it with
 * `--rule redundant-ascription`.
 */
@:nullSafety(Strict)
final class RedundantAscription implements Check implements DefaultOff {

	/** The rule's stable identifier — the `apqlint.json` key and the `--rule` selector. */
	private static inline final RULE_ID: String = 'redundant-ascription';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a `(new T(...) : T)` ascription restating the constructed type';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (provider == null) return [];
		final typed: TypeInfoProvider = provider;
		final violations: Array<Violation> = [];
		for (entry in files) scanFile(entry, plugin, seams, typed, violations);
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		return seams == null
			? []
			: CheckScan.applyBySpan(plugin, source, violations, [seams.checkTypeKind], (node, span) -> {
				if (node.children.length != 1) return null;
				final opSpan: Null<Span> = node.children[0].span;
				return opSpan == null ? null : { span: span, text: source.substring(opSpan.from, opSpan.to) };
			});
	}

	/** Append every finding in ONE file to `violations`. */
	private static function scanFile(
		entry: { file: String, source: String }, plugin: GrammarPlugin, seams: Seams, typed: TypeInfoProvider, violations: Array<Violation>
	): Void {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
		if (tree == null) return;
		final source: String = entry.source;
		final castTargets: Map<Int, String> = typed.castTargetSources(source);
		final opaqueKinds: Array<String> = seams.opaqueKinds;
		function walk(node: QueryNode): Void {
			if (opaqueKinds.contains(node.kind)) return;
			if (node.kind == seams.checkTypeKind && node.children.length == 1) {
				final span: Null<Span> = node.span;
				final operand: QueryNode = node.children[0];
				final operandSpan: Null<Span> = operand.span;
				if (
					span != null && operandSpan != null && operand.kind == seams.newExprKind
					&& redundantTargetSource(node, span, operand, operandSpan, source, castTargets) != null
				) violations.push({
					file: entry.file,
					span: span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: 'redundant ascription — already constructs ${operand.name}'
				});
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
	}

	/**
	 * The ascribed type source when EVERY gate passes — the operand is a `new T(...)` with a
	 * recovered constructor name, the ascribed type carries no type parameters, its written form
	 * is byte-equal (whitespace-insensitive) to the constructor name, and no comment sits in
	 * either region the fix deletes. Null at the first gate that fails.
	 */
	private static function redundantTargetSource(
		node: QueryNode, span: Span, operand: QueryNode, operandSpan: Span, source: String, castTargets: Map<Int, String>
	): Null<String> {
		final ctorName: Null<String> = operand.name;
		if (ctorName == null) return null;
		final targetSource: Null<String> = TypeResolver.castTargetWithin(span, castTargets);
		if (targetSource == null || targetSource.indexOf('<') != -1) return null;
		if (TypeResolver.stripWs(targetSource) != TypeResolver.stripWs(ctorName)) return null;
		if (deletedRegionHasComment(source, span, operandSpan)) return null;
		return targetSource;
	}

	/**
	 * Whether a comment marker sits in either region the fix DELETES — the `(` head
	 * `[node.from, operand.from)` or the ` : T)` tail `[operand.to, node.to)`. A comment inside
	 * the operand is preserved verbatim by the fix and is fine.
	 */
	private static function deletedRegionHasComment(source: String, nodeSpan: Span, operandSpan: Span): Bool {
		return CheckScan.hasCommentMarker(source, nodeSpan.from, operandSpan.from)
			|| CheckScan.hasCommentMarker(source, operandSpan.to, nodeSpan.to);
	}

	/** Resolve the check-type + new-expr + opaque seam kinds, or null when either required kind is unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final checkTypeKind: Null<String> = shape.checkTypeKind;
		final newExprKind: Null<String> = shape.newExprKind;
		if (checkTypeKind == null || newExprKind == null) return null;
		return { checkTypeKind: checkTypeKind, newExprKind: newExprKind, opaqueKinds: shape.opaqueKinds ?? [] };
	}

}

/** The resolved seams `RedundantAscription` reads in both `run` and `fix`. */
private typedef Seams = {
	final checkTypeKind: String;
	final newExprKind: String;
	final opaqueKinds: Array<String>;
};
