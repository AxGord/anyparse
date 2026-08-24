package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags a LOCAL declaration whose name is already bound — by an enclosing local, a loop or catch
 * binder, a local function, or a parameter — at the point it takes effect. `Warning`,
 * REPORT-ONLY: which of the two names is the wrong one is the author's call.
 *
 * ## The mistake it names
 *
 * Haxe allows the redeclaration and says nothing. The reader sees one name and assumes one
 * variable, so a write meant for the OUTER binding silently lands on the inner one and the outer
 * keeps whatever it had:
 *
 * ```haxe
 * var displayObject:DisplayObject = null;
 * switch element.name {
 *     case 'div':
 *         var displayObject:Sprite = new Sprite();   // shadows — the outer stays null
 *         renderXHTML(element, displayObject, maxWidth);
 * }
 * if (displayObject == null) continue;               // always taken for a 'div'
 * ```
 *
 * That is a real defect found by this rule: everything a `<div>` rendered went into a sprite
 * nobody attached. Nothing in the type system or the formatter can see it — the two declarations
 * are individually correct.
 *
 * ## Scope-correct by construction
 *
 * `shadowing-case-binder` asks a sibling question through `CasePatternScan.shadowedDeclaration`,
 * whose `declaresBefore` scans the WHOLE enclosing function subtree for an earlier declaration of
 * the name. For a case binder that over-approximation is harmless. For a local declaration it is
 * not: two `switch` arms each declaring `q` are mutually invisible, and the arm written second
 * would be reported as shadowing the first. So this check walks the ANCESTOR chain instead, and
 * at each `RefShape.positionScopedKinds` frame on it inspects that frame's DIRECT children only —
 * exactly the declarations a reference at the inner site could resolve to. The frame the walk
 * arrived FROM is skipped, so a declaration never shadows itself.
 *
 * The walk stops at the first class-like container (`RefactorSupport.classLikeContainerKinds`):
 * a local that shares its name with a FIELD is the ordinary Haxe idiom, not a mistake, and
 * reporting it would bury the finding above in noise.
 *
 * A same-block redeclaration (`var q = 1; … var q = 2;` in one statement list) IS reported: the
 * second takes over from its own position, which is the same trap one indent shallower.
 *
 * ## What is not reported
 *
 * A declaration whose INITIALIZER reads the name it shadows is skipped: `final x:T = x;`,
 * `final o:ONotNull = setDefaults(o);`. See `rebindsShadowed` — the outer binding is being
 * CONSUMED there on purpose, not hidden by accident. Measured over an 805-file tree, that gate
 * turned 49 findings into 34, and every one it removed was one of those two idioms.
 *
 * A declaration inside a conditional-compilation region (`RefShape.conditionalMemberKind`) is
 * skipped: two mutually exclusive `#if` arms may each declare the name, and only one of them is
 * ever compiled, so an earlier arm's declaration is not in scope for the later one. The walk
 * still DESCENDS into the region — a shadow whose inner declaration is unguarded and whose outer
 * one is not is still visible from outside it.
 *
 * Macro-reification subtrees (`RefShape.opaqueKinds`) are never descended into: a splice may
 * carry declarations no source scan resolves.
 */
@:nullSafety(Strict)
final class ShadowingLocal implements Check {

