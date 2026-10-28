package anyparse.check;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.LintConfig.RuleConfig;
import anyparse.check.LintConfig.RuleSwitches;
import anyparse.check.config.ApqLintConfig;
import anyparse.check.config.ApqLintConfigParser;
import anyparse.check.config.OwnedTypesDeclaration;
import anyparse.check.oracle.OracleDeclaration;
import anyparse.grammar.json.JValue;
import anyparse.query.NamingPolicy.FrameworkContract;
import haxe.Exception;
import haxe.io.Path;

/**
 * One `apqlint.json` document as DECLARED (`LintDocument`): read off its JSON, folded over the
 * documents above it, and finished into the `LintConfig` the rules ask.
 *
 * Its own module rather than more of `LintConfig` because the two hold different things: that
 * class is the finished config every rule queries, this one is the pipeline that produces it,
 * the place where "the document did not say" is still distinguishable from "the document said the
 * default". `LintConfig.discover` / `parse` stay the doors; the key readers beside it
 * (`OracleDeclaration`, `OwnedTypesDeclaration`, `RuleDeclaration`) share the per-entry-lenient
 * helpers here.
 */
@:nullSafety(Strict)
final class LintDocuments {

	/**
	 * Append every `JString` of `items` to `out`, dropping any other element
	 * — the loop `stringListOption` runs one level up, shared with it.
	 *
	 * Public for `OracleDeclaration`, which reads a list of defines off the same per-entry-lenient
	 * contract and must not answer a wrong-typed element differently from the rest of this reader.
	 */
	public static function collectStrings(items: Array<JValue>, out: Array<String>): Void {
		for (item in items) switch item {
			case JString(v):
				out.push(v);
			case _:
		}
	}

	/**
	 * Resolve a config-relative path (a `resolutionRoots` entry, the `compilerOracle` hxml) to
	 * absolute against the config dir; an absolute path (or one parsed without a base) is kept as-is.
	 *
	 * Public for `OracleDeclaration`: every path a document declares is resolved against the
	 * directory of THAT document, and one reader spelling it differently is how a nested config's
	 * oracle would come to point somewhere else.
	 */
	public static function resolveAgainstConfigDir(baseDir: Null<String>, path: String): String {
		return baseDir == null || Path.isAbsolute(path) ? path : Path.normalize(Path.join([baseDir, path]));
	}

	/**
	 * `near` layered over `far` — the nearer document's declared keys win, and every
	 * key it did not name falls through. A `compilerOracle` list replaces wholesale like
	 * every other array: each element carries its own compile directory and defines, so a
	 * document that names its own oracles can no longer inherit a directory belonging to
	 * somebody else's hxml. `reachConfigurationsComplete` is a claim about one such list, so a document naming its own
	 * list claims nothing about it until it says so. Enablement is the one key not
	 * folded: each document's switches are kept, nearest first (`LintDocument.switches`).
	 */
	public static function mergeDocuments(near: LintDocument, far: LintDocument): LintDocument {
		final rules: Map<String, RuleConfig> = [];
		for (id => rc in far.rules) rules[id] = rc;
		for (id => rc in near.rules) rules[id] = mergeRule(rc, far.rules[id]);
		return {
			rules: rules,
			switches: near.switches.concat(far.switches),
			compilerOracles: near.compilerOracles ?? far.compilerOracles,
			compilerOracleServer: near.compilerOracleServer ?? far.compilerOracleServer,
			reachConfigurationsComplete: near.reachConfigurationsComplete ?? (
				near.compilerOracles == null ? far.reachConfigurationsComplete : null
			),
			reflectiveClasses: near.reflectiveClasses ?? far.reflectiveClasses,
			reflectiveMethodHolders: near.reflectiveMethodHolders ?? far.reflectiveMethodHolders,
			resolutionRoots: near.resolutionRoots ?? far.resolutionRoots,
			resolutionLibs: near.resolutionLibs ?? far.resolutionLibs,
			resolutionStd: near.resolutionStd ?? far.resolutionStd,
			languageVersion: near.languageVersion ?? far.languageVersion,
			frameworks: near.frameworks ?? far.frameworks,
			reportSummaryThreshold: near.reportSummaryThreshold ?? far.reportSummaryThreshold,
			ownedTypes: near.ownedTypes ?? far.ownedTypes,
			drops: near.drops.concat(far.drops)
		};
	}

