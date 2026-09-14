package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.OccurrenceScan;
import anyparse.query.QueryNode;
import anyparse.query.SourceComments;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
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
 * `Null<T>`. A FOURTH arm hoists a coalesced default: an optional parameter with NO default whose every
 * read is `name ?? <compile-time constant>` is declared `name:T = <constant>` instead, and every `??`
 * collapses to a bare `name`. `Severity.Info` for all four arms (a style cleanup), each with an autofix. For
 * the first two arms the fix rewrites the parameter to `?name:T` — unwrapping one `Null<>`
 * layer when present (else keeping the type as-is), dropping the ` = null`, and prepending
 * `?`; for the third arm the fix drops ONLY the leading `?`, leaving `name:T = <default>`
 * byte-for-byte otherwise unchanged; for the fourth the parameter and every coalescing read
 * are rewritten together. Grammar-agnostic over `RefShape.paramKinds` (unset -> no-op).
 *
 * ## Equivalence — why the rewrite is safe
 *
 * `?x:T` and `x:Null<T> = null` are equivalent for a nullable-defaulted parameter: the `?`
 * widens `x`'s type to `Null<T>` (so the body sees the same nullable value on static
 * targets), and both permit omitting the argument at trailing call sites — the `= null`
 * default and the `?` sigil compile the same calls. No call site changes. And
 * `x:T = null` types identically: `$type` gives `(?p:Null<T>)
 * -> Void` for BOTH `p:Int = null` and `?p:Int`, and the `haxe.PosInfos` call-site auto-fill
 * magic fires in both forms — so the bare-type arm needs no extra gates. For the
 * already-optional arm the equivalence is immediate: an omitted `?x:T` argument already
 * yields `null`, so an explicit `= null` default changes nothing.
 *
 * For the THIRD arm the equivalence is just as immediate: a default value alone already
 * makes a parameter optional (Haxe permits omitting any trailing argument that has a
 * default, `?` or not), so the `?` adds nothing but the type widening:
 * `?p:Bool = true` gives the BODY type `Null<Bool>` and the external signature
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
 *   declaration) is refused. Dropping `?` there changes the contract (`Field h has
 *   different type than in I ... error: Bool should be Null<Bool>`).
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
 *   enclosing function's subtree. Breakages: `if (p == null)` -> `(Eq (IdentExpr p)
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
 * ## The FOURTH arm — `?name:T` with `name ?? CONST` as its every read -> `name:T = CONST`
 *
 * Haxe compiles a signature default into `if (name == null) name = CONST;` at the top of the
 * function, so the two spellings are the same program: an omitted argument and an explicitly
 * passed `null` both yield `CONST` in either form, for `String` and
 * for `Int` alike, including a caller forwarding its own null-valued optional parameter. No call site
 * changes. The signature form is strictly better — it names the default where a reader looks
 * for it, and under `@:nullSafety` the body sees `T` rather than `Null<T>`, so nothing
 * downstream needs a null proof.
 *
 * The arm reuses G1-G5 unchanged, because its OUTPUT is the third arm's output: it makes
 * exactly the same signature change and inherits exactly the same override / interface exposure
 * and the same residual risk below. Four gates of its own sit on top:
 *
 * - The default must be a value Haxe accepts in a signature — a scalar or string literal, a
 *   negated numeric literal, a `static inline` field, or an enum-abstract value, the last two
 *   proven through the cross-file `SymbolIndex` exactly as `prefer-switch` proves a `case`
 *   pattern. A non-inline `static final` is `Default argument value should be
 *   constant`, so an unresolvable reference is a refusal, never an assumption. A LITERAL
 *   additionally has to FIT the declared type — `p ?? 0.` on a `?p:Int` widens to `Float` and
 *   compiles, `p:Int = 0.` does not — which `RefShape.literalTypeNames` answers wherever the
 *   grammar has an opinion (`literalFitsType`).
 * - EVERY occurrence of the name inside the enclosing function must be the declaration or one of
 *   the collected `??` left operands. This is the gate that fails SILENTLY when omitted: the
 *   hoist removes `null` from the parameter's value range, so any read that observed it dies
 *   with no compiler complaint. A textual scan answers it, which over-refuses on a mention in a
 *   comment or a string — the safe direction, and the same trade the `unused-*` family makes. A
 *   DOT-QUALIFIED occurrence is skipped: a parameter is never reached through a `.`, so the
 *   `this.name = name ?? CONST` constructor idiom names a FIELD on its left, not the parameter.
 * - All the collected fallbacks must spell the SAME constant. Two different ones mean the
 *   parameter's absence is read differently per site, which one signature default cannot
 *   express.
 * - The declared type is the annotation with one `Null<>` layer removed, and a text still
 *   nullable after that unwrap is refused: `name:Null<T> = CONST` leaves the body type nullable
 *   and defeats the rewrite.
 *
 * ## Residual risk
 *
 * No in-file gate can close two residual cases, both surfacing as BUILD ERRORS, never as
 * silent misbehaviour — the finding stays `Severity.Info` regardless: a caller in ANOTHER
 * file passing a LITERAL `null` into the slot of a BASIC-typed parameter (`noQ(null)` where
 * `p:Bool = true`) is a compile error after the fix; and a subclass in another file whose
 * override keeps the `?` breaks too. The fourth arm adds a third of the same kind: a NAMED
 * constant whose own declared type is not assignable to the parameter's. `literalFitsType`
 * answers that for a LITERAL; for a resolved member it would mean comparing type TEXT across
 * files, which an enum-abstract value — usually unannotated — fails, so that one is left to
 * the compiler.
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
 * - For the FOURTH arm: a parameter with no coalescing read at all, one read some other way, one
 *   whose fallbacks disagree, one whose fallback is not a compile-time constant (a call, an
 *   arithmetic expression, an unresolvable name) or does not fit the declared type, and an
 *   untyped `?name = <default>` — its
 *   default may spell a colon of its own, so there is no annotation to carry the rewrite.
 * - For the third arm: a parameter in a type that `extends` / `implements` (unless the
 *   function is the constructor or `static`), a body-less declaration, a parameter the
 *   enclosing function tests against `null` or switches on, or a parameter whose enclosing
 *   function cannot be found — G1-G4 above; the arm stays silent, not merely downgraded.
 *
 * Fine with NO gate for the third arm: function-value contexts (`var
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
			+ 'replaces, a redundant = null default on an already-optional ?name:T, a redundant ? on ?name:T = <non-null default>, '
			+ 'or an optional ?name:T whose every read is name ?? CONST (declare name:T = CONST instead)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Seams = buildSeams(plugin);
		if (seams.params.length == 0) return [];
		final resolveIndex: () -> Null<SymbolIndex> = SwitchChain.lazyIndexOf(files, plugin);
		return RunScan.collect(files, plugin, (entry, tree, violations) -> {
			final scope: HoistScope = {
				root: tree,
				resolveIndex: resolveIndex,
				commentRegions: lazyCommentRegions(plugin, entry.source),
				matchMask: lazyMatchMask(plugin, entry.source)
			};
			final sites: Array<ParamSite> = [];
			collectParams(sites, tree, null, null, null, seams);
			for (site in sites) report(violations, entry.file, entry.source, site, seams, scope);
		});
	}

	/**
	 * Rewrite each flagged parameter. The parameter node is re-found by its reported span and its
	 * arm re-derived from the bytes, so an edit fires only while the source still matches the shape
	 * the finding was reported for. The parameter's own span is what the first three arms replace —
	 * commas, the surrounding parentheses and the sibling parameters sit outside it, so position and
	 * trivia stay intact; the hoist arm adds one edit per coalescing read on top, which is why the
	 * whole parse is redone here rather than reached through `CheckScan.applyBySpan` (one violation,
	 * several edits).
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Seams = buildSeams(plugin);
		return seams.params.length == 0
			? []
			: RunScan.edits(plugin, source, tree -> {
				final scope: HoistScope = {
					root: tree,
					resolveIndex: SwitchChain.lazyIndexOf([{ file: '', source: source }], plugin, index),
					commentRegions: lazyCommentRegions(plugin, source),
					matchMask: lazyMatchMask(plugin, source)
				};
				final sites: Array<ParamSite> = [];
				collectParams(sites, tree, null, null, null, seams);
				final byKey: Map<String, ParamSite> = [];
				for (site in sites) {
					final span: Null<Span> = site.node.span;
					if (span != null) byKey['${span.from}:${span.to}'] = site;
				}
				final edits: Array<{ span: Span, text: String }> = [];
				RunScan.eachMatched(violations, byKey, (site, span) -> collectEdits(edits, source, span, site, seams, scope));
				return edits;
			});
	}

	/**
	 * Every parameter node under `node`, each paired with the function that declares it and that
	 * function's own parent. The whole tree is walked so class methods, constructors and local
	 * functions are all reached; a LAMBDA parameter is reached too, and reports the enclosing named
	 * function as its `fn` (`RefShape.functionKinds` does not list the lambda kinds), which only ever
	 * widens the region the hoist arm's completeness scan covers.
	 *
	 * One walk shared by `run` and `fix`: the two must agree on which parameter a violation span
	 * addresses, and on which function the gates are asked about.
	 */
	private static function collectParams(
		out: Array<ParamSite>, node: QueryNode, parent: Null<QueryNode>, fn: Null<QueryNode>, fnParent: Null<QueryNode>, seams: Seams
	): Void {
		final isFn: Bool = seams.functionKinds.contains(node.kind);
		final curFn: Null<QueryNode> = isFn ? node : fn;
		final curFnParent: Null<QueryNode> = isFn ? parent : fnParent;
		if (seams.params.contains(node.kind)) out.push({ node: node, fn: curFn, fnParent: curFnParent });
		for (c in node.children) collectParams(out, c, node, curFn, curFnParent, seams);
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
			shape: shape,
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
			finalModifierMemberKind: shape.finalModifierMemberKind,
			nullCoalKind: shape.nullCoalesceKind,
			fieldAccessKind: shape.fieldAccessKind,
			fieldDeclKinds: shape.fieldDeclKinds ?? [],
			enumAbstractDeclKind: shape.enumAbstractDeclKind,
			constLiteralKinds: shape.inlineConstantLiteralKinds ?? [],
			numericKinds: shape.numericLiteralKinds ?? [],
			literalTypeNames: shape.literalTypeNames ?? [],
			negationKind: shape.negationKind,
			stringFold: plugin.stringFoldSupport()
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
		return targetKind != null
			&& MemberKinds.precedingModifiers(fn, parent, seams.visibilityKinds.concat(seams.modifierKinds))
				.exists(sib -> sib.kind == targetKind);
	}

	/**
	 * G5: whether `fn` is provably UN-overridable — the constructor
	 * (`RefShape.constructorName`, never inherited-overridable), `static`
	 * (`RefShape.staticModifierKind`, never virtual), a local or inline-local function
	 * (`RefShape.localFunctionKinds` / `inlineFunctionKinds`, not a class member at all),
	 * `inline` (`RefShape.inlineModifierKind` — `Field mi is inlined and cannot be
	 * overridden`), or a `RefShape.finalModifierMemberKind` node (`public final function
	 * f(...)`, which the grammar projects as its OWN kind rather than a `Final` modifier
	 * sibling — `Cannot override final method mf`). Anything else — a plain
	 * instance method of a non-final class — CAN be overridden from a subclass in ANOTHER
	 * file, which G2 cannot see (G2 only reads THIS type's own supertype clause, not
	 * whether some other file extends it). A seam left unset here simply grants no
	 * exemption from it (fail closed), never widens one.
	 *
	 * Deliberately NOT covering a method of a `final class` (`final class C { … }` cannot
	 * be extended — `Cannot extend a final class`): the grammar projects it as
	 * `(FinalDecl (ClassForm C …))`, so recognising it needs GRANDPARENT tracking `walk`
	 * does not otherwise carry, and every real site found needing it was already a
	 * constructor or a `static`. A conservative miss, not a correctness gap.
	 */
	private static function isUnoverridable(fn: QueryNode, fnParent: QueryNode, seams: Seams): Bool {
		return seams.constructorName != null && fn.name == seams.constructorName || seams.localFunctionKinds.contains(fn.kind)
			|| seams.inlineFunctionKinds.contains(fn.kind) || seams.finalModifierMemberKind != null
			&& fn.kind == seams.finalModifierMemberKind || hasModifier(fn, fnParent, seams, seams.staticModifierKind)
			|| hasModifier(fn, fnParent, seams, seams.inlineModifierKind);
	}

	/** Whether `fn` is a body-less declaration (an interface / abstract method) — G1. */
	private static function hasNoBody(fn: QueryNode, noBodyKind: Null<String>): Bool {
		return noBodyKind != null && fn.children.exists(c -> c.kind == noBodyKind);
	}

	/**
	 * G3', precise: whether `name`'s identifier is (a) an operand of an equality node
	 * (`RefShape.equalityKinds`) whose OTHER operand is the `null` literal — reusing
	 * `NullFlow.nullComparisonOperand`, the exact pair test `AlwaysNullComparison` /
	 * `DeadNullGuard` already use, rather than re-deriving it; or (b) the LHS (first child) of
	 * an `Assign` (`RefShape.assignKind`) node whose RHS (last child) is the `null` literal —
	 * anywhere in `node`'s subtree. Narrower than "shares a direct parent with a `null`
	 * literal": `foo(name, null)` (the parameter and a `null` as sibling call ARGUMENTS) does
	 * not match — the single biggest false-refusal cluster on a real tree, each site shaped
	 * like a trailing-`null` constructor call.
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

	/**
	 * Push the ONE finding `site` earns, if any. `classify` decides which arm owns the parameter;
	 * the signature gates (G1-G5, `isSigilDropSafe`) apply to the two arms that DROP a `?` — the
	 * nullable-default arm adds one and changes no external type.
	 */
	private static function report(
		out: Array<Violation>, file: String, source: String, site: ParamSite, seams: Seams, scope: HoistScope
	): Void {
		final name: Null<String> = site.node.name;
		final nodeSpan: Null<Span> = site.node.span;
		if (name == null || nodeSpan == null) return;
		// Re-bound to non-null locals: strict null-safety takes a struct literal's field type
		// from the declared type, not the narrowed one.
		final span: Span = nodeSpan;
		final arm: Null<ParamArm> = classify(site, source, seams, scope);
		if (arm == null) return;
		// G1-G5 govern both arms that DROP a `?`; the nullable-default arm adds one and needs none.
		final message: Null<String> = switch arm {
			case NullDefault(shape): 'prefer ?$name:${shape.inner} over ${shape.opt ? '?' : ''}$name:${shape.raw} = null';
			case _ if (!isSigilDropSafe(site.fn, site.fnParent, name, seams)): null;
			case RedundantSigil(rawType): 'drop the redundant ? on ?$name:$rawType'
				+ ' - a non-null default already makes the parameter optional, and the ? widens its body type to Null<$rawType>';
			case Hoist(plan): 'prefer $name:${plan.typeText} = ${plan.constText} over ?$name:${plan.rawType}'
				+ ' with $name ?? ${plan.constText}';
		}
		if (message == null) return;
		// Re-bound to a non-null local — see above.
		final text: String = message;
		out.push({
			file: file,
			span: span,
			rule: RULE_ID,
			severity: Severity.Info,
			message: text
		});
	}

	/**
	 * The edits ONE violation earns, appended to `out`. The arm is re-derived from the bytes through
	 * the same `classify` `run` used, so an edit fires only while the source still matches the shape
	 * the finding was reported for — and never a DIFFERENT arm's rewrite. The hoist arm is the only
	 * one that emits more than one edit: the signature and every coalescing read must change together
	 * or the result does not compile.
	 */
	private static function collectEdits(
		out: Array<{ span: Span, text: String }>, source: String, span: Span, site: ParamSite, seams: Seams, scope: HoistScope
	): Void {
		final name: Null<String> = site.node.name;
		final arm: Null<ParamArm> = name == null ? null : classify(site, source, seams, scope);
		if (arm == null || name == null) return;
		switch arm {
			case NullDefault(shape):
				out.push({ span: span, text: '?$name:${shape.inner}' });
			case RedundantSigil(_):
				out.push({ span: span, text: source.substring(span.from + 1, span.to) });
			case Hoist(plan):
				out.push({ span: span, text: '$name:${plan.typeText} = ${plan.constText}' });
				for (read in plan.sites) out.push({ span: read.coal, text: name });
		}
	}

	/**
	 * The hoist arm's shape: an OPTIONAL parameter with NO default whose every read in `fn` is
	 * `name ?? <constant>`, all spelling the SAME constant. Returns the type to declare, that
	 * constant's verbatim text, and the reads to collapse; null when any gate refuses.
	 *
	 * The gates run cheapest-first, and the order is load-bearing for cost as much as for safety:
	 * the structural tests reject every parameter that is not `?name:T`, the read scan rejects an
	 * unused one, the COMPLETENESS scan rejects everything the coalescing scan could not account
	 * for, and only what survives all three is worth resolving a cross-file constant for (which may
	 * build a `SymbolIndex`).
	 *
	 * The completeness scan is the gate that fails SILENTLY when omitted. Hoisting removes `null`
	 * from the parameter's value range, so any occurrence that observed it — a bare read, a write, a
	 * `switch`, a shadowing declaration in a nested function — dies with no compiler complaint.
	 * `OccurrenceScan.referencedUnqualifiedInRange` over the enclosing function's span, with the
	 * declaration and the collected left operands excluded, answers exactly that: it over-refuses (a
	 * mention in a comment or a string counts), which is the safe direction, and it skips a
	 * DOT-QUALIFIED occurrence, which is not over-refusal but correctness — a parameter is never
	 * reached through a `.`, so the `this.name = name ?? CONST` constructor idiom names a FIELD on
	 * its left.
	 */
	private static function hoistPlan(
		node: QueryNode, fn: Null<QueryNode>, source: String, seams: Seams, scope: HoistScope
	): Null<HoistPlan> {
		final coalKind: Null<String> = seams.nullCoalKind;
		final identKind: Null<String> = seams.identKind;
		final span: Null<Span> = node.span;
		final name: Null<String> = node.name;
		if (coalKind == null || identKind == null || span == null || name == null) return null;
		if (source.fastCodeAt(span.from) != '?'.code || defaultTypeSlice(node, source) != null) return null;
		final declSpan: Span = span;
		final colon: Int = typeColonOffset(source, span, name);
		if (colon < 0 || fn == null) return null;
		final rawType: String = source.substring(colon + 1, span.to).trim();
		final typeText: Null<String> = hoistTypeText(rawType);
		if (typeText == null) return null;
		// Re-bound to a non-null local: strict null-safety does not narrow a captured
		// parameter across the calls below.
		final owner: QueryNode = fn;
		final fnSpan: Null<Span> = owner.span;
		if (fnSpan == null) return null;
		final sites: Array<CoalescingRead> = [];
		collectCoalescingReads(sites, owner, name, coalKind, identKind);
		if (sites.length == 0) return null;
		final accounted: Array<Span> = [for (read in sites) read.ident];
		accounted.push(declSpan);
		final comments: Array<Span> = scope.commentRegions();
		if (OccurrenceScan.referencedUnqualifiedInRange(source, name, fnSpan.from, fnSpan.to, accounted, comments, scope.matchMask()))
			return null;
		final constText: Null<String> = agreedConstant(sites, typeText, seams, scope, source);
		return constText == null ? null : {
			typeText: typeText,
			rawType: rawType,
			constText: constText,
			sites: sites
		};
	}

	/**
	 * The type the hoisted parameter must be DECLARED with: the annotation as written, with one
	 * `Null<>` layer removed. A text the unwrapper rejects (decorated or malformed), and one still
	 * nullable after the unwrap, are both refused — `name:Null<T> = CONST` would leave the body type
	 * nullable and defeat the whole rewrite.
	 */
	private static function hoistTypeText(rawType: String): Null<String> {
		if (rawType.length == 0) return null;
		final unwrapped: Null<String> = unwrapNull(rawType);
		final inner: String = unwrapped ?? rawType;
		return nullWrapperPrefixed(inner) ? null : inner;
	}

	/**
	 * The offset of the parameter's OWN type colon — the first non-space character after the
	 * `?` and the name token must be `:` — or -1 when the parameter carries no annotation.
	 *
	 * Located from the name token rather than searched for. An `indexOf(':')` from the span's
	 * start reads an untyped parameter's own default (`?c = ':'`) as the annotation, and takes
	 * a LATER parameter's colon when the default holds none — both yield a "type" that is a
	 * fragment of a string literal, which the arms with a default never ask for because their
	 * `=` discriminator refuses first.
	 */
	private static function typeColonOffset(source: String, span: Span, name: String): Int {
		var i: Int = span.from + 1;
		while (i < span.to && source.isSpace(i)) i++;
		if (source.substr(i, name.length) != name) return -1;
		i += name.length;
		while (i < span.to && source.isSpace(i)) i++;
		return i < span.to && source.fastCodeAt(i) == ':'.code ? i : -1;
	}

	/**
	 * Collect every `name ?? <fallback>` in `node`'s subtree whose LEFT operand is the bare
	 * identifier `name`. A read on the RIGHT (`x ?? name`) is not collected and therefore
	 * blocks the arm through the completeness scan — it observes the parameter's `null`.
	 */
	private static function collectCoalescingReads(
		out: Array<CoalescingRead>, node: QueryNode, name: String, coalKind: String, identKind: String
	): Void {
		if (node.kind == coalKind && node.children.length == 2) {
			final left: QueryNode = node.children[0];
			final coal: Null<Span> = node.span;
			final ident: Null<Span> = left.span;
			// Re-bound as non-null locals: strict null-safety takes a struct literal's field
			// type from the declared type, not the narrowed one.
			if (left.kind == identKind && left.name == name && coal != null && ident != null) {
				final whole: Span = coal;
				final subject: Span = ident;
				out.push({ coal: whole, ident: subject, fallback: node.children[1] });
			}
		}
		for (c in node.children) collectCoalescingReads(out, c, name, coalKind, identKind);
	}

	/**
	 * The ONE constant every collected read falls back to, or null when a read's fallback is
	 * not a compile-time constant or two of them disagree. Two different fallbacks mean the
	 * parameter's absence is read differently per site, which one signature default cannot
	 * express; the comparison is on the verbatim source text, so a respelling of the same value
	 * is a refusal too.
	 */
	private static function agreedConstant(
		sites: Array<CoalescingRead>, typeText: String, seams: Seams, scope: HoistScope, source: String
	): Null<String> {
		var agreed: Null<String> = null;
		for (read in sites) {
			final text: Null<String> = constantDefaultText(read.fallback, typeText, seams, scope, source);
			if (text == null || agreed != null && agreed != text) return null;
			agreed = text;
		}
		return agreed;
	}

	/**
	 * `node`'s verbatim source when it is a value Haxe accepts as a PARAMETER DEFAULT, else
	 * null: a scalar literal (`RefShape.inlineConstantLiteralKinds`), a negated numeric one, a
	 * string literal the fold support recognises, or a reference the index proves constant.
	 * Anything else — a call, an arithmetic expression, an unresolvable name — is
	 * `Default argument value should be constant` at the declaration, so an unknown is a
	 * refusal, never an assumption.
	 *
	 * The `null` literal is refused explicitly rather than left to the literal set: the result would be `name:T = null`, the FIRST arm's
	 * INPUT shape, and the two arms would then rewrite each other on every `--fix` pass. Unreachable through a grammar whose constant
	 * kinds exclude it, as Haxe's do — it states the contract a grammar must keep, the way the unset-seam refusals around it do.
	 */
	private static function constantDefaultText(
		node: QueryNode, typeText: String, seams: Seams, scope: HoistScope, source: String
	): Null<String> {
		final span: Null<Span> = node.span;
		if (span == null || node.kind == seams.nullLitKind) return null;
		final negated: Bool = seams.negationKind != null && node.kind == seams.negationKind && node.children.length == 1
			&& seams.numericKinds.contains(node.children[0].kind);
		final literal: Bool = seams.constLiteralKinds.contains(node.kind) || negated || seams.stringFold?.literalOf(node, source) != null;
		final fits: Bool = literal
			? literalFitsType(typeText, negated ? node.children[0].kind : node.kind, seams)
			: provesConstantReference(node, span, seams, scope);
		return fits ? source.substring(span.from, span.to) : null;
	}

	/**
	 * Whether `node` NAMES a compile-time constant, in either spelling: a qualified `T.M`
	 * (`RefShape.fieldAccessKind` over a bare identifier receiver) or a BARE identifier whose
	 * occurrence BINDS to a field declaration (`TypeResolver.bareFieldOwner`, which answers the
	 * owning type). The binding proof is what separates a constant from a same-named LOCAL that
	 * shadows it — a name-keyed lookup reads the two identically.
	 *
	 * Both spellings then go through `isConstantField` for EVERY declaration the index resolves
	 * them to, so the two can never disagree about one constant. This is the proof
	 * `prefer-switch` applies to a `case` pattern; the two questions coincide because Haxe
	 * accepts the same values in both slots.
	 */
	private static function provesConstantReference(node: QueryNode, span: Span, seams: Seams, scope: HoistScope): Bool {
		final identKind: Null<String> = seams.identKind;
		final name: Null<String> = node.name;
		if (identKind == null || name == null) return false;
		return if (
			seams.fieldAccessKind != null && node.kind == seams.fieldAccessKind && node.children.length == 1
			&& node.children[0].kind == identKind
		)
			isConstantMember(node.children[0].name, name, seams, scope)
		else if (node.kind == identKind && node.children.length == 0)
			isConstantMember(TypeResolver.bareFieldOwner(name, span, scope.root, seams.shape, seams.fieldDeclKinds), name, seams, scope)
		else
			false;
	}

	/**
	 * Whether `typeName.memberName` resolves through the index to at least one declaration,
	 * EVERY one of which `isConstantField` accepts. An empty resolution means "unknown", never
	 * "absent" — the index skips unparseable files and models neither packages nor
	 * macro-generated members — so it is a refusal too.
	 */
	private static function isConstantMember(typeName: Null<String>, memberName: String, seams: Seams, scope: HoistScope): Bool {
		if (typeName == null) return false;
		final index: Null<SymbolIndex> = scope.resolveIndex();
		if (index == null) return false;
		final decls: Array<{ type: TypeDeclInfo, member: MemberInfo }> = index.members.memberDeclarationsOf(typeName, memberName);
		return decls.length != 0 && decls.foreach(decl -> isConstantField(decl.type, decl.member, seams));
	}

	/**
	 * Whether ONE resolved field declaration is a value Haxe folds at compile time: an
	 * enum-abstract value (a non-`static` member of an `enumAbstractDeclKind`) or a
	 * `static inline` field. The `inline` modifier is the proof — Haxe refuses it on a
	 * non-constant initializer — while a plain `static final` is `Default argument value should
	 * be constant` at the declaration site. A `#if`-guarded declaration is branch-dependent
	 * while the index is branch-blind, so it is refused.
	 */
	private static function isConstantField(type: TypeDeclInfo, member: MemberInfo, seams: Seams): Bool {
		if (member.guarded || !seams.fieldDeclKinds.contains(member.kind)) return false;
		final enumAbstractKind: Null<String> = seams.enumAbstractDeclKind;
		if (enumAbstractKind != null && type.kind == enumAbstractKind && !member.isStatic) return true;
		return member.isStatic && member.isInline;
	}

	/**
	 * Which arm owns `site`, or null when none does. The ONE place the three shapes are told
	 * apart, so `run` and `fix` cannot drift into disagreeing about a parameter. The signature
	 * gates (G1-G5) are NOT applied here: `fix` trusts the finding it is handed and must not
	 * re-derive a verdict `run` already took, while `run` needs the classification first to
	 * know whether they apply at all.
	 */
	private static function classify(site: ParamSite, source: String, seams: Seams, scope: HoistScope): Null<ParamArm> {
		final node: QueryNode = site.node;
		final shape: Null<{ inner: String, raw: String, opt: Bool }> = nullableDefaultInner(node, source);
		if (shape != null) return NullDefault(shape);
		final rawType: Null<String> = redundantSigil(node, source);
		if (rawType != null) return RedundantSigil(rawType);
		final plan: Null<HoistPlan> = hoistPlan(node, site.fn, source, seams, scope);
		return plan == null ? null : Hoist(plan);
	}

	/**
	 * A memoised thunk for `source`'s comment spans — the mask the completeness scan's qualifier
	 * test needs. A thunk so a file with no candidate parameter never pays the lexical pass.
	 */
	private static function lazyCommentRegions(plugin: GrammarPlugin, source: String): () -> Array<Span> {
		var cached: Null<Array<Span>> = null;
		function resolve(): Array<Span> {
			final have: Null<Array<Span>> = cached;
			if (have != null) return have;
			final built: Array<Span> = SourceComments.collectCommentRegions(plugin.lexicalRegions(source));
			cached = built;
			return built;
		}
		return resolve;
	}

	/**
	 * `HoistScope.matchMask`'s producer — the full inert mask (comments, regex, non-interpolating
	 * strings), lazy for the same reason `lazyCommentRegions` is: a run whose files hold no
	 * candidate parameter lexes nothing.
	 */
	private static function lazyMatchMask(plugin: GrammarPlugin, source: String): () -> Array<Span> {
		var cached: Null<Array<Span>> = null;
		function resolve(): Array<Span> {
			final have: Null<Array<Span>> = cached;
			if (have != null) return have;
			final built: Array<Span> = OccurrenceScan.inertMask(source, plugin);
			cached = built;
			return built;
		}
		return resolve;
	}

	/**
	 * Whether a LITERAL of `kind` may stand as the default of a parameter declared `typeText`.
	 *
	 * The one type question this arm cannot leave to the `??` it replaces: `p ?? 0.` on a
	 * `?p:Int` widens to `Float` and compiles, while `p:Int = 0.` does not. `literalTypeNames`
	 * answers it wherever the grammar has an opinion — when the declared type is itself a type
	 * that map PRODUCES, the literal's own type must BE that type. A declared type the map never
	 * names (an abstract with its own `@:from`, any nominal type) is left to the compiler: the
	 * map cannot speak for a conversion it does not model, and refusing there would lose every
	 * enum-abstract and `UInt` default. The price is one over-refusal — an integer literal
	 * defaulting a float-typed parameter, which the language widens — and that is the
	 * fail-closed side.
	 */
	private static function literalFitsType(typeText: String, kind: String, seams: Seams): Bool {
		final literalType: Null<String> = seams.literalTypeNames[kind];
		if (literalType == null) return true;
		for (name in seams.literalTypeNames) if (name == typeText) return literalType == typeText;
		return true;
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
	/** The whole shape, for `TypeResolver.bareFieldOwner` — the one seam reader that needs more than a kind list. */
	final shape: RefShape;

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

	/** `RefShape.nullCoalesceKind` — the hoist arm's whole subject; unset makes that arm a no-op. */
	final nullCoalKind: Null<String>;

	/** The seams the hoist arm's compile-time-constant proof reads — see `constantDefaultText`. */
	final fieldAccessKind: Null<String>;

	final fieldDeclKinds: Array<String>;
	final enumAbstractDeclKind: Null<String>;
	final constLiteralKinds: Array<String>;
	final numericKinds: Array<String>;
	final literalTypeNames: Map<String, String>;
	final negationKind: Null<String>;
	final stringFold: Null<StringFoldSupport>;
};

/**
 * One parameter declaration and its context: the node itself, the function that declares it
 * (`RefShape.functionKinds`), and that function's own parent — the node the supertype-clause
 * and modifier gates read. Both `fn` fields are null for a parameter no enclosing function
 * could be found for, which every gated arm treats as a refusal.
 */
private typedef ParamSite = {
	final node: QueryNode;
	final fn: Null<QueryNode>;
	final fnParent: Null<QueryNode>;
};

/**
 * One `name ?? <fallback>` the hoist arm collected: the whole coalescing node's span (what the
 * fix replaces with a bare `name`), the left operand's span (what the completeness scan
 * excludes), and the fallback node (what the constant proof reads).
 */
private typedef CoalescingRead = {
	final coal: Span;
	final ident: Span;
	final fallback: QueryNode;
};

/**
 * An accepted hoist: the type to DECLARE (one `Null<>` layer off), the annotation as WRITTEN
 * (which the message quotes back, so a reader recognises the parameter), the default's verbatim
 * text, and the reads to collapse.
 */
private typedef HoistPlan = {
	final typeText: String;
	final rawType: String;
	final constText: String;
	final sites: Array<CoalescingRead>;
};

/**
 * The two per-FILE services the constant proof asks for: the file's own parsed `root`, against
 * which a BARE reference's binding is resolved, and the lazy cross-file `SymbolIndex` a named
 * constant's modifiers are read from. A pair rather than two parameters because they must
 * describe the SAME file — a root from one file with an index over another answers
 * "unprovable" for every bare constant, silently narrowing the arm to literals.
 */
private typedef HoistScope = {
	final root: QueryNode;
	final resolveIndex: () -> Null<SymbolIndex>;

	/**
	 * The file's comment spans, for the completeness scan's qualifier test — a line comment
	 * ending in a full stop puts a `.` directly before the next line's first token, and reading
	 * that as qualification would skip a real reference. Lazy for the same reason the index is:
	 * a run whose files hold no candidate parameter lexes nothing.
	 */
	final commentRegions: () -> Array<Span>;

	/**
	 * The file's full inert mask (comments, regex, non-interpolating strings), for the
	 * completeness scan's MATCH test — a parameter name spelled only in a doc comment or an
	 * unrelated string literal must not read as a real coalescing read. A separate question from
	 * `commentRegions` above: that one narrows the qualifier test, this one narrows the match
	 * itself, and conflating them would change the qualifier test's answer too.
	 */
	final matchMask: () -> Array<Span>;
};

/**
 * Which arm owns one parameter — the classification `run` and `fix` MUST agree on, since a
 * finding reported for one arm and rewritten by another produces a silently wrong signature.
 * `classify` answers it once and both read the answer; the three are disjoint by construction
 * (a `null` default, any other default, no default at all), so this is a dispatch and not a
 * priority.
 */
private enum ParamArm {

	/** `name:Null<T> = null` / `name:T = null` / `?name:T = null` -> `?name:T`. */
	NullDefault(shape: { inner: String, raw: String, opt: Bool });

	/** `?name:T = <non-null default>` -> `name:T = <non-null default>`; gated by G1-G5. */
	RedundantSigil(rawType: String);

	/** `?name:T` whose every read is `name ?? CONST` -> `name:T = CONST`; gated by G1-G5 and `hoistPlan`. */
	Hoist(plan: HoistPlan);

}
