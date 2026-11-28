package anyparse.check.haxe.expressions;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.OptionKeyed;
import anyparse.check.haxe.expressions.CompareFunctions.ConfigProblem;
import anyparse.check.haxe.expressions.CopyPairInference.InferredCopy;
import anyparse.check.scan.PurityScan;
import anyparse.grammar.json.JValue;
import anyparse.query.Constructs;
import anyparse.query.ElementSpan;
import anyparse.query.LexicalRegions;
import anyparse.query.ShapeVocab;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeSyntax.TypeSyntaxReader;

/** A type with a proven copy method, configured or inferred: its simple name, the fields a copy reads in order, and the method. */
private typedef Pair = {
	final path: String;
	final name: String;
	final fields: Array<String>;
	final copy: String;
	final key: String;
	final isFinal: Bool;
}

/**
 * A construction whose arguments all read one receiver: the span it
 * replaces, the type it names, the fields read, and the methods around it.
 */
private typedef Site = {
	final span: Span;
	final typeName: String;
	final fields: Array<String>;
	final args: Array<QueryNode>;
	final receiver: QueryNode;
	final receiverText: String;
	final enclosing: Array<String>;
}

private typedef Copy = { var span: Span; final site: Site; final pair: Pair; }

/** The pairs one config chain declares and the lines naming what is wrong with it. */
private typedef Pairs = { final pairs: Array<Pair>; final problems: Array<String>; }

private typedef Seams = {
	final newKind: String;
	final fieldAccessKind: String;
	final methodKinds: Array<String>;
	final opaqueKinds: Array<String>;
}

/**
 * Flags a hand copy through the constructor, `new Point(p.x, p.y)`, and rewrites it to the type's copy method,
 * `p.clone()`. `Severity.Info`, with an autofix. Off until the project enables it. The pair of constructor and copy method comes
 * from the type's own source (`CopyPairInference`) or, for a type that source does not prove, from the project's `apq.json`:
 *
 *     "prefer-copy-method": { "enabled": true, "types": { "pkg.Point": { "fields": ["x", "y"], "copy": "clone" } } }
 *
 * A type declared under `types` is read from there alone, never inferred.
 *
 * ## What a site must be
 *
 * - **The arguments are `v.<fields[i]>` in exactly that order and count**, over one receiver `v` spelled the same each time.
 *   An extra, missing, reordered or differently sourced argument is left alone.
 * - **`v` is exactly `T`** by the shared typer (`CheckScan.typeNominalResolver`): `new Point(sprite.x, sprite.y)` converts a
 *   position and is left alone, as is a `Dynamic`, a `Null<T>` or a subtype. The constructor names the configured type
 *   itself, resolved through the file's imports.
 * - **Everything read is pure** (`PurityScan`): `v` and each field are read once on the left and not at all on the right, so
 *   a call or a getter among them would be dropped.
 * - **No subtype overrides the copy method.** A virtual `clone` of a subtype yields the subtype, `new T` yields exactly `T`.
 *   The question is asked of the widest index the project declared (`IndexScope.widestScopeIndex`); a hierarchy the index
 *   cannot resolve is no proof and refuses, except for a final class, which has no subtype at all.
 * - **The type's simple name is declared once in the index.** The typer answers by simple name, so with a second
 *   declaration of it a receiver cannot be told from the configured type and the rule refuses. A same-named type outside the
 *   index is not seen.
 * - **The site is outside any method of the copy method's name**, which would call itself.
 * - **No comment inside the replaced text.**
 *
 * ## Option
 *
 * `types` maps the qualified path of a type to `fields` (the constructor arguments, each read off the copied value) and
 * `copy` (the name of its public instance method with no parameters returning `T`, or unannotated). A type the resolution
 * index cannot find or finds twice, a private one, or a copy method that is not exactly that is a configuration error that
 * stops the rule on the files it governs.
 *
 * ## Grammar-agnostic
 *
 * Driven by `newExprKind`, `fieldAccessKind` and the member kinds; a plugin without type information makes the rule a no-op.
 */
@:nullSafety(Strict)
final class PreferCopyMethod extends HaxeRule implements DefaultOff implements ConfigAware implements OptionKeyed {

