package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.Refs;
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
 * A frame that binds a name into ITSELF — a `for` iterator, a catch exception
 * (`RefShape.selfScopeDeclKinds`) — is asked too, and asked first. Such a binder is the frame
 * node's own `name`, not one of its children, so the direct-children walk alone could not see it:
 * `for (p in xs) { var p = …; }` reported the outer `p` two frames up, and with no outer `p` at
 * all reported nothing. The message names which one it found — `loop iterator` / `catch binding`
 * rather than `local` — because that is the information a reader of the finding needs.
 *
 * A same-block redeclaration (`var q = 1; … var q = 2;` in one statement list) IS reported: the
 * second takes over from its own position, which is the same trap one indent shallower.
 *
 * ## What is not reported
 *
 * A declaration that CONSUMES a binding it hides is skipped: `final x:T = x;`,
 * `final o:ONotNull = setDefaults(o);`. The outer binding is not hidden by accident there, it is
 * being re-derived under its own name on purpose. `rebindsShadowed` asks `Refs` — the same lexical
 * resolver `apq refs` runs — whether a read inside the declaration binds to something declared
 * OUTSIDE it; a walk over identifier nodes gets that backwards for a multi-declarator continuation
 * and for a braceless `$name` interpolation, and cannot see either. Nested functions are the one
 * region the resolver is not trusted in, because it does not model an unannotated arrow parameter.
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
			if (tree != null) scan(tree, tree, [], false, resolved, entry.file, violations);
		}
		return violations;
	}

	/** Report-only: renaming the inner declaration or the outer one is the author's call. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** Whether `span` lies wholly inside `outer`. */
	private static inline function within(span: Span, outer: Span): Bool {
		return span.from >= outer.from && span.to <= outer.to;
	}

	/**
	 * Whether `binding` is a declaration the local declaration at `declSpan` HIDES — anything not
	 * declared by that statement itself. A read resolving to the statement's own continuation, or to
	 * a declaration nested inside its initializer, binds WITHIN `declSpan` and consumes nothing the
	 * statement hides.
	 */
	private static inline function bindsOutside(binding: Null<Span>, declSpan: Span): Bool {
		return binding != null && !within(binding, declSpan);
	}

	/** What to call a binder of `kind` in the message — the two self-scoped families read differently. */
	private static inline function binderLabel(kind: String, seams: ScopeSeams): String {
		return kind == seams.catchKind ? 'catch binding' : 'loop iterator';
	}

	/**
	 * Walk `node`'s subtree carrying its ANCESTOR chain, reporting every local declaration whose
	 * name a frame on that chain already binds. `ancestors` is mutated in place and restored on the
	 * way out — one array for the whole file rather than a path lookup per declaration.
	 */
	private static function scan(
		root: QueryNode, node: QueryNode, ancestors: Array<QueryNode>, inConditional: Bool, seams: ScopeSeams, file: String,
		out: Array<Violation>
	): Void {
		if (seams.opaqueKinds.contains(node.kind)) return;
		final span: Null<Span> = node.span;
		final name: Null<String> = node.name;
		if (!inConditional && seams.localDeclKinds.contains(node.kind) && name != null && span != null) {
			final hidden: Null<String> = shadowedBinding(node, ancestors, seams);
			if (hidden != null && !rebindsShadowed(root, node, name, seams)) out.push({
				file: file,
				span: span,
				rule: RULE_ID,
				severity: Severity.Warning,
				message: 'shadowing declaration - "$name" is already a $hidden in scope here'
			});
		}
		final nested: Bool = inConditional || node.kind == seams.conditionalKind;
		ancestors.push(node);
		for (child in node.children) scan(root, child, ancestors, nested, seams, file, out);
		ancestors.pop();
	}

	/**
	 * What `decl`'s name is ALREADY bound to on the ancestor chain — `'parameter'`, `'local'`,
	 * `'loop iterator'` or `'catch binding'` — or null when nothing binds it. Walks inward-out: at
	 * every position-scoped frame the frame's own SELF-SCOPED binder is asked first (`bindsItself`),
	 * then its DIRECT declaration-host children, minus the one the walk arrived from, and a
	 * candidate counts only when it starts before `decl` does. Stops at the first class-like
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
				if (bindsItself(frame, name, declSpan.from, seams)) return binderLabel(frame.kind, seams);
				final hidden: Null<String> = declaredIn(frame, arrivedFrom, name, declSpan.from, seams);
				if (hidden != null) return hidden;
			}
			arrivedFrom = frame;
			at--;
		}
		return null;
	}

	/**
	 * Whether `frame` is a SELF-SCOPED binder (`RefShape.selfScopeDeclKinds` — a `for` iterator, a
	 * catch exception) whose own name is `name` and is in effect at `before`.
	 *
	 * These bind into the frame they OPEN, so the name sits in the frame node's own `name` slot
	 * and never appears among its children — which is why the enclosing-frame walk could not see
	 * one and, in `for (p in xs) { var p = …; }`, named an outer `p` two frames up or, with no
	 * outer `p` at all, reported nothing. The asymmetry was visible inside ONE construct:
	 * `for (k => v in m)` puts the VALUE binder in a child node, so `var v` was reported and
	 * `var k` was not.
	 *
	 * `Refs.selfScopeBinderFloor` is the same seam the resolver builds its scope frame from, so the
	 * two cannot disagree about where the binding starts: it covers the BODY, not the header, and
	 * `<=` rather than `<` because a brace-less body (`for (p in xs) var p = 1;`) IS the
	 * declaration and still sits inside the binding. The kind test is NOT redundant with the one
	 * inside that function: its `0` means both "no such binding" and "from the first byte", and
	 * `0 <= before` holds for every declaration in the file.
	 */
	private static function bindsItself(frame: QueryNode, name: String, before: Int, seams: ScopeSeams): Bool {
		return frame.name == name && seams.selfScopeKinds.contains(frame.kind) && Refs.selfScopeBinderFloor(frame, seams.shape) <= before;
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
			if (span == null || span.from >= before) continue;
			// A loop's VALUE binder is a child node while its KEY binder is the frame's own name;
			// both are the same kind of binding to a reader, so both answer the same word.
			return if (seams.valueBinderKinds.contains(child.kind))
				binderLabel(frame.kind, seams);
			else if (seams.paramKinds.contains(child.kind))
				'parameter';
			else
				'local';
		}
		return null;
	}

	/**
	 * Whether a read inside `decl` resolves to a binding `decl` HIDES — `final x:T = x;`,
	 * `final o:ONotNull = setDefaults(o);`, `final p:String = isVirtual(p) ? p.substr(1) : p;`.
	 *
	 * The author is re-deriving that value under the same name on purpose: a null-safety narrowing
	 * re-bind (`Null<T>` to `T`, which is what the language's own guidance prescribes), or a
	 * parameter normalised once at the top of a function because Haxe has no `final` parameter to
	 * assign into. The outer binding is not hidden by accident there, it is CONSUMED, and the name
	 * is the point.
	 *
	 * The question goes to `Refs` — the lexical resolver `apq refs` itself runs, and the one three
	 * sibling checks already ask — rather than to a walk over identifier nodes, because a walk gets
	 * two shapes backwards and the resolver gets both right (each verified by running it):
	 *
	 * - `var a = 1; var a = 2, r = a;` — the read is in the CONTINUATION of a multi-declarator
	 *   chain, where the NEW binding is already in effect (`r` is 2). A subtree walk counts it and
	 *   suppresses a genuine shadow. Same class, one level up: a read inside a nested declaration in
	 *   the initializer (`var e = switch v { case 1: var e = 2; e; … }`) belongs to that declaration.
	 * - `var n = 1; var n = '$n!';` — a braceless interpolation read binds like a bare identifier,
	 *   and `RefShape.identKind` does not name it, so a walk does not see the read at all.
	 *
	 * `bindsOutside` is what carries both: a read resolving to something declared INSIDE `decl` —
	 * its own continuation, a nested declaration, a lambda parameter — consumes nothing `decl`
	 * hides. The containment test does the other half, keeping a read BETWEEN the two declarations
	 * (`var a = 1; trace(a); var a = 2;`) from counting.
	 *
	 * Note this asks nothing about WHICH binding `shadowedBinding` named. That was FORCED when the
	 * gate was written: `for (q in xs) { var q = h(q); }` consumes the loop iterator, and the
	 * enclosing-frame walk named an outer `q` instead, so identity gating would have reported a
	 * declaration whose whole shape is the deliberate re-bind — 8 of 9 haxelib findings, measured.
	 * `bindsItself` closes that gap, so identity gating is no longer unsound for this shape. It is
	 * still not what runs here: swapping a containment test for an identity one is its own
	 * decision with its own measurement, and `testRebindGateAcceptsShadowedLoopIterator` pins the
	 * current answer rather than the reason it was reached.
	 *
	 * Nested functions are the one region the resolver is not trusted in — see
	 * `collectNestedFnSpans`.
	 *
	 * The SIBLING mechanism, which is not this one: `unused-local` reaches the same verdict for
	 * `var a = 1; var a = a + 1;` by leaving the re-declaration's initializer OUT of the regions it
	 * excludes from a raw text scan. That is a different question (is the FIRST binding dead) with a
	 * different subject (the first declaration, not the second), a different conservative direction,
	 * and no predicate to share. Do not fold the two together.
	 */
	private static function rebindsShadowed(root: QueryNode, decl: QueryNode, name: String, seams: ScopeSeams): Bool {
		final declSpan: Null<Span> = decl.span;
		if (declSpan == null) return false;
		final nested: Array<Span> = [];
		collectNestedFnSpans(decl, nested, seams);
		return Refs.find(name, root, seams.shape).exists(
			hit ->
				hit.kind == RefKind.Read && within(hit.span, declSpan) && !nested.exists(fn -> within(hit.span, fn))
				&& bindsOutside(hit.bindingSpan, declSpan)
		);
	}

	/**
	 * The spans of the nested functions and lambdas directly under `decl` — the regions where this
	 * check does not consult the resolver, because it cannot see an UNANNOTATED arrow parameter.
	 *
	 * `(q: Int) -> q > 0` and `function(q) return q > 0` both surface their parameter as a
	 * declaration, and a read in the body binds to it. `q -> q > 0` surfaces the parameter as a
	 * plain identifier, so BOTH it and the body read resolve to whatever the enclosing scope binds
	 * — which for `var q = 0; final q = xs.filter(q -> q > 0);` is the very declaration being
	 * hidden. Trusting that would call the accident a deliberate re-bind and lose the finding. The
	 * outer regions carry no such ambiguity, so the resolver is trusted everywhere else.
	 */
	private static function collectNestedFnSpans(node: QueryNode, out: Array<Span>, seams: ScopeSeams): Void {
		for (child in node.children) {
			final span: Null<Span> = child.span;
			if (span != null && seams.nestedFnKinds.contains(child.kind))
				out.push(span);
			else
				collectNestedFnSpans(child, out, seams);
		}
	}

	/** The scope vocabulary this check reads, or null when the grammar names no local declaration. */
	private static function seamsOf(shape: RefShape): Null<ScopeSeams> {
		final localDeclKinds: Array<String> = shape.localDeclKinds ?? [];
		return localDeclKinds.length == 0 ? null : {
			shape: shape,
			localDeclKinds: localDeclKinds,
			declHostKinds: shape.declHostKinds,
			positionScopedKinds: (shape.positionScopedKinds ?? []).concat(shape.branchScopeKinds ?? []),
			classLikeKinds: RefactorSupport.classLikeContainerKinds(shape),
			paramKinds: shape.paramKinds ?? [],
			selfScopeKinds: shape.selfScopeDeclKinds,
			valueBinderKinds: shape.iterationValueBinderKinds ?? [],
			catchKind: shape.catchClauseKind,
			opaqueKinds: shape.opaqueKinds ?? [],
			conditionalKind: shape.conditionalMemberKind,
			nestedFnKinds: (shape.functionKinds ?? []).concat(RefactorSupport.nestedFunctionKinds(shape))
		};
	}

}

/** The scope vocabulary `ShadowingLocal` walks with — resolved once per run, never per node. */
private typedef ScopeSeams = {
	final shape: RefShape;
	final localDeclKinds: Array<String>;
	final declHostKinds: Array<String>;
	final positionScopedKinds: Array<String>;
	final classLikeKinds: Array<String>;
	final paramKinds: Array<String>;
	final selfScopeKinds: Array<String>;
	final valueBinderKinds: Array<String>;
	final catchKind: Null<String>;
	final opaqueKinds: Array<String>;
	final conditionalKind: Null<String>;

	/**
	 * Every node that opens a function scope: `RefactorSupport.nestedFunctionKinds` — THE
	 * authority for function VALUES — plus `functionKinds`, the declarations (methods,
	 * module-level functions) that open one without being a value. That second half is this
	 * check's documented extra over the authority.
	 */
	final nestedFnKinds: Array<String>;
};
