package anyparse.check.common.design;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.CrossFileAnchored;
import anyparse.check.Check.CrossFileEdits;
import anyparse.check.Check.CrossFileFix;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.VolatileMessage;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.IndexScope;
import anyparse.query.ModuleMove;
import anyparse.query.ModuleScan;
import anyparse.query.NewFile;
import anyparse.query.ParseGate;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeRefPrinter;
import anyparse.util.Compare;
import haxe.io.Path;

using anyparse.util.Groups;
using StringTools;

/** The resolved kind sets threaded through the walk, built once per run. */
typedef AnonCtx = {
	final anonKind: String;
	final fieldKinds: Array<String>;
	final optionalFieldKind: Null<String>;
	final typeRefKinds: Array<String>;
	final typeDeclKinds: Array<String>;
};

/**
 * One written-out occurrence of a shape: the file it sits in, its span, and that file's source the report quotes;
 * `fields` the whitespace-free text of each field in WRITTEN order, `typeNames` the simple type names it spells.
 */
private typedef Occurrence = {
	final file: String;
	final at: Span;
	final source: String;
	final fields: Array<String>;
	final typeNames: Array<String>;
};

/** A structure the config names: the typedef's full path, its fields as configured and their whitespace-free signature. */
private typedef NamedType = { final path: String; final spelled: Array<String>; final signature: String; };

/** The occurrences one finding's fix rewrites, and the typedef they become. */
private typedef Plan = { final named: NamedType; final hits: Array<Occurrence>; };

/**
 * Flags an anonymous structure TYPE that is written out three or more times
 * (configurable) across the lint scope — a shape that has earned a name.
 * The NAME is intent a human supplies, so the fix runs only for a structure the config names
 * (`named`, below); `extract-typedef` is the operation half for the rest.
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
 * (default 2), read from a discovered `apq.json` against the FIRST file of
 * the run — the grouping is cross-file, so a per-file threshold would make the
 * verdict depend on which occurrence happened to come first.
 *
 * `anon-type-dup.named` maps a typedef path to its field list, `{"pkg.Name": ["a: Int", "?b: Array<X>"]}`,
 * and is the only thing that makes the fix run: it creates `pkg/Name` and rewrites every occurrence that
 * matches EXACTLY (fields, optionality, written order, compared as text with whitespace removed).
 */
