package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberBranchScan;
import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;

/**
 * Flags a `static final` constant of a basic scalar type whose initializer is a compile-time
 * constant, and rewrites it to `static inline final` by inserting the `inline` keyword.
 * `Severity.Info` (a codegen / modernization cleanup), with an autofix. An inline scalar constant
 * folds to an immediate at every use site instead of a static-field load. PUBLIC constants are
 * included, gated by the reflection-name and macro-consumption checks below.
 *
 * ## The initializer: a literal, or a REFERENCE to an inline constant
 *
 * A bare `inlineConstantLiteralKinds` literal (or `negationKind` over a numeric one) is the
 * primary shape. The second is a REFERENCE that provably resolves to an already-`static inline`
 * final / var whose OWN initializer is such a literal — the `PLAYER_MALE_GENDER` shape:
 *
 * ```
 * public static inline final PLAYER_MALE_GENDER:Int = 1;
 * private static final GENDER:Int = PLAYER_MALE_GENDER;   // -> private static inline final
 * ```
 *
 * Measured live with `haxe --interp`: `static inline final B:Int = A;` compiles and folds when `A`
 * is `static inline` (final OR var — both are valid targets), and it does so REGARDLESS of
 * declaration order, so a forward reference is legal and nothing gates on source position. The
 * `inline` on the TARGET is the single load-bearing gate: against a plain non-inline
 * `static final A`, the very same line fails to compile with
 * "Inline variable initialization must be a constant value".
 *
 * Only a BARE name resolves, against the owning container's DIRECT children.
 * `isInlinableInitializer` owns the proof, documents every gate, and records why a QUALIFIED
 * `Other.A` is deliberately NOT attempted — twice measured at ZERO yield, over a receiver the
 * check cannot even prove to be a TYPE.
 *
 * The String exclusion applies TRANSITIVELY for free: `inlineConstantLiteralKinds` omits the
 * string kinds, so a reference to a String constant fails `isInlinableLiteral` on the TARGET; no
 * second check is needed. Likewise the reflection-name and macro-consumption gates cover the new
 * candidates unchanged, because `consider` runs both BEFORE testing the initializer — extending
 * only the initializer predicate routes the reference arm through them automatically.
 *
 * Constant ARITHMETIC over references (`static inline final C:Int = A * 2;`, which also compiles)
 * is deliberately OUT OF SCOPE — a known conservative miss, deferred rather than half-proven.
 *
 * A CHAIN reaches its fixpoint over successive `--fix` passes rather than within one: given
 * `static final A = 1; static final B = A;`, pass one inlines only `A` (the proof reads the SOURCE,
 * where `A` is not yet inline), and pass two then inlines `B`. That is deliberate — treating a
 * fellow candidate as already-inline would stake `B`'s proof on a gate that may still veto `A`.
 *
 * ## Also: `static inline var` -> `static inline final`
 *
 * A `static inline var` of a constant literal (scalar OR String) is ALSO flagged and rewritten to
 * `final`. Behaviour-neutral: a write to a `static inline var` is already a compile error ("This
 * expression cannot be accessed for writing"), so `final` merely makes the existing immutability
 * explicit. `var` -> `final` changes no ABI and no reflection surface (`Reflect.field` /
 * `Type.getClassFields` are identical for inline var vs inline final, verified). String is accepted
 * here (excluded for the add-inline case) for the same reason: no per-use-site codegen change, only
 * the keyword. The reflection-name and `#if`-divergent gates below still apply, except a self-named
 * event constant (`X = 'X'`) does not self-trip the reflection gate (its own value is subtracted
 * from the reflection-key count). This arm's own initializer test (`isConstLiteral`) stays
 * LITERAL-only — it is not extended to references.
 *
 * ## The type annotation is PRESERVED (not dropped)
 *
 * The fix inserts only `inline`; it does NOT strip the `:Type` annotation. Dropping it is unsound:
 * `static final X:Float = 5` would re-infer as `Int` (the literal's type), silently changing `X`'s
 * type and every use — the classic Float-constant-becomes-Int hazard. Keeping the annotation is
 * also consistent with the project's explicit-type preference. So `static final X:Int = 5` becomes
 * `static inline final X:Int = 5`.
 *
 * ## Why String is excluded (hxcpp evidence)
 *
 * `inlineConstantLiteralKinds` (the grammar's policy seam) lists only `IntLit` / `HexLit` /
 * `FloatLit` / `BoolLit` and OMITS the string kinds. Measured against hxcpp 4.3 codegen: an inlined
 * String re-emits its full literal (`HX_("...")`) at EVERY use site, duplicating the string's bytes
 * once per use across translation units, whereas a non-inline `static final` keeps exactly one
 * shared copy — with no compensating runtime benefit (both are static-backed, allocation-free). A
 * scalar instead constant-folds to a tiny immediate with zero duplication. So String constants stay
 * `static final`; only scalars are inlined.
 *
 * ## Reflection visibility: the name-as-string gate is MANDATORY (hxcpp evidence)
 *
 * Adding `inline` REMOVES the constant's value from run-time reflection — unlike `var` -> `final`,
 * which is reflection-neutral. Measured on hxcpp 4.3.7 (default `-dce std`): a
 * `public static final X = 5` is reflectively readable, `Reflect.field(Cls, "X")` returns `5`;
 * adding `inline` folds the value into every use site and drops the runtime field storage, so
 * `Reflect.field(Cls, "X")` then returns `null` (the NAME may still stub in `Type.getClassFields` /
 * `Reflect.hasField`, but the VALUE is gone). Any `Reflect.field(o, "X")` read therefore silently
 * degrades to `null` after inlining. This is why the name-as-string gate (gate 4) is MANDATORY, not
 * advisory: a constant whose name appears as any string literal in scope — the shape a reflective
 * read takes — is never inlined.
 *
 * ## Macro-consumption gate (public arm)
 *
 * A public constant may be consumed by another module's macro. Instead of the old blanket public
 * exclusion, the check skips a PUBLIC constant only when its owning MODULE (class name) is
 * referenced inside macro-context code anywhere in scope. The detector
 * (`collectMacroConsumedModules` / `isMacroContext`) is deliberately cheap and conservative: a file
 * is macro-context when its source imports `haxe.macro`, contains a `#if macro` / `#elseif macro`
 * region, or declares a `macro function`; every capitalised (type-name) identifier token of such a
 * file — code AND trivia, so a name mentioned only inside a `#if macro` block still counts — is
 * collected, and a public constant whose class name is in that set is left alone. Textual by design
 * (it reaches `#if macro` interiors that project as opaque trivia) and conservative (it only ever
 * KEEPS a constant non-inline). A private constant is off every external module surface, so the gate
 * is public-only.
 *
 * ## Soundness gates (must-skip)
 *
 * 1. VISIBILITY. A non-public constant is always a candidate. A PUBLIC constant is a candidate too
 *    (the blanket public exclusion is lifted), additionally gated by the reflection-name gate
 *    (mandatory — see above) and the macro-consumption gate, which together keep an inlined public
 *    field off any external reflection / macro surface.
 * 2. STATIC final only. `inline` requires a static field; an instance `final` and a `var` are
 *    skipped, as is an already-`inline` field (nothing to do).
 * 3. COMPILE-TIME CONSTANT initializer only — a bare `inlineConstantLiteralKinds` literal,
 *    `negationKind` wrapping a numeric one (`-5`), or a reference PROVEN to resolve to a
 *    `static inline` constant of such a literal (see above). Any other initializer (arithmetic —
 *    including arithmetic over a proven reference, a call, an array / object literal, `null`, an
 *    `#if`-divergent value, a String, an unresolvable or ambiguous reference) is not provably a
 *    basic constant and is left alone.
 * 4. NO reflection. A constant whose NAME appears as a string literal ANYWHERE in the lint scope is
 *    skipped — it may be read by `Reflect.field(o, "NAME")`, which an inline field (whose value is
 *    erased) would break. Conservative: the name matches any string content, which only ever KEEPS a
 *    constant non-inline.
 * 5. NO `@:keep` / `@:rtti`. A `@:keep`- or `@:rtti`-annotated field, or any member of a class
 *    carrying class-level `@:keep` / `@:rtti`, is explicitly retained for reflection / external
 *    tooling; inlining would erase its reflective value.
 * 6. ENUM ABSTRACT values are structurally excluded — they live under `EnumAbstractDecl`, not a
 *    `visibilityContainerKinds` host, and are handled by `prefer-enum-abstract`. A `#if`-guarded
 *    member IS scanned: the container walk descends into the region branch by branch, so a
 *    guarded `static final` is judged exactly like its plain sibling (adding `inline` to a scalar
 *    constant is behaviour-preserving in whichever build compiles the branch). A member whose
 *    modifier run only SOME builds see — a `static` carried out of a region — is refused instead.
 *
 * ## Grammar-agnostic
 *
 * Reads `visibilityContainerKinds` / `memberDeclKinds` / `fieldDeclKinds` / `mutableFieldDeclKinds`
 * (the final-field host = field minus mutable), `visibilityModifierKinds` +
 * `defaultVisibilityModifierText`, `staticModifierKind`, `inlineModifierKind`, `identKind`,
 * `inlineConstantLiteralKinds`, `numericLiteralKinds` + `negationKind`, plus `metaShape().metaKinds`
 * and `stringFoldSupport()`. Any required seam unset makes the check a no-op.
 */
