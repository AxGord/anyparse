package anyparse.check.common.design;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.CrossFileEdits;
import anyparse.check.Check.CrossFileFix;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.OptionKeyed;
import anyparse.check.Check.ScopeDependent;
import anyparse.check.LintConfig;
import anyparse.check.common.design.AnonTypeDup.AnonCtx;
import anyparse.check.common.design.AnonTypeDup.Occurrence;
import anyparse.check.common.design.AnonTypeDup.RewriteSite;
import anyparse.query.IndexScope;
import anyparse.query.ModuleScan;
import anyparse.query.ParseGate;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeRefPrinter;
import anyparse.query.Uses;
import anyparse.util.Compare;

using anyparse.util.Groups;

/**
 * One typedef whose right-hand side is an anonymous structure, as the tree shows it: `fields` the whitespace-free text of each
 * field sorted (field order is no part of the type), `typeNames` the simple type names it spells, `refusal` why it may not be
 * named from outside (null when nothing in the tree forbids it).
 */
private typedef RawAlias = {
	final file: String;
	final name: String;
	final key: String;
	final fields: String;
	final typeNames: Array<String>;
	final refusal: Null<String>;
};

/** A `RawAlias` read against the index: the module path an occurrence would write, what its type names denote, and its final refusal. */
private typedef Alias = {
	final raw: RawAlias;
	final path: String;
	final denotes: String;
	final refusal: Null<String>;
	final moduleOnly: Bool;
};

/** The kinds the walk of a module's typedefs reads from the grammar, resolved once per run. */
private typedef Seams = {
	final ctx: AnonCtx;
	final aliasKind: String;
	final leadKinds: Array<String>;
	final metaKinds: Array<String>;
	final conditionalKinds: Array<String>;
};

/**
 * The one answer to "which project typedef already names this anonymous structure type": an anonymous structure written out
 * where a typedef of the same structure exists is flagged and, when exactly one typedef has that structure, rewritten to the
 * typedef's name (with the import the printer decides). The name was chosen once; no configuration repeats it.
 *
 * ## Equal
 *
 * The structure and the typedef's right-hand side have the same fields (name, optionality, written type, in any order), and
 * every simple type name in them denotes the same declaration from the occurrence's file as from the typedef's
 * (`SymbolIndex.resolveTypeRefsFrom`) — the structural key alone compares simple names, so `{ a: Foo }` over two different
 * `Foo` would key alike. The fields are compared as written, so a nested structure with its fields in another order is a
 * miss, never a wrong rewrite. A typedef alias is the same type as its structure, so the rewrite changes no typing.
 *
 * ## Refused (reported, not fixed)
 *
 * Two or more typedefs equal to the structure (ambiguous); a typedef with metadata, under `#if`, with type parameters, or
 * private to another module, and one the file does not already see (its package, an import, a type its supertypes spell):
 * that match is by shape alone, and `acrossModules` restores the rewrite. The body of a typedef is never an occurrence. The
 * rule only sees the typedefs of the files of the run: lint the whole project.
 */
