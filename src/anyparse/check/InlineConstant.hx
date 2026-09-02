package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.ConstantFieldScan.ConstantFieldSeams;
import anyparse.check.ReflectionScan.ReflectionSurface;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberBranchScan;
import anyparse.query.MemberWriteScan;
import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
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
 * string kinds, so a reference to a String constant fails `ConstantFieldScan.isScalarLiteral` on the TARGET; no
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
 * ## Native-interop gate (public arm) — and what it deliberately does NOT cover
 *
 * A type the grammar marks with `nativeInteropDeclMetaName` (Haxe `@:nativeGen`) is emitted as a plain
 * native type SO THAT code outside this compilation holds it — a C# script, a serializer, an editor
 * inspector. That consumer is invisible to every scan here AND to the project's own compiler oracle, so
 * a rewrite it would break fails SILENTLY, which is the one failure direction this rule set refuses.
 * `inline` is exactly such a rewrite. Measured on Haxe 4.3.7 `-cs` over a `@:nativeGen class`:
 * `public static var X:Float = 0.5` and `public static inline final X:Float = 0.5` emit a
 * BYTE-IDENTICAL class — the field and its static initialiser survive verbatim — while the caller's
 * read changes from `Cls.X` to the literal `0.5`. So the foreign side still has a field to write and
 * this side has stopped reading it. A PUBLIC constant of such a type is skipped (gate 8); a private one
 * is on no foreign surface and still inlines, and the `static inline var` -> `static inline final` arm
 * changes no emission at all, only the keyword.
 *
 * The same measurement is why the gate stops there. On the same `@:nativeGen` class,
 * `public var x` -> `public final x` and `public var x` -> `public var x(default, null)` emit
 * byte-identical C# as well — no `readonly`, no property, the same plain public field a Unity Inspector
 * serialises — so `prefer-final-public-field` / `prefer-read-only-field` need no such carve-out and were
 * deliberately left alone. The marker is the ANNOTATION, not a superclass and not a target: a
 * `@:nativeGen` type need not extend anything (Pony declares `@:nativeGen class Tooltip` with no
 * superclass, and `class PercentSize extends MonoBehaviour` with no annotation), and one source tree is
 * compiled for several targets at once, so "is this the cs build" is not a question a check can ask.
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
 * 6. NO macro-built OWNER. A `@:build` / `@:autoBuild` / `@:genericBuild` type's fields are not the
 *    fields the declaration holds, so neither arm can reason about them:
 *    `SymbolIndex.transitivelyCarriesBuildMacro` declines the whole container. Measured on Haxe
 *    4.3.7 — a builder that rewrites the flagged field's initializer makes the added `inline`
 *    "Inline variable initialization must be a constant value", for a `@:build` on the class and
 *    for an `@:autoBuild` reached through `implements` alike, and in the second shape the class
 *    carries no metadata of its own. This rule consulted no build-macro predicate at all until it
 *    was measured, while the four field rules, `member-order` and `prefer-inline` all took one.
 * 7. ENUM ABSTRACT values are structurally excluded — they live under `EnumAbstractDecl`, not a
 *    `visibilityContainerKinds` host, and are handled by `prefer-enum-abstract`. A `#if`-guarded
 *    member IS scanned: the container walk descends into the region branch by branch, so a
 *    guarded `static final` is judged exactly like its plain sibling (adding `inline` to a scalar
 *    constant is behaviour-preserving in whichever build compiles the branch). A member whose
 *    modifier run only SOME builds see — a `static` carried out of a region — is refused instead.
 *
 * 8. NO foreign-facing OWNER for a PUBLIC constant. A `nativeInteropDeclMetaName` type
 *    (Haxe `@:nativeGen`) is held by code outside the compilation, which keeps writing the field
 *    `inline` leaves behind while every read here is baked — see the native-interop gate above.
 *
 * ## Grammar-agnostic
 *
 * Reads `visibilityContainerKinds` / `memberDeclKinds` / `fieldDeclKinds` / `mutableFieldDeclKinds`
 * (the final-field host = field minus mutable), `visibilityModifierKinds` +
 * `defaultVisibilityModifierText`, `staticModifierKind`, `inlineModifierKind`, `identKind`,
 * `inlineConstantLiteralKinds`, `numericLiteralKinds` + `negationKind`,
 * `nativeInteropDeclMetaName`, plus `metaShape().metaKinds` and `stringFoldSupport()`. Any
 * required seam unset makes the check a no-op.
 */
@:nullSafety(Strict)
final class InlineConstant implements Check {

	/** The `final` keyword the member host span starts at — `inline ` is inserted immediately before it. */
	private static inline final FINAL_KEYWORD: String = 'final';

	/** The `var` keyword a `static inline var` host span starts at - swapped to `final`. */
	private static inline final VAR_KEYWORD: String = 'var';

