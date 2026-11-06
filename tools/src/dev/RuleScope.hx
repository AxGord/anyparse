package dev;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import dev.SuiteImpact.DeclaredTypes;
import dev.SuiteImpact.ImpactSource;
import devkit.Args;
import devkit.RawJson;
import haxe.Exception;
import haxe.io.Path;

using Lambda;
using StringTools;

/**
 * The one answer to "which lint rules can this slice's diff move": `idsOf` follows the engine inputs the diff touches through the
 * sources that reach them (`SuiteImpact.dependents`) and answers the ids of the registered rules reached when all of that stays inside
 * `src/anyparse/check` and within a few rules, or null — the whole tree — for anything else. The `infra4` row then compares only those
 * rules, and `dev rule-scope <tree>` prints the same answer.
 */
@:nullSafety(Strict)
final class RuleScope {

	public static inline final USAGE: String = 'usage: dev rule-scope <tree> [--base <rev>]';

	/** The file whose `builtins` list instantiates every rule. */
	public static inline final REGISTRY: String = 'src/anyparse/check/Linter.hx';

	/** What `dev rule-scope` prints for a diff no rule list bounds. */
	public static inline final WHOLE: String = 'whole';

	private static inline final CHECK_DIR: String = 'src/anyparse/check/';
	private static inline final ENGINE_DIR: String = 'src/';

	/** The most rules a bounded answer names: past it a run of them costs what the whole tree does. */
	private static inline final MAX_RULES: Int = 40;

	private static final RULE_FILE: EReg = ~/^src\/anyparse\/check\/(?:common|haxe)\/(?:[A-Za-z0-9_]+\/)*([A-Z][A-Za-z0-9_]*)\.hx$/;
	private static final RULE_CLASS: EReg = ~/\bclass\s+[A-Z]\w*\s+extends\s+(?:RuleBase|HaxeRule)\b/;
	private static final SUPER_ID: EReg = ~/\bsuper\(\s*(?:'([a-z0-9-]+)'|([A-Z][A-Z0-9_]*)\b)/;
	private static final EMITTED: EReg = ~/\brule:\s*'([a-z0-9-]+)'/g;
	private static final INSTANTIATED: EReg = ~/\bnew\s+([A-Z]\w*)\(\)/;
	private static final REGISTRY_LINE: EReg = ~/^\s*(?:import\s+[\w.]+;|new\s+([A-Z]\w*)\(\),?|\/\/.*)\s*$/;

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final base: Null<String> = args.option('--base');
		final ids: Null<Array<String>> = answer(args.positionals(['<tree>'])[0], base);
		Sys.println(ids == null ? WHOLE : ids.join(','));
		return 0;
	}

	/** The rule ids the diff of `tree` against `base` (default `merge-base HEAD main`) can move, or null when it can move any. */
	public static function answer(tree: String, ?rev: String): Null<Array<String>> {
		if (GateTree.gitIn(tree, ['rev-parse', '--show-prefix']).trim() != '')
			throw new Exception('$tree is not the top of a git work tree');
		final base: String = rev ?? GateTree.gitIn(tree, ['merge-base', 'HEAD', 'main']).trim();
		return ofTree(tree, base, GateTree.touchedSince(tree, base).paths);
	}

	/**
	 * `idsOf` over the sources of `tree`, for the engine inputs `touched` names (rule code and
	 * everything else the engine is built from), the diff of the registry taken against `base`.
	 */
	public static function ofTree(tree: String, base: String, touched: Array<String>): Null<Array<String>> {
		final engine: Array<String> = touched.filter(GateTree.isEngineInput);
		if (engine.exists(path -> !path.endsWith('.hx'))) return null;
		final diff: Null<String> = engine.contains(REGISTRY) ? GateTree.gitIn(tree, ['diff', '-U0', base, '--', REGISTRY]) : null;
		return idsOf(SuiteImpact.sourcesOf(tree), engine, diff);
	}

	/**
	 * The ids of the rules a change of `touched` (paths in `sources`) can move, or null for the whole tree. The change is followed through
	 * `SuiteImpact.dependents`, the registry a sink; the answer is bounded only when everything reached in `src` lies in
	 * `src/anyparse/check`, none of it replaces another rule (`Supersedes`), every registered class reached is a rule class that spells
	 * its id, no reached helper is named by the registry beyond its `new`
	 * lines, and at most `MAX_RULES` rules are reached. The registry may
	 * be among `touched` only as `registryDiff` shows it gaining imports, comments and the `new` of a touched class.
	 */
	public static function idsOf(sources: Array<ImpactSource>, touched: Array<String>, registryDiff: Null<String>): Null<Array<String>> {
		if (touched.length == 0 || touched.exists(path -> !path.startsWith(CHECK_DIR))) return null;
		final declared: DeclaredTypes = SuiteImpact.declaredTypes(sources);
		if (declared.unparsed.exists(path -> path.startsWith(ENGINE_DIR))) return null;
		final texts: Map<String, String> = [for (s in sources) s.path => s.text];
		final registered: Array<String> = registeredIn(sources);
		final registry: String = registryRest(texts[REGISTRY] ?? '');
		final ids: Array<String> = [];
		for (path in SuiteImpact.reached(sources, touched, [REGISTRY], declared)) if (path.startsWith(ENGINE_DIR) && path != REGISTRY) {
			final own: Null<Array<String>> = reachedIds(path, texts[path] ?? '', declared.types[path] ?? [], registered, registry);
			if (own == null) return null;
			for (id in own) if (!ids.contains(id)) ids.push(id);
		}
		final created: Array<String> = touched.map(moduleOf);
		final registryOk: Bool = !touched.contains(REGISTRY) || gainsOnly(registryDiff, created);
		if (ids.length == 0 || ids.length > MAX_RULES || !registryOk) return null;
		ids.sort(Reflect.compare);
		return ids;
	}

