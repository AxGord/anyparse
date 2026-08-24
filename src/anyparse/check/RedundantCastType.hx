package anyparse.check;

import anyparse.check.Check.DefaultOff;
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
 * Flags a runtime-CHECKED cast `cast(e, T)` sitting in a position whose expected type is
 * EXPLICITLY annotated exactly `T` — the annotation already pins the type, so the checked
 * form's type argument only restates it. The fix rewrites to the UNCHECKED `cast e`:
 * `final s:Sprite = cast(x, Sprite);` becomes `final s:Sprite = cast x;`. `Severity.Info`.
 *
 * ## Four positions, direct child only
 *
 * Only `RefShape.checkedCastKind` (Haxe `TypedCastExpr`) with exactly one child is inspected;
 * the unchecked `cast e` and the `(e : T)` ascription are different kinds and are never
 * touched. Which POSITIONS count, and every gate and bail behind them, is `ExpectedType`'s —
 * a declaration initializer, an annotated `return`, a call-argument slot, a plain assignment —
 * and its class doc is where they are documented, since `redundant-unchecked-cast` reads the
 * same four from the other side. This check owns only what it does with the answer.
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
		final violations: Array<Violation> = [];
		ExpectedType.eachPositionedCast(files, plugin, plugin.refShape().checkedCastKind, (site, scan) -> {
			final targetSource: Null<String> = redundantTargetSource(site, scan);
			if (targetSource != null) violations.push({
				file: scan.file,
				span: site.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'redundant cast type - the position is already typed $targetSource'
			});
		});
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
	private static function redundantTargetSource(site: CastSite, scan: CastScan): Null<String> {
		final types: FileTypes = scan.types;
		final operand: Null<QueryNode> = ExpectedType.soleOperand(site);
		if (operand == null) return null;
		final operandSpan: Null<Span> = operand.span;
		final rawTarget: Null<String> = TypeResolver.castTargetWithin(site.span, types.castTargets);
		if (operandSpan == null || rawTarget == null) return null;
		final targetSource: String = rawTarget;
		if (ExpectedType.isNullableWrapper(targetSource, types.wrapperNames)) return null;
		if (deletedRegionHasComment(types.source, site.span, operandSpan)) return null;
		final expected: Null<String> = ExpectedType.expectedTypeSource(site, scan.root, types, scan.resolutionIndex);
		return expected != null && TypeResolver.sameTypeSource(expected, targetSource, types.importMap) ? targetSource : null;
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