@:nullSafety(Strict)
final class InlineConstant implements Check {

	/** The `final` keyword the member host span starts at — `inline ` is inserted immediately before it. */
	private static inline final FINAL_KEYWORD: String = 'final';

	/** The `var` keyword a `static inline var` host span starts at - swapped to `final`. */
	private static inline final VAR_KEYWORD: String = 'var';

	/** The meta that pins a field in place (reflection / external tooling); such a field is never inlined. */
	private static inline final KEEP_META: String = '@:keep';

	/** The meta that enables runtime type info (`haxe.rtti.Rtti`) for a type; a field it exposes is never inlined. */
	private static inline final RTTI_META: String = '@:rtti';

	public function new() {}

	public function id(): String {
		return 'inline-constant';
	}

	public function description(): String {
		return 'a static final scalar that can be inline, or a static inline var that can be final';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final resolved: Null<Seams> = resolveSeams(plugin);
		if (resolved == null) return [];
		final seams: Seams = resolved;
		final reflected: Array<String> = collectReflectedNames(files, plugin, seams.stringFold);
		final macroConsumed: Array<String> = collectMacroConsumedModules(files);
		final proof: InitProof = (container, init) -> isInlinableInitializer(container, init, seams);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null)
				walk(
					violations, entry.file, entry.source, tree, seams, reflected, macroConsumed, false, proof,
					MemberBranchScan.seamsOf(plugin.refShape(), entry.source)
				);
		}
		return violations;
	}

	/**
	 * Insert `inline ` before the `final` keyword of each flagged member. The candidate is
	 * a static, non-inline final field by construction, so the insertion yields the
	 * canonical `static inline final`; the edit fires only when the bytes at the span start
	 * are literally `final` (so an unexpected span simply fails the equality).
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			// Two flag shapes share this rule. The add-inline case flags a `static final`
			// host (span starts at `final`) - insert `inline `. The var->final case flags a
			// `static inline var` host (span starts at `var`) - swap the keyword. The byte
			// check gates each, so an unexpected span simply produces no edit.
			if (source.substring(span.from, span.from + FINAL_KEYWORD.length) == FINAL_KEYWORD)
				edits.push({ span: new Span(span.from, span.from), text: 'inline ' });
			else if (source.substring(span.from, span.from + VAR_KEYWORD.length) == VAR_KEYWORD)
				edits.push({ span: new Span(span.from, span.from + VAR_KEYWORD.length), text: FINAL_KEYWORD });
		}
		return edits;
	}

	/**
	 * Walk `node`; scan every visibility-bearing container's direct children for inlinable static
	 * final constants. Class-level `@:keep` / `@:rtti` meta projects as `Meta` siblings PRECEDING the
	 * container (not as its children), so a running pin flag over each node's direct children — set by
	 * such a meta, cleared at the next non-meta node — marks the container it attaches to; a pinned
	 * container's members are retained for reflection / tooling and never inlined. A `final class`
	 * nests its body in a `FinalDecl(ClassForm …)` wrapper, so the pin is carried into the recursion
	 * (`inheritedPin`) to reach the container one level down.
	 */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, seams: Seams, reflected: Array<String>,
		macroConsumed: Array<String>, inheritedPin: Bool, proof: InitProof, branch: MemberBranchSeams
	): Void {
		var classPinned: Bool = inheritedPin;
		for (child in node.children) {
			if (seams.metaKinds.contains(child.kind))
				classPinned = classPinned || isPinMeta(child.name);
			else {
				if (seams.containers.contains(child.kind))
					scanContainer(out, file, source, child, seams, reflected, macroConsumed, classPinned, proof, branch);
				walk(out, file, source, child, seams, reflected, macroConsumed, classPinned, proof, branch);
				classPinned = false;
			}
		}
	}

	/**
	 * Scan `container`'s DIRECT children in source order. Modifier / meta siblings precede the member
	 * they attach to, so a running flag set (`static`, `inline`, exported visibility, `@:keep` /
	 * `@:rtti`) — reset at each member — describes the member that just appeared. Public members are
	 * candidates too (the reflection and macro-consumption gates in `consider` keep them sound);
	 * `classPinned` (a class-level `@:keep` / `@:rtti`) blocks the add-inline arm for every member.
	 * `MemberBranchScan.eachMember` supplies the members, so a `#if`-guarded one is visited with the
	 * modifier run of its OWN branch; a run the branches disagree on cannot answer `static` and the
	 * member is skipped.
	 */
	private static function scanContainer(
		out: Array<Violation>, file: String, source: String, container: QueryNode, seams: Seams, reflected: Array<String>,
		macroConsumed: Array<String>, classPinned: Bool, proof: InitProof, branch: MemberBranchSeams
	): Void {
		MemberBranchScan.eachMember(branch, container, child -> seams.members.contains(child.kind), (member, run, certain) -> {
			// A modifier run only SOME builds see cannot answer `static` / `inline`, both of which
			// this rule reads as enabling — see `MemberBranchScan.joinRuns`.
			if (!certain) return;
			final kind: String = member.kind;
			var sawStatic: Bool = false;
			var sawInline: Bool = false;
			var exported: Bool = false;
			var sawKeep: Bool = false;
			for (mod in run) {
				if (mod.kind == seams.staticKind)
					sawStatic = true;
				else if (seams.inlineKind != null && mod.kind == seams.inlineKind)
					sawInline = true;
				else if (seams.visibility.contains(mod.kind))
					exported = exported || isExportedVisibility(source, mod, seams.defaultVis);
				else if (seams.metaKinds.contains(mod.kind))
					sawKeep = sawKeep || isPinMeta(mod.name);
			}
			if (seams.finalFieldKinds.contains(kind) && sawStatic && !sawInline && !sawKeep && !classPinned)
				consider(out, file, member, seams, reflected, macroConsumed, container, exported, proof);
			else if (seams.mutableFieldKinds.contains(kind) && sawStatic && sawInline && !sawKeep)
				considerInlineVar(out, file, source, member, seams, reflected);
		});
	}

	/** Whether `child` (a visibility modifier) is a non-default (exported) keyword — `public` rather than the private default. */
	private static function isExportedVisibility(source: String, child: QueryNode, defaultVis: String): Bool {
		final span: Null<Span> = child.span;
		return span != null && source.substring(span.from, span.to).trim() != defaultVis;
	}

	/**
	 * Flag `field` when its initializer is an inlinable compile-time literal, its name is not read by
	 * reflection, and (when PUBLIC) its owning module is not macro-consumed. The visibility / static /
	 * inline / keep gates are already applied by the caller; the reflection gate runs for every
	 * visibility (mandatory for public — see the reflection-visibility note on the class), and the
	 * macro-consumption gate applies only to a public constant (a private one is off every external
	 * module surface).
	 */
	private static function consider(
		out: Array<Violation>, file: String, field: QueryNode, seams: Seams, reflected: Array<String>, macroConsumed: Array<String>,
		container: QueryNode, exported: Bool, proof: InitProof
	): Void {
		final name: Null<String> = field.name;
		final span: Null<Span> = field.span;
		if (name == null || span == null) return;
		if (reflected.contains(name)) return;
		final containerName: Null<String> = container.name;
		if (exported && containerName != null && macroConsumed.contains(containerName)) return;
		final init: Null<QueryNode> = initializerOf(field);
		if (init == null || !proof(container, init)) return;
		final detail: String = isInlinableLiteral(init, seams) ? 'is a scalar literal' : 'folds to an inline constant';
		flag(out, file, span, 'static constant \'$name\' $detail; use inline');
	}

	/** The member host's initializer — its last child (the value expression; the type annotation is not a child). */
	private static function initializerOf(field: QueryNode): Null<QueryNode> {
		final count: Int = field.children.length;
		return count >= 1 ? field.children[count - 1] : null;
	}

	/** Whether `init` is a basic scalar literal in `inlineConstantLiteralKinds`, or a negation wrapping a numeric one (`-5`). */
	private static function isInlinableLiteral(init: QueryNode, seams: Seams): Bool {
		if (seams.literalKinds.contains(init.kind)) return true;
		if (seams.negationKind == null || init.kind != seams.negationKind || init.children.length != 1) return false;
		return seams.numericKinds.contains(init.children[0].kind);
	}

	/**
	 * Whether `init` proves the constant inlinable — a bare scalar literal, OR a REFERENCE that
	 * resolves to an already-`static inline` constant whose own initializer is such a literal.
	 *
	 * The reference arm exists because Haxe folds one inline constant into another:
	 * `static inline final B:Int = A;` compiles and folds when `A` is itself `static inline`
	 * (verified live with `haxe --interp`, in BOTH declaration orders — a forward reference is
	 * legal, so nothing here gates on source order). The `inline` on the TARGET is the load-bearing
	 * gate: with a plain non-inline `static final A`, the very same line fails to compile with
	 * "Inline variable initialization must be a constant value".
	 *
	 * ONE shape resolves: a bare `identKind` name, looked up among the OWNING container's direct
	 * children (`declaresInlineConstant`). Everything else — a qualified `Other.A`, a deeper
	 * `pkg.Other.A` chain, arithmetic — is refused.
	 *
	 * ## Why the QUALIFIED arm stays out — measured twice, not merely unimplemented
	 *
	 * A cross-class `Other.A` was implemented against `SymbolIndex.resolveTypeRefsFrom` and withdrawn,
	 * then re-costed before any second attempt. The premise is real — `static inline final B:Int =
	 * Other.A;` compiles and folds when the target is itself `static inline` — but the arm has no INPUT.
	 * Across 2831 real files (TM 798, anyparse 636, Pony 677, OpenFL 720) exactly TEN `static final`
	 * fields carry a qualified initializer; NINE are already `inline`, and the tenth is
	 * `SOME_STRING.length`, which `inline` refuses in EVERY configuration ("Inline variable
	 * initialization must be a constant value", verified live against both an inline and a non-inline
	 * target). Yield zero, ceiling zero — the idiom is written WITH the keyword
	 * (`static inline final C:UInt = Colors.MEDIUM_GREY;`).
	 *
	 * That is decisive, because the proof is not close to reachable either. Every hole found emitted a
	 * `--fix` edit that does not compile in some configuration:
	 *
	 *  - the receiver need not be a TYPE at all. A static field of the ENCLOSING class spelled like an
	 *    in-scope type wins in expression position, so `T.A` reads the VALUE's field while the arm proves
	 *    the type's constant, and the emitted `inline` then fails to compile (verified live; an INHERITED
	 *    static does not shadow — Haxe does not inherit statics). The single non-inline site in the whole
	 *    corpus is exactly this shape, so the arm's real input is dominated by the class it cannot see;
	 *  - an ALIAS import (`import pkg.Other as Alias;`) never enters simple-name scope — the grammar's
	 *    `ImportAliasDecl` carries only the alias — so a same-simple-named local type is proven in the
	 *    real target's place. `ModuleScan.aliasTargetsOf` recovers the target by re-reading the
	 *    import's own source span for the file it is printing: a per-file text scan, not an index
	 *    capability, so the arm can only REFUSE an alias-bound receiver, never resolve through it;
	 *  - an import of a type OUTSIDE the resolution scope (a haxelib module, a file the lint scope
	 *    excludes) is absent from the candidate set, and unanimity across candidates cannot vet a
	 *    declaration that was never collected. An `import.hx` is the same hole with no per-file evidence
	 *    at all — anyparse ignores `import.hx` repo-wide;
	 *  - a type declared twice through `#if` is deduped BY DESIGN — `SymbolIndexBuilder` keeps the first
	 *    declaration of a name so `declaringFiles` does not report a phantom ambiguity. This one is now
	 *    cheap to close: the builder's `GuardedNode` already carries a per-decl `guarded` flag (as
	 *    `ImportInfo` publishes its own), so plumbing it onto `TypeDeclInfo` and refusing a guarded
	 *    candidate would also cover the `typedef` / `interface` / `enum` half that counting container
	 *    NODES could not.
	 *
	 * The first attempt found its leaks one at a time and patched each with one more exclusion — the shape
	 * that says a filter is enumerating harm instead of proving benefit; the receiver hole above came
	 * later still, from re-reading the corpus rather than the model. Re-adding is therefore gated on YIELD
	 * FIRST — a corpus that actually holds non-inline qualified constants — and only then on the index
	 * work, which buys nothing until such a corpus exists.
	 *
	 * The String exclusion applies transitively for free: `inlineConstantLiteralKinds` omits the string
	 * kinds, so a reference to a String constant fails `isInlinableLiteral` ON THE TARGET. Constant
	 * ARITHMETIC over references (`A * 2`, which also compiles) is likewise out of scope — a known
	 * conservative miss, deferred rather than half-proven.
	 */
	private static function isInlinableInitializer(container: QueryNode, init: QueryNode, seams: Seams): Bool {
		if (isInlinableLiteral(init, seams)) return true;
		final name: Null<String> = init.name;
		return name != null && init.kind == seams.identKind && declaresInlineConstant(container, name, seams);
	}

	/**
	 * Whether `container` DIRECTLY declares a `static inline` final / var named `name` whose own
	 * initializer is an accepted scalar literal. Same running-modifier-flag walk `scanContainer`
	 * uses: `static` / `inline` project as childless siblings PRECEDING the member they attach to,
	 * so the flags standing when a member appears describe that member, and each member resets them.
	 *
	 * Both `static inline final` and `static inline var` are valid fold targets (verified live).
	 * Direct children only, so a `#if`-guarded target is nested in a `Conditional` and stays
	 * invisible — exactly the conservative answer wanted, since the reference may be compiled in a
	 * configuration where that member does not exist.
	 *
	 * The reset discipline is load-bearing HERE in a way it is not in `scanContainer`, and the two
	 * copies must not be kept in step by accident: a stale `sawInline` there merely SKIPS a
	 * candidate, while a stale one here PROVES a non-inline target and emits code that does not
	 * compile. Every `memberDeclKinds` child resets, so a preceding `static inline function` cannot
	 * leak its modifiers onto the next member.
	 *
	 * `isField` is a shape guard rather than a provable gate: the only `memberDeclKinds` entries it
	 * excludes are the FUNCTION forms, whose last child is a body node and so never satisfies the
	 * terminal literal test either. It states the intent (a fold target is a FIELD) and costs
	 * nothing, but no fixture can isolate it.
	 */
	private static function declaresInlineConstant(container: QueryNode, name: String, seams: Seams): Bool {
		var sawStatic: Bool = false;
		var sawInline: Bool = false;
		for (child in container.children) {
			final kind: String = child.kind;
			if (kind == seams.staticKind)
				sawStatic = true;
			else if (seams.inlineKind != null && kind == seams.inlineKind)
				sawInline = true;
			else if (seams.members.contains(kind)) {
				if (child.name == name) {
					final isField: Bool = seams.finalFieldKinds.contains(kind) || seams.mutableFieldKinds.contains(kind);
					final init: Null<QueryNode> = initializerOf(child);
					return isField && sawStatic && sawInline && init != null && isInlinableLiteral(init, seams);
				}
				sawStatic = false;
				sawInline = false;
			}
		}
		return false;
	}

	/** Every plain string literal's raw content across `files` — the names a constant might be reflected by. */
	private static function collectReflectedNames(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, stringFold: Null<StringFoldSupport>
	): Array<String> {
		final out: Array<String> = [];
		if (stringFold == null) return out;
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) collectStrings(tree, entry.source, stringFold, out);
		}
		return out;
	}

	/** Append every plain string literal's content in `node`'s subtree to `out` (duplicates kept — only membership is read). */
	private static function collectStrings(node: QueryNode, source: String, stringFold: StringFoldSupport, out: Array<String>): Void {
		final literal: Null<StringLiteral> = stringFold.literalOf(node, source);
		if (literal != null) out.push(literal.content);
		for (child in node.children) collectStrings(child, source, stringFold, out);
	}

	/** Resolve every seam the check reads, or null when a required one is unset (the check no-ops). */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final containers: Array<String> = shape.visibilityContainerKinds ?? [];
		final members: Array<String> = shape.memberDeclKinds ?? [];
		final fieldKinds: Array<String> = shape.fieldDeclKinds ?? [];
		final mutable: Array<String> = shape.mutableFieldDeclKinds ?? [];
		final visibility: Array<String> = shape.visibilityModifierKinds ?? [];
		final defaultVis: Null<String> = shape.defaultVisibilityModifierText;
		final staticKind: Null<String> = shape.staticModifierKind;
		final literalKinds: Array<String> = shape.inlineConstantLiteralKinds ?? [];
		final stringKinds: Array<String> = shape.stringLiteralKinds ?? [];
		if (
			containers.length == 0 || members.length == 0 || fieldKinds.length == 0 || visibility.length == 0 || defaultVis == null
			|| staticKind == null || literalKinds.length == 0
		)
			return null;
		final finalFieldKinds: Array<String> = [for (k in fieldKinds) if (!mutable.contains(k)) k];
		return finalFieldKinds.length == 0 ? null : {
			containers: containers,
			members: members,
			finalFieldKinds: finalFieldKinds,
			mutableFieldKinds: mutable,
			visibility: visibility,
			defaultVis: defaultVis,
			staticKind: staticKind,
			inlineKind: shape.inlineModifierKind,
			identKind: shape.identKind,
			metaKinds: plugin.metaShape().metaKinds,
			literalKinds: literalKinds,
			stringLiteralKinds: stringKinds,
			numericKinds: shape.numericLiteralKinds ?? [],
			negationKind: shape.negationKind,
			stringFold: plugin.stringFoldSupport()
		};
	}

	/**
	 * Flag a `static inline var` whose initializer is a compile-time constant literal for
	 * `var` -> `final`. Behaviour-neutral: a write to a `static inline var` is already a
	 * compile error ("This expression cannot be accessed for writing"), so finalizing it
	 * changes nothing at runtime, and PUBLIC is included (an inline field is erased
	 * identically whether `var` or `final`, so reflection is unchanged). The `static` /
	 * `inline` / `@:keep` gates are applied by the caller.
	 */
	private static function considerInlineVar(
		out: Array<Violation>, file: String, source: String, field: QueryNode, seams: Seams, reflected: Array<String>
	): Void {
		final name: Null<String> = field.name;
		final span: Null<Span> = field.span;
		if (name == null || span == null) return;
		final init: Null<QueryNode> = initializerOf(field);
		if (init == null || !isConstLiteral(init, seams)) return;
		if (reflectedElsewhere(name, init, source, seams, reflected)) return;
		flag(out, file, span, 'static inline var \'$name\' is a constant; use final');
	}

	/**
	 * Whether `init` is a compile-time constant literal for the `var` -> `final` case: a
	 * scalar (`isInlinableLiteral`) OR a String literal. Unlike the add-inline case, String
	 * is accepted here - the field is already inline, so there is no per-use-site codegen
	 * change, only the keyword. Rejects arithmetic, calls, identifiers and an
	 * `#if`-divergent value (a `ConditionalExpr`, not a literal).
	 */
	private static function isConstLiteral(init: QueryNode, seams: Seams): Bool {
		return isInlinableLiteral(init, seams) || seams.stringLiteralKinds.contains(init.kind);
	}

	/**
	 * Whether `name` is read as a reflection key SOMEWHERE OTHER than this field's own
	 * value. The whole-scope reflection gate is kept, but a self-named event constant
	 * (`X = 'X'`, the common event-name shape) must not self-trip it: `var` -> `final` is
	 * reflection-neutral, so only a name stringified in OTHER code (`Reflect.field(o, "X")`)
	 * keeps the field a `var`. The field's own value string is subtracted from the count.
	 */
	private static function reflectedElsewhere(
		name: String, init: QueryNode, source: String, seams: Seams, reflected: Array<String>
	): Bool {
		var count: Int = 0;
		for (s in reflected) if (s == name) count++;
		if (count == 0) return false;
		final self: Int = ownValueIsName(name, init, source, seams.stringFold) ? 1 : 0;
		return count > self;
	}

	/** Whether `init` is a String literal whose content equals `name` (a self-named event constant). */
	private static function ownValueIsName(name: String, init: QueryNode, source: String, stringFold: Null<StringFoldSupport>): Bool {
		if (stringFold == null) return false;
		final lit: Null<StringLiteral> = stringFold.literalOf(init, source);
		return lit != null && lit.content == name;
	}

	/** Push an `inline-constant` Info violation for a field at `span` with `message`. */
	private static function flag(out: Array<Violation>, file: String, span: Span, message: String): Void {
		out.push({
			file: file,
			span: span,
			rule: 'inline-constant',
			severity: Severity.Info,
			message: message
		});
	}

	/**
	 * Whether `meta` is an annotation that pins a member in place for reflection / external tooling
	 * (`@:keep` or `@:rtti`) — a field it covers is never inlined. Applies to a field-level meta and,
	 * via `walk`, to a class-level one covering every member.
	 */
	private static inline function isPinMeta(meta: Null<String>): Bool {
		return meta == KEEP_META || meta == RTTI_META;
	}

	/**
	 * The module (class) names referenced inside macro-context code across `files` — a public constant
	 * of one is macro-consumed and left non-inline. Cheap and conservative: a file is macro-context
	 * when its source imports `haxe.macro`, contains a `#if macro` / `#elseif macro` region, or
	 * declares a `macro function`; every capitalised (type-name) identifier token of such a file — code
	 * AND trivia, so a name mentioned only inside a `#if macro` block still counts — is collected.
	 * Textual by design: it reaches `#if macro` interiors that project as opaque trivia, and it only
	 * ever KEEPS a constant non-inline.
	 */
	private static function collectMacroConsumedModules(files: Array<{ file: String, source: String }>): Array<String> {
		final out: Array<String> = [];
		for (entry in files) if (isMacroContext(entry.source)) collectTypeTokens(entry.source, out);
		return out;
	}

	/** Whether `source` is macro-context code — it imports `haxe.macro`, has a positive `#if` / `#elseif macro` region, or declares a `macro function`. */
	private static function isMacroContext(source: String): Bool {
		final signals: Array<String> = [
			'haxe.macro',
			'#if macro',
			'#if (macro',
			'#elseif macro',
			'#elseif (macro',
			'macro function'
		];
		for (signal in signals) if (source.indexOf(signal) >= 0) return true;
		return false;
	}

	/** Append every capitalised identifier token (a type / module name) in `source` to `out`, de-duplicated. */
	private static function collectTypeTokens(source: String, out: Array<String>): Void {
		final n: Int = source.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = source.fastCodeAt(i);
			if (isIdentStart(c)) {
				final start: Int = i;
				i++;
				while (i < n && isIdentPart(source.fastCodeAt(i))) i++;
				final token: String = source.substring(start, i);
				if (isUpper(token.fastCodeAt(0)) && !out.contains(token)) out.push(token);
			} else
				i++;
		}
	}

	/** Whether `c` can start an identifier — a letter or `_`. */
	private static inline function isIdentStart(c: Int): Bool {
		return c == '_'.code || isUpper(c) || (c >= 'a'.code && c <= 'z'.code);
	}

	/** Whether `c` can continue an identifier — an identifier-start char or a digit. */
	private static inline function isIdentPart(c: Int): Bool {
		return isIdentStart(c) || (c >= '0'.code && c <= '9'.code);
	}

	/** Whether `c` is an ASCII uppercase letter — the first char of a type / module name. */
	private static inline function isUpper(c: Int): Bool {
		return c >= 'A'.code && c <= 'Z'.code;
	}

}

/** The resolved seams `InlineConstant` reads across `run` / `fix` helpers. */
private typedef Seams = {
	final containers: Array<String>;
	final members: Array<String>;
	final finalFieldKinds: Array<String>;
	final mutableFieldKinds: Array<String>;
	final visibility: Array<String>;
	final defaultVis: String;
	final staticKind: String;
	final inlineKind: Null<String>;
	final identKind: String;
	final metaKinds: Array<String>;
	final literalKinds: Array<String>;
	final stringLiteralKinds: Array<String>;
	final numericKinds: Array<String>;
	final negationKind: Null<String>;
	final stringFold: Null<StringFoldSupport>;
};

/**
 * The initializer proof `scanContainer` threads down to `consider` — "does this member's
 * initializer make it inlinable, given its owning container and file". Closed over the resolved
 * seams, the plugin and the LAZY resolution index in `run`, so a run with no qualified reference
 * never pays for an index.
 */
private typedef InitProof = (container:QueryNode, init:QueryNode) -> Bool;