	/** The finished config for a folded document — the one place the "absent" nulls collapse into the defaults. */
	public static function fromDocument(doc: LintDocument): LintConfig {
		return new LintConfig(
			doc.rules, doc.compilerOracles, doc.resolutionRoots, doc.resolutionLibs, doc.resolutionStd, doc.compilerOracleServer,
			doc.languageVersion, doc.frameworks, doc.drops, doc.reachConfigurationsComplete, doc.reportSummaryThreshold,
			doc.reflectiveClasses, doc.reflectiveMethodHolders, doc.ownedTypes, doc.switches
		);
	}

	/**
	 * The typed parse and mapping of ONE `apqlint.json` document, or null when the
	 * schema rejects it. Stops at `LintDocument` rather than at `LintConfig` so a
	 * caller folding a chain can still tell an unsaid key from a defaulted one, and
	 * so every relative path is resolved here — against THIS document's directory,
	 * the only place that knows it. `parse` folds the null into the silent empty
	 * config (it cannot tell a probe from a real config file, so it never prints);
	 * `discover` turns the same null into the user-facing diagnostic, because it
	 * knows the file path.
	 */
	public static function parseDocument(content: String, ?baseDir: String): Null<LintDocument> {
		final config: Null<ApqLintConfig> = try ApqLintConfigParser.parse(content) catch (exception: Exception) null;
		if (config == null) return null;
		final drops: Array<String> = [];
		final rules: Map<String, RuleConfig> = [];
		final declared: Null<Map<String, JValue>> = config.rules;
		if (declared != null) for (id => raw in declared) {
			final rule: Null<RuleConfig> = parseRule(raw);
			if (rule != null)
				rules[id] = rule;
			else
				drops.push('rules "$id" is neither true, false nor an object of options — ignored');
		}
		final declaredCategories: Null<Map<String, JValue>> = config.categories;
		final switches: RuleSwitches = {
			rules: [for (id => rule in rules) id => rule.enabled == true],
			categories: declaredCategories == null ? [] : parseCategories(declaredCategories, drops)
		};
		final declaredOracle: Null<JValue> = config.compilerOracle;
		final oracles: Null<Array<OracleConfig>> = declaredOracle == null ? null : OracleDeclaration.read(declaredOracle, baseDir, drops);
		final declaredRoots: Null<Array<String>> = config.resolutionRoots;
		// Absence has to survive the mapping: `null` is "this document said nothing about
		// roots, ask the one above", where `[]` is "this document declares none". Collapsing
		// the two here is what would make an inheriting document silently claim an empty scope.
		final roots: Null<Array<String>> = declaredRoots?.map(resolveAgainstConfigDir.bind(baseDir));
		final declaredFrameworks: Null<Array<JValue>> = config.frameworks;
		final frameworks: Null<Array<FrameworkContract>> = declaredFrameworks == null ? null : parseFrameworks(declaredFrameworks, drops);
		final declaredOwnership: Null<Array<JValue>> = config.ownedTypes;
		final ownedTypes: Null<Array<TypeOwnership>> = declaredOwnership == null
			? null
			: OwnedTypesDeclaration.read(declaredOwnership, drops);
		return {
			rules: rules,
			switches: [switches],
			compilerOracles: oracles,
			compilerOracleServer: config.compilerOracleServer,
			reachConfigurationsComplete: config.reachConfigurationsComplete,
			reflectiveClasses: config.reflectiveClasses,
			reflectiveMethodHolders: config.reflectiveMethodHolders,
			resolutionRoots: roots,
			resolutionLibs: config.resolutionLibs,
			resolutionStd: config.resolutionStd,
			languageVersion: config.languageVersion,
			frameworks: frameworks,
			reportSummaryThreshold: config.reportSummaryThreshold,
			ownedTypes: ownedTypes,
			inherit: config.inherit,
			drops: drops
		};
	}

	/** `parseDocument`, answered from `memo` when the same content was parsed against the same directory before. */
	public static function parseDocumentIn(memo: Null<DocumentMemo>, content: String, ?baseDir: String): Null<LintDocument> {
		if (memo == null) return parseDocument(content, baseDir);
		final key: String = '${baseDir ?? ''}\n$content';
		if (memo.exists(key)) return memo[key];
		final doc: Null<LintDocument> = parseDocument(content, baseDir);
		memo[key] = doc;
		return doc;
	}

