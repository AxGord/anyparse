package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.ExpectedType.CastScan;
import anyparse.check.ExpectedType.CastSite;
import anyparse.check.ExpectedType.FileTypes;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Flags an UNCHECKED cast `cast e` whose POSITION is written exactly the type `e` is already
 * declared to be — the cast converts nothing, tests nothing, and can be deleted.
 * `renderXHTML(element, cast sprite, w)` where the parameter is `parentObject:Sprite` and the
 * local is `final sprite:Sprite` is the shape. `Severity.Info`; `fix` unwraps to the operand.
 *
 * ## The gap it closes
 *
 * The four sibling cast rules — `redundant-cast`, `redundant-upcast`, `impossible-cast`,
 * `redundant-cast-type` — all read `RefShape.typedCastKinds` / `checkedCastKind`, so every one
 * of them sees only `cast(x, T)` and `(x : T)`. The single-argument `cast e`
 * (`RefShape.uncheckedCastKind`) had no rule at all: it carries no target type of its own, so
 * "is the target redundant?" is not a question that can be asked of it. The question that CAN
 * be asked is the mirror one — does the position demand exactly what the operand already is?
 *
 * ## What it takes to be provable
 *
 * The POSITION half is `ExpectedType.expectedTypeSource`, shared verbatim with
 * `redundant-cast-type`: an annotated declaration initializer, an annotated `return`, a plain
 * assignment to an annotated lvalue, or a call-argument slot whose parameter is written `T` (see
 * that module's doc for every gate and bail). The OPERAND half is
 * `TypeResolver.identDeclaredTypeSource`, which resolves a local, a parameter or an own field and
 * bails on a name RE-SHADOWED in a visible scope, on an unresolved binding, and on an
 * inference-typed declaration with no written annotation. It is called with
 * `skipNullableOptionalParam = true`: an optional / `= null`-defaulted / rest parameter's body
 * type is `Null<T>` rather than its written `T`, and a cast from `Null<T>` to `T` is doing work.
 *
 * Both sides must then be the SAME written type under `TypeResolver.sameTypeSource`
 * (whitespace-insensitive, with FQN reconciliation through the file's imports). That comparison
 * is what makes the rule safe on the shape an unchecked cast most often exists FOR — an invariant
 * generic (`content.addItems(cast _elements)` handing an `Array<CheckBox>` to an
 * `Array<DisplayObject>` slot). Two different spellings never match, so a variance bridge is
 * never proposed for deletion.
 *
 * ## Two vetoes
 *
 * A position whose type is a `RefShape.nullableWrapperTypeNames` entry (`Null` / `Dynamic` /
 * `Any`) is refused by `ExpectedType.isNullableWrapper`: a cast INTO one is what ERASES a type,
 * which is work, not a restatement. And a comment between the `cast` keyword and its operand
 * suppresses the finding — that is exactly the region the fix deletes, and it is where an author
 * records why a cast that looks pointless is not.
 *
 * Macro-reification subtrees (`RefShape.opaqueKinds`) are never descended into.
 */
@:nullSafety(Strict)
final class RedundantUncheckedCast implements Check {

	/** The rule's stable identifier — the `apqlint.json` key and the `--rule` selector. */
	private static inline final RULE_ID: String = 'redundant-unchecked-cast';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'an unchecked cast whose position is already typed exactly what the operand is';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final violations: Array<Violation> = [];
		ExpectedType.eachPositionedCast(files, plugin, plugin.refShape().uncheckedCastKind, (site, scan) -> {
			final settled: Null<String> = settledTypeSource(site, scan);
			if (settled != null) violations.push({
				file: scan.file,
				span: site.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'redundant cast - operand and position are both $settled'
			});
		});
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final castKind: Null<String> = plugin.refShape().uncheckedCastKind;
		return castKind == null
			? []
			: CheckScan.applyBySpan(plugin, source, violations, [castKind], (node, span) -> {
				if (node.children.length != 1) return null;
				final operandSpan: Null<Span> = node.children[0].span;
				return operandSpan == null ? null : { span: span, text: source.substring(operandSpan.from, operandSpan.to) };
			});
	}

	/**
	 * The written type BOTH sides settle on when every gate passes — the cast has exactly one
	 * operand, no comment sits in the `cast ` head the fix deletes, the position demands a type
	 * that is not a nullable wrapper, the operand carries a resolvable written type, and the two
	 * are the same type. Null at the first gate that fails.
	 */
	private static function settledTypeSource(site: CastSite, scan: CastScan): Null<String> {
		final types: FileTypes = scan.types;
		final operand: Null<QueryNode> = ExpectedType.soleOperand(site);
		if (operand == null) return null;
		final operandSpan: Null<Span> = operand.span;
		if (operandSpan == null || CheckScan.hasCommentMarker(types.source, site.span.from, operandSpan.from)) return null;
		final expected: Null<String> = ExpectedType.expectedTypeSource(site, scan.root, types, scan.resolutionIndex);
		if (expected == null || ExpectedType.isNullableWrapper(expected, types.wrapperNames)) return null;
		final position: String = expected;
		final declared: Null<String> = TypeResolver.identDeclaredTypeSource(
			operand, types.shape, scan.root, () -> types.declaredTypeSources, true
		);
		return declared != null && TypeResolver.sameTypeSource(declared, position, types.importMap) ? position : null;
	}

}