	private static inline final RULE_ID: String = 'prefer-copy-method';
	private static final OPTION_TYPES: String = 'types';
	private static final KEY_FIELDS: String = 'fields';
	private static final KEY_COPY: String = 'copy';

	/** The linter's per-file config resolver, or null to read each file's chain from disk. */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(RULE_ID, 'a hand copy through the constructor that the type\'s copy method already makes', RuleCategory.Expressions);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function acceptedOptions(): Array<String> {
		return [OPTION_TYPES];
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		final problems: Array<ConfigProblem> = [];
		final found: Array<Violation> = RunScan.collectWith(files, plugin, readSeams(plugin), (entry, tree, seams, out) -> {
			final sites: Array<Site> = candidates(tree, entry.source, ElementSpan.lazyRegions(entry.source, plugin), seams);
			if (sites.length == 0) return;
			final declared: Pairs = pairsOf(entry.file, plugin, index);
			// A broken declaration stops the rule on the files it governs: a fix would otherwise rewrite on a pair nobody proved.
			final enabled: Bool = Linter.enabledBy(LintConfig.resolveWith(_resolveConfig, entry.file), this);
			for (message in declared.problems) CompareFunctions.anchorProblem(problems, message, entry.file, enabled);
			if (declared.problems.length > 0) return;
			for (c in proved(sites, declared.pairs, tree, entry.file, entry.source, plugin, index())) out.push({
				file: entry.file,
				span: c.site.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'this copy of ${c.pair.name} is ${c.site.receiverText}.${c.pair.copy}()',
				remedy: c.pair.path
			});
		});
		return found.concat(CompareFunctions.problemViolations(problems, RULE_ID));
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		// A configuration error has no site to fix: said here, or `--fix`, which lists no findings, would never mention it.
		for (v in violations) if (v.span == null) v.declineReason = v.message;
		final build: Null<Constructs> = plugin.constructs();
		return RunScan.matchedEdits(
			plugin, source, readSeams(plugin), violations.filter(v -> v.span != null), index, (tree, seams, symbols, file) -> {
				final declared: Pairs = pairsOf(file, plugin, symbols);
				return declared.problems.length > 0
					? []
					: proved(
						candidates(tree, source, ElementSpan.lazyRegions(source, plugin), seams), declared.pairs, tree, file, source,
						plugin, symbols()
					);
			},
			c -> {
				final copy: Null<Built> = copyCall(build, source, c.site.receiver, c.pair.copy);
				return copy == null ? [] : [{ span: c.span, text: copy.text }];
			}
		);
	}

	private function pairsOf(file: String, plugin: GrammarPlugin, index: () -> Null<SymbolIndex>): Pairs {
		final option: Null<JValue> = LintConfig.resolveWith(_resolveConfig, file).jsonOption(RULE_ID, OPTION_TYPES);
		return readPairs(option, plugin, index);
	}

	private static function readPairs(option: Null<JValue>, plugin: GrammarPlugin, index: () -> Null<SymbolIndex>): Pairs {
		final out: Pairs = { pairs: [], problems: [] };
		if (option == null) return out;
		final methods: Array<String> = ShapeVocab.methodDeclKinds(plugin.refShape());
		switch option {
			case JObject(entries):
				for (entry in entries) readPair(entry.key, entry.value, methods, plugin.typeSyntax, index, out);
			case _:
				out.problems.push('$OPTION_TYPES is not an object of a qualified type path to its fields and copy method');
		}
		return out;
	}