	/** The configs `resolve` hands `files`, each once (by identity), in the order of the first file that names it. */
	public static function distinctConfigs(files: Array<String>, resolve: (String) -> LintConfig): Array<LintConfig> {
		final configs: Array<LintConfig> = [];
		for (file in files) {
			final config: LintConfig = resolve(file);
			if (!configs.contains(config)) configs.push(config);
		}
		return configs;
	}

	/**
	 * One rule entry layered over the ancestor's entry of the same id: `enabled` and
	 * `severity` fall through when the nearer document leaves them unsaid, and the
	 * option bags merge per key. So a nested `{"oversized-type": {"maxMembers": 100}}`
	 * raises exactly that threshold and changes nothing else about the rule.
	 */
	private static function mergeRule(near: RuleConfig, far: Null<RuleConfig>): RuleConfig {
		if (far == null) return near;
		final props: Map<String, JValue> = [];
		for (key => value in far.props) props[key] = value;
		for (key => value in near.props) props[key] = value;
		return { enabled: near.enabled ?? far.enabled, severity: near.severity ?? far.severity, props: props };
	}

	/**
	 * One `rules` entry → its `RuleConfig`, or null when the value is not an entry at all. `true` / `false` is the
	 * shorthand for `{"enabled": …}`; an object enables the rule unless it says `enabled` itself, lifts `severity` (resolved
	 * through `Severity.fromName`, an unknown label yielding no override) and keeps every other key in `props` verbatim for the
	 * owning check to read. A string is reserved for a severity shorthand and is no entry yet.
	 */
	private static function parseRule(raw: JValue): Null<RuleConfig> {
		return switch raw {
			case JBool(v):
				{ enabled: v, props: [] };
			case JObject(entries):
				var enabled: Null<Bool> = null;
				var severity: Null<Severity> = null;
				final props: Map<String, JValue> = [];
				for (entry in entries) {
					final key: String = entry.key;
					final value: JValue = entry.value;
					switch [key, value] {
						case ['enabled', JBool(v)]:
							enabled = v;
						case ['severity', JString(v)]:
							severity = Severity.fromName(v);
						case _:
							props[key] = value;
					}
				}
				{ enabled: enabled ?? true, severity: severity, props: props };
			case _: null;
		};
	}

	/**
	 * The `frameworks` entries → their `FrameworkContract`s. An entry that is not an object, names no
	 * `root`, or reaches no name at all is dropped: a contract with no root can be tested against no
	 * type and one that names nothing nominates nothing, so keeping either would be a half-applied
	 * declaration the project could not tell from a working one. Per-ENTRY leniency, like `rules` — the
	 * whole-document rejection stays the schema's job.
	 *
	 * But a dropped entry that says NOTHING is indistinguishable from one that works, so every drop
	 * appends a diagnostic line to `drops`, which `discover` prints once per config file.
	 */
	private static function parseFrameworks(raw: Null<Array<JValue>>, drops: Array<String>): Array<FrameworkContract> {
		if (raw == null) return [];
		final entries: Array<JValue> = raw;
		final out: Array<FrameworkContract> = [];
		for (i in 0...entries.length) switch entries[i] {
			case JObject(fields):
				var declaredRoot: Null<String> = null;
				final names: Array<String> = [];
				final prefixes: Array<String> = [];
				// `into`, not `out`: the enclosing `out` is the contract list, and a same-named
				// parameter here would shadow it for every reader of this block.
				inline function collect(key: String, items: Array<JValue>, into: Array<String>): Void {
					final before: Int = into.length;
					collectStrings(items, into);
					final skipped: Int = items.length - (into.length - before);
					if (skipped > 0) drops.push('frameworks[$i] "$key" ignored $skipped value(s) that are not strings');
				}
				// A wrong-SHAPED value was the last silence in this reader. The entry survives, the key
				// it declares simply is not there, and the surviving half reads as the whole:
				// `"names": "Start"` claimed nothing and said nothing, while `"root": ["X"]` fell
				// through to the no-root drop below, which then reported "declares no root" about an
				// entry that declares one. An unknown key is the same silence spelled as a typo —
				// `"name"` for `"names"` leaves an entry claiming only its prefixes.
				for (field in fields) switch [field.key, field.value] {
					case ['root', JString(v)]:
						declaredRoot = v;
					case ['names', JArray(items)]:
						collect(field.key, items, names);
					case ['prefixes', JArray(items)]:
						collect(field.key, items, prefixes);
					case ['root', _]:
						drops.push('frameworks[$i] "root" is not a string — ignored');
					case ['names', _], ['prefixes', _]:
						drops.push('frameworks[$i] "${field.key}" is not an array of strings — ignored');
					case _:
						drops.push('frameworks[$i] declares unknown key "${field.key}" — ignored');
				}
				final root: Null<String> = declaredRoot;
				if (root == null) {
					drops.push('frameworks[$i] declares no "root" — dropped');
					continue;
				}
				// Re-bound: strict null-safety does not carry a narrowed local into a structure literal.
				final rootName: String = root;
				// An EMPTY fragment would claim every method of every subtype, so a stray "" is dropped
				// here rather than read as a universal claim; an entry left with nothing then falls into
				// the drop below and says so.
				final claimedNames: Array<String> = names.filter(s -> s != '');
				final claimedPrefixes: Array<String> = prefixes.filter(s -> s != '');
				if (claimedNames.length == 0 && claimedPrefixes.length == 0) {
					drops.push('frameworks[$i] ("$rootName") declares neither "names" nor "prefixes" — dropped');
					continue;
				}
				out.push({ root: rootName, names: claimedNames, prefixes: claimedPrefixes });
			case _:
				drops.push('frameworks[$i] is not an object — dropped');
		}
		return out;
	}

