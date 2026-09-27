package anyparse.query;

import anyparse.query.CasePatterns.PatternScan;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.query.Scope.ScopeBinding;
import anyparse.query.Scope.ScopeFrame;
import anyparse.query.Scope.ScopeStack;
import anyparse.runtime.Span;

/**
 * The `case` pattern captures of ONE `Refs` walk: which pattern nodes bind, and how each is emitted.
 *
 * A bare lowercase identifier in a pattern CAPTURES — it never compares against a same-named local,
 * parameter or field in scope — so it is a declaration, bound into its arm's frame and visible to
 * the arm's guard and body. Which nodes capture is `CasePatterns.scan`'s answer, the one definition
 * every consumer shares; this class only turns it into hits.
 *
 * A capture binds from the arm's first byte, so every alternative of `case A(x), B(x):` resolves
 * to the FIRST one's binding. A capture of a name no binding in the file reaches is still a
 * declaration, marked undecided (an imported constant of that name would compare). A name a
 * constant declaration in this file may claim stays a READ of whatever it resolves to, undecided
 * unless it resolves to the file's ONLY constant declaration of that name.
 *
 * Instance state for one walk, never shared: the constants are computed from the walk's root on
 * the first arm and the node map dies with the walk.
 */
@:nullSafety(Strict)
final class CaptureIndex {

	private final _hits: Map<QueryNode, PatternHit> = [];
	private final _root: QueryNode;
	private final _shape: RefShape;
	private var _constants: Null<Array<QueryNode>> = null;
	private var _count: Int = 0;

	public function new(root: QueryNode, shape: RefShape) {
		_root = root;
		_shape = shape;
	}

	/** How `node` is emitted when it is a pattern name `bindArm` classified, else null. */
	public inline function hitOf(node: QueryNode): Null<PatternHit> {
		return _count == 0 ? null : _hits[node];
	}

	/**
	 * Classify every pattern name of `arm` that the walk searches for, binding each capture into
	 * `frame` — the arm's own frame, not yet on `scopes`, so a lookup through `scopes` answers the
	 * binding the capture SHADOWS.
	 */
	public function bindArm(arm: QueryNode, frame: ScopeFrame, scopes: ScopeStack, out: Map<String, Array<RefHit>>): Void {
		final armSpan: Null<Span> = arm.span;
		if (armSpan == null) return;
		final constants: Array<QueryNode> = constantDeclarations();
		final found: PatternScan = CasePatterns.scan(arm, _shape, [for (c in constants) c.name ?? '']);
		final declared: Array<String> = [];
		for (ident in found.idents) {
			final name: String = ident.name;
			final span: Null<Span> = ident.node.span;
			if (span == null || !out.exists(name)) continue;
			final outer: Null<ScopeBinding> = scopes.resolveInnermost(name, span.from);
			final hit: PatternHit = switch ident.role {
				case Capture:
					if (!declared.contains(name)) {
						declared.push(name);
						frame.declare(name, ident.node, span, armSpan.from);
					}
					{ kind: RefKind.Decl, undecided: !ident.explicit && outer == null };
				case Undecided:
					{ kind: RefKind.Read, undecided: outer == null || !isSoleConstant(constants, outer.node, name) };
			};
			_hits[ident.node] = hit;
			_count++;
		}
	}

	/** The constant declarations of the walk's root, computed once. */
	private function constantDeclarations(): Array<QueryNode> {
		final cached: Null<Array<QueryNode>> = _constants;
		if (cached != null) return cached;
		final found: Array<QueryNode> = CasePatterns.constantDeclarations([_root], _shape);
		_constants = found;
		return found;
	}

	/** Whether `decl` is a constant declaration and no OTHER one in the file shares its name. */
	private static function isSoleConstant(constants: Array<QueryNode>, decl: QueryNode, name: String): Bool {
		return constants.contains(decl) && constants.filter(c -> c.name == name).length == 1;
	}

}

/** How `Refs` emits one pattern name `CaptureIndex` classified. */
typedef PatternHit = {
	final kind: RefKind;
	final undecided: Bool;
};