	private static function readPair(
		path: String, value: JValue, methods: Array<String>, typeSyntax: TypeSyntaxReader, index: () -> Null<SymbolIndex>, out: Pairs
	): Void {
		final label: String = '$OPTION_TYPES.$path';
		var fields: Null<Array<String>> = null;
		var copy: Null<String> = null;
		switch value {
			case JObject(entries):
				for (e in entries) {
					final key: String = e.key;
					switch e.value {
						case JArray(items) if (key == KEY_FIELDS): fields = [
							for (item in items)
								switch item {
									case JString(name): name;
									case _: '';
								}
						];
						case JString(name) if (key == KEY_COPY): copy = name;
						case _: out.problems.push('$label: "$key" is not $KEY_FIELDS (an array of names) or $KEY_COPY (a name)');
					}
				}
			case _:
				out.problems.push('$label is not an object with $KEY_FIELDS and $KEY_COPY');
				return;
		}
		if (fields == null || fields.length == 0 || fields.contains('') || copy == null || copy == '') {
			out.problems.push('$label needs $KEY_FIELDS, a non-empty array of names, and $KEY_COPY, the name of a method');
			return;
		}
		final read: Array<String> = fields;
		final method: String = copy;
		final idx: Null<SymbolIndex> = index();
		final types: Array<ResolvedType> = idx == null ? [] : idx.refs.resolveQualifiedRefAll(path);
		if (types.length != 1) {
			out.problems.push(
				types.length == 0
					? '$label: "$path" names no type: the resolution index declares no "$path"'
					: '$label: "$path" is ambiguous: it names ${types.length} types in the resolution index'
			);
			return;
		}
		final type: ResolvedType = types[0];
		final name: String = type.type.name;
		if (idx == null || type.type.isPrivate) {
			out.problems.push('$label: "$path" is a private type, which no other file can construct');
			return;
		}
		final found: Array<MemberInfo> = type.type.members.filter(m -> m.name == method);
		if (found.length != 1 || !CopyPairInference.isCopyOf(found[0], name, methods, typeSyntax)) {
			out.problems.push('$label: "$path" has no one public instance method $method() returning $name');
			return;
		}
		out.pairs.push({
			path: path,
			name: name,
			fields: read,
			copy: method,
			key: idx.refs.seenKey(type),
			isFinal: type.type.isFinal
		});
	}

	private static function candidates(tree: QueryNode, source: String, regions: () -> Array<LexRegion>, s: Seams): Array<Site> {
		final out: Array<Site> = [];
		final enclosing: Array<String> = [];
		function walk(node: QueryNode): Void {
			if (s.opaqueKinds.contains(node.kind)) return;
			final site: Null<Site> = siteAt(node, source, regions, s, enclosing);
			if (site != null) out.push(site);
			final method: Bool = s.methodKinds.contains(node.kind) && node.name != null;
			if (method) enclosing.push(node.name ?? '');
			for (c in node.children) walk(c);
			if (method) enclosing.pop();
		}
		walk(tree);
		return out;
	}

	private static function siteAt(
		node: QueryNode, source: String, regions: () -> Array<LexRegion>, s: Seams, enclosing: Array<String>
	): Null<Site> {
		final span: Null<Span> = node.span;
		final typeName: Null<String> = node.name;
		if (node.kind != s.newKind || span == null || typeName == null || node.children.length == 0) return null;
		final fields: Array<String> = [];
		var receiver: Null<QueryNode> = null;
		var text: Null<String> = null;
		for (arg in node.children) {
			final read: Null<QueryNode> = arg.children[0];
			final readSpan: Null<Span> = read?.span;
			final name: Null<String> = arg.name;
			if (arg.kind != s.fieldAccessKind || arg.children.length != 1 || read == null || readSpan == null || name == null) return null;
			final spelled: String = source.substring(readSpan.from, readSpan.to);
			if (text != null && spelled != text) return null;
			receiver = read;
			text = spelled;
			fields.push(name);
		}
		return receiver == null || text == null || LexicalRegions.commentIntersects(span.from, span.to, regions()) ? null : {
			span: span,
			typeName: typeName,
			fields: fields,
			args: node.children,
			receiver: receiver,
			receiverText: text,
			enclosing: enclosing.copy()
		};
	}

	private static function proved(
		sites: Array<Site>, pairs: Array<Pair>, tree: QueryNode, file: String, source: String, plugin: GrammarPlugin,
		index: Null<SymbolIndex>
	): Array<Copy> {
		if (index == null) return [];
		final home: Null<FileInfo> = index.refs.fileNamed(file);
		final purity: Null<PurityCtx> = PurityScan.contextOf(plugin, source, tree, index, file);
		final nominal: Null<(QueryNode) -> Null<String>> = CheckScan.typeNominalResolver(source, plugin, tree, file, index);
		if (home == null || purity == null || nominal == null) return [];
		final widest: Null<SymbolIndex> = IndexScope.widestScopeIndex(plugin, index);
		final refused: Map<String, Bool> = [];
		final inferred: Map<String, Null<Pair>> = [];
		final out: Array<Copy> = [];
		for (site in sites) {
			final pair: Null<Pair> = pairFor(site, pairs, inferred, plugin, index, home);
			if (pair == null || site.enclosing.contains(pair.copy) || nominal(site.receiver) != pair.name) continue;
			if (!site.args.foreach(arg -> PurityScan.isPure(arg, purity))) continue;
			if (!refused.exists(pair.key)) refused[pair.key] = refuses(index, widest, pair);
			final chosen: Pair = pair;
			if (refused[chosen.key] != true) out.push({ span: site.span, site: site, pair: chosen });
		}
		return out;
	}