	/** `report` (a `lint --format json` array) without the findings of every rule outside `ids`. */
	public static function keep(report: String, ids: Array<String>): String {
		return switch JValueParser.parse(report) {
			case JArray(records):
				RawJson.print(JArray([
					for (record in records) if (ids.contains(RawJson.stringAt(record, 'rule') ?? '')) record
				]), '  ');
			case _:
				report;
		}
	}

	/**
	 * The ids the rule class `file` answers for — its own and every rule
	 * id it writes into a finding — or null when it is no bounded rule.
	 */
	private static function idsOfRule(file: ImpactSource): Null<Array<String>> {
		if (!RULE_FILE.match(file.path) || !RULE_CLASS.match(file.text) || file.text.contains('Supersedes')) return null;
		if (!SUPER_ID.match(file.text)) return null;
		final literal: Null<String> = SUPER_ID.matched(1);
		final id: Null<String> = literal ?? constantValue(file.text, SUPER_ID.matched(2));
		if (id == null) return null;
		final ids: Array<String> = [id];
		var rest: String = file.text;
		while (EMITTED.match(rest)) {
			final emitted: String = EMITTED.matched(1);
			if (!ids.contains(emitted)) ids.push(emitted);
			rest = EMITTED.matchedRight();
		}
		return ids;
	}

	/** The string literal a `NAME: String = '…'` constant of `text` holds, or null. */
	private static function constantValue(text: String, name: Null<String>): Null<String> {
		if (name == null) return null;
		final declaration: EReg = new EReg('\\b$name\\s*:\\s*String\\s*=\\s*\'([a-z0-9-]+)\'', '');
		return declaration.match(text) ? declaration.matched(1) : null;
	}

	/** Whether the `-U0` diff `diff` of the registry only adds imports, comments and the `new` of a class in `classes`. */
	private static function gainsOnly(diff: Null<String>, classes: Array<String>): Bool {
		if (diff == null) return false;
		for (line in diff.split('\n')) if (
			!line.startsWith('+++') && !line.startsWith('---') && (line.startsWith('+') || line.startsWith('-'))
		) {
			if (line.startsWith('-') || !REGISTRY_LINE.match(line.substr(1))) return false;
			final created: Null<String> = REGISTRY_LINE.matched(1);
			if (created != null && !classes.contains(created)) return false;
		}
		return true;
	}

	/** The classes the registry in `engine` instantiates. */
	private static function registeredIn(engine: Array<ImpactSource>): Array<String> {
		final out: Array<String> = [];
		for (source in engine) if (source.path == REGISTRY) {
			var rest: String = source.text;
			while (INSTANTIATED.match(rest)) {
				out.push(INSTANTIATED.matched(1));
				rest = INSTANTIATED.matchedRight();
			}
		}
		return out;
	}

	private static function moduleOf(path: String): String {
		return Path.withoutExtension(Path.withoutDirectory(path));
	}

	/** The registry's text as a reader of other types: its comments dropped, and the lines that only list a rule. */
	private static function registryRest(text: String): String {
		return [
			for (line in SuiteImpact.uncommented(text).split('\n')) if (!REGISTRY_LINE.match(line)) line
		].join('\n');
	}

	/**
	 * The ids of the rules the reached file `path` (holding `text`, declaring `types`) stands for: its own for a registered rule class,
	 * none for a helper; null when it bounds nothing — outside the check package, replacing a rule, a rule that spells no id, or a
	 * helper the registry text `registry` names.
	 */
	private static function reachedIds(
		path: String, text: String, types: Array<String>, registered: Array<String>, registry: String
	): Null<Array<String>> {
		if (!path.startsWith(CHECK_DIR) || text.contains('Supersedes')) return null;
		final name: String = moduleOf(path);
		if (registered.contains(name)) return idsOfRule({ path: path, text: text });
		return types.concat([name]).exists(type -> SuiteImpact.names(registry, type)) ? null : [];
	}

}
