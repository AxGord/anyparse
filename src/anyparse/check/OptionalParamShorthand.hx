package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Flags a function parameter written `name:Null<T> = null` or `name:T = null` — a
 * nullable-or-plain type with a `null` default — that the `?` optional-parameter shorthand
 * `?name:T` replaces; an already-optional parameter carrying a redundant `null` default
 * (`?name:T = null`); and an already-optional parameter carrying a NON-null default
 * (`?name:T = <default>`), whose leading `?` is itself redundant — the default alone already
 * makes the parameter optional, and the `?` needlessly widens the parameter's body type to
 * `Null<T>`. `Severity.Info` for all three arms (a style cleanup), each with an autofix. For
 * the first two arms the fix rewrites the parameter to `?name:T` — unwrapping one `Null<>`
 * layer when present (else keeping the type as-is), dropping the ` = null`, and prepending
 * `?`; for the third arm the fix drops ONLY the leading `?`, leaving `name:T = <default>`
 * byte-for-byte otherwise unchanged. Grammar-agnostic over `RefShape.paramKinds` (unset ->
 * no-op).
 *
 * ## Equivalence — why the rewrite is safe
 *
 * `?x:T` and `x:Null<T> = null` are equivalent for a nullable-defaulted parameter: the `?`
 * widens `x`'s type to `Null<T>` (so the body sees the same nullable value on static
 * targets), and both permit omitting the argument at trailing call sites — the `= null`
 * default and the `?` sigil compile the same calls. No call site changes. A live compiler
 * probe additionally confirmed `x:T = null` types identically: `$type` gives `(?p:Null<T>)
 * -> Void` for BOTH `p:Int = null` and `?p:Int`, and the `haxe.PosInfos` call-site auto-fill
 * magic fires in both forms — so the bare-type arm needs no extra gates. For the
 * already-optional arm the equivalence is immediate: an omitted `?x:T` argument already
 * yields `null`, so an explicit `= null` default changes nothing.
 *
 * For the THIRD arm the equivalence is just as immediate: a default value alone already
 * makes a parameter optional (Haxe permits omitting any trailing argument that has a
 * default, `?` or not), so the `?` adds nothing but the type widening. Measured on Haxe
 * 4.3.7 — `?p:Bool = true` gives the BODY type `Null<Bool>` and the external signature
 * `(?p : Null<Bool>) -> Void`; `p:Bool = true` gives `Bool` and `(?p : Bool) -> Void`. On
 * hxcpp the `?` form degrades the generated signature to `::Dynamic __o_p` with a boxed
 * default and leaves `p` as `::Dynamic` for the whole body (every use is a dynamic unbox);
 * without `?` it is `::hx::Null<bool> __o_p` + `bool p = __o_p.Default(true);` — native past
 * the boundary. The parameter stays optional either way; the `?` form is strictly worse.
 *
 * ## What is flagged
 *
 * A `paramKinds` node whose last child (the default value) is the `null` literal and which
 * is either: a plain required parameter (source does not start with `?`) whose type text —
 * between the name's `:` and the default's `=` — is a single balanced `Null<...>` (the outer
 * `Null<>` balanced to its matching `>` at the type's end, inner `T` source-spliced with
 * nested `<>` and a function-type `->` balanced correctly) or any other non-empty type text
 * (`name:T = null`) that does not itself open as a `Null<` wrapper; or an already-optional
 * parameter (`?name:T = null`) with any non-empty type text — the `?` sigil already makes it
 * optional, so the `= null` is redundant and the fix drops it, keeping the type verbatim
 * (`?name:Null<T> = null` fixes to `?name:Null<T>`, no unwrap).
 *
 * A THIRD arm: `?name:T = <default>` where `<default>` is anything other than the `null`
 * literal — `redundantSigil`'s shape, disjoint from the first two by construction (both of
 * those require the default to actually BE `null`). Flagged only when all four gates below
 * pass.
 *
 * ## Why four gates (G1-G4)
 *
 * Unlike the first two arms, dropping a working `?` is NOT unconditionally safe — it can
 * break code the way adding one never does. Four gates, all fail-closed (refuse when in
 * doubt):
 *
 * - G1 — a body-less function (`RefShape.noBodyKind`, an interface / abstract method
 *   declaration) is refused. Dropping `?` there changes the contract; measured `Field h has
 *   different type than in I ... error: Bool should be Null<Bool>`.
 * - G2 — refused when the enclosing type carries a supertype clause
 *   (`RefShape.supertypeClauseKinds`) UNLESS the function is the constructor
 *   (`RefShape.constructorName` — a constructor can neither override nor implement; Haxe
 *   interfaces cannot declare one) or `static` (`RefShape.staticModifierKind` — a static can
 *   never participate in instance dispatch); and always refused when the function itself
 *   carries `override` (`RefShape.overrideModifierKind`) — Haxe requires NO `override`
 *   keyword to implement an `abstract` superclass method or an interface method, so its
 *   ABSENCE proves nothing. Both directions of the mismatch are compile errors (`Field f
 *   overrides parent class with different or incomplete type`).
 * - G3 — refused when a `null` literal (`RefShape.nullLiteralKind`) shares a DIRECT PARENT
 *   with an identifier (`RefShape.identKind`) named for the parameter, anywhere in the
 *   enclosing function's subtree. Measured breakages: `if (p == null)` -> `(Eq (IdentExpr p)
 *   (NullLit))`; `p = null;` -> `(Assign (IdentExpr p) (NullLit))`; `p == null ? 0 : p`. All
 *   produce `On static platforms, null can't be used as basic type Bool/Int` after the `?`
 *   is dropped. Deliberately a SUPERSET of a strict comparison test (it also refuses e.g.
 *   `foo(p, null)`, a harmless over-refusal).
 * - G4 — refused when the parameter is the SUBJECT (first child) of any `switch`
 *   (`RefShape.switchKinds`) inside the enclosing function. `switch p { case null: … }`
 *   breaks the same way, and its `NullLit` sits under `(CaseBranch (Plain (NullLit)))` — not
 *   a sibling of the subject, so G3 cannot see it.
 *
 * Also refused when the enclosing function cannot be determined (no ancestor whose kind is
 * in `RefShape.functionKinds`). If any seam the gates need is unset on the grammar
 * (`functionKinds` empty, `identKind` null, `nullLiteralKind` null), the third arm is a
 * no-op — the other two arms keep working exactly as before.
 *
 * ## Residual risk
 *
 * No in-file gate can close two residual cases, both surfacing as BUILD ERRORS, never as
 * silent misbehaviour — the finding stays `Severity.Info` regardless: a caller in ANOTHER
 * file passing a LITERAL `null` into the slot of a BASIC-typed parameter (`noQ(null)` where
 * `p:Bool = true`) is a compile error after the fix; and a subclass in another file whose
 * override keeps the `?` breaks too.
 *
 * ## Deliberate misses
 *
 * - `name:Null<T> = <non-null default>` — a different default semantics, left alone.
 * - `?name:T` and `?name:Null<T>` without a default — nothing redundant to drop; the nested
 *   `Null<Null<T>>` fix produces `?name:Null<T>`, which this convention leaves as-is
 *   (unwrapping only ONE layer, per the rule).
 * - `name = null` and `?name = null` (no type annotation) — skipped: no type text to carry
 *   the rewrite.
 * - A `Null<`-prefixed type text that `unwrapNull` rejects — decorated (e.g. a comment
 *   between the type and the `=`) or malformed; coercing it into the bare-type arm would
 *   prepend `?` without unwrapping, so it stays a safe miss.
 * - For the third arm: a parameter in a type that `extends` / `implements` (unless the
 *   function is the constructor or `static`), a body-less declaration, a parameter the
 *   enclosing function tests against `null` or switches on, or a parameter whose enclosing
 *   function cannot be found — G1-G4 above; the arm stays silent, not merely downgraded.
 *
 * Fine with NO gate for the third arm (measured): function-value contexts (`var
 * v:(?p:Null<Bool>)->Void = noQ;`, `take(noQ)`, `.bind`) all compile; `p ?? x` compiles;
 * `var n:Null<Int> = p` compiles; a `Null<Int>` VARIABLE passed at a call site compiles;
 * `@:nullSafety(Strict)` adds no constraint; runtime behaviour is identical — an explicit
 * `null` argument yields the default in BOTH forms.
 */
