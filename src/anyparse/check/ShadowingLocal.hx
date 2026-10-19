package anyparse.check;

import anyparse.check.Check.FixEdit;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.LexicalRegions.LexRegionKind;
import anyparse.query.MemberKinds;
import anyparse.query.OccurrenceScan;
import anyparse.query.ParseGate;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.Rename;
import anyparse.query.ShapeVocab;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.TreePath;
import anyparse.query.TypeNameBinding;
import anyparse.runtime.Span;

using StringTools;
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
 *
 * ## The parameter half is a separate rule
 *
 * A nested function's PARAMETER hides an enclosing binding the same way a local declaration
 * does, and this rule is silent on every spelling of it — the parameter is only ever the OUTER
 * side of the question asked here. That half is `shadowing-parameter` (`ShadowingParameter`),
 * off by default, and it runs `collect` below with the same walk and the same gates.
 */
@:nullSafety(Strict)
final class ShadowingLocal implements Check {

	/** The rule's stable identifier — the `apqlint.json` key and the `--rule` selector. */
	private static inline final RULE_ID: String = 'shadowing-local';

	/** What a plain local declaration is called — in the message and in `Hidden.label`. */
	private static inline final LOCAL_LABEL: String = 'local';

	/** A finding `fix` cannot place back on its declaration. */
	private static inline final DECLINE_UNPLACED: String = 'the declaration cannot be placed in the source again';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a local declaration whose name is already bound by an enclosing local, binder or parameter';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return collect(files, plugin, false, RULE_ID);
	}

	/**
	 * The mechanical subset: a shadow whose hidden binding is never read after the declaration — so the shadow cannot
	 * be the defect the rule names, a write meant for the outer binding — is resolved without changing what any
	 * reference means. A same-block redeclaration of a `var` with the same written type becomes an assignment
	 * (`assignmentEdit`); any other declaration is renamed to its written type's lower-camel name (`renameEdits`). Each
	 * edit is verified by the shared binder, and every site it does not take carries the gate that kept it.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return fixWith(source, violations, plugin, false, RULE_ID);
	}

	/**
	 * The fix both spellings of the question share, as `collect` is the walk they share: `parameters` picks the family
	 * the findings are of. A local declaration goes through `shadowFix`'s gates; a PARAMETER goes straight to the rename
	 * (`paramFix`), scoped to the function declaring it.
	 */
	public static function fixWith(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, parameters: Bool, ruleId: String
	): Array<FixEdit> {
		final seams: Null<ScopeSeams> = seamsOf(plugin.refShape(), parameters, ruleId);
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		if (seams == null || tree == null) return [];
		final root: QueryNode = tree;
		final scope: ScopeSeams = seams;
		final site: FixFile = {
			source: source,
			tree: root,
			plugin: plugin,
			seams: scope,
			typeSources: RunScan.typeInfoOf(plugin)?.declaredTypeSources(source) ?? [],
			claimed: []
		};
		final declKinds: Array<String> = parameters ? scope.paramKinds : scope.localDeclKinds;
		final edits: Array<FixEdit> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			final decl: Null<QueryNode> = span == null ? null : declAt(root, span, declKinds);
			// A finding this call cannot place gets no sentence: one would be invented, not the deciding gate speaking.
			if (decl != null) switch parameters ? paramFix(site, decl) : shadowFix(site, decl) {
				case Applied(own):
					for (e in own) edits.push(e);
				case Declined(reason):
					v.declineReason = reason;
			}
		}
		return edits;
	}

	/**
	 * The ancestor-chain walk both spellings of the question share. `parameters` picks which
	 * declaration family is REPORTED — the local declarations this rule owns, or the parameters
	 * `shadowing-parameter` owns — and `ruleId` is stamped on every finding. The outer side, the
	 * frame walk and every gate are identical for both: only the inner declaration kind differs,
	 * which is why the two rules are one walk and not two.
	 *
	 * They are two RULES rather than one because the parameter half is a DIFFERENT question from
	 * the one this rule's own doc advertises ("a LOCAL declaration whose name is already bound"),
	 * and reusing a lambda parameter name is common idiom. A project that opted into
	 * `shadowing-local` did not thereby ask for the wider question, so
	 * the parameter half ships `DefaultOff` under its own id and this rule's bar cannot move.
	 */
	public static function collect(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, parameters: Bool, ruleId: String
	): Array<Violation> {
		final seams: Null<ScopeSeams> = seamsOf(plugin.refShape(), parameters, ruleId);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, entry.source);
			if (tree != null) scan(tree, tree, [], false, seams, entry.file, violations);
		}
		return violations;
	}

	/**
	 * What `name` is already bound to where `node` stands — `'parameter'`, `'local'`, `'loop iterator'` or
	 * `'catch binding'` — or null: the declarations a binding of `name` introduced at `node` would hide, by the
	 * same ancestor walk this rule reports with. A rewrite introducing such a binding asks it, so it never creates
	 * what this rule reports.
	 */
	public static function boundAt(root: QueryNode, node: QueryNode, name: String, shape: RefShape): Null<String> {
		final seams: Null<ScopeSeams> = seamsOf(shape, true, RULE_ID);
		final path: Null<Array<QueryNode>> = TreePath.pathTo(root, node);
		final at: Null<Span> = node.span;
		return seams == null || path == null || at == null
			? null
			: boundBefore(name, at.from, node, path.slice(0, path.length - 1), seams)?.label;
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

	/** Whether `binding` lies inside `span` — the reference is to the declaration at `span`. */
	private static inline function bindsWithin(binding: Null<Span>, span: Span): Bool {
		return binding != null && within(binding, span);
	}

	/** `offset` in a source whose run ending at `end` changed length by `delta`. */
	private static inline function shifted(offset: Int, end: Int, delta: Int): Int {
		return offset >= end ? offset + delta : offset;
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
		final reported: Bool = seams.reportParameters ? reportableParam(node, ancestors, seams) : seams.localDeclKinds.contains(node.kind);
		if (!inConditional && reported && name != null && span != null) {
			final hidden: Null<String> = shadowedBinding(node, ancestors, seams)?.label;
			final noun: String = seams.reportParameters ? 'parameter' : 'declaration';
			if (hidden != null && !rebindsShadowed(root, node, name, seams)) out.push({
				file: file,
				span: span,
				rule: seams.ruleId,
				severity: Severity.Warning,
				message: 'shadowing $noun - "$name" is already a $hidden in scope here'
			});
		}
		final nested: Bool = inConditional || node.kind == seams.conditionalKind;
		ancestors.push(node);
		for (child in node.children) scan(root, child, ancestors, nested, seams, file, out);
		ancestors.pop();
	}

	/**
	 * What `decl`'s name is ALREADY bound to on the ancestor chain — the binding it hides, labelled `'parameter'`,
	 * `'local'`, `'loop iterator'` or `'catch binding'` — or null when nothing binds it. Walks inward-out: at
	 * every position-scoped frame the frame's own SELF-SCOPED binder is asked first (`bindsItself`),
	 * then its DIRECT declaration-host children, minus the one the walk arrived from, and a
	 * candidate counts only when it starts before `decl` does. Stops at the first class-like
	 * container, so a field of the same name is never a finding.
	 */
	private static function shadowedBinding(decl: QueryNode, ancestors: Array<QueryNode>, seams: ScopeSeams): Null<Hidden> {
		final name: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		return name == null || declSpan == null ? null : boundBefore(name, declSpan.from, decl, ancestors, seams);
	}

	/** `shadowedBinding`'s walk for `name` in effect before `from`, starting at `start` under `ancestors`: the binding it hides. */
	private static function boundBefore(
		name: String, from: Int, start: QueryNode, ancestors: Array<QueryNode>, seams: ScopeSeams
	): Null<Hidden> {
		var arrivedFrom: QueryNode = start;
		var at: Int = ancestors.length - 1;
		while (at >= 0) {
			final frame: QueryNode = ancestors[at];
			if (seams.classLikeKinds.contains(frame.kind)) return null;
			if (seams.positionScopedKinds.contains(frame.kind)) {
				if (bindsItself(frame, name, from, seams)) return { label: binderLabel(frame.kind, seams), frame: frame, node: frame };
				final hidden: Null<Hidden> = declaredIn(frame, arrivedFrom, name, from, seams);
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
	 * The binding `frame` declares under `name` before offset `before`, skipping the child
	 * the walk arrived from, or null when it declares none. Direct children only: a declaration
	 * nested deeper sits in its own frame and is invisible from `decl`'s position, which is the
	 * whole reason this check does not reuse `CasePatternScan.shadowedDeclaration`.
	 */
	private static function declaredIn(
		frame: QueryNode, arrivedFrom: QueryNode, name: String, before: Int, seams: ScopeSeams
	): Null<Hidden> {
		for (child in frame.children) if (child != arrivedFrom && child.name == name && seams.declHostKinds.contains(child.kind)) {
			final span: Null<Span> = child.span;
			if (span == null || span.from >= before) continue;
			// A loop's VALUE binder is a child node while its KEY binder is the frame's own name;
			// both are the same kind of binding to a reader, so both answer the same word.
			final label: String = if (seams.valueBinderKinds.contains(child.kind))
				binderLabel(frame.kind, seams);
			else if (seams.paramKinds.contains(child.kind))
				'parameter';
			else
				LOCAL_LABEL;
			return { label: label, frame: frame, node: child };
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
	 * declaration whose whole shape is the deliberate re-bind — most haxelib findings.
	 * `bindsItself` closes that gap, so identity gating is no longer unsound for this shape. It is
	 * still not what runs here: swapping a containment test for an identity one is its own
	 * decision, and `testRebindGateAcceptsShadowedLoopIterator` pins the current answer rather
	 * than the reason it was reached.
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
	private static function seamsOf(shape: RefShape, parameters: Bool, ruleId: String): Null<ScopeSeams> {
		final localDeclKinds: Array<String> = shape.localDeclKinds ?? [];
		return localDeclKinds.length == 0 ? null : {
			shape: shape,
			reportParameters: parameters,
			ruleId: ruleId,
			localDeclKinds: localDeclKinds,
			declHostKinds: shape.declHostKinds,
			positionScopedKinds: (shape.positionScopedKinds ?? []).concat(shape.branchScopeKinds ?? []),
			classLikeKinds: MemberKinds.classLikeContainerKinds(shape),
			paramKinds: shape.paramKinds ?? [],
			selfScopeKinds: shape.selfScopeDeclKinds,
			valueBinderKinds: shape.iterationValueBinderKinds ?? [],
			catchKind: shape.catchClauseKind,
			opaqueKinds: shape.opaqueKinds ?? [],
			conditionalKind: shape.conditionalMemberKind,
			nestedFnKinds: ShapeVocab.functionLikeKinds(shape)
		};
	}

	/**
	 * Whether `node` is a PARAMETER this rule reports: a `RefShape.paramKinds` node declared by a
	 * function, whose name is not the project's declared-unused marker.
	 *
	 * Two gates, each earned by a measured false-positive class:
	 *
	 * - The PARENT must be a function scope (`ScopeSeams.nestedFnKinds`). Haxe's anonymous
	 *   STRUCTURE type projects its fields with the same kind a parameter uses —
	 *   `{ node: Int, width: Int }` is `Anon(Required node …, Required width …)` — so without this
	 *   a return type's field name reads as a binding, and every helper returning
	 *   `{ node: …, width: … }` out of a function that also takes a `node` is a finding. This project
	 *   types its edit lists as `Array<{ span: Span, text: String }>` and its inputs as
	 *   `{ file: String, source: String }`, so that class is every one of its raw findings. An
	 *   enum constructor's parameters fall out with them (their host
	 *   is `ParamCtor`, not a function), which is right: nothing encloses them.
	 * - A leading `_` is this project's "declared unused" marker, exempted by `unused-parameter`
	 *   on exactly the same test. A binding the body never reads cannot be mistaken for the one it
	 *   hides, which is the whole mistake this rule names — and the `_` shadowing `_` pair it drops
	 *   is produced by the dozen wherever the convention is used.
	 */
	private static function reportableParam(node: QueryNode, ancestors: Array<QueryNode>, seams: ScopeSeams): Bool {
		if (!seams.paramKinds.contains(node.kind) || ancestors.length == 0) return false;
		final name: Null<String> = node.name;
		return name != null && !name.startsWith('_') && seams.nestedFnKinds.contains(ancestors[ancestors.length - 1].kind);
	}

	/** The local declaration of one of `kinds` spanning exactly `span` — where a finding of this rule sits. */
	private static function declAt(tree: QueryNode, span: Span, kinds: Array<String>): Null<QueryNode> {
		return TreePath.firstAround(tree, span, n -> TreePath.spansExactly(n, span) && kinds.contains(n.kind));
	}

	/**
	 * `fix`'s answer for the flagged declaration `decl`. Gates in order: the hidden binding is read after `decl` within
	 * the frame declaring it (then the shadow may be the defect itself, and resolving it would bury the finding); `decl`
	 * continues another declarator; then the assignment and, failing it, the rename are asked.
	 */
	private static function shadowFix(site: FixFile, decl: QueryNode): ShadowFix {
		final path: Null<Array<QueryNode>> = TreePath.pathTo(site.tree, decl);
		final name: Null<String> = decl.name;
		final span: Null<Span> = decl.span;
		if (path == null || name == null || span == null) return Declined(DECLINE_UNPLACED);
		final ancestors: Array<QueryNode> = path.slice(0, path.length - 1);
		final hidden: Null<Hidden> = shadowedBinding(decl, ancestors, site.seams);
		if (hidden == null) return Declined(DECLINE_UNPLACED);
		final hits: Array<RefHit> = Refs.find(name, site.tree, site.seams.shape);
		if (readAfter(hits, hidden.frame, span))
			return Declined('the hidden ${hidden.label} is read after this declaration, so the shadow may be the defect itself');
		if ((site.seams.shape.localDeclContinuationKinds ?? []).contains(decl.kind))
			return Declined('a continuation declarator: renaming one name of a `var a, b` chain is left to the author');
		final assignment: Null<FixEdit> = assignmentEdit(site, decl, name, span, hidden, ancestors, hits);
		return assignment != null ? Applied([assignment]) : renameEdits(site, decl, name, span, hidden.frame);
	}

	/**
	 * `fix`'s answer for the flagged PARAMETER `decl`: the rename of `renameEdits`, scoped to the function declaring it.
	 * None of `shadowFix`'s other gates applies: a parameter is bound by the call, so no write meant for the hidden
	 * binding can land on it (the defect `readAfter` guards against), every read inside the function reads the argument
	 * whatever the parameter is called, and a parameter neither continues a declarator chain nor takes an assignment.
	 */
	private static function paramFix(site: FixFile, decl: QueryNode): ShadowFix {
		final path: Null<Array<QueryNode>> = TreePath.pathTo(site.tree, decl);
		final name: Null<String> = decl.name;
		final span: Null<Span> = decl.span;
		if (path == null || path.length < 2 || name == null || span == null) return Declined(DECLINE_UNPLACED);
		return renameEdits(site, decl, name, span, path[path.length - 2]);
	}

	/**
	 * Whether a read of the name after `declSpan`, inside `frame`, binds to anything but the declaration at `declSpan` —
	 * the hidden binding, or a binding the resolver cannot name. Inside the declaration's scope every read is its own, so
	 * a hit here is a read of the hidden binding past the scope's end, which is the defect shape.
	 */
	private static function readAfter(hits: Array<RefHit>, frame: QueryNode, declSpan: Span): Bool {
		final frameSpan: Null<Span> = frame.span;
		return frameSpan == null
			|| hits.exists(
				hit ->
					hit.kind == RefKind.Read && hit.span.from >= declSpan.to && within(hit.span, frameSpan)
					&& !bindsWithin(hit.bindingSpan, declSpan)
			);
	}

	/**
	 * The edit turning a same-block redeclaration into an assignment — `var i:Int = 0; … var i:Int = f();` becomes
	 * `… i = f();` — or null when it does not apply: the hidden binding must be a single-declarator mutable local of the
	 * SAME statement list, both must write the same type, `decl` must have an initializer and nothing but its keyword,
	 * name and annotation before it, and no nested function may capture the hidden binding (a closure would then read the
	 * new value). Verified by re-resolution: every read of `decl` must bind to the hidden declaration afterwards.
	 */
	private static function assignmentEdit(
		site: FixFile, decl: QueryNode, name: String, span: Span, hidden: Hidden, ancestors: Array<QueryNode>, hits: Array<RefHit>
	): Null<FixEdit> {
		final shape: RefShape = site.seams.shape;
		final outer: QueryNode = hidden.node;
		final outerSpan: Null<Span> = outer.span;
		final continuation: Array<String> = shape.localDeclContinuationKinds ?? [];
		final outerType: Null<String> = outerSpan == null ? null : site.typeSources[outerSpan.from];
		final innerType: Null<String> = site.typeSources[span.from];
		final init: Null<QueryNode> = decl.children.length == 1 ? decl.children[0] : null;
		final initSpan: Null<Span> = init?.span;
		if (outerSpan == null || init == null || initSpan == null || innerType == null || outerType == null) return null;
		if (
			outerType.trim() != innerType.trim() || hidden.label != LOCAL_LABEL || hidden.frame != ancestors[ancestors.length - 1]
			|| !(shape.mutableLocalDeclKinds ?? []).contains(outer.kind) || SourceText.isMultiDeclarator(outer, continuation)
			|| continuation.contains(init.kind) || capturedInNestedFunction(hits, outerSpan, hidden.frame, site.seams)
			|| !declaratorPrefixOnly(site, span, initSpan, name, innerType)
		)
			return null;
		final edit: FixEdit = { span: new Span(span.from, initSpan.from), text: '$name = ' };
		return rebindsToHidden(site, edit, name, span, outerSpan, hits) ? edit : null;
	}

	/**
	 * Whether the source from `span.from` to `initFrom` is exactly a keyword, `name`, `:` + the written `type` and `=`,
	 * with no comment anywhere in it — the run the assignment replaces with `name = `.
	 */
	private static function declaratorPrefixOnly(site: FixFile, span: Span, initSpan: Span, name: String, type: String): Bool {
		final prefix: String = site.source.substring(span.from, initSpan.from);
		if (site.plugin.lexicalRegions(site.source).exists(r -> r.from < initSpan.from && r.to > span.from)) return false;
		final head: EReg = new EReg('^[A-Za-z_]+\\s+${EReg.escape(name)}\\s*:\\s*${EReg.escape(type.trim())}\\s*=\\s*$$', '');
		return head.match(prefix);
	}

	/**
	 * Whether a reference bound to the declaration at `outerSpan` sits inside a nested function within `frame` — a
	 * closure capturing the hidden binding, which an assignment would hand the new value.
	 */
	private static function capturedInNestedFunction(hits: Array<RefHit>, outerSpan: Span, frame: QueryNode, seams: ScopeSeams): Bool {
		final nested: Array<Span> = [];
		collectNestedFnSpans(frame, nested, seams);
		return hits.exists(hit -> bindsWithin(hit.bindingSpan, outerSpan) && nested.exists(fn -> within(hit.span, fn)));
	}

	/**
	 * The binder's verdict on the assignment `edit`: re-resolved on the rewritten source, every read that bound to the
	 * declaration at `span` binds to the hidden one at `outerSpan`, and nothing else moves onto it.
	 */
	private static function rebindsToHidden(
		site: FixFile, edit: FixEdit, name: String, span: Span, outerSpan: Span, hits: Array<RefHit>
	): Bool {
		final rewritten: String = site.source.substring(0, edit.span.from) + edit.text + site.source.substring(edit.span.to);
		final tree: Null<QueryNode> = ParseGate.parseOrNull(site.plugin, rewritten);
		if (tree == null) return false;
		final delta: Int = edit.text.length - (edit.span.to - edit.span.from);
		final moved: Array<Int> = [
			for (hit in hits) if (
				hit.kind == RefKind.Read && (bindsWithin(hit.bindingSpan, span) || bindsWithin(hit.bindingSpan, outerSpan))
			)
				shifted(hit.span.from, span.to, delta)
		];
		final bound: Array<Int> = [
			for (hit in Refs.find(
				name, tree, site.seams.shape
			)) if (hit.kind == RefKind.Read && bindsWithin(hit.bindingSpan, outerSpan)) hit.span.from
		];
		return moved.length == bound.length && moved.foreach(m -> bound.contains(m));
	}

	/**
	 * The rename of `decl` to its written type's lower-camel name (`final event:SidebarTabEvent` → `sidebarTabEvent`),
	 * or the gate that refused it: no written nominal type, a name already handed out by this call, a nested function
	 * in `frame` rebinding the name, the name in a string of `frame` (code text no resolver reads), and finally
	 * `Rename.rename` — the scope-correct rename `hxq rename` runs, which refuses a capture and every resolution blind spot.
	 * `frame` is the scope the gates read: the hidden binding's frame for a local, the declaring function for a parameter.
	 */
	private static function renameEdits(site: FixFile, decl: QueryNode, name: String, span: Span, frame: QueryNode): ShadowFix {
		final shape: RefShape = site.seams.shape;
		final written: Null<String> = site.typeSources[span.from];
		final candidate: Null<String> = written == null ? null : typeNamedLocal(written);
		if (candidate == null || candidate == name || (shape.reservedWords ?? []).contains(candidate))
			return Declined('no written nominal type names a replacement for "$name"');
		final newName: String = candidate;
		if (nestedFunctionRebinds(frame, name, site.seams))
			return Declined('a nested function in its scope declares a parameter "$name", which the rename would have to tell apart');
		final frameSpan: Null<Span> = frame.span;
		final regions: Array<LexRegion> = site.plugin.lexicalRegions(site.source);
		if (frameSpan == null || regions.exists(
			r ->
				r.kind == LexRegionKind.StringLit && r.from >= frameSpan.from && r.to <= frameSpan.to
				&& SourceText.mentionsIdent(site.source, new Span(r.from, r.to), name)
		))
			return Declined('"$name" occurs in a string in its scope, which no resolver reads');
		if (site.claimed.exists(c -> c.name == newName && c.scope.from < frameSpan.to && frameSpan.from < c.scope.to))
			return Declined('another declaration of this pass takes "$newName" in an overlapping scope — the next pass renames this one');
		final at: Int = OccurrenceScan.activeCodeIdentTokenOffset(site.source, span, name, regions);
		if (at < 0) return Declined(DECLINE_UNPLACED);
		final pos: Position = new Span(at, at).lineCol(site.source);
		return switch Rename.rename(site.source, pos.line, pos.col, newName, site.plugin, shape) {
			case Err(message):
				Declined('renaming it to "$newName" is refused: $message');
			case Ok(_):
				site.claimed.push({ name: newName, scope: frameSpan });
				Applied([
					for (occ in Rename.renameOccurrences(site.source, site.tree, at, shape)) { span: occ, text: newName }
				]);
		};
	}

	/** Whether a nested function inside `frame` declares a parameter named `name`. */
	private static function nestedFunctionRebinds(frame: QueryNode, name: String, seams: ScopeSeams): Bool {
		for (child in frame.children) {
			if (seams.nestedFnKinds.contains(child.kind) && child.children.exists(p -> seams.paramKinds.contains(p.kind) && p.name == name))
				return true;
			if (nestedFunctionRebinds(child, name, seams)) return true;
		}
		return false;
	}

	/**
	 * The local name a declaration written with type `written` takes: the lower-camel of its simple nominal
	 * (`events.SidebarTabEvent` → `sidebarTabEvent`), or null for anything else — a type argument, a function or
	 * structure type, a name not starting upper-case, and a std root type (`TypeNameBinding.AMBIENT_TYPE_NAMES`:
	 * `int` / `string` would name a type, not the value).
	 */
	private static function typeNamedLocal(written: String): Null<String> {
		final path: String = written.trim();
		final simple: String = path.substr(path.lastIndexOf('.') + 1);
		return SourceText.isIdentifier(path.replace('.', '')) && simple.length > 0 && simple.charAt(0) != simple.charAt(0).toLowerCase()
			&& !TypeNameBinding.AMBIENT_TYPE_NAMES.contains(simple)
			? SourceText.lowerCamel(simple)
			: null;
	}

}

/** The scope vocabulary `ShadowingLocal` walks with — resolved once per run, never per node. */
private typedef ScopeSeams = {
	final shape: RefShape;

	/** Whether this run reports PARAMETERS (`shadowing-parameter`) rather than local declarations (`shadowing-local`). */
	final reportParameters: Bool;

	/** The rule id stamped on every finding of this run — the two spellings share the walk, not the id. */
	final ruleId: String;

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
	 * Every node that opens a function scope: `ShapeVocab.nestedFunctionKinds` — THE
	 * authority for function VALUES — plus `functionKinds`, the declarations (methods,
	 * module-level functions) that open one without being a value. That second half is this
	 * check's documented extra over the authority.
	 */
	final nestedFnKinds: Array<String>;
};

/** The binding a shadowing declaration hides: what to call it, the scope frame declaring it, and its own node. */
private typedef Hidden = {
	final label: String;

	/** The position-scoped frame the binding is declared in — a loop / catch frame binds itself (`node == frame`). */
	final frame: QueryNode;

	final node: QueryNode;
};

/** What `fix` does with one finding: its edits, or the gate that kept it report-only. */
private enum ShadowFix {
	Applied(edits: Array<FixEdit>);
	Declined(reason: String);
}

/** The per-file context of `ShadowingLocal.fix`. */
private typedef FixFile = {
	final source: String;
	final tree: QueryNode;
	final plugin: GrammarPlugin;
	final seams: ScopeSeams;

	/** `TypeInfoProvider.declaredTypeSources`: each declaration's WRITTEN type, by its span start. */
	final typeSources: Map<Int, String>;

	/**
	 * The names this call already gave a renamed declaration, each with the scope frame it was checked in: a second
	 * site taking the same name in an OVERLAPPING frame was validated against a source without the first rename, so it
	 * waits for the next pass. Disjoint frames cannot meet.
	 */
	final claimed: Array<{ name: String, scope: Span }>;
};
