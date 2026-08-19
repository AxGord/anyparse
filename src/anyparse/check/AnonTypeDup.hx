package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;

/**
 * Flags an anonymous structure TYPE that is written out three or more times
 * (configurable) across the lint scope — a shape that has earned a name.
 * Report-only: like `string-literal-dup` and `magic-number`, the NAME is intent
 * a human supplies, so `fix` produces no edits. `extract-typedef` is the
 * operation half.
 *
 * ## The key is STRUCTURAL, never textual
 *
 * Haxe structural typing makes field ORDER irrelevant:
 * `{ isReadOnly:Bool, cloudTimestamp:Int, cloudId:Int }` and
 * `{ cloudId:Int, cloudTimestamp:Int, isReadOnly:Bool }` are the SAME type, and
 * a key built from the source text splits them — losing exactly the candidates
 * worth naming. So each occurrence is reduced to a canonical key built from the
 * TREE: every field as `name:type` (an optional field prefixed `?`, which IS
 * part of the type), the list sorted by that rendering, and nested anonymous
 * bodies reduced by the same function. Whitespace, the `,` / `;` separator
 * choice and a trailing separator are invisible to it by construction — the
 * key never reads the source at all.
 *
 * This is only possible because an anon field carries its TYPE in the query
 * tree (`@:queryTypeRef` on the grammar's field body). Before that,
 * `{ xml:Xml, text:String }` and `{ xml:Int, text:Int }` projected identically
 * and this rule would have merged two different types into one finding.
 *
 * ## What counts as an occurrence
 *
 * An `anonTypeKind` node whose EVERY direct child is a short-form field
 * (`paramKinds` — Haxe `Required` / `Optional`) carrying a type. Any other
 * member makes the whole occurrence unkeyable and it is skipped rather than
 * keyed approximately: a structure-extension clause (`> Base`), a
 * class-notation `var` / `final` / `function` field, or a `#if`-guarded run
 * changes what the type IS, and a key that ignored one would group two
 * different types. A structure needs at least `minFields` (default 2) fields —
 * a one-field shape is rarely worth a name and would flood the report.
 *
 * The body of a TYPE DECLARATION is not an occurrence: `typedef T = { … }` is
 * the migration TARGET, not a duplicate of it. The gate is the parent kind
 * being one of `RefShape.typeDeclKinds`, so it holds for any grammar whose type
 * declarations take a structural body.
 *
 * ## Scope
 *
 * Occurrences group ACROSS the files of one lint run — the shapes worth naming
 * are the cross-file ones (the leader in the reference corpus spans five
 * files). One finding per group, anchored at the scope-earliest occurrence,
 * carrying the total count and the number of distinct files.
 *
 * A consequence worth stating plainly: linting ONE file can only ever see that
 * file's occurrences, so a shape repeated across a package reports NOTHING at
 * single-file scope. That is not a gate refusing — it is the population being
 * absent. Run the rule at project scope before concluding a shape is not
 * duplicated.
 *
 * ## Configuration
 *
 * `anon-type-dup.minOccurrences` (default 3) and `anon-type-dup.minFields`
 * (default 2), read from a discovered `apqlint.json` against the FIRST file of
 * the run — the grouping is cross-file, so a per-file threshold would make the
 * verdict depend on which occurrence happened to come first.
 */
@:nullSafety(Strict)
final class AnonTypeDup implements Check implements ConfigAware implements DefaultOff {

	/** Least occurrences of one shape before the group is flagged. */
	private static inline final DEFAULT_MIN_OCCURRENCES: Int = 3;

	/** Least fields a structure must have before it is a naming candidate. */
	private static inline final DEFAULT_MIN_FIELDS: Int = 2;

	/** Longest rendered shape echoed verbatim in a finding message before it is elided. */
	private static inline final MESSAGE_PREVIEW: Int = 60;