	/**
	 * The `categories` entries → the switch each names. Only a known `RuleCategory` id with a boolean is kept: an unknown
	 * id or any other value is dropped with a diagnostic naming it, since a misspelt category would otherwise switch
	 * nothing and say nothing.
	 */
	private static function parseCategories(declared: Map<String, JValue>, drops: Array<String>): Map<String, Bool> {
		final categories: Map<String, Bool> = [];
		for (id => raw in declared) switch [RuleCategory.fromId(id), raw] {
			case [null, _]:
				drops.push('categories declares unknown category "$id" (known: ${RuleCategory.ALL.join(', ')}) — ignored');
			case [_, JBool(on)]:
				categories[id] = on;
			case _:
				drops.push('categories "$id" is neither true nor false — ignored');
		}
		return categories;
	}

}

/**
 * `apqlint.json` documents already parsed in one run, keyed by directory and content (`LintDocuments.parseDocumentIn`),
 * null for content the schema rejects. Owned by a caller that resolves the chains of many directories and only READS
 * the documents — the oracle entries a lint run prepares are written in place, so a memo shared with that run's own
 * configs would hand one directory's prepared entries to another.
 */
typedef DocumentMemo = Map<String, Null<LintDocument>>;

/**
 * ONE `apqlint.json` document, as DECLARED — the intermediate a chain of them is
 * folded through before it becomes a `LintConfig`.
 *
 * Two things separate it from the finished config. Every key is optional, so
 * "the document did not say" stays distinguishable from "the document said the
 * default" — a merge has no other way to know whether a nearer document meant to
 * override. And every path is ALREADY resolved against the directory of the
 * document that declared it, so folding a chain never has to remember which
 * `apqlint.json` a relative `"../src"` was written next to.
 */
typedef LintDocument = {
	var rules: Map<String, RuleConfig>;

	/**
	 * What each folded document states about enablement, nearest first: one entry per document, never flattened, since
	 * the nearest document naming a rule OR its category decides it (`LintConfig.switchFor`).
	 */
	var switches: Array<RuleSwitches>;
	var ?compilerOracles: Array<OracleConfig>;
	var ?compilerOracleServer: Bool;
	var ?reachConfigurationsComplete: Bool;
	var ?reflectiveClasses: Array<String>;
	var ?reflectiveMethodHolders: Array<String>;
	var ?resolutionRoots: Array<String>;
	var ?resolutionLibs: Array<String>;
	var ?resolutionStd: Bool;
	var ?languageVersion: String;
	var ?frameworks: Array<FrameworkContract>;
	var ?reportSummaryThreshold: Int;
	var ?ownedTypes: Array<TypeOwnership>;

	/** Read off the document as PARSED, never off a merged one — a fold has already decided where the chain ends. */
	var ?inherit: Bool;
	var drops: Array<String>;
}
