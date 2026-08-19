package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.ConstantFieldScan.ConstantFieldSeams;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberBranchScan;
import anyparse.query.MemberWriteScan;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;

/**
 * Flags an INSTANCE `final` field whose initializer is a pure compile-time literal, and rewrites it
 * to `static final` by inserting the `static` keyword. `Severity.Info` (a per-instance storage
 * cleanup), with an autofix, DEFAULT OFF. Every instance of the type stores its own copy of a value
 * the compiler already knows; one static field says the same thing once.
 *
 * The sibling in the other direction is `inline-constant` (`static final` scalar -> `static inline
 * final`), and the two COMPOSE: this rule's output is exactly that rule's input, so a second `--fix`
 * pass turns a promoted scalar into `static inline final`.
 *
 * ## The initializer gate is a POSITIVE criterion, not a blacklist
 *
 * The obvious gate — "the field is never reassigned" — lets a catastrophe through, and the corpus
 * has it on adjacent lines: `private final _lists:Array<E> = [];` is never reassigned (every
 * occurrence classifies as a READ) because the mutation goes through `push` / `splice`.
 * Read/write classification is about the BINDING, not the object, so a never-reassigned field can
 * still hold per-instance MUTABLE state; promoting it would share one list across every instance.
 * The same holds for `new Sprite()`, `new Mutex()`, `new Map()` and every constructor call nobody
 * has thought of yet.
 *
 * So the initializer must PROVE itself rather than merely avoid a known-bad list: an
 * `inlineConstantLiteralKinds` literal (Int / Hex / Float / Bool), a `negationKind` over a numeric
 * one (`-5`), or a PLAIN string literal — one the grammar's `stringFoldSupport().literalOf` accepts,
 * which is exactly the no-interpolation case. Everything else refuses by construction.
 *
 * ## …and the initializer is a DEFAULT, not the value — the write gate is the OTHER half
 *
 * The lesson above has a second layer that a literal initializer hides completely: an INSTANCE
 * `final` with a declaration initializer can still be REASSIGNED in the constructor. Measured on
 * Haxe 4.3.7 — `final _n:Int = 5;` plus `public function new(f:Bool) if (f) _n = 9;` compiles, and
 * the two constructions print 5 and 9. The `static` form of the same class rejects that write with
 * `This expression cannot be accessed for writing`, so the promotion would not compile. (Outside a
 * constructor the write is already illegal, for the instance form too.)
 *
 * So "the initializer is a compile-time literal" does NOT mean "every instance holds that value" —
 * it means every instance STARTS there. `MemberWriteScan.writtenInRange` supplies the missing half,
 * the same conservative complete write scan `prefer-final-field` proves `var -> final` with: any
 * assignment to the name anywhere in the file, outside the declaration, refuses. Found by
 * typechecking a `--fix` over a real 805-file tree; the unit suite was green, and six of the
 * fifteen sites did not compile.
 *
 * The interpolation half of that is load-bearing and invisible to a type-based reading: a CALL
 * inside a `'…'` literal makes the value differ per instance just as much as a call in value
 * position — `private final _closeAction:String = '${UUID.uuid()}: close';` is a distinct token per
 * instance, and sharing one would collapse every instance's identity onto the first. `literalOf`
 * returns null for any interpolated literal, so this refuses for the same reason `new UUID()` does.
 *
 * A reference to a `static inline final` constant (`= SOME_CONST`) also folds at compile time and
 * would be sound. It is deliberately NOT accepted: `inline-constant`'s equivalent arm is documented
 * as a measured-zero-yield shape, this rule has no corpus evidence for it either, and a reference
 * arm is where the qualified-receiver holes that rule catalogues would arrive. Add it when a corpus
 * shows sites, not before.
 *
 * ## Why the promotion is a CROSS-FILE question, and where it fails closed
 *
 * `static` changes how the member is REACHED, not only where it is stored. Measured on Haxe 4.3.7,
 * identical on `--interp` and `-cpp`:
 *
 *  - a subclass reads an inherited private INSTANCE field unqualified and it resolves; the same
 *    bare read of a private STATIC of the superclass is `Unknown identifier : S_VAL`. Only
 *    `Base.S_VAL` works. So a correct fix is "add `static` AND rewrite every unqualified read in
 *    every subtype to `Owner.NAME`" — an edit in files `Check.fix` never sees (it is handed ONE
 *    file's source). There is no `--scope`, so the rule FAILS CLOSED: any subtype that so much as
 *    mentions the name refuses the finding outright;
 *  - `this.NAME` and `obj.NAME` are both `Cannot access static field NAME from a class instance`.
 *    A member access on the name anywhere in the declaring file therefore refuses, and a PUBLIC
 *    field refuses wholesale — its readers are every file in the project, and rewriting them is the
 *    same cross-file edit;
 *  - `Reflect.field(instance, 'NAME')` returns the value for an instance field and `null` for a
 *    static one (the class object keeps it, the instance does not). The reflection-name gate is
 *    therefore mandatory, exactly as it is for `inline-constant`.
 *
 * ## The OBJECT case is not autofixable, and this rule does not pretend otherwise
 *
 * The motivating shapes in a real tree are the shared immutable OBJECTS — a `TextFormat` a view
 * hands to its text fields, a reusable `Point`. Whether one is shareable depends on what the
 * consumer does with it (does it retain the reference, does it mutate the argument), which lives in
 * a library this rule cannot read; and the value LEAVES the declaring type, so even "the value never
 * escapes" does not prove it. That is a config-allowlist question (`staticPromotableTypes`) or a
 * hand review, not a structural proof, and it is deliberately out of scope here.
 *
 * ## Soundness gates (must-skip)
 *
 * 1. INSTANCE `final` only — a `var` (shared mutable state), an already-`static` field and an
 *    `inline` one are skipped, as is a member whose modifier run the `#if` branches disagree on.
 * 2. A class-like container only (`RefactorSupport.classLikeContainerKinds`), so an `enum abstract`
 *    value — which a crude census reads as a scalar field — is structurally excluded.
 * 3. PRIVATE only (see above).
 * 4. The initializer proves itself (see above), AND nothing assigns the name anywhere in the file
 *    outside its declaration — a constructor may reassign an instance `final`, a static one not.
 * 5. NO member access on the name in the declaring file — `this.NAME` / `obj.NAME` do not compile
 *    against a static.
 * 6. NO subtype in scope mentions the name, and no `@:access(Owner)` grantee does; the hierarchy
 *    must be resolvable (`MemberWriteScan` fails closed when it is not) and the report index must
 *    have parsed every file, with no `@:allow` in the declaring file
 *    (`RefactorSupport.privateMemberScanIsSound`).
 * 7. NO `@:build` / `@:autoBuild` in the file — a macro can inject a `this.NAME` read no text scan
 *    can see.
 * 8. NO `@:keep` / `@:rtti` on the field or its class, and the NAME must not appear as a string
 *    literal anywhere in scope (the reflection gate).
 * 9. NO `@:structInit` on the class — an initialized `final` there is an OPTIONAL CONSTRUCTOR
 *    ARGUMENT, so promoting it removes a name every `{ … }` literal may pass.
 *
 * Like `prefer-final-field` and `unused-private`, gate 6 is only sound when the lint scope holds
 * every file that can reference the type; the sound usage is linting the whole project.
 *
 * ## Grammar-agnostic
 *
 * Reads `visibilityContainerKinds` / `memberDeclKinds` / `fieldDeclKinds` / `mutableFieldDeclKinds`
 * (the final-field host = field minus mutable), `visibilityModifierKinds` +
 * `defaultVisibilityModifierText`, `staticModifierKind`, `inlineModifierKind`,
 * `inlineConstantLiteralKinds`, `numericLiteralKinds` + `negationKind`, plus `metaShape().metaKinds`
 * and `stringFoldSupport()`. Any required seam unset makes the check a no-op.
 */