@:nullSafety(Strict)
final class OptionalParamShorthand implements Check {

	/** The rule id — repeated across `id()` and every arm's violation push. */
	private static inline final RULE_ID: String = 'optional-param-shorthand';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a nullable-defaulted parameter (name:Null<T> = null or name:T = null) the ? shorthand (?name:T) '
			+ 'replaces, a redundant = null default on an already-optional ?name:T, or a redundant ? on ?name:T = <non-null default>';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Seams = buildSeams(plugin);
		if (seams.params.length == 0) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, entry.source, tree, null, null, null, seams);
		}
		return violations;
	}

	/**
	 * Rewrite each flagged parameter to `?name:T`. The parameter node is re-found by its
	 * reported span and the inner type re-derived, so the edit fires only when the bytes
	 * still match `name:Null<T> = null` (a guard against any unexpected span). The whole
	 * parameter span is replaced — commas, the surrounding parentheses, and the other
	 * parameters sit outside it, so position and trivia stay intact.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final params: Array<String> = plugin.refShape().paramKinds ?? [];
		return params.length == 0
			? []
			: CheckScan.applyBySpan(plugin, source, violations, params, (node, span) -> {
				final shape: Null<{ inner: String, raw: String, opt: Bool }> = nullableDefaultInner(node, source);
				if (shape == null)
					return redundantSigil(node, source) == null ? null : { span: span, text: source.substring(span.from + 1, span.to) };
				final name: Null<String> = node.name;
				return name == null ? null : { span: span, text: '?$name:${shape.inner}' };
			});
	}

	/**
	 * Walk `node`, flagging every parameter that matches a nullable-defaulted parameter
	 * shape (`name:Null<T> = null` or `name:T = null`). The whole tree is walked so class
	 * methods, constructors, and local functions are all reached (lambda parameters project
	 * as the same kind but the grammar does not record a default for them, so none match).
	 */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, parent: Null<QueryNode>, fn: Null<QueryNode>,
		fnParent: Null<QueryNode>, seams: Seams
	): Void {
		final isFn: Bool = seams.functionKinds.contains(node.kind);
		final curFn: Null<QueryNode> = isFn ? node : fn;
		final curFnParent: Null<QueryNode> = isFn ? parent : fnParent;
		if (seams.params.contains(node.kind)) {
			final name: Null<String> = node.name;
			final span: Null<Span> = node.span;
			if (name != null && span != null) {
				final shape: Null<{ inner: String, raw: String, opt: Bool }> = nullableDefaultInner(node, source);
				if (shape != null)
					out.push({
						file: file,
						span: span,
						rule: RULE_ID,
						severity: Severity.Info,
						message: 'prefer ?$name:${shape.inner} over ${shape.opt ? '?' : ''}$name:${shape.raw} = null'
					});
				else {
					final rawType: Null<String> = redundantSigil(node, source);
					if (rawType != null && isSigilDropSafe(curFn, curFnParent, name, seams)) out.push({
						file: file,
						span: span,
						rule: RULE_ID,
						severity: Severity.Info,
						message: 'drop the redundant ? on ?$name:$rawType'
						+ ' - a non-null default already makes the parameter optional, and the ? widens its body type to Null<$rawType>'
					});
				}
			}
		}
		for (c in node.children) walk(out, file, source, c, node, curFn, curFnParent, seams);
	}

	/**
	 * `plugin.refShape()`'s seams, bundled for `walk`'s gates. `params` backs all three arms;
	 * `functionKinds` is what makes the ancestor tracking below even start — an unset one means
	 * `fn` never binds, so `isSigilDropSafe` always refuses via its `fn == null` check (see
	 * "if the enclosing function cannot be determined" in the class doc).
	 */
	private static function buildSeams(plugin: GrammarPlugin): Seams {
		final shape: RefShape = plugin.refShape();
		return {
			params: shape.paramKinds ?? [],
			functionKinds: shape.functionKinds ?? [],
			supertypeClauseKinds: shape.supertypeClauseKinds ?? [],
			noBodyKind: shape.noBodyKind,
			identKind: shape.identKind,
			nullLitKind: shape.nullLiteralKind,
			switchKinds: shape.switchKinds ?? [],
			visibilityKinds: shape.visibilityModifierKinds ?? [],
			modifierKinds: shape.modifierOrderKinds ?? [],
			overrideModifierKind: shape.overrideModifierKind,
			staticModifierKind: shape.staticModifierKind,
			constructorName: shape.constructorName,
			equalityKinds: shape.equalityKinds ?? [],
			assignKind: shape.assignKind,
			localFunctionKinds: shape.localFunctionKinds ?? [],
			inlineFunctionKinds: shape.inlineFunctionKinds ?? [],
			inlineModifierKind: shape.inlineModifierKind,
			finalModifierMemberKind: shape.finalModifierMemberKind
		};
	}

	/**
	 * The redundant-sigil arm's five gates (G1-G5), all fail-closed: `fn`/`fnParent` null (the
	 * enclosing function could not be resolved), a body-less declaration, `identKind` unset, a
	 * contract obligation (G2, see `refusedByContract`), an overridable instance method (G5,
	 * see `isUnoverridable`), a `null` comparison / assignment involving `name` anywhere in
	 * `fn` (G3'), or `name` as a bare `switch` subject anywhere in `fn` (G4) all refuse.
	 * `nullLitKind` unset narrows only G3' (G4 needs no null literal), matching the class
	 * doc's "the NEW ARM is a no-op" contract for the three seams it names — `identKind` gates
	 * both G3' and G4 here since neither can run without it.
	 */
	private static function isSigilDropSafe(fn: Null<QueryNode>, fnParent: Null<QueryNode>, name: String, seams: Seams): Bool {
		if (fn == null) return false;
		if (fnParent == null) return false;
		if (hasNoBody(fn, seams.noBodyKind)) return false;
		final identKind: Null<String> = seams.identKind;
		if (identKind == null) return false;
		if (refusedByContract(fn, fnParent, seams)) return false;
		if (!isUnoverridable(fn, fnParent, seams)) return false;
		final nullLitKind: Null<String> = seams.nullLitKind;
		if (nullLitKind != null && hasNullComparisonOrAssign(fn, name, identKind, nullLitKind, seams)) return false;
		return !hasSwitchSubject(fn, name, identKind, seams.switchKinds);
	}

	/**
	 * G2, refined: refuse when `fn` carries an explicit `override` (Haxe requires NO `override`
	 * to implement an `abstract` superclass method or an interface method, so its ABSENCE proves
	 * nothing — a plain instance method in a type that `extends` / `implements` stays refused
	 * too); or when `fnParent` carries a supertype clause AND `fn` is neither the constructor
	 * (which can never override or implement — Haxe interfaces cannot declare one) nor `static`
	 * (which can never participate in instance dispatch). `constructorName` / `staticModifierKind`
	 * unset drops the corresponding exemption (fail closed to the blunt gate), never the refusal.
	 */
	private static function refusedByContract(fn: QueryNode, fnParent: QueryNode, seams: Seams): Bool {
		if (hasModifier(fn, fnParent, seams, seams.overrideModifierKind)) return true;
		if (!hasSupertypeClause(fnParent, seams.supertypeClauseKinds)) return false;
		final isConstructor: Bool = seams.constructorName != null && fn.name == seams.constructorName;
		final isStatic: Bool = hasModifier(fn, fnParent, seams, seams.staticModifierKind);
		return !isConstructor && !isStatic;
	}

	/** Whether `parent` (a function's enclosing node) carries a supertype clause. */
	private static function hasSupertypeClause(parent: QueryNode, supertypeClauseKinds: Array<String>): Bool {
		return parent.children.exists(c -> supertypeClauseKinds.contains(c.kind));
	}

	/**
	 * Whether `fn` carries `targetKind` among its preceding sibling modifiers in `parent`'s
	 * children — a backward scan over the contiguous modifier run, mirroring
	 * `UnusedParameter.isDynamicFn`. `targetKind` unset (the seam not carried by the grammar) is
	 * always a miss, never a match.
	 */
	private static function hasModifier(fn: QueryNode, parent: QueryNode, seams: Seams, targetKind: Null<String>): Bool {
		if (targetKind == null) return false;
		final sibs: Array<QueryNode> = parent.children;
		final fnIdx: Int = sibs.indexOf(fn);
		if (fnIdx < 0) return false;
		var i: Int = fnIdx - 1;
		while (i >= 0) {
			final sib: QueryNode = sibs[i];
			final isModifier: Bool = seams.visibilityKinds.contains(sib.kind) || seams.modifierKinds.contains(sib.kind);
			if (!isModifier) break;
			if (sib.kind == targetKind) return true;
			i--;
		}
		return false;
	}

	/**
	 * G5: whether `fn` is provably UN-overridable — the constructor
	 * (`RefShape.constructorName`, never inherited-overridable), `static`
	 * (`RefShape.staticModifierKind`, never virtual), a local or inline-local function
	 * (`RefShape.localFunctionKinds` / `inlineFunctionKinds`, not a class member at all),
	 * `inline` (`RefShape.inlineModifierKind` — measured `Field mi is inlined and cannot be
	 * overridden`), or a `RefShape.finalModifierMemberKind` node (`public final function
	 * f(...)`, which the grammar projects as its OWN kind rather than a `Final` modifier
	 * sibling — measured `Cannot override final method mf`). Anything else — a plain
	 * instance method of a non-final class — CAN be overridden from a subclass in ANOTHER
	 * file, which G2 cannot see (G2 only reads THIS type's own supertype clause, not
	 * whether some other file extends it). A seam left unset here simply grants no
	 * exemption from it (fail closed), never widens one.
	 *
	 * Deliberately NOT covering a method of a `final class` (`final class C { … }` cannot
	 * be extended — measured `Cannot extend a final class`): the grammar projects it as
	 * `(FinalDecl (ClassForm C …))`, so recognising it needs GRANDPARENT tracking `walk`
	 * does not otherwise carry, and every real site found needing it was already a
	 * constructor or a `static`. A conservative miss, not a correctness gap.
	 */
	private static function isUnoverridable(fn: QueryNode, fnParent: QueryNode, seams: Seams): Bool {
		if (seams.constructorName != null && fn.name == seams.constructorName) return true;
		if (seams.localFunctionKinds.contains(fn.kind)) return true;
		if (seams.inlineFunctionKinds.contains(fn.kind)) return true;
		if (seams.finalModifierMemberKind != null && fn.kind == seams.finalModifierMemberKind) return true;
		if (hasModifier(fn, fnParent, seams, seams.staticModifierKind)) return true;
		return hasModifier(fn, fnParent, seams, seams.inlineModifierKind);
	}

	/** Whether `fn` is a body-less declaration (an interface / abstract method) — G1. */
	private static function hasNoBody(fn: QueryNode, noBodyKind: Null<String>): Bool {
		if (noBodyKind == null) return false;
		return fn.children.exists(c -> c.kind == noBodyKind);
	}

	/**
	 * G3', precise: whether `name`'s identifier is (a) an operand of an equality node
	 * (`RefShape.equalityKinds`) whose OTHER operand is the `null` literal — reusing
	 * `NullFlow.nullComparisonOperand`, the exact pair test `AlwaysNullComparison` /
	 * `DeadNullGuard` already use, rather than re-deriving it; or (b) the LHS (first child) of
	 * an `Assign` (`RefShape.assignKind`) node whose RHS (last child) is the `null` literal —
	 * anywhere in `node`'s subtree. Narrower than "shares a direct parent with a `null`
	 * literal": `foo(name, null)` (the parameter and a `null` as sibling call ARGUMENTS) no
	 * longer matches — measured as the single biggest false-refusal cluster on a real tree (10
	 * of ~21 sites in one file, each shaped like a trailing-`null` constructor call).
	 */
	private static function hasNullComparisonOrAssign(
		node: QueryNode, name: String, identKind: String, nullLitKind: String, seams: Seams
	): Bool {
		if (seams.equalityKinds.contains(node.kind)) {
			final operand: Null<QueryNode> = NullFlow.nullComparisonOperand(node, identKind, nullLitKind);
			if (operand != null && operand.name == name) return true;
		}
		if (seams.assignKind != null && node.kind == seams.assignKind && node.children.length >= 2) {
			final lhs: QueryNode = node.children[0];
			final rhs: QueryNode = node.children[node.children.length - 1];
			if (lhs.kind == identKind && lhs.name == name && rhs.kind == nullLitKind) return true;
		}
		return node.children.exists(c -> hasNullComparisonOrAssign(c, name, identKind, nullLitKind, seams));
	}

	/**
	 * G4: whether `name` is the SUBJECT (first child) of any `switch` anywhere in `node`'s
	 * subtree — `switch p { case null: … }` puts its `NullLit` under `(CaseBranch (Plain
	 * (NullLit)))`, not a sibling of the subject, so `hasNullComparisonOrAssign` cannot see it.
	 */
	private static function hasSwitchSubject(node: QueryNode, name: String, identKind: String, switchKinds: Array<String>): Bool {
		if (switchKinds.contains(node.kind) && node.children.length > 0) {
			final subject: QueryNode = node.children[0];
			if (subject.kind == identKind && subject.name == name) return true;
		}
		return node.children.exists(c -> hasSwitchSubject(c, name, identKind, switchKinds));
	}

	/**
	 * The shared discriminator both default-value arms need: the node's `span`, at least one
	 * child (the default), that default's own span, and the `=` boundary the two arms read
	 * identically (`colon`/`eq` — see `nullableDefaultInner`'s doc for why this exact
	 * arithmetic is load-bearing). Returns the default's raw source text and the untrimmed
	 * type text between the name's `:` and the default's `=`, or null when any precondition
	 * fails; each caller applies its own default-text discriminator afterward.
	 */
	private static function defaultTypeSlice(node: QueryNode, source: String): Null<{ defText: String, typeText: String }> {
		final span: Null<Span> = node.span;
		if (span == null) return null;
		final kids: Array<QueryNode> = node.children;
		if (kids.length == 0) return null;
		final defSpan: Null<Span> = kids[kids.length - 1].span;
		if (defSpan == null) return null;
		final colon: Int = source.indexOf(':', span.from);
		if (colon < 0 || colon >= defSpan.from) return null;
		final eq: Int = source.lastIndexOf('=', defSpan.from - 1);
		return eq <= colon ? null : { defText: source.substring(defSpan.from, defSpan.to), typeText: source.substring(colon + 1, eq) };
	}

	/**
	 * The redundant-sigil shape: `?name:T = <non-null default>`, else null. The node's span
	 * must start with `?`; it must have at least one child (a default); the last child's source
	 * text must NOT be `null` (that shape belongs to the OTHER arm, `nullableDefaultInner`); and
	 * the `=` discriminator from `nullableDefaultInner` must hold, so an anon type with no
	 * default (`?a:{x:Int}`, whose sole child is the anon type itself) is correctly rejected —
	 * `eq` is either `-1` or an earlier parameter's `=`, both `<= colon`. The returned text is
	 * the type verbatim, untouched — there is nothing to unwrap here.
	 */
	private static function redundantSigil(node: QueryNode, source: String): Null<String> {
		final span: Null<Span> = node.span;
		if (span == null || source.fastCodeAt(span.from) != '?'.code) return null;
		final slice: Null<{ defText: String, typeText: String }> = defaultTypeSlice(node, source);
		if (slice == null || slice.defText == 'null') return null;
		final typeText: String = slice.typeText.trim();
		return typeText.length > 0 ? typeText : null;
	}


	/**
	 * The nullable-defaulted parameter shape of a parameter that reads `name:Null<T> = null`,
	 * `name:T = null`, or `?name:T = null`, else null. The parameter's last child (the
	 * default value) must be exactly the `null` literal. For a required parameter (no
	 * leading `?`), when the type text between the name's `:` and the default's `=` unwraps
	 * as a single `Null<T>`, `inner` is `T` (the wrapped arm); otherwise the type text
	 * stands as its own `inner` (the bare-type arm) — a live compiler probe confirmed
	 * `p:T = null` and `?p:T` type identically to `(?p:Null<T>)`, so the rewrite is safe
	 * without unwrapping. A `Null<`-prefixed text that `unwrapNull` rejected (decorated or
	 * malformed) is refused rather than claimed by the bare arm. For an already-optional
	 * parameter (`opt` true) the `= null` default is redundant — `inner` is the type text
	 * verbatim (no unwrap, so `?x:Null<T> = null` keeps `Null<T>`), and the fix only drops
	 * the ` = null`. `raw` is always the trimmed type text, used to compose the violation
	 * message.
	 */
	private static function nullableDefaultInner(node: QueryNode, source: String): Null<{ inner: String, raw: String, opt: Bool }> {
		final span: Null<Span> = node.span;
		if (span == null) return null;
		final opt: Bool = source.fastCodeAt(span.from) == '?'.code;
		final slice: Null<{ defText: String, typeText: String }> = defaultTypeSlice(node, source);
		if (slice == null || slice.defText != 'null') return null;
		final raw: String = slice.typeText.trim();
		if (opt) return raw.length > 0 ? { inner: raw, raw: raw, opt: true } : null;
		final unwrapped: Null<String> = unwrapNull(slice.typeText);
		return if (unwrapped != null)
			{ inner: unwrapped, raw: raw, opt: false }
		else if (raw.length > 0 && !nullWrapperPrefixed(raw))
			{ inner: raw, raw: raw, opt: false }
		else
			null;
	}

	/**
	 * The inner `T` of a `Null<T>` type text, else null. The text (trimmed) must be `Null`
	 * followed by a `<...>` whose matching close is the final character — so a same-prefix
	 * name (`Nullable<T>`) or trailing tokens are rejected. A `>` preceded by `-` is the
	 * arrow `->` of a function-type parameter, not an angle close, and does not decrement
	 * the depth.
	 */
	private static function unwrapNull(typeText: String): Null<String> {
		final t: String = typeText.trim();
		if (!t.startsWith('Null')) return null;
		var i: Int = 4;
		while (i < t.length && t.isSpace(i)) i++;
		if (i >= t.length || t.fastCodeAt(i) != '<'.code) return null;
		final open: Int = i;
		var depth: Int = 0;
		var close: Int = -1;
		while (i < t.length) {
			switch t.fastCodeAt(i) {
				case '<'.code:
					depth++;
				case '>'.code if (t.fastCodeAt(i - 1) != '-'.code):
					depth--;
					if (depth == 0) {
						close = i;
						break;
					}
				case _:
			}
			i++;
		}
		if (close < 0) return null;
		// The matching `>` must be the last non-space character, else the text is not a
		// clean single `Null<...>` (e.g. `Null<Int>Foo`).
		var j: Int = t.length - 1;
		while (j > close && t.isSpace(j)) j--;
		if (j != close) return null;
		final inner: String = t.substring(open + 1, close).trim();
		return inner.length > 0 ? inner : null;
	}


	/**
	 * Whether the trimmed type text opens as a `Null<` wrapper — `Null` followed, after
	 * optional spaces, by `<`. Such a text that `unwrapNull` still rejected is a decorated
	 * or malformed `Null<...>` (e.g. a trailing comment before the default's `=`), which
	 * the bare-type arm must not claim: coercing it would prepend `?` without unwrapping,
	 * violating the one-layer-unwrap contract.
	 */
	private static function nullWrapperPrefixed(t: String): Bool {
		if (!t.startsWith('Null')) return false;
		var i: Int = 4;
		while (i < t.length && t.isSpace(i)) i++;
		return i < t.length && t.fastCodeAt(i) == '<'.code;
	}

}

/**
 * Grammar seams the redundant-sigil arm's gates read, bundled so `walk` does not carry a
 * long positional-parameter list. `params` and `functionKinds` back all three arms;
 * everything else is specific to gates G1-G4 and the constructor / `static` / `override`
 * exemptions of G2 (see the class doc). The `Null<String>` fields are seams
 * `nullableDefaultInner` and the two existing arms never needed — an unset one narrows only
 * the redundant-sigil arm to a no-op, never the two pre-existing arms.
 */
private typedef Seams = {
	final params: Array<String>;
	final functionKinds: Array<String>;
	final supertypeClauseKinds: Array<String>;
	final noBodyKind: Null<String>;
	final identKind: Null<String>;
	final nullLitKind: Null<String>;
	final switchKinds: Array<String>;
	final visibilityKinds: Array<String>;
	final modifierKinds: Array<String>;
	final overrideModifierKind: Null<String>;
	final staticModifierKind: Null<String>;
	final constructorName: Null<String>;
	final equalityKinds: Array<String>;
	final assignKind: Null<String>;
	final localFunctionKinds: Array<String>;
	final inlineFunctionKinds: Array<String>;
	final inlineModifierKind: Null<String>;
	final finalModifierMemberKind: Null<String>;
};