@:nullSafety(Strict)
final class AnonTypeDup extends RuleBase implements CrossFileFix implements ConfigAware implements DefaultOff implements VolatileMessage
		implements CrossFileAnchored {

	/** Least occurrences of one shape before the group is flagged. */
	private static inline final DEFAULT_MIN_OCCURRENCES: Int = 3;

	/** Least fields a structure must have before it is a naming candidate. */
	private static inline final DEFAULT_MIN_FIELDS: Int = 2;

	/** Longest rendered shape echoed verbatim in a finding message before it is elided. */
	private static inline final MESSAGE_PREVIEW: Int = 60;

	/** This check's stable id — named once so the literal is not itself a repeated string. */
	private static inline final RULE_ID: String = 'anon-type-dup';

	/** The option mapping a typedef's full path to the field list of the structure it names. */
	private static final OPTION_NAMED: String = 'named';

	/**
	 * The fragment that precedes the OCCURRENCE TALLY in a message, shared by the builder and
	 * by `messageIdentity` so the mask anchor cannot drift from the wording it points at.
	 */
	private static final WRITTEN_LEAD: String = ' written ';

	/** The same, for the DISTINCT-FILE tally of the cross-file wording. */
	private static final ACROSS_LEAD: String = 'across ';

	/** The fix plan of each finding, keyed by its anchor (`file:from`) — rebuilt by every `run`, read by `crossFileFix`. */
	private final _plans: Map<String, Plan> = [];

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	/** The linter's per-file "does a finding here survive" answer; null when every file's does. */
	private var _reportable: Null<(String) -> Bool> = null;

	public function new() {
		super(
			RULE_ID, 'an anonymous structure type written out many times across the scope that should be a named typedef',
			RuleCategory.Design
		);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function setReportable(reportable: Null<(String) -> Bool>): Void {
		_reportable = reportable;
	}

	public function messageIdentity(message: String): String {
		return MessageMask.maskAfter(MessageMask.maskAfter(message, WRITTEN_LEAD), ACROSS_LEAD);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final ctx: Null<AnonCtx> = buildCtx(shape);
		if (ctx == null || files.length == 0) return [];
		// Both options are read per FILE: `minFields` where a shape is written, `minOccurrences` where a group's
		// occurrence sits, so a scope spanning two config chains holds each file to its own.
		final minOccOf: Map<String, Int> = [];
		final groups: Map<String, Array<Occurrence>> = [];
		final namedOf: Map<String, Array<NamedType>> = [];
		_plans.clear();
		final order: Array<String> = [];
		for (entry in files) {
			final config: LintConfig = LintConfig.resolveWith(_resolveConfig, entry.file);
			minOccOf[entry.file] = positiveOr(config.intOption(RULE_ID, 'minOccurrences'), DEFAULT_MIN_OCCURRENCES);
			final problems: Array<String> = [];
			namedOf[entry.file] = namedTypesOf(config, problems);
			for (p in problems) ConfiguredTypes.warn(_configNotes, RULE_ID, p);
			final minFields: Int = positiveOr(config.intOption(RULE_ID, 'minFields'), DEFAULT_MIN_FIELDS);
			final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			collect(tree, null, entry.file, entry.source, ctx, minFields, groups, order);
		}
		return report(groups, order, minOccOf, namedOf, _reportable);
	}

	/** The per-file seam has nothing to say: a structure's occurrences sit in many files and the typedef is a new one. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/**
	 * One atomic group per finding whose structure the config names: the typedef module created, every exactly matching
	 * occurrence rewritten to it with the imports each file needs. A finding naming nothing has no group.
	 */
	public function crossFileFix(
		files: Array<{ file: String, source: String }>, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<Array<CrossFileEdits>> {
		final out: Array<Array<CrossFileEdits>> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			final plan: Null<Plan> = span == null ? null : _plans['${v.file}:${span.from}'];
			final slices: Null<Array<CrossFileEdits>> = plan == null ? null : slicesOf(plan, files, plugin, index);
			if (slices != null) out.push(slices);
		}
		return out;
	}

	/**
	 * One `Info` per group that reaches the `minOccurrences` of one of its occurrences' files, anchored at the
	 * scope-earliest such occurrence whose file `reportable` accepts (see `Check.CrossFileAnchored`). `order` is
	 * first-seen order over the scope's files, so the report does not depend on map iteration order.
	 */
	private function report(
		groups: Map<String, Array<Occurrence>>, order: Array<String>, minOccOf: Map<String, Int>, namedOf: Map<String, Array<NamedType>>,
		reportable: Null<(String) -> Bool>
	): Array<Violation> {
		final out: Array<Violation> = [];
		for (key in order) {
			final hits: Null<Array<Occurrence>> = groups[key];
			if (hits == null) continue;
			final anchor: Null<Occurrence> = hits.find(
				hit -> hits.length >= (minOccOf[hit.file] ?? DEFAULT_MIN_OCCURRENCES) && (reportable == null || reportable(hit.file))
			);
			if (anchor == null) continue;
			final files: Array<String> = [];
			for (hit in hits) if (!files.contains(hit.file)) files.push(hit.file);
			final quoted: String = collapse(anchor.source.substring(anchor.at.from, anchor.at.to));
			final where: String = files.length == 1 ? 'in this file' : '$ACROSS_LEAD${files.length} files';
			final plan: Null<Plan> = planOf(hits, namedOf[anchor.file] ?? []);
			if (plan != null) _plans['${anchor.file}:${anchor.at.from}'] = plan;
			final tail: String = plan == null
				? 'extract a typedef, or name it under "$OPTION_NAMED" of $RULE_ID in apq.json to fix it'
				: 'extract typedef ${plan.named.path}';
			out.push({
				file: anchor.file,
				span: anchor.at,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'anonymous structure ${preview(quoted)}$WRITTEN_LEAD${hits.length} times $where — $tail'
			});
		}
		return out;
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
		fields.sort(Compare.compareString);
		return '{ ${fields.join(', ')} }';
	}

	/** The resolved kind sets, or null when the grammar names no anonymous-structure type. */
	public static function buildCtx(shape: RefShape): Null<AnonCtx> {
		final anon: Null<String> = shape.anonTypeKind;
		final fieldKinds: Null<Array<String>> = shape.paramKinds;
		final typeRefKinds: Null<Array<String>> = shape.typeRefChildKinds;
		return anon == null || fieldKinds == null || typeRefKinds == null ? null : {
			anonKind: anon,
			fieldKinds: fieldKinds,
			optionalFieldKind: shape.optionalParamKind,
			typeRefKinds: typeRefKinds,
			typeDeclKinds: shape.typeDeclKinds ?? []
		};
	}

	/** A configured value when it is a positive integer, else the built-in default (a zero / negative option is ignored). */
	private static inline function positiveOr(value: Null<Int>, fallback: Int): Int {
		return value != null && value > 0 ? value : fallback;
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
		return switch (names.length) {
			case 0: null;
			case 1: names[0];
			case _: '${names[0]}<${names.slice(1).join(', ')}>';
		};
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
				final typeNames: Array<String> = [];
				collectTypeNames(node, ctx, typeNames);
				final hit: Occurrence = {
					file: file,
					at: at,
					source: source,
					fields: fieldTexts(node, source),
					typeNames: typeNames
				};
				final bucket: Null<Array<Occurrence>> = groups[key];
				if (bucket == null) {
					groups[key] = [hit];
					order.push(key);
				} else {
					bucket.push(hit);
				}
			}
		}
		for (child in node.children) collect(child, node.kind, file, source, ctx, minFields, groups, order);
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

	/** The structures `config` names under `named`: a typedef path mapped to a list of `name: Type` field strings. */
	private static function namedTypesOf(config: LintConfig, problems: Array<String>): Array<NamedType> {
		return RuleDeclaration.namedFields(config, RULE_ID, OPTION_NAMED, problems)
			.map(named -> { path: named.path, spelled: named.fields, signature: named.fields.map(squeeze).join('\n') });
	}

	/** The first named structure some of `hits` match EXACTLY — same fields, same optionality, same written order. */
	private static function planOf(hits: Array<Occurrence>, named: Array<NamedType>): Null<Plan> {
		for (candidate in named) {
			final matched: Array<Occurrence> = hits.filter(hit -> hit.fields.join('\n') == candidate.signature);
			if (matched.length > 0) return { named: candidate, hits: matched };
		}
		return null;
	}

	/** `text` with every whitespace run removed: two spellings of one field compare equal. */
	private static function squeeze(text: String): String {
		return ~/\s+/g.replace(text, '');
	}

	/** The whitespace-free text of each field of `anon`, in written order; empty when a field has no span. */
	private static function fieldTexts(anon: QueryNode, source: String): Array<String> {
		final out: Array<String> = [];
		for (child in anon.children) {
			final span: Null<Span> = child.span;
			if (span == null) return [];
			out.push(squeeze(source.substring(span.from, span.to)));
		}
		return out;
	}

	/** The simple names of every type reference under `node`, each once. */
	private static function collectTypeNames(node: QueryNode, ctx: AnonCtx, out: Array<String>): Void {
		for (child in node.children) {
			final name: Null<String> = child.name;
			if (name != null && ctx.typeRefKinds.contains(child.kind) && name.indexOf('.') < 0 && !out.contains(name)) out.push(name);
			collectTypeNames(child, ctx, out);
		}
	}

	/**
	 * The create slice of the named typedef plus one rewrite slice per file holding an occurrence, or null when the module
	 * cannot be placed, already exists, or cannot be written. The occurrences are printed against an index that already
	 * holds the new module, so a same-package file needs no import and a shadowed name falls back to the full path.
	 */
	private static function slicesOf(
		plan: Plan, files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, index: Null<SymbolIndex>
	): Null<Array<CrossFileEdits>> {
		final known: SymbolIndex = index ?? IndexScope.report(files, plugin);
		final found: Null<String> = targetFileOf(plan, known);
		if (found == null || files.exists(f -> f.file == found)) return null;
		final target: String = found;
		final created: Null<String> = createdSource(plan, known, plugin);
		if (created == null) return null;
		// A host of its own, with no resolution scope: the new module exists only in `grown`, and the run's resolution index
		// (which cannot know it) would make the printer refuse the import it needs.
		final host: GrammarPlugin = new CachingGrammarPlugin(plugin);
		final grown: SymbolIndex = IndexScope.over(files.concat([{ file: target, source: created }]), host);
		final out: Array<CrossFileEdits> = [{ file: target, edits: [], create: created }];
		final done: Array<String> = [];
		for (hit in plan.hits) if (!done.contains(hit.file)) {
			done.push(hit.file);
			final slice: Null<CrossFileEdits> = rewriteOf(plan, hit, grown, host);
			if (slice == null) return null;
			out.push(slice);
		}
		return out;
	}

	/** Where the typedef's module goes: its package directories under the source root the first occurrence's file sits in. */
	private static function targetFileOf(plan: Plan, index: SymbolIndex): Null<String> {
		final first: Occurrence = plan.hits[0];
		final info: Null<FileInfo> = index.fileInfo(first.file);
		if (info == null) return null;
		final dir: String = Path.directory(first.file);
		final root: Null<String> = info.pkg == '' ? dir : ModuleMove.sourceRootOf(dir, info.pkg);
		if (root == null) return null;
		final pkg: String = packageOf(plan.named.path);
		final name: String = plan.named.path.substr(pkg == '' ? 0 : pkg.length + 1);
		return Path.join([
			root,
			pkg.split('.').join('/'),
			Path.withExtension(name, Path.extension(first.file))
		]);
	}

	/** The package part of a dotted type path, empty for a root-package type. */
	private static function packageOf(path: String): String {
		final cut: Int = path.lastIndexOf('.');
		return cut < 0 ? '' : path.substr(0, cut);
	}

	/** The new module's source, built by `NewFile` (the backend of `new`) from the configured fields and the imports they need. */
	private static function createdSource(plan: Plan, index: SymbolIndex, plugin: GrammarPlugin): Null<String> {
		final pkg: String = packageOf(plan.named.path);
		final imports: Array<String> = importsFor(plan.hits[0], pkg, index, plugin);
		final built: NewFileResult = NewFile.create({
			className: plan.named.path.substr(pkg == '' ? 0 : pkg.length + 1),
			pkg: pkg,
			kind: 'typedef',
			fields: plan.named.spelled,
			bodiesRaw: imports.length == 0 ? null : '@@ imports\n${imports.join('\n')}'
		}, plugin);
		return switch built.result {
			case Ok(text, _): text;
			case Err(_): null;
		};
	}

	/** The import statements the structure of `hit` needs in package `pkg`: each type it names, as the file it sits in sees it. */
	private static function importsFor(hit: Occurrence, pkg: String, index: SymbolIndex, plugin: GrammarPlugin): Array<String> {
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		final written: Map<String, String> = provider == null ? [] : provider.importMap(hit.source, hit.file);
		final out: Array<String> = [];
		for (name in hit.typeNames) {
			var path: Null<String> = written[name];
			if (path == null) {
				final found: Array<{ file: FileInfo, type: TypeDeclInfo }> = index.resolveTypeRefsFrom(name, hit.file);
				if (found.length == 1 && found[0].file.pkg != '') path = ModuleScan.pathOfDecl(found[0].file, found[0].type);
			}
			if (path == null || packageOf(path) == pkg) continue;
			final statement: String = 'import $path;';
			out.pushUnique(statement);
		}
		return out;
	}

	/** The rewrite of every occurrence in `first`'s file to the typedef's name, with the import the printer decides it needs. */
	private static function rewriteOf(plan: Plan, first: Occurrence, index: SymbolIndex, plugin: GrammarPlugin): Null<CrossFileEdits> {
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, first.source);
		if (tree == null) return null;
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		final printer: TypeRefPrinter = TypeRefPrinter.forFile(
			first.file, first.source, tree, provider == null ? [] : provider.importMap(first.source, first.file), plugin, index
		);
		final printed: PrintedTypeRef = printer.print(plan.named.path);
		final edits: Array<{ span: Span, text: String }> = [
			for (hit in plan.hits) if (hit.file == first.file) { span: hit.at, text: printed.text }
		];
		edits.sort((a, b) -> a.span.from - b.span.from);
		return { file: first.file, edits: edits.concat(printer.pendingImportEdits().map(e -> { span: e.span, text: e.text })) };
	}

}