@:nullSafety(Strict)
final class PreferExistingTypedef extends RuleBase implements CrossFileFix implements DefaultOff implements ScopeDependent
		implements ConfigAware implements OptionKeyed {

	private static inline final RULE_ID: String = 'prefer-existing-typedef';
	private static final ACROSS_MODULES_KEY: String = 'acrossModules';

	/** The source of each file of the run, by path: what a supertype's module is read from. Rebuilt by every `run`. */
	private final _sources: Map<String, String> = [];

	/** The type-reference projection of each module a supertype check read, by path (null: unreadable). Rebuilt by every `run`. */
	private final _typeTrees: Map<String, Null<QueryNode>> = [];

	/** The rewrite of each fixable finding, keyed by its anchor (`file:from`): the typedef path it becomes. Rebuilt by every `run`. */
	private final _plans: Map<String, String> = [];

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(RULE_ID, 'an anonymous structure type that a project typedef already names', RuleCategory.Design);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function acceptedOptions(): Array<String> {
		return [ACROSS_MODULES_KEY];
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		_plans.clear();
		_sources.clear();
		_typeTrees.clear();
		final seams: Null<Seams> = seamsOf(plugin);
		if (seams == null || files.length == 0) return [];

		for (entry in files) _sources[entry.file] = entry.source;
		final groups: Map<String, Array<Occurrence>> = [];
		final order: Array<String> = [];
		final raws: Map<String, Array<RawAlias>> = [];
		var any: Bool = false;
		for (entry in files) {
			final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			AnonTypeDup.collect(tree, null, entry.file, entry.source, seams.ctx, 1, groups, order);
			for (raw in aliasesOf(tree, false, entry, seams)) {
				any = true;
				raws.push(raw.key, raw);
			}
		}
		if (!any) return [];
		final index: SymbolIndex = IndexScope.resolution(files, plugin);
		final out: Array<Violation> = [];
		final scopes: Map<String, Map<String, Array<Span>>> = [];
		for (key in order) {
			final candidates: Null<Array<RawAlias>> = raws[key];
			final hits: Null<Array<Occurrence>> = groups[key];
			if (candidates == null || hits == null) continue;
			final aliases: Array<Alias> = candidates.map(raw -> aliasOf(raw, index));
			for (hit in hits) judge(hit, aliases, index, plugin, scopes, out);
		}
		return withoutNested(out);
	}

	/** The per-file seam has nothing to say: the typedef usually sits in another file than the structure it names. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** One atomic group per file holding a fixable finding: every structure of it rewritten, with the imports the file needs. */
	public function crossFileFix(
		files: Array<{ file: String, source: String }>, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<Array<CrossFileEdits>> {
		final sites: Map<String, Array<RewriteSite>> = [];
		final order: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final at: Span = span;
			final planned: Null<String> = _plans['${v.file}:${at.from}'];
			if (planned == null) continue;
			final path: String = planned;
			if (!sites.exists(v.file)) order.push(v.file);
			sites.push(v.file, { span: at, path: path });
		}
		final known: SymbolIndex = index ?? IndexScope.report(files, plugin);
		final out: Array<Array<CrossFileEdits>> = [];
		for (file in order) {
			final entry: Null<{ file: String, source: String }> = files.find(f -> f.file == file);
			final bucket: Null<Array<RewriteSite>> = sites[file];
			final slice: Null<CrossFileEdits> = entry == null || bucket == null
				? null
				: AnonTypeDup.rewriteSites(file, entry.source, bucket, known, plugin);
			if (slice != null) out.push([slice]);
		}
		return out;
	}

	/** One finding for `hit` when a typedef equals it: fixable when exactly one does and nothing refuses it, else report-only. */
	private function judge(
		hit: Occurrence, aliases: Array<Alias>, index: SymbolIndex, plugin: GrammarPlugin, scopes: Map<String, Map<String, Array<Span>>>,
		out: Array<Violation>
	): Void {
		final fields: String = sortedFields(hit.fields);
		final denotes: String = denotesOf(hit.typeNames, hit.file, index);
		final equal: Array<Alias> = aliases.filter(a -> a.raw.fields == fields && a.denotes == denotes);
		if (equal.length == 0 || bindsAParameter(hit, plugin, scopes)) return;
		final only: Alias = equal[0];
		final refusal: Null<String> = if (equal.length > 1)
			'ambiguous: ${equal.map(a -> a.path).join(', ')} have this structure'
		else if (only.moduleOnly && only.raw.file != hit.file)
			'its typedef is private to ${only.raw.file}'
		else
			only.refusal;
		final byShape: Bool = refusal == null && !acrossModules(hit.file) && !visibleFrom(only, hit, index, plugin);
		final reason: Null<String> = byShape ? 'matches ${only.path} by shape; name it if it means the same thing' : refusal;
		out.push({
			file: hit.file,
			span: hit.at,
			rule: RULE_ID,
			severity: Severity.Info,
			message: reason == null
				? 'this structure is the typedef ${only.path} — write the name'
				: byShape ? 'this structure $reason' : 'this structure is the typedef ${only.path}, not rewritten: $reason',
			declineReason: reason
		});
		if (reason == null) _plans['${hit.file}:${hit.at.from}'] = only.path;
	}

	/** `acrossModules: true` restores the rewrite to a typedef the file does not already see. */
	private function acrossModules(file: String): Bool {
		return LintConfig.resolveWith(_resolveConfig, file).boolOption(RULE_ID, ACROSS_MODULES_KEY) ?? false;
	}

	/**
	 * Whether the typedef is one the hit's file already sees — its own package, an import, or the member type of a supertype
	 * (an implemented interface) that spells it — so naming it adds no coupling the file has not accepted.
	 */
	private function visibleFrom(alias: Alias, hit: Occurrence, index: SymbolIndex, plugin: GrammarPlugin): Bool {
		if (reaches(alias, hit.file, index, hit.at.from)) return true;
		final info: Null<FileInfo> = index.fileInfo(hit.file);
		if (info == null) return false;
		for (type in info.types)
			for (raw in type.supertypesRaw)
				for (found in index.resolveTypeRefsFrom(raw, hit.file))
					if (reaches(alias, found.file.file, index) && spells(alias.raw.name, found.file.file, plugin)) return true;
		return false;
	}

	/** Whether the module `file` writes the simple type `name` in a type position (the parallel type-reference projection). */
	private function spells(name: String, file: String, plugin: GrammarPlugin): Bool {
		if (!_typeTrees.exists(file)) {
			final source: Null<String> = _sources[file];
			_typeTrees[file] = source == null || ParseGate.parseOrNull(plugin, source) == null ? null : plugin.parseFileTypeRefs(source);
		}
		final tree: Null<QueryNode> = _typeTrees[file];
		return tree != null && Uses.find(name, tree, plugin.typeRefShape()).length > 0;
	}

	/**
	 * `found` without the fixable findings that sit inside another fixable one of their file: rewriting the outer structure
	 * replaces the inner, and two edits over one span would drop the whole file's group.
	 */
	private function withoutNested(found: Array<Violation>): Array<Violation> {
		final planned: Array<Violation> = found.filter(v -> _plans.exists(planKey(v)));
		final nested: Array<Violation> = planned.filter(v -> planned.exists(o -> o != v && o.file == v.file && covers(o.span, v.span)));
		for (v in nested) _plans.remove(planKey(v));
		return found.filter(v -> !nested.contains(v));
	}

	public static function sortedFields(fields: Array<String>): String {
		final sorted: Array<String> = fields.copy();
		sorted.sort(Compare.compareString);
		return sorted.join('\n');
	}

	/** What each simple name of `names` denotes from `file`, as one comparable text: equal only when every name binds alike. */
	public static function denotesOf(names: Array<String>, file: String, index: SymbolIndex): String {
		final parts: Array<String> = names.map(name -> '$name>${denotationOf(name, file, index)}');
		parts.sort(Compare.compareString);
		return parts.join(',');
	}

	/**
	 * Whether a type name the structure spells is a type parameter in scope where it is written (a class's or a function's): a
	 * parameter outranks every type of its name, so the typedef's own `Foo` would replace a parameter `Foo`. `memo` holds each
	 * file's parameter scopes, read once from the tree.
	 */
	public static function bindsAParameter(hit: Occurrence, plugin: GrammarPlugin, memo: Map<String, Map<String, Array<Span>>>): Bool {
		final known: Null<Map<String, Array<Span>>> = memo[hit.file];
		final scopes: Map<String, Array<Span>> = known ?? parameterScopes(hit, plugin, memo);
		final at: Int = hit.at.from;
		return hit.typeNames.exists(name -> (scopes[name] ?? []).exists(s -> s.from <= at && at < s.to));
	}

	/** Whether `file` binds the typedef's simple name to the typedef, or shares its package. */
	private static function reaches(alias: Alias, file: String, index: SymbolIndex, ?at: Int): Bool {
		final home: Null<FileInfo> = index.fileInfo(alias.raw.file);
		final here: Null<FileInfo> = index.fileInfo(file);
		if (home != null && here != null && home.pkg == here.pkg) return true;
		return index.resolveTypeRefsFrom(alias.raw.name, file, at)
			.find(f -> f.file.file == alias.raw.file && f.type.name == alias.raw.name) != null;
	}

	/** The structure-bodied typedefs of a module, `guarded` once the walk is inside a conditional region. */
	private static function aliasesOf(
		node: QueryNode, guarded: Bool, entry: { file: String, source: String }, seams: Seams
	): Array<RawAlias> {
		final out: Array<RawAlias> = [];
		final kids: Array<QueryNode> = node.children;
		for (i in 0...kids.length) {
			final kid: QueryNode = kids[i];
			if (kid.kind == seams.aliasKind) {
				final raw: Null<RawAlias> = rawAliasOf(kids, i, guarded, entry, seams);
				if (raw != null) out.push(raw);
			} else if (seams.conditionalKinds.contains(kid.kind)) {
				for (raw in aliasesOf(kid, true, entry, seams)) out.push(raw);
			}
		}
		return out;
	}

	private static function rawAliasOf(
		siblings: Array<QueryNode>, at: Int, guarded: Bool, entry: { file: String, source: String }, seams: Seams
	): Null<RawAlias> {
		final decl: QueryNode = siblings[at];
		final name: Null<String> = decl.name;
		if (name == null || decl.children.length != 1 || decl.children[0].kind != seams.ctx.anonKind) return null;
		final anon: QueryNode = decl.children[0];
		final key: Null<String> = AnonTypeDup.shapeKey(anon, seams.ctx, 1);
		if (key == null) return null;
		final typeNames: Array<String> = [];
		AnonTypeDup.collectTypeNames(anon, seams.ctx, typeNames);
		return {
			file: entry.file,
			name: name,
			key: key,
			fields: sortedFields(AnonTypeDup.fieldTexts(anon, entry.source)),
			typeNames: typeNames,
			refusal: guarded ? 'it is declared under a conditional' : carriesMeta(siblings, at, seams) ? 'it carries metadata' : null
		};
	}

	/** Whether an annotation sits in the run of annotations and modifiers right before `siblings[at]`. */
	private static function carriesMeta(siblings: Array<QueryNode>, at: Int, seams: Seams): Bool {
		var i: Int = at - 1;
		while (i >= 0 && seams.leadKinds.contains(siblings[i].kind)) {
			if (seams.metaKinds.contains(siblings[i].kind)) return true;
			i--;
		}
		return false;
	}

	/** `raw` read against `index`: its path, what its names denote, and the refusals only the index knows (type parameters, privacy). */
	private static function aliasOf(raw: RawAlias, index: SymbolIndex): Alias {
		final info: Null<FileInfo> = index.fileInfo(raw.file);
		final decl: Null<TypeDeclInfo> = info?.types.find(t -> t.name == raw.name);
		final path: String = info == null || decl == null ? raw.name : ModuleScan.pathOfDecl(info, decl);
		return {
			raw: raw,
			path: path,
			denotes: denotesOf(raw.typeNames, raw.file, index),
			refusal: raw.refusal ?? (
				if (decl == null)
					'the index does not hold it'
				else if (decl.typeParamArity > 0)
					'it has type parameters'
				else
					null
			),
			moduleOnly: decl != null && decl.isPrivate
		};
	}

	/** The declaration `name` binds from `file`: its path, empty when none in the index, unique to the file when ambiguous. */
	private static function denotationOf(name: String, file: String, index: SymbolIndex): String {
		final found: Array<{ file: FileInfo, type: TypeDeclInfo }> = index.resolveTypeRefsFrom(name, file);
		return switch found.length {
			case 0: '';
			case 1: ModuleScan.pathOfDecl(found[0].file, found[0].type);
			case _: '?$file';
		};
	}

	private static function seamsOf(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ctx: Null<AnonCtx> = AnonTypeDup.buildCtx(shape);
		final alias: Null<String> = shape.typeAliasDeclKind;
		if (ctx == null || alias == null) return null;
		final metaKinds: Array<String> = plugin.metaShape().metaKinds;
		final member: Null<String> = shape.conditionalMemberKind;
		return {
			ctx: ctx,
			aliasKind: alias,
			leadKinds: metaKinds.concat(shape.modifierOrderKinds ?? []),
			metaKinds: metaKinds,
			conditionalKinds: (shape.conditionalRegionKinds ?? []).concat(member == null ? [] : [member])
		};
	}

	private static function planKey(v: Violation): String {
		final span: Null<Span> = v.span;
		return '${v.file}:${span == null ? -1 : span.from}';
	}

	/** Whether `outer` holds `inner` and is not the same span. */
	private static function covers(outer: Null<Span>, inner: Null<Span>): Bool {
		return outer != null && inner != null && outer.from <= inner.from && inner.to <= outer.to
			&& (outer.from != inner.from || outer.to != inner.to);
	}

	private static function parameterScopes(
		hit: Occurrence, plugin: GrammarPlugin, memo: Map<String, Map<String, Array<Span>>>
	): Map<String, Array<Span>> {
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, hit.source);
		final scopes: Map<String, Array<Span>> = tree == null ? [] : TypeRefPrinter.typeParamScopesOf(hit.source, tree, plugin);
		memo[hit.file] = scopes;
		return scopes;
	}

}