	/** The configured pair the site copies by, else the pair the type's own source proves; a configured type is never inferred. */
	private static function pairFor(
		site: Site, pairs: Array<Pair>, inferred: Map<String, Null<Pair>>, plugin: GrammarPlugin, index: SymbolIndex, home: FileInfo
	): Null<Pair> {
		final configured: Null<Pair> = pairs.find(p -> p.fields.join(',') == site.fields.join(',') && namesPair(p, site, index, home));
		if (configured != null) return configured;
		final named: Null<ResolvedType> = index.refs.resolveTypeRef(site.typeName, home, site.span.from);
		if (named == null) return null;
		final key: String = index.refs.seenKey(named);
		if (pairs.exists(p -> p.key == key)) return null;
		if (!inferred.exists(key)) inferred[key] = inferredPair(named, key, plugin, index);
		final pair: Null<Pair> = inferred[key];
		return pair != null && pair.fields.join(',') == site.fields.join(',') ? pair : null;
	}

	private static function inferredPair(type: ResolvedType, key: String, plugin: GrammarPlugin, index: SymbolIndex): Null<Pair> {
		final proven: Null<InferredCopy> = CopyPairInference.of(type, plugin, index);
		final name: String = type.type.name;
		return proven == null ? null : {
			path: type.file.pkg == '' ? name : '${type.file.pkg}.$name',
			name: name,
			fields: proven.fields,
			copy: proven.copy,
			key: key,
			isFinal: type.type.isFinal
		};
	}

	/** Whether the type a construction names, read in its file, is the configured declaration itself. */
	private static function namesPair(pair: Pair, site: Site, index: SymbolIndex, home: FileInfo): Bool {
		final named: Null<ResolvedType> = index.refs.resolveTypeRef(site.typeName, home, site.span.from);
		return named != null && index.refs.seenKey(named) == pair.key;
	}

	/**
	 * Whether no site of the pair may be rewritten: the simple name of the configured type declares more than one type in the
	 * index, so a receiver typed by that name cannot be told apart from the other; or a subtype may override the copy method,
	 * which a final type rules out.
	 */
	private static function refuses(index: SymbolIndex, widest: Null<SymbolIndex>, pair: Pair): Bool {
		return index.refs.onlyDeclaration(pair.name) == null || (!pair.isFinal && (widest == null || isOverridden(widest, pair)));
	}

	/** Whether a subtype may override the copy method; a hierarchy the index cannot resolve counts as yes. */
	private static function isOverridden(index: SymbolIndex, pair: Pair): Bool {
		final family: Null<Array<OverrideFamilyMember>> = index.subtypes.overrideFamilyOf(pair.name, pair.copy);
		return family == null || family.length > 0;
	}

	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final newKind: Null<String> = shape.newExprKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		return newKind == null || fieldAccessKind == null || !(plugin is TypeInfoProvider) ? null : {
			newKind: newKind,
			fieldAccessKind: fieldAccessKind,
			methodKinds: ShapeVocab.methodDeclKinds(shape),
			opaqueKinds: shape.opaqueKinds ?? []
		};
	}

	/** The call of `method` on `receiver` as `source` spells it, built by the grammar; null when it builds none. */
	private static function copyCall(build: Null<Constructs>, source: String, receiver: QueryNode, method: String): Null<Built> {
		final span: Null<Span> = receiver.span;
		if (build == null || span == null) return null;
		final owner: Null<Built> = build.copied(source, span, Expression);
		final callee: Null<Built> = owner == null ? null : build.qualified(owner, method);
		return callee == null ? null : build.call(callee, []);
	}

}
