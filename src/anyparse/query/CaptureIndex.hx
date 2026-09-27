package anyparse.query;

import anyparse.query.CasePatterns.PatternScan;
import anyparse.query.CasePatterns.SubjectProof;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Refs.RefBinding;
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
 * A capture is visible from the end of the arm's pattern run, and every alternative of
 * `case A(x), B(x):` resolves to the FIRST one's binding. A capture `CasePatterns.isDecidedCapture`
 * cannot prove is still a declaration, marked undecided with the binding it would hide. The walk sees
 * one file and no index, so the file's lookup order (`PatternNameScope`) is unreadable here and
 * every BARE capture is undecided; only `var x` and `x = p` are proven. A name a
 * constant declaration in this file may claim stays a READ of whatever it resolves to, undecided
 * unless it resolves to the file's ONLY constant declaration of that name.
 *
 * Instance state for one walk, never shared: the constants are computed from the walk's root on
 * the first arm and the node map dies with the walk.
 */
@:nullSafety(Strict)
final class CaptureIndex {

	private final _hits: Map<QueryNode, PatternHit> = [];
	private final _switchOf: Map<QueryNode, QueryNode> = [];
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
	 * The name of every identifier a `switch` of the root switches on. `Refs` resolves them alongside
	 * the searched names — a capture's reading depends on its subject's declared type — and drops
	 * their hits afterwards. Also records each arm's switch for `bindArm`.
	 */
	public function subjectNames(): Array<String> {
		final out: Array<String> = [];
		final switchKinds: Array<String> = _shape.switchKinds ?? [];
		function walk(node: QueryNode): Void {
			if (switchKinds.contains(node.kind) && node.children.length > 0) {
				for (i in 1...node.children.length) _switchOf[node.children[i]] = node;
				var subject: QueryNode = node.children[0];
				while (subject.kind == _shape.parenKind && subject.children.length == 1) subject = subject.children[0];
				final name: Null<String> = subject.kind == _shape.identKind ? subject.name : null;
				if (name != null && !out.contains(name)) out.push(name);
			}
			for (child in node.children) walk(child);
		}
		walk(_root);
		return out;
	}

	/**
	 * Classify every pattern name of `arm` that the walk searches for, binding each capture into
	 * `frame` — the arm's own frame, not yet on `scopes`, so a lookup through `scopes` answers the
	 * binding the capture SHADOWS and the declaration of the switch subject.
	 *
	 * A capture is visible from the end of the arm's pattern run: the guard and the body see it, an
	 * extractor's left side (an expression evaluated on the subject) does not. Every later capture
	 * of the same name — an alternative of `case A(x), B(x):` or a side of `A(x) | B(x)` — binds to
	 * the first.
	 */
	public function bindArm(arm: QueryNode, frame: ScopeFrame, scopes: ScopeStack, out: Map<String, Array<RefHit>>): Void {
		final run: Array<QueryNode> = CasePatterns.patternRun(arm, _shape);
		final armSpan: Null<Span> = arm.span;
		if (armSpan == null) return;
		final lastSpan: Null<Span> = run.length == 0 ? null : run[run.length - 1].span;
		final visibleFrom: Int = lastSpan == null ? armSpan.from : lastSpan.to;
		final constants: Array<QueryNode> = constantDeclarations();
		final found: PatternScan = CasePatterns.scan(arm, _shape, [for (c in constants) c.name ?? '']);
		final proof: SubjectProof = CasePatterns.subjectProof(_switchOf[arm], _root, _shape, subject -> {
			final name: Null<String> = subject.name;
			final span: Null<Span> = subject.span;
			return name == null || span == null ? null : scopes.resolveInnermost(name, span.from)?.node;
		});
		final first: Map<String, RefBinding> = [];
		for (ident in found.idents) {
			final name: String = ident.name;
			final span: Null<Span> = ident.node.span;
			if (span == null || !out.exists(name)) continue;
			final outer: Null<ScopeBinding> = scopes.resolveInnermost(name, span.from);
			final hit: PatternHit = switch ident.role {
				case Capture:
					final binding: RefBinding = first[name] ?? { node: ident.node, span: span };
					if (!first.exists(name)) {
						first[name] = binding;
						frame.declare(name, ident.node, span, visibleFrom);
					}
					final decided: Bool = CasePatterns.isDecidedCapture(ident, proof, null);
					{
						kind: RefKind.Decl,
						binding: binding,
						undecided: !decided,
						shadows: decided ? null : outer?.span
					};
				case Undecided:
					final constant: Bool = outer != null && isSoleConstant(constants, outer.node, name) && ident.whole && proof.typed;

					{
						kind: RefKind.Read,
						binding: null,
						undecided: !constant,
						shadows: null
					};
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

	/** The first capture of the name in the arm, for a capture; null for a read, which resolves as usual. */
	final binding: Null<RefBinding>;
	final undecided: Bool;

	/** For an undecided capture, the binding it would shadow if it does capture — a rewrite of THAT binding refuses too. */
	final shadows: Null<Span>;
};
