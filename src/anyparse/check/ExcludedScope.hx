package anyparse.check;

import anyparse.query.FileIdentity;
import anyparse.query.Glob;
import anyparse.query.ModuleScan;
import anyparse.query.ParseGate;
import anyparse.runtime.Span;
import haxe.io.Path;

using Lambda;

/** One top-level type of a file: the dotted paths it goes by and the span of its whole declaration. */
private typedef TopLevelType = { paths: Array<String>, span: Span };

/**
 * The one answer to "which findings does a rule's config scope out": the `excludePaths` and `excludeTypes` keys that
 * every rule's `apq.json` entry takes, read here and never by the rule.
 *
 * `excludePaths` are globs (`Glob.covers`: a file, a directory and everything below it, `*` / `**` / `?`), resolved
 * against the directory of the document that wrote them (`LintDocuments`, at parse), so a nested document's entry stays
 * relative to ITS directory. `excludeTypes` are dotted-name globs matched against the top-level type enclosing the
 * finding, spelled `pkg.Type` or, for a secondary type of a module, `pkg.Module.Type`.
 *
 * A scoped-out file is dropped from the rule's FINDINGS, never from its scan input: a cross-file rule still reads the
 * excluded file's references, so excluding a file cannot make what it uses look unused. A `CrossFileAnchored` rule is
 * steered off an excluded file when it picks the anchor (`Linter.reportableFor`), or the one finding would be dropped for
 * every other file too; `excludeTypes` is judged per finding and cannot steer an anchor, so it can still drop such a finding.
 */
@:nullSafety(Strict)
final class ExcludedScope {

	/** The path-scope key of a rule entry. */
	public static inline final PATHS_KEY: String = 'excludePaths';

	/** The type-scope key of a rule entry. */
	public static inline final TYPES_KEY: String = 'excludeTypes';

	/** Both scope keys: what a rule entry may carry whatever its rule declares. */
	public static final KEYS: Array<String> = [PATHS_KEY, TYPES_KEY];

	/** Whether the `excludePaths` of `rule` in `config` cover `file`. */
	public static function excludesFile(config: LintConfig, rule: String, file: String): Bool {
		final patterns: Array<String> = config.scopeList(rule, PATHS_KEY);
		if (patterns.length == 0) return false;
		final normal: String = Path.normalize(file);
		final real: String = FileIdentity.realPath(file);
		return patterns.exists(pattern -> Glob.covers(pattern, Path.isAbsolute(pattern) ? real : normal));
	}

	/**
	 * `violations` without the findings their rule's config scopes out: those in an excluded file, and those inside a
	 * top-level type an `excludeTypes` entry names. `files` are the sources the run read; a finding with no span or in a
	 * file that does not parse is judged by path alone.
	 */
	public static function without(
		violations: Array<Violation>, files: Array<{ file: String, source: String }>, plugin: GrammarPlugin,
		resolveConfig: (String) -> LintConfig
	): Array<Violation> {
		final sourceByFile: Map<String, String> = [ for (entry in files) entry.file => entry.source ];
		final typesByFile: Map<String, Array<TopLevelType>> = [];
		return violations.filter(violation -> {
			final config: LintConfig = resolveConfig(violation.file);
			if (excludesFile(config, violation.rule, violation.file)) return false;
			final patterns: Array<String> = config.scopeList(violation.rule, TYPES_KEY);
			final span: Null<Span> = violation.span;
			if (patterns.length == 0 || span == null) return true;
			final enclosing: Array<String> = enclosingTypePaths(typesByFile, sourceByFile, plugin, violation.file, span);
			!enclosing.exists(path -> patterns.exists(pattern -> Glob.qualifiedNames(pattern).match(path)));
		});
	}

	private static function enclosingTypePaths(
		cache: Map<String, Array<TopLevelType>>, sources: Map<String, String>, plugin: GrammarPlugin, file: String, span: Span
	): Array<String> {
		var declared: Null<Array<TopLevelType>> = cache[file];
		if (declared == null) {
			final source: Null<String> = sources[file];
			final tree: Null<QueryNode> = source == null ? null : ParseGate.parseOrNull(plugin, source);
			declared = tree == null ? [] : topLevelTypes(tree, file, plugin);
			cache[file] = declared;
		}
		for (entry in declared) if (entry.span.from <= span.from && span.to <= entry.span.to) return entry.paths;
		return [];
	}

	private static function topLevelTypes(root: QueryNode, file: String, plugin: GrammarPlugin): Array<TopLevelType> {
		final out: Array<TopLevelType> = [];
		final pkg: String = ModuleScan.packageOf(root);
		final module: String = ModuleScan.moduleOf(root, file).path;
		collectOutermost(root, declKinds(plugin), node -> {
			final bounds: Null<Span> = node.span;
			final name: Null<String> = node.name;
			if (bounds != null && name != null) {
				final span: Span = bounds;
				out.push({ paths: [pkg == '' ? name : '$pkg.$name', '$module.$name'], span: span });
			}
		});
		return out;
	}

	private static function declKinds(plugin: GrammarPlugin): Array<String> {
		final shape: RefShape = plugin.refShape();
		final kinds: Array<String> = (shape.typeDeclKinds ?? []).copy();
		final enumAbstract: Null<String> = shape.enumAbstractDeclKind;
		if (enumAbstract != null) kinds.push(enumAbstract);
		return kinds;
	}

	private static function collectOutermost(node: QueryNode, kinds: Array<String>, visit: QueryNode -> Void): Void {
		for (child in node.children)
			if (kinds.contains(child.kind))
				visit(child)
			else
				collectOutermost(child, kinds, visit);
	}

}