	/** The rule's stable identifier — the `apqlint.json` key and the `--rule` selector. */
	private static inline final RULE_ID: String = 'shadowing-local';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a local declaration whose name is already bound by an enclosing local, binder or parameter';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<ScopeSeams> = seamsOf(plugin.refShape());
		if (seams == null) return [];
		final resolved: ScopeSeams = seams;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) scan(tree, [], false, resolved, entry.file, violations);
		}
		return violations;
	}

	/** Report-only: renaming the inner declaration or the outer one is the author's call. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/**
	 * Walk `node`'s subtree carrying its ANCESTOR chain, reporting every local declaration whose
	 * name a frame on that chain already binds. `ancestors` is mutated in place and restored on the
	 * way out — one array for the whole file rather than a path lookup per declaration.
	 */
	private static function scan(
		node: QueryNode, ancestors: Array<QueryNode>, inConditional: Bool, seams: ScopeSeams, file: String, out: Array<Violation>
	): Void {
		if (seams.opaqueKinds.contains(node.kind)) return;
		final span: Null<Span> = node.span;
		final name: Null<String> = node.name;
		if (!inConditional && seams.localDeclKinds.contains(node.kind) && name != null && span != null) {
			final hidden: Null<String> = shadowedBinding(node, ancestors, seams);
			if (hidden != null && !rebindsShadowed(node, name, seams)) out.push({
				file: file,
				span: span,
				rule: RULE_ID,
				severity: Severity.Warning,
				message: 'shadowing declaration - "$name" is already a $hidden in scope here'
			});
		}
		final nested: Bool = inConditional || node.kind == seams.conditionalKind;
		ancestors.push(node);
		for (child in node.children) scan(child, ancestors, nested, seams, file, out);
		ancestors.pop();
	}

	/**
	 * What `decl`'s name is ALREADY bound to on the ancestor chain — `'parameter'` or `'local'` —
	 * or null when nothing binds it. Walks inward-out: at every position-scoped frame the frame's
	 * DIRECT declaration-host children are the candidates, minus the one the walk arrived from, and
	 * a candidate counts only when it starts before `decl` does. Stops at the first class-like
	 * container, so a field of the same name is never a finding.
	 */
	private static function shadowedBinding(decl: QueryNode, ancestors: Array<QueryNode>, seams: ScopeSeams): Null<String> {
		final name: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		if (name == null || declSpan == null) return null;
		var arrivedFrom: QueryNode = decl;
		var at: Int = ancestors.length - 1;
		while (at >= 0) {
			final frame: QueryNode = ancestors[at];
			if (seams.classLikeKinds.contains(frame.kind)) return null;
			if (seams.positionScopedKinds.contains(frame.kind)) {
				final hidden: Null<String> = declaredIn(frame, arrivedFrom, name, declSpan.from, seams);
				if (hidden != null) return hidden;
			}
			arrivedFrom = frame;
			at--;
		}
		return null;
	}

	/**
	 * The kind of binding `frame` declares under `name` before offset `before`, skipping the child
	 * the walk arrived from, or null when it declares none. Direct children only: a declaration
	 * nested deeper sits in its own frame and is invisible from `decl`'s position, which is the
	 * whole reason this check does not reuse `CasePatternScan.shadowedDeclaration`.
	 */
	private static function declaredIn(
		frame: QueryNode, arrivedFrom: QueryNode, name: String, before: Int, seams: ScopeSeams
	): Null<String> {
		for (child in frame.children) if (child != arrivedFrom && child.name == name && seams.declHostKinds.contains(child.kind)) {
			final span: Null<Span> = child.span;
			if (span != null && span.from < before) return seams.paramKinds.contains(child.kind) ? 'parameter' : 'local';
		}
		return null;
	}

	/**
	 * Whether `decl`'s initializer READS the name it declares — `final x:T = x;`,
	 * `final o:ONotNull = setDefaults(o);`, `final p:String = isVirtual(p) ? p.substr(1) : p;`.
	 *
	 * The author is re-deriving that value under the same name on purpose: a null-safety narrowing
	 * re-bind (`Null<T>` to `T`, which is what the language's own guidance prescribes), or a
	 * parameter normalised once at the top of a function because Haxe has no `final` parameter to
	 * assign into. The outer binding is not hidden by accident there, it is CONSUMED, and the name
	 * is the point. Measured over an 805-file tree: 11 of 49 findings were this shape.
	 *
	 * An initializer that reads nothing of the kind — `var displayObject:Sprite = new Sprite();`
	 * over an enclosing `displayObject` — is exactly the shape this check exists for and is
	 * unaffected.
	 */
	private static function rebindsShadowed(decl: QueryNode, name: String, seams: ScopeSeams): Bool {
		final identKind: Null<String> = seams.identKind;
		return identKind != null && decl.children.exists(child -> readsName(child, identKind, name, seams));
	}

	/**
	 * Whether `node`'s subtree holds an identifier read of `name`, NOT descending into a nested
	 * function or lambda. A same-named binding inside one is a THIRD declaration, not the shadowed
	 * one — `final item:Null<T> = folders.find((item:T) -> …item.filePath…);` reads the lambda's own
	 * parameter, so counting it would suppress a real finding on a coincidence of spelling.
	 */
	private static function readsName(node: QueryNode, identKind: String, name: String, seams: ScopeSeams): Bool {
		return (node.kind == identKind && node.name == name)
			|| (!seams.nestedFnKinds.contains(node.kind) && node.children.exists(child -> readsName(child, identKind, name, seams)));
	}

	/** The scope vocabulary this check reads, or null when the grammar names no local declaration. */
	private static function seamsOf(shape: RefShape): Null<ScopeSeams> {
		final localDeclKinds: Array<String> = shape.localDeclKinds ?? [];
		return localDeclKinds.length == 0 ? null : {
			localDeclKinds: localDeclKinds,
			declHostKinds: shape.declHostKinds,
			positionScopedKinds: (shape.positionScopedKinds ?? []).concat(shape.branchScopeKinds ?? []),
			classLikeKinds: RefactorSupport.classLikeContainerKinds(shape),
			paramKinds: shape.paramKinds ?? [],
			opaqueKinds: shape.opaqueKinds ?? [],
			conditionalKind: shape.conditionalMemberKind,
			identKind: shape.identKind,
			nestedFnKinds: (shape.functionKinds ?? []).concat(shape.lambdaKinds ?? [])
		};
	}

}

/** The scope vocabulary `ShadowingLocal` walks with — resolved once per run, never per node. */
private typedef ScopeSeams = {
	final localDeclKinds: Array<String>;
	final declHostKinds: Array<String>;
	final positionScopedKinds: Array<String>;
	final classLikeKinds: Array<String>;
	final paramKinds: Array<String>;
	final opaqueKinds: Array<String>;
	final conditionalKind: Null<String>;
	final identKind: Null<String>;
	final nestedFnKinds: Array<String>;
};
