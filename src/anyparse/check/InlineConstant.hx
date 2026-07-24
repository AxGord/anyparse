package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a non-public `static final` constant of a basic scalar type whose
 * initializer is a compile-time literal, and rewrites it to `static inline final`
 * by inserting the `inline` keyword. `Severity.Info` (a codegen / modernization
 * cleanup), with an autofix. An inline scalar constant folds to an immediate at
 * every use site instead of a static-field load.
 *
 * ## The type annotation is PRESERVED (not dropped)
 *
 * The fix inserts only `inline`; it does NOT strip the `:Type` annotation. Dropping
 * it is unsound: `static final X:Float = 5` would re-infer as `Int` (the literal's
 * type), silently changing `X`'s type and every use — the classic
 * Float-constant-becomes-Int hazard. Keeping the annotation is also consistent with
 * the project's explicit-type preference. So `static final X:Int = 5` becomes
 * `static inline final X:Int = 5`.
 *
 * ## Why String is excluded (hxcpp evidence)
 *
 * `inlineConstantLiteralKinds` (the grammar's policy seam) lists only `IntLit` /
 * `HexLit` / `FloatLit` / `BoolLit` and OMITS the string kinds. Measured against
 * hxcpp 4.3 codegen: an inlined String re-emits its full literal (`HX_("...")`) at
 * EVERY use site, duplicating the string's bytes once per use across translation
 * units, whereas a non-inline `static final` keeps exactly one shared copy — with no
 * compensating runtime benefit (both are static-backed, allocation-free). A scalar
 * instead constant-folds to a tiny immediate with zero duplication. So String
 * constants stay `static final`; only scalars are inlined.
 *
 * ## Soundness gates (must-skip)
 *
 * 1. NON-PUBLIC only. A public constant may be consumed by another module's macro or
 *    reflected across files; inlining erases the field. Restricting to private /
 *    default visibility keeps the field off any external surface — a private inline
 *    constant cannot be a macro-consumed public one.
 * 2. STATIC final only. `inline` requires a static field; an instance `final` and a
 *    `var` are skipped, as is an already-`inline` field (nothing to do).
 * 3. COMPILE-TIME LITERAL initializer only — a bare `inlineConstantLiteralKinds`
 *    literal, or `negationKind` wrapping a numeric one (`-5`). Any other initializer
 *    (arithmetic, a call, another identifier, an array / object literal, `null`, an
 *    `#if`-divergent value, a String) is not provably a basic constant and is left
 *    alone.
 * 4. NO reflection. A constant whose NAME appears as a string literal ANYWHERE in the
 *    lint scope is skipped — it may be read by `Reflect.field(o, "NAME")`, which an
 *    inline field (erased from the runtime type) would break. Conservative: the name
 *    matches any string content, which only ever KEEPS a constant non-inline.
 * 5. NO `@:keep`. A `@:keep`-annotated field is explicitly retained (often for
 *    reflection / external tooling); inlining would erase it.
 * 6. ENUM ABSTRACT and `#if` members are structurally excluded — an enum abstract's
 *    values live under `EnumAbstractDecl` (not a `visibilityContainerKinds` host, and
 *    handled by `prefer-enum-abstract`), and a `#if`-guarded member is nested in a
 *    `Conditional` rather than a direct container child, so neither is ever scanned.
 *
 * ## Grammar-agnostic
 *
 * Reads `visibilityContainerKinds` / `memberDeclKinds` / `fieldDeclKinds` /
 * `mutableFieldDeclKinds` (the final-field host = field minus mutable),
 * `visibilityModifierKinds` + `defaultVisibilityModifierText`, `staticModifierKind`,
 * `inlineModifierKind`, `inlineConstantLiteralKinds`, `numericLiteralKinds` +
 * `negationKind`, plus `metaShape().metaKinds` and `stringFoldSupport()`. Any required
 * seam unset makes the check a no-op.
 */
@:nullSafety(Strict)
final class InlineConstant implements Check {

	/** The `final` keyword the member host span starts at — `inline ` is inserted immediately before it. */
	private static inline final FINAL_KEYWORD: String = 'final';

	/** The meta that pins a field in place (reflection / external tooling); such a field is never inlined. */
	private static inline final KEEP_META: String = '@:keep';

	public function new() {}

	public function id(): String {
		return 'inline-constant';
	}

	public function description(): String {
		return 'a non-public static final scalar constant that can be inline';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final reflected: Array<String> = collectReflectedNames(files, plugin, seams.stringFold);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, entry.source, tree, seams, reflected);
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
			if (source.substring(span.from, span.from + FINAL_KEYWORD.length) != FINAL_KEYWORD) continue;
			edits.push({ span: new Span(span.from, span.from), text: 'inline ' });
		}
		return edits;
	}

	/** Walk `node`; scan every visibility-bearing container's direct children for inlinable static final constants. */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, seams: Seams, reflected: Array<String>
	): Void {
		if (seams.containers.contains(node.kind)) scanContainer(out, file, source, node, seams, reflected);
		for (child in node.children) walk(out, file, source, child, seams, reflected);
	}

	/**
	 * Scan `container`'s DIRECT children in source order. Modifier / meta siblings precede
	 * the member they attach to, so a running flag set (`static`, `inline`, exported
	 * visibility, `@:keep`) — reset at each member — describes the member that just
	 * appeared. A `#if`-guarded member is nested in a `Conditional` (not a direct child),
	 * so it is never seen here.
	 */
	private static function scanContainer(
		out: Array<Violation>, file: String, source: String, container: QueryNode, seams: Seams, reflected: Array<String>
	): Void {
		var sawStatic: Bool = false;
		var sawInline: Bool = false;
		var exported: Bool = false;
		var sawKeep: Bool = false;
		for (child in container.children) {
			final kind: String = child.kind;
			if (kind == seams.staticKind)
				sawStatic = true;
			else if (seams.inlineKind != null && kind == seams.inlineKind)
				sawInline = true;
			else if (seams.visibility.contains(kind))
				exported = exported || isExportedVisibility(source, child, seams.defaultVis);
			else if (seams.metaKinds.contains(kind))
				sawKeep = sawKeep || child.name == KEEP_META;
			else if (seams.members.contains(kind)) {
				if (seams.finalFieldKinds.contains(kind) && sawStatic && !sawInline && !exported && !sawKeep)
					consider(out, file, child, seams, reflected);
				sawStatic = false;
				sawInline = false;
				exported = false;
				sawKeep = false;
			}
		}
	}

	/** Whether `child` (a visibility modifier) is a non-default (exported) keyword — `public` rather than the private default. */
	private static function isExportedVisibility(source: String, child: QueryNode, defaultVis: String): Bool {
		final span: Null<Span> = child.span;
		return span != null && StringTools.trim(source.substring(span.from, span.to)) != defaultVis;
	}

	/**
	 * Flag `field` when its initializer is an inlinable compile-time literal and its name is
	 * not read by reflection. The visibility / static / inline / keep gates are already
	 * applied by the caller.
	 */
	private static function consider(out: Array<Violation>, file: String, field: QueryNode, seams: Seams, reflected: Array<String>): Void {
		final name: Null<String> = field.name;
		final span: Null<Span> = field.span;
		if (name == null || span == null) return;
		if (reflected.contains(name)) return;
		final init: Null<QueryNode> = initializerOf(field);
		if (init == null || !isInlinableLiteral(init, seams)) return;
		out.push({
			file: file,
			span: span,
			rule: 'inline-constant',
			severity: Severity.Info,
			message: 'static constant \'$name\' is a scalar literal; use inline'
		});
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
		if (
			containers.length == 0 || members.length == 0 || fieldKinds.length == 0 || visibility.length == 0 || defaultVis == null
			|| staticKind == null || literalKinds.length == 0
		)
			return null;
		final finalFieldKinds: Array<String> = [for (k in fieldKinds) if (!mutable.contains(k)) k];
		if (finalFieldKinds.length == 0) return null;
		return {
			containers: containers,
			members: members,
			finalFieldKinds: finalFieldKinds,
			visibility: visibility,
			defaultVis: defaultVis,
			staticKind: staticKind,
			inlineKind: shape.inlineModifierKind,
			metaKinds: plugin.metaShape().metaKinds,
			literalKinds: literalKinds,
			numericKinds: shape.numericLiteralKinds ?? [],
			negationKind: shape.negationKind,
			stringFold: plugin.stringFoldSupport()
		};
	}

}

/** The resolved seams `InlineConstant` reads across `run` / `fix` helpers. */
private typedef Seams = {
	final containers: Array<String>;
	final members: Array<String>;
	final finalFieldKinds: Array<String>;
	final visibility: Array<String>;
	final defaultVis: String;
	final staticKind: String;
	final inlineKind: Null<String>;
	final metaKinds: Array<String>;
	final literalKinds: Array<String>;
	final numericKinds: Array<String>;
	final negationKind: Null<String>;
	final stringFold: Null<StringFoldSupport>;
};