	/** This check's stable id — named once so the literal is not itself a repeated string. */
	private static inline final RULE_ID: String = 'anon-type-dup';

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'an anonymous structure type written out many times across the scope that should be a named typedef';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final ctx: Null<AnonCtx> = buildCtx(shape);
		if (ctx == null || files.length == 0) return [];
		final config: LintConfig = LintConfig.resolveWith(_resolveConfig, files[0].file);
		final minOcc: Int = positiveOr(config.intOption(RULE_ID, 'minOccurrences'), DEFAULT_MIN_OCCURRENCES);
		final minFields: Int = positiveOr(config.intOption(RULE_ID, 'minFields'), DEFAULT_MIN_FIELDS);

		final groups: Map<String, Array<Occurrence>> = [];
		final order: Array<String> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			collect(tree, null, entry.file, entry.source, ctx, minFields, groups, order);
		}
		return report(groups, order, minOcc);
	}

	/** No mechanical autofix — the typedef's name is intent a human supplies (like `string-literal-dup`). */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/**
	 * The canonical structural key of an anonymous-structure body, or null when
	 * the shape holds a member this rule refuses to key (see the class doc).
	 * `minFields` applies at the TOP level only — a nested body of one field is
	 * still part of its parent's identity.
	 */
	public static function shapeKey(anon: QueryNode, ctx: AnonCtx, minFields: Int): Null<String> {
		final fields: Array<String> = [];
		for (child in anon.children) {
			if (!ctx.fieldKinds.contains(child.kind)) return null;
			final name: Null<String> = child.name;
			if (name == null) return null;
			final type: Null<String> = typeKey(child, ctx);
			if (type == null) return null;
			fields.push('${child.kind == ctx.optionalFieldKind ? '?' : ''}$name:$type');
		}
		if (fields.length < minFields) return null;
		// Sorted: Haxe structural typing makes two field orders THE SAME type, so a
		// key that preserved source order would split a group and lose the very
		// candidate the rule exists to find.
		fields.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		return '{ ${fields.join(', ')} }';
	}

	/**
	 * The rendered type of one field: a nested anonymous body reduced by
	 * `shapeKey`, else the field's projected type references joined in source
	 * order (`Map<A, B>` → `Map<A, B>`). Null when the field projects no type,
	 * which makes the whole structure unkeyable.
	 *
	 * The projection is FLAT — `Array<Array<X>>` reaches this function as the three
	 * nominals `Array`, `Array`, `X` with the nesting gone — so two differently
	 * nested spellings over the SAME nominals in the same order (`A<B<C>, D>` and
	 * `A<B, C<D>>`) key alike. A known limit shared with `uses`: it can only ever
	 * MERGE two shapes into one finding, never split a real group. It is also why
	 * the finding MESSAGE quotes the anchor occurrence's SOURCE text rather than
	 * this rendering, which would spell that same `Array<Array<X>>` as the
	 * nonexistent `Array<Array, X>`.
	 */
	private static function typeKey(field: QueryNode, ctx: AnonCtx): Null<String> {
		final kids: Array<QueryNode> = field.children;
		if (kids.length == 1 && kids[0].kind == ctx.anonKind) return shapeKey(kids[0], ctx, 1);
		final names: Array<String> = [];
		for (child in kids) {
			if (!ctx.typeRefKinds.contains(child.kind)) return null;
			final name: Null<String> = child.name;
			if (name == null) return null;
			names.push(name);
		}
		if (names.length == 0) return null;
		return names.length == 1 ? names[0] : '${names[0]}<${names.slice(1).join(', ')}>';
	}

	/**
	 * Walk `node`, recording every keyable anonymous-structure occurrence under
	 * its structural key. `parentKind` gates the type-declaration body: a
	 * `typedef T = { … }` is the naming TARGET, never one of the duplicates.
	 */
	private static function collect(
		node: QueryNode, parentKind: Null<String>, file: String, source: String, ctx: AnonCtx, minFields: Int,
		groups: Map<String, Array<Occurrence>>, order: Array<String>
	): Void {
		if (node.kind == ctx.anonKind && !(parentKind != null && ctx.typeDeclKinds.contains(parentKind))) {
			final span: Null<Span> = node.span;
			final key: Null<String> = shapeKey(node, ctx, minFields);
			if (key != null && span != null) {
				// Re-bound: a narrowed local never reaches an anonymous-structure literal
				// whose expected field type is non-nullable.
				final at: Span = span;
				final bucket: Null<Array<Occurrence>> = groups[key];
				if (bucket == null) {
					groups[key] = [{ file: file, at: at, text: collapse(source.substring(at.from, at.to)) }];
					order.push(key);
				} else {
					bucket.push({ file: file, at: at, text: '' });
				}
			}
		}
		for (child in node.children) collect(child, node.kind, file, source, ctx, minFields, groups, order);
	}

	/**
	 * One `Info` per group that reaches `minOcc`, anchored at its scope-earliest
	 * occurrence. `order` is first-seen order over the scope's files, so the
	 * report does not depend on map iteration order.
	 */
	private static function report(groups: Map<String, Array<Occurrence>>, order: Array<String>, minOcc: Int): Array<Violation> {
		final out: Array<Violation> = [];
		for (key in order) {
			final hits: Null<Array<Occurrence>> = groups[key];
			if (hits == null || hits.length < minOcc) continue;
			final files: Array<String> = [];
			for (hit in hits) if (!files.contains(hit.file)) files.push(hit.file);
			final anchor: Occurrence = hits[0];
			final where: String = files.length == 1 ? 'in this file' : 'across ${files.length} files';
			out.push({
				file: anchor.file,
				span: anchor.at,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'anonymous structure ${preview(anchor.text)} written ${hits.length} times $where — extract a typedef'
			});
		}
		return out;
	}

	/** A configured value when it is a positive integer, else the built-in default (a zero / negative option is ignored). */
	private static inline function positiveOr(value: Null<Int>, fallback: Int): Int {
		return value != null && value > 0 ? value : fallback;
	}

	/** `text` elided to `MESSAGE_PREVIEW` characters so a wide structure does not bloat the report. */
	private static function preview(text: String): String {
		return text.length > MESSAGE_PREVIEW ? '${text.substr(0, MESSAGE_PREVIEW)}…' : text;
	}

	/**
	 * `text` with every whitespace run reduced to one space and the ends trimmed —
	 * a structure written across several source lines still reads as one line in the
	 * report.
	 */
	private static function collapse(text: String): String {
		final out: StringBuf = new StringBuf();
		var space: Bool = false;
		for (i in 0...text.length) {
			final c: Int = text.fastCodeAt(i);
			final blank: Bool = c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
			if (blank) {
				space = out.length > 0;
				continue;
			}
			if (space) out.addChar(' '.code);
			space = false;
			out.addChar(c);
		}
		return out.toString();
	}

	/** The resolved kind sets, or null when the grammar names no anonymous-structure type. */
	public static function buildCtx(shape: RefShape): Null<AnonCtx> {
		final anon: Null<String> = shape.anonTypeKind;
		final fieldKinds: Null<Array<String>> = shape.paramKinds;
		final typeRefKinds: Null<Array<String>> = shape.typeRefChildKinds;
		if (anon == null || fieldKinds == null || typeRefKinds == null) return null;
		return {
			anonKind: anon,
			fieldKinds: fieldKinds,
			optionalFieldKind: shape.optionalParamKind,
			typeRefKinds: typeRefKinds,
			typeDeclKinds: shape.typeDeclKinds ?? []
		};
	}

}

/** The resolved kind sets threaded through the walk, built once per run. */
typedef AnonCtx = {
	final anonKind: String;
	final fieldKinds: Array<String>;
	final optionalFieldKind: Null<String>;
	final typeRefKinds: Array<String>;
	final typeDeclKinds: Array<String>;
};

/**
 * One written-out occurrence of a shape: the file it sits in, its span, and — for
 * the group's FIRST occurrence only — its source text as the report quotes it.
 */
private typedef Occurrence = {
	final file: String;
	final at: Span;
	final text: String;
};
