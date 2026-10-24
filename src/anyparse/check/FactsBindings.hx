package anyparse.check;

import anyparse.check.facts.FactsTypeOracle;
import anyparse.query.BoolExprShape;
import anyparse.query.CasePatterns;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.NominalTypes;
import anyparse.runtime.Span;

using Lambda;

/**
 * Which bindings the compiler typed the moment it bound them, read off its facts (`FactsTypeOracle`): a binding no later
 * use of its value can have typed, as one may an unannotated local's (`var xs = []`, then `StringTools.trim(xs[0])`).
 * `fixedAt` is the positive list. Its own module because the question walks the syntax — a case arm's pattern
 * (`CasePatterns`), a loop's operands (`NominalTypes`) — as well as the facts.
 */
@:nullSafety(Strict)
final class FactsBindings {

	/**
	 * Whether the compiler fixed the type of the binding `decl` declares (in `root`, the tree of `file`) when it bound it,
	 * read off `oracle`'s facts of the text the compile read (`FactsTypeOracle.readsAsCompiled`). A POSITIVE list:
	 *
	 * - a capture of a constructor pattern's argument (`CasePatterns`, `PatternSite.Slot`) when every constructor of that
	 *   name the facts hold types the argument closed (`FactsTypeTree.isClosed`): a type parameter there takes the
	 *   subject's type argument, which may be a monomorph a later call binds (`case Box(v)` over `var g = Box(null)`);
	 * - the binder of a single-binder loop over a call every call fact at its range dispatches to one field, neither a
	 *   macro nor overloaded, declared with a closed result: the iterable's type, and so the binder's, is that signature's
	 *   whatever the arguments are.
	 *
	 * Anything else is false: a loop over a local or over a generic call, a lambda's parameter, a whole-pattern capture.
	 */
	public static function fixedAt(oracle: FactsTypeOracle, file: String, root: QueryNode, decl: QueryNode, shape: RefShape): Bool {
		final span: Null<Span> = decl.span;
		if (span == null || !oracle.readsAsCompiled(file)) return false;
		if ((shape.iterationBindingKinds ?? []).contains(decl.kind)) return iteratesClosedCall(oracle, file, decl, shape);
		return switch captureSite(root, span, shape) {
			case Slot(callee, index): oracle.constructorArgumentClosed(callee, index);
			case _: false;
		};
	}

	/**
	 * Where the expected type of the pattern capture at `at` comes from (`CasePatterns.PatternSite`), read off the case arm
	 * under `node` whose pattern holds it; null when no arm's pattern captures there.
	 */
	private static function captureSite(node: QueryNode, at: Span, shape: RefShape): Null<PatternSite> {
		final within: Null<Span> = node.span;
		// a node the parser gave no span (the module root) may still hold the arm
		if (within != null && (within.from > at.from || within.to < at.to)) return null;
		if (node.kind == shape.caseBranchKind) {
			final ident: Null<PatternIdent> = CasePatterns.scan(node, shape, [])
				.idents.find(i -> i.role == PatternRole.Capture && i.node.span?.from == at.from);
			if (ident != null) return ident.site;
		}
		for (child in node.children) {
			final found: Null<PatternSite> = captureSite(child, at, shape);
			if (found != null) return found;
		}
		return null;
	}

	/** Whether the single-binder loop `loop` of `file` iterates a call with a closed result (`FactsTypeOracle.callResultClosed`). */
	private static function iteratesClosedCall(oracle: FactsTypeOracle, file: String, loop: QueryNode, shape: RefShape): Bool {
		final binders: Array<String> = shape.iterationValueBinderKinds ?? [];
		final iterable: Null<QueryNode> = NominalTypes.iterationValueBinder(loop, binders) == null
			? NominalTypes.iterationIterable(loop, binders)
			: null;
		final call: Null<QueryNode> = iterable == null ? null : BoolExprShape.unwrapParens(iterable, shape.parenKind);
		final at: Null<Span> = call?.span;
		return call != null && at != null && call.kind == shape.callKind && oracle.callResultClosed(file, at);
	}

}