@:nullSafety(Strict)
final class StaticConstant implements Check implements DefaultOff {

	/** The `final` keyword the member host span starts at — `static ` is inserted immediately before it. */
	private static inline final FINAL_KEYWORD: String = 'final';

	/** The meta that pins a field in place for reflection / external tooling; such a field is never promoted. */
	private static inline final KEEP_META: String = '@:keep';

	/** The meta that enables runtime type info for a type; a field it exposes is never promoted. */
	private static inline final RTTI_META: String = '@:rtti';

	/** The meta that turns an initialized `final` field into an OPTIONAL CONSTRUCTOR ARGUMENT — promoting it would delete that argument. */
	private static inline final STRUCT_INIT_META: String = '@:structInit';

	public function new() {}

	public function id(): String {
		return 'static-constant';
	}

	public function description(): String {
		return 'an instance final field initialized to a compile-time literal that can be static';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final resolved: Null<ConstantFieldSeams> = ConstantFieldScan.seams(plugin);
		if (resolved == null) return [];
		final seams: ConstantFieldSeams = resolved;
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final reflected: Array<String> = ConstantFieldScan.reflectedNames(files, plugin, seams.stringFold);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null || MemberWriteScan.carriesBuildMacro(entry.source)) continue;
			walk(tree, {
				out: violations,
				file: entry.file,
				source: entry.source,
				seams: seams,
				reflected: reflected,
				index: index,
				plugin: plugin,
				branch: MemberBranchScan.seamsOf(plugin.refShape(), entry.source)
			}, false);
		}
		return violations;
	}

	/**
	 * Insert `static ` before the `final` keyword of each flagged member, yielding the canonical
	 * `private static final` (the visibility modifier precedes the member's own span). The edit
	 * fires only when the bytes at the span start are literally `final`, so an unexpected span
	 * simply produces no edit.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null || source.substring(span.from, span.from + FINAL_KEYWORD.length) != FINAL_KEYWORD) continue;
			edits.push({ span: new Span(span.from, span.from), text: 'static ' });
		}
		return edits;
	}

	/** Whether `meta` blocks the promotion — reflection pins (`@:keep` / `@:rtti`) and `@:structInit`. */
	private static inline function isBlockingMeta(meta: Null<String>): Bool {
		return meta == KEEP_META || meta == RTTI_META || meta == STRUCT_INIT_META;
	}

	/**
	 * Walk `node`; scan every class-like container's members. A class-level `@:keep` / `@:rtti` /
	 * `@:structInit` projects as `Meta` siblings PRECEDING the container rather than as its children,
	 * so a running flag over each node's direct children — set by such a meta, cleared at the next
	 * non-meta node — marks the container it attaches to. A `final class` nests its body one level
	 * down in a `FinalDecl(ClassForm …)` wrapper, so the flag is carried into the recursion.
	 */
	private static function walk(node: QueryNode, ctx: Ctx, inheritedBlock: Bool): Void {
		var blocked: Bool = inheritedBlock;
		for (child in node.children) {
			if (ctx.seams.metaKinds.contains(child.kind))
				blocked = blocked || isBlockingMeta(child.name);
			else {
				if (ctx.seams.classLikeContainers.contains(child.kind) && !blocked) scanContainer(child, ctx);
				walk(child, ctx, blocked);
				blocked = false;
			}
		}
	}

	/**
	 * Scan `container`'s members. Modifier / meta siblings precede the member they attach to, so the
	 * running run `MemberBranchScan.eachMember` supplies describes that member; a run only SOME
	 * builds see cannot answer `static`, and such a member is skipped.
	 */
	private static function scanContainer(container: QueryNode, ctx: Ctx): Void {
		final seams: ConstantFieldSeams = ctx.seams;
		MemberBranchScan.eachMember(ctx.branch, container, child -> seams.members.contains(child.kind), (member, run, certain) -> {
			if (!certain || !seams.finalFieldKinds.contains(member.kind)) return;
			var blocked: Bool = false;
			for (mod in run) {
				if (mod.kind == seams.staticKind || seams.inlineKind != null && mod.kind == seams.inlineKind)
					blocked = true;
				else if (seams.visibility.contains(mod.kind))
					blocked = blocked || ConstantFieldScan.isExportedVisibility(ctx.source, mod, seams.defaultVis);
				else if (seams.metaKinds.contains(mod.kind))
					blocked = blocked || isBlockingMeta(mod.name);
			}
			if (!blocked) consider(member, container, ctx);
		});
	}

	/**
	 * Flag `field` when its initializer proves itself a compile-time literal and no reader of the
	 * name would break. The static / inline / visibility / meta gates are already applied by the
	 * caller; what remains is the initializer proof and the reachability gates the class doc lists.
	 */
	private static function consider(field: QueryNode, container: QueryNode, ctx: Ctx): Void {
		final name: Null<String> = field.name;
		final span: Null<Span> = field.span;
		final owner: Null<String> = container.name;
		if (name == null || span == null || owner == null) return;
		final init: Null<QueryNode> = ConstantFieldScan.initializerOf(field);
		if (init == null || !isConstantLiteral(init, ctx.source, ctx.seams)) return;
		if (MemberWriteScan.writtenInRange(ctx.source, name, span, 0, ctx.source.length)) return;
		if (ctx.reflected.contains(name)) return;
		if (memberAccessedInFile(ctx.source, name, span)) return;
		if (!RefactorSupport.privateMemberScanIsSound(ctx.source, ctx.index)) return;
		if (MemberWriteScan.accessGrantMayReference(owner, name, ctx.index, ctx.plugin)) return;
		if (MemberWriteScan.subtypeMayReference(owner, name, ctx.index, ctx.plugin)) return;
		ctx.out.push({
			file: ctx.file,
			span: span,
			rule: 'static-constant',
			severity: Severity.Info,
			message: 'field \'$name\' is a compile-time literal, identical in every instance; use static'
		});
	}

	/**
	 * Whether `init` is a value the compiler knows and every instance would share: an
	 * `inlineConstantLiteralKinds` literal, a `negationKind` over a numeric one, or a PLAIN string
	 * literal. `literalOf` is what makes the string arm safe — it answers null for an interpolated
	 * literal, so `'${UUID.uuid()}: close'` refuses exactly like a call in value position.
	 */
	private static function isConstantLiteral(init: QueryNode, source: String, seams: ConstantFieldSeams): Bool {
		if (ConstantFieldScan.isScalarLiteral(init, seams)) return true;
		final fold: Null<StringFoldSupport> = seams.stringFold;
		return seams.stringLiteralKinds.contains(init.kind) && fold?.literalOf(init, source) != null;
	}

	/**
	 * Whether `name` occurs in `source` — outside its own declaration `decl` — immediately after a
	 * `.`, i.e. as a member access. Both `this.NAME` and `obj.NAME` are `Cannot access static field
	 * NAME from a class instance`, so ONE such occurrence refuses the promotion. Conservative: the
	 * scan is textual and word-boundary only, so a same-named member of an unrelated type, or the
	 * name inside a comment or string, also refuses — which only ever KEEPS the field an instance
	 * one.
	 */
	private static function memberAccessedInFile(source: String, name: String, decl: Span): Bool {
		final len: Int = name.length;
		var at: Int = 0;
		while (true) {
			final idx: Int = source.indexOf(name, at);
			if (idx < 0) return false;
			at = idx + len;
			final boundedBefore: Bool = idx == 0 || !RefactorSupport.isIdentChar(source.fastCodeAt(idx - 1));
			final boundedAfter: Bool = at >= source.length || !RefactorSupport.isIdentChar(source.fastCodeAt(at));
			if (!boundedBefore || !boundedAfter || idx >= decl.from && idx < decl.to) continue;
			if (precededByDot(source, idx)) return true;
		}
	}

	/** Whether the nearest non-space character before `idx` is a `.` — the member-access form. */
	private static function precededByDot(source: String, idx: Int): Bool {
		var i: Int = idx - 1;
		while (i >= 0 && RefactorSupport.isSpace(source.fastCodeAt(i))) i--;
		return i >= 0 && source.fastCodeAt(i) == '.'.code;
	}

}

/** The per-file state the container walk threads down to `consider`. */
private typedef Ctx = {
	final out: Array<Violation>;
	final file: String;
	final source: String;
	final seams: ConstantFieldSeams;
	final reflected: Array<String>;
	final index: SymbolIndex;
	final plugin: GrammarPlugin;
	final branch: MemberBranchSeams;
};