	public function new() {}

	public function id(): String {
		return 'inline-constant';
	}

	public function description(): String {
		return 'a static final scalar that can be inline, or a static inline var that can be final';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final resolved: Null<ConstantFieldSeams> = ConstantFieldScan.seams(plugin);
		if (resolved == null) return [];
		final seams: ConstantFieldSeams = resolved;
		final reflected: ReflectionSurface = ReflectionScan.reflectionSurface(files, plugin);
		final macroConsumed: Array<String> = collectMacroConsumedModules(files);
		final proof: InitProof = (container, init) -> isInlinableInitializer(container, init, seams);
		// Built for ONE question — `transitivelyCarriesBuildMacro` in `scanContainer`. This rule
		// asked no index before; the four field rules, `member-order` and `prefer-inline` all did,
		// and the gap was measured rather than argued (see the class doc).
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			// Core-API bail: both arms of this rule change a field's PROPERTY ACCESS — `static final`
			// -> `static inline final`, and `static inline var` -> `static inline final` — and a
			// `@:coreApi` type's fields are pinned to the access of a core type in the compiler's std
			// path. Measured on Haxe 4.3.7: `static var X` -> `static inline var X` is already
			// "Field X has different property access than core type".
			if (tree != null && !MemberWriteScan.coreApiPinsMemberShape(entry.source))
				walk(
					violations, entry.file, entry.source, tree, seams, reflected, macroConsumed, false, false, proof,
					MemberBranchScan.seamsOf(plugin.refShape(), entry.source, plugin.lexicalRegions.bind(entry.source)), index
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
	 * Whether `init` is a compile-time-constant SCALAR initializer under `plugin`'s grammar — a bare
	 * `inlineConstantLiteralKinds` literal or a `negationKind` over a numeric one. The same proof this
	 * check applies before adding `inline`, published so `naming`'s constant-hoist arm asks THIS
	 * question rather than re-deriving it: both act on the answer by emitting an `inline` keyword, and
	 * a second opinion about what folds would be a second, worse copy of the policy. False when the
	 * grammar leaves a seam the proof needs unset (see `ConstantFieldScan.seams`). String literals are absent by
	 * construction — `inlineConstantLiteralKinds` omits them (see the hxcpp note on this class).
	 */
	public static function isConstantScalarInitializer(init: QueryNode, plugin: GrammarPlugin): Bool {
		final resolved: Null<ConstantFieldSeams> = ConstantFieldScan.seams(plugin);
		return resolved != null && ConstantFieldScan.isScalarLiteral(init, resolved);
	}

	/**
	 * Whether `meta` is an annotation that pins a member in place — the grammar's RETAINED tag
	 * (nothing may delete this declaration) or its REFLECTED one (its member names are runtime data).
	 * Two questions with one answer here: inlining moves the value out of the field either way. A
	 * field it covers is never inlined; applies to a field-level meta and, via `walk`, to a
	 * class-level one covering every member. Both tags come from the grammar, so this check spells no
	 * Haxe metadata of its own.
	 */
	private static inline function isPinMeta(meta: Null<String>, seams: ConstantFieldSeams): Bool {
		return meta != null && (meta == seams.retainedMetaName || meta == seams.reflectedMetaName);
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

	/** Whether `container`'s type — or anything in its supertype / interface closure — is built by a macro. */
	private static inline function ownerIsMacroBuilt(container: QueryNode, file: String, index: SymbolIndex): Bool {
		final owner: Null<String> = container.name;
		return owner != null && index.transitivelyCarriesBuildMacro(owner, file);
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
		out: Array<Violation>, file: String, source: String, node: QueryNode, seams: ConstantFieldSeams, reflected: ReflectionSurface,
		macroConsumed: Array<String>, inheritedPin: Bool, inheritedNative: Bool, proof: InitProof, branch: MemberBranchSeams,
		index: SymbolIndex
	): Void {
		var classPinned: Bool = inheritedPin;
		var classNative: Bool = inheritedNative;
		for (child in node.children) {
			if (seams.metaKinds.contains(child.kind)) {
				classPinned = classPinned || isPinMeta(child.name, seams);
				classNative = classNative || seams.nativeInteropMetaName != null && child.name == seams.nativeInteropMetaName;
			} else {
				if (seams.containers.contains(child.kind))
					scanContainer(
						out, file, source, child, seams, reflected, macroConsumed, classPinned, classNative, proof, branch, index
					);
				walk(out, file, source, child, seams, reflected, macroConsumed, classPinned, classNative, proof, branch, index);
				classPinned = false;
				classNative = false;
			}
		}
	}

	/**
	 * The four questions a member's leading modifier run answers for this rule, read in one pass:
	 * is it `static`, is it already `inline`, is its visibility exported, and does it carry a pin
	 * meta (`@:keep` / `@:rtti`). Extracted from `scanContainer` so the arm conditions there read as
	 * conditions rather than as the tail of a scan.
	 */
	private static function modifierRunOf(run: Array<QueryNode>, source: String, seams: ConstantFieldSeams): ModifierRun {
		var isStatic: Bool = false;
		var isInline: Bool = false;
		var exported: Bool = false;
		var pinned: Bool = false;
		for (mod in run) {
			if (mod.kind == seams.staticKind)
				isStatic = true;
			else if (seams.inlineKind != null && mod.kind == seams.inlineKind)
				isInline = true;
			else if (seams.visibility.contains(mod.kind))
				exported = exported || ConstantFieldScan.isExportedVisibility(source, mod, seams.defaultVis);
			else if (seams.metaKinds.contains(mod.kind))
				pinned = pinned || isPinMeta(mod.name, seams);
		}
		return {
			isStatic: isStatic,
			isInline: isInline,
			exported: exported,
			pinned: pinned
		};
	}

	/**
	 * Scan `container`'s DIRECT children in source order. Modifier / meta siblings precede the member
	 * they attach to, so a running flag set (`static`, `inline`, exported visibility, `@:keep` /
	 * `@:rtti`) — reset at each member — describes the member that just appeared. Public members are
	 * candidates too (the reflection and macro-consumption gates in `consider` keep them sound);
	 * `classPinned` (a class-level `@:keep` / `@:rtti`) blocks the add-inline arm for every member, and
	 * `classNative` (a class-level `nativeInteropDeclMetaName`) blocks it for every EXPORTED one.
	 * `MemberBranchScan.eachMember` supplies the members, so a `#if`-guarded one is visited with the
	 * modifier run of its OWN branch; a run the branches disagree on cannot answer `static` and the
	 * member is skipped.
	 */
	private static function scanContainer(
		out: Array<Violation>, file: String, source: String, container: QueryNode, seams: ConstantFieldSeams, reflected: ReflectionSurface,
		macroConsumed: Array<String>, classPinned: Bool, classNative: Bool, proof: InitProof, branch: MemberBranchSeams, index: SymbolIndex
	): Void {
		// Build-macro bail. A macro-built type's fields are not the fields the declaration holds, and
		// BOTH arms of this rule act on the declaration alone: measured on Haxe 4.3.7, a `@:build`
		// builder that rewrites this field's initializer turns the added `inline` into "Inline
		// variable initialization must be a constant value". The grant is inherited through
		// `implements` / `extends` (`@:autoBuild`), where the class carries no metadata of its own,
		// so the FILE-scoped text scan beside the `@:coreApi` bail above would miss it — the same
		// per-owner question the four field rules, `member-order` and `prefer-inline` all ask.
		if (ownerIsMacroBuilt(container, file, index)) return;
		MemberBranchScan.eachMember(branch, container, child -> seams.members.contains(child.kind), (member, run, certain) -> {
			// A modifier run only SOME builds see cannot answer `static` / `inline`, both of which
			// this rule reads as enabling — see `MemberBranchScan.joinRuns`.
			if (!certain) return;
			final kind: String = member.kind;
			final mods: ModifierRun = modifierRunOf(run, source, seams);
			final sawStatic: Bool = mods.isStatic;
			final sawInline: Bool = mods.isInline;
			final exported: Bool = mods.exported;
			final sawKeep: Bool = mods.pinned;
			// Native-interop bail. A type the grammar marks as emitted for FOREIGN consumption
			// (`nativeInteropDeclMetaName`) exists so that code outside this compilation holds its
			// members; adding `inline` bakes the value into every read site here while LEAVING the
			// field the foreign side writes, so that write silently stops being observed. Measured
			// on Haxe 4.3.7 `-cs`, `@:nativeGen class`: `static var X = 0.5` and
			// `static inline final X = 0.5` emit a byte-identical class (the field and its static
			// initialiser survive verbatim), and the caller's read changes from `Cls.X` to `0.5`.
			// PUBLIC only — a private constant is on no foreign surface, and the `static inline
			// var` -> `static inline final` arm below changes no emission at all, only the keyword.
			final pinned: Bool = sawKeep || classPinned || classNative && exported;
			if (seams.finalFieldKinds.contains(kind) && sawStatic && !sawInline && !pinned)
				consider(out, file, member, seams, reflected, macroConsumed, container, exported, proof);
			else if (seams.mutableFieldKinds.contains(kind) && sawStatic && sawInline && !sawKeep)
				considerInlineVar(out, file, source, member, seams, reflected);
		});
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
		out: Array<Violation>, file: String, field: QueryNode, seams: ConstantFieldSeams, reflected: ReflectionSurface,
		macroConsumed: Array<String>, container: QueryNode, exported: Bool, proof: InitProof
	): Void {
		final name: Null<String> = field.name;
		final span: Null<Span> = field.span;
		if (name == null || span == null) return;
		if (reflected.whole.contains(name) || ReflectionScan.runtimeNameFragment(reflected.fragments, name)) return;
		final containerName: Null<String> = container.name;
		if (exported && containerName != null && macroConsumed.contains(containerName)) return;
		final init: Null<QueryNode> = ConstantFieldScan.initializerOf(field);
		if (init == null || !proof(container, init)) return;
		final detail: String = ConstantFieldScan.isScalarLiteral(init, seams) ? 'is a scalar literal' : 'folds to an inline constant';
		flag(out, file, span, 'static constant \'$name\' $detail; use inline');
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
	 * kinds, so a reference to a String constant fails `ConstantFieldScan.isScalarLiteral` ON THE TARGET. Constant
	 * ARITHMETIC over references (`A * 2`, which also compiles) is likewise out of scope — a known
	 * conservative miss, deferred rather than half-proven.
	 */
	private static function isInlinableInitializer(container: QueryNode, init: QueryNode, seams: ConstantFieldSeams): Bool {
		if (ConstantFieldScan.isScalarLiteral(init, seams)) return true;
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
	private static function declaresInlineConstant(container: QueryNode, name: String, seams: ConstantFieldSeams): Bool {
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
					final init: Null<QueryNode> = ConstantFieldScan.initializerOf(child);
					return isField && sawStatic && sawInline && init != null && ConstantFieldScan.isScalarLiteral(init, seams);
				}
				sawStatic = false;
				sawInline = false;
			}
		}
		return false;
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
		out: Array<Violation>, file: String, source: String, field: QueryNode, seams: ConstantFieldSeams, reflected: ReflectionSurface
	): Void {
		final name: Null<String> = field.name;
		final span: Null<Span> = field.span;
		if (name == null || span == null) return;
		final init: Null<QueryNode> = ConstantFieldScan.initializerOf(field);
		if (init == null || !isConstLiteral(init, seams)) return;
		if (reflectedElsewhere(name, init, source, seams, reflected)) return;
		flag(out, file, span, 'static inline var \'$name\' is a constant; use final');
	}

	/**
	 * Whether `init` is a compile-time constant literal for the `var` -> `final` case: a
	 * scalar (`ConstantFieldScan.isScalarLiteral`) OR a String literal. Unlike the add-inline case, String
	 * is accepted here - the field is already inline, so there is no per-use-site codegen
	 * change, only the keyword. Rejects arithmetic, calls, identifiers and an
	 * `#if`-divergent value (a `ConditionalExpr`, not a literal).
	 */
	private static function isConstLiteral(init: QueryNode, seams: ConstantFieldSeams): Bool {
		return ConstantFieldScan.isScalarLiteral(init, seams) || seams.stringLiteralKinds.contains(init.kind);
	}

	/**
	 * Whether `name` is read as a reflection key SOMEWHERE OTHER than this field's own
	 * value. The whole-scope reflection gate is kept, but a self-named event constant
	 * (`X = 'X'`, the common event-name shape) must not self-trip it: `var` -> `final` is
	 * reflection-neutral, so only a name stringified in OTHER code (`Reflect.field(o, "X")`)
	 * keeps the field a `var`. The field's own value string is subtracted from the count.
	 *
	 * An interpolation FRAGMENT is never the field's OWN value — a self-name test can only read a
	 * plain literal — so it needs no subtraction and answers on its own.
	 */
	private static function reflectedElsewhere(
		name: String, init: QueryNode, source: String, seams: ConstantFieldSeams, reflected: ReflectionSurface
	): Bool {
		if (ReflectionScan.runtimeNameFragment(reflected.fragments, name)) return true;
		var count: Int = 0;
		for (s in reflected.whole) if (s == name) count++;
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
		return signals.exists(signal -> source.indexOf(signal) >= 0);
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

}

/**
 * The initializer proof `scanContainer` threads down to `consider` — "does this member's
 * initializer make it inlinable, given its owning container and file". Closed over the resolved
 * seams, the plugin and the LAZY resolution index in `run`, so a run with no qualified reference
 * never pays for an index.
 */
private typedef InitProof = (container:QueryNode, init:QueryNode) -> Bool;
/**
 * What a member's leading modifier run says about it, resolved once by `modifierRunOf`:
 * `static` / already-`inline` / exported visibility / carrying a pin meta (`@:keep`, `@:rtti`).
 */
private typedef ModifierRun = {
	final isStatic: Bool;
	final isInline: Bool;
	final exported: Bool;
	final pinned: Bool;
};
