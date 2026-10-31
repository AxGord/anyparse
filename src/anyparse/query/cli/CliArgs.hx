package anyparse.query.cli;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.grammar.json.JsonQueryPlugin;
import anyparse.grammar.mermaid.MermaidQueryPlugin;
import anyparse.query.merge.StructuralMerge.MergeShape;
import anyparse.runtime.Span;

/**
 * The argument door of the `apq` CLI: everything that turns argv and the path
 * specs on it into the values a command actually runs on — one flag's value,
 * a `--limit`, a `<line>:<col>`, the grammar plugin `--lang` names, the
 * `hxformat.json` a file is governed by, and the expansion of a glob or
 * directory into the file list a walk visits.
 *
 * These are the members `hxq clusters` reports with the highest fan-in after
 * IO (`pickPlugin` first), for the obvious reason: every one of
 * the 69 commands parses arguments before it does anything. Reaching them from
 * outside `Cli` is what lets a command move onto the `CliCommand` registry
 * without dragging the whole god type behind it.
 *
 * Every member is a pure function of its arguments — no state, so a run holds
 * nothing that a second run in the same process could observe.
 */
@:nullSafety(Strict)
final class CliArgs {

	/** The maximum 32-bit signed integer — a null-span sort sentinel and the unbounded `--top` / `--all` count. */
	public static inline final MAX_INT: Int = 0x7FFFFFFF;

	/** The `--lang` of the JSON grammar plugin. */
	public static inline final JSON_LANG: String = JsonQueryPlugin.LANG;

	/** The `--lang` of the Mermaid flowchart grammar plugin. */
	public static inline final MERMAID_LANG: String = MermaidQueryPlugin.LANG;

	/**
	 * The nearest ancestor `hxformat.json` content for `filePath`, or null. Thin alias
	 * for `FormatConfigDiscovery.discover` — the CLI keeps the short local name its call sites use.
	 */
	public static inline function discoverFormatConfig(filePath: String): Null<String> {
		return FormatConfigDiscovery.discover(filePath);
	}

	/**
	 * The index of the bare `--` in `args`, or `-1` — the separator that turns a walker's
	 * leading positionals into a LIST of queries instead of one query plus scope specs.
	 *
	 * An INDEX rather than a flag, and computed up front, because the loop that consumes
	 * `args` has to know at the FIRST positional whether a separator is coming, and each
	 * later positional has to know which side of it it fell on. Argv already holds both
	 * answers; a running `afterSeparator` flag in every parser only copies them.
	 *
	 * Why a separator at all, rather than a "last positional is the scope" rule or a
	 * repeatable `--name`: `apq refs X src test` is a legal TWO-SCOPE call today, so
	 * reading the last positional as the scope would silently reinterpret it, and
	 * `--name A --name B` doubles the typing at exactly the call the batch exists for.
	 * A bare `--` occurs in no invocation that works today, so every existing form keeps
	 * its meaning byte for byte. One blind spot, inherited rather than introduced: this
	 * reads the RAW argv, so a `--` consumed as some flag's VALUE (`--lang --`) is still
	 * found here while the parse loop never reaches its separator arm.
	 */
	public static inline function nameSeparatorIndex(args: Array<String>): Int {
		return args.indexOf('--');
	}

	/** A fresh `PositionalScan` for `args`: an empty scope-spec accumulator and its separator index. */
	public static inline function beginPositionalScan(args: Array<String>): PositionalScan {
		return { inputSpecs: [], separator: nameSeparatorIndex(args) };
	}

	public static inline function stripQuotes(s: String): String {
		final t: String = s.trim();
		if (t.length < 2) return t;
		final first: String = t.charAt(0);
		final last: String = t.charAt(t.length - 1);
		return (first == "'" && last == "'") || (first == '"' && last == '"') ? t.substring(1, t.length - 1) : t;
	}

	/**
	 * A fresh `WalkerScan` for `args`: `--flat`/`--limit` at their defaults, an empty name
	 * and scope-spec accumulator, and the separator index.
	 */
	public static function beginWalkerScan(args: Array<String>): WalkerScan {
		return {
			flat: false,
			limit: -1,
			names: [],
			inputSpecs: [],
			separator: nameSeparatorIndex(args)
		};
	}

	/**
	 * Route one positional argument of a batch-capable walker into either the QUERY list
	 * or the SCOPE list, given its own `index` in argv and the `separator` index
	 * `nameSeparatorPresent` found (`-1` = none).
	 *
	 * With a separator every positional before it is a query and every one after it a
	 * scope spec; without one the grammar is the one that shipped — the FIRST positional
	 * is the query, every later one a scope spec.
	 *
	 * One member because four argument parsers (`refs`, `mentions`, `lit`, `declares`)
	 * ask the same question, and a fifth command gaining a batch form must inherit the
	 * rule rather than copy it — the copy is what `duplicate-code` reported across the
	 * first three. Taking the INDEX rather than a running `afterSeparator` flag also
	 * leaves the parsers with no batch state of their own: argv already knows.
	 */
	public static function routePositional(arg: String, index: Int, separator: Int, queries: Array<String>, specs: Array<String>): Void {
		if (separator >= 0)
			(index > separator ? specs : queries).push(arg);
		else if (queries.length == 0)
			queries.push(arg);
		else
			specs.push(arg);
	}

	/**
	 * Parse a `<line>:<col>` coordinate. Both components must be
	 * non-negative integers; returns null on any malformed shape so the
	 * caller emits a usage error rather than silently clamping.
	 */
	public static function parseLineCol(spec: String): Null<Position> {
		final colon: Int = spec.indexOf(':');
		if (colon <= 0 || colon >= spec.length - 1) return null;
		final line: Null<Int> = SourceText.parseStrictInt(spec.substring(0, colon));
		final col: Null<Int> = SourceText.parseStrictInt(spec.substring(colon + 1));
		return line == null || col == null ? null : { line: line, col: col };
	}

	/**
	 * Every CODE-grammar `--lang` the CLI can dispatch - the registry of
	 * plugins whose `RefShape` carries a code kind vocabulary, enumerable so a
	 * whole-registry check (`RefShapeKindProjectionTest`) covers a plugin added here without
	 * being taught its name. That test calls `pickPlugin` for every name here, so a name declared here and
	 * not constructed there fails the suite. `pickPlugin` builds from the whole registry (`grammars`),
	 * never gated on this list, so a plugin registered there is never refused for being absent here.
	 * The DATA grammars `json` (`JSON_LANG`) and `mermaid` (`MERMAID_LANG`) are registered there and
	 * deliberately absent: `json` declares only its two container kinds and the string kind and `mermaid`
	 * none, which the registry check's Haxe-sized floors would reject as a shrunken vocabulary;
	 * `JsonQueryPluginTest` and `MermaidQueryPluginTest` hold them against their own projections instead.
	 */
	public static function langNames(): Array<String> {
		return [HaxeQueryPlugin.LANG];
	}

	/**
	 * Every grammar the CLI can dispatch, each with the `--lang`, file extensions and content test its plugin
	 * declares — the ONE registry `pickPlugin`, `langOfFile` and `langOfContent` read, so a new grammar is a new
	 * row here and no extension is spelled anywhere else in the CLI. Built fresh per call: a shared
	 * registry would be process-scoped state (invariant 1).
	 */
	public static function grammars(): Array<GrammarEntry> {
		return [
			{
				lang: HaxeQueryPlugin.LANG,
				extensions: HaxeQueryPlugin.EXTENSIONS,
				recognises: null,
				make: HaxeQueryPlugin.new,
				merge: Declarations
			},
			{
				lang: JsonQueryPlugin.LANG,
				extensions: JsonQueryPlugin.EXTENSIONS,
				recognises: JsonQueryPlugin.recognises,
				make: JsonQueryPlugin.new,
				merge: Records
			},
			{
				lang: MermaidQueryPlugin.LANG,
				extensions: MermaidQueryPlugin.EXTENSIONS,
				recognises: null,
				make: MermaidQueryPlugin.new,
				merge: Declarations
			}
		];
	}

	public static function pickPlugin(lang: String): GrammarPlugin {
		return grammarOf(lang).make();
	}

	/**
	 * The `--lang` of the grammar whose declared extension `path` ends with (case-insensitive), or null when no
	 * registered grammar claims it.
	 */
	public static function langOfFile(path: String): Null<String> {
		final lower: String = path.toLowerCase();
		for (entry in grammars()) for (extension in entry.extensions) if (lower.endsWith(extension)) return entry.lang;
		return null;
	}

	/** The `--lang` of the one grammar whose content test accepts `text`, or null when none or several do. */
	public static function langOfContent(text: String): Null<String> {
		final langs: Array<String> = [
			for (entry in grammars()) {
				final recognises: Null<String -> Bool> = entry.recognises;
				if (recognises != null && recognises(text)) entry.lang;
			}
		];
		return langs.length == 1 ? langs[0] : null;
	}

	/**
	 * The plugin for the FILE at `path` (null: no file — source from `--code`
	 * / stdin): the grammar whose extension the file carries (`langOfFile`) whatever
	 * `lang` says, any other file `lang`'s (`pickPlugin`); `lang` itself must still
	 * name a registered grammar. The `hxq` shim prepends `--lang haxe` to every command, so the
	 * extension is the only signal an agent's `hxq add-element arms.json …` carries;
	 * an explicit `--lang json` reaches the same plugin through `pickPlugin`. The edit
	 * and read commands that work on a data grammar (`add-element`, `remove-element`,
	 * `replace-node`, `ast`, `source`) pick through here.
	 */
	public static function pickPluginFor(lang: String, path: Null<String>): GrammarPlugin {
		final named: GrammarEntry = grammarOf(lang);
		final ofFile: Null<String> = path == null ? null : langOfFile(path);
		return ofFile == null ? named.make() : pickPlugin(ofFile);
	}

	/**
	 * Resolve the new-code text for a writer-emit mutation op (`add-member`
	 * / `replace-node` / `add-element`) when it comes from somewhere other
	 * than the inline positional argument: a `--from-file <path>`, or stdin
	 * when the positional is the literal `-` (mirroring `apq probe -`). This
	 * is the quote-safe input path for code containing `$` or `'` that the
	 * shell would otherwise mangle as a positional argument. Called only
	 * when `fromFile != null` or `code == '-'`; returns the resolved text,
	 * or null after printing the reason to stderr (the caller then exits
	 * non-zero). `opName` names the op in those messages.
	 */
	public static function resolveCodeArg(
		opName: String, code: Null<String>, fromFile: Null<String>, stripTrailing: Bool = false
	): Null<String> {
		if (fromFile != null && code != null) {
			CliIo.stderr('apq $opName: provide the code inline, via --from-file, or as - for stdin — not more than one\n');
			return null;
		}
		if (fromFile != null) {
			try {
				return stripTrailing ? withoutTrailingNewline(CliIo.readFile(fromFile)) : CliIo.readFile(fromFile);
			} catch (exception: Exception) {
				CliIo.stderr('apq $opName: $fromFile: ${exception.message}\n');
				return null;
			}
		}
		// code == '-' → read the new code from stdin.
		try {
			return stripTrailing ? withoutTrailingNewline(CliIo.readStdin()) : CliIo.readStdin();
		} catch (exception: Exception) {
			CliIo.stderr('apq $opName: reading stdin: ${exception.message}\n');
			return null;
		}
	}

	/**
	 * Resolve the writer-config JSON for `path`. For a `.hxtest` input it
	 * auto-extracts section-1 (the harness's per-fixture config), returning
	 * `null` when the file lacks the canonical 3-section layout. For a
	 * normal `.hx` it falls back to project-config DISCOVERY — the first
	 * `hxformat.json` found walking up from the file's directory (see
	 * `discoverFormatConfig`), so `apq` formats a file by its project's own
	 * style. `null` (no `.hxtest` section, no discovered config) leaves the
	 * plugin on its compiled defaults. The result feeds
	 * `plugin.writeRoundTrip(source, optsJson)`.
	 */
	public static function readWriteOptionsJsonOrNull(path: String): Null<String> {
		if (!path.endsWith('.hxtest')) return discoverFormatConfig(path);
		final content: String = CliIo.readFile(path);
		final parts: Array<String> = content.split('\n---\n');
		if (parts.length != 3) return null;
		final section: String = parts[0];
		return section.length > 0 && section.charAt(section.length - 1) == '\n' ? section.substr(0, section.length - 1) : section;
	}

	/**
	 * Expand one-or-more file/dir/glob specs into a deduped path list,
	 * order-preserving. `singleFile` (parse-fail becomes a hard error,
	 * mirroring `apq ast`) holds only when exactly one spec was given
	 * and it resolved to exactly that one concrete file — multi-spec or
	 * glob/dir scans skip unparseable files silently.
	 *
	 * `unmatched` is every spec that expanded to NOTHING, in the order given. The union alone cannot
	 * answer for them: a spec naming a file that is not there disappears into it the moment any OTHER
	 * spec matched, and the run then analyses a scope that is silently short of what was asked for.
	 * The list is a fact about the arguments, so it is computed here and REPORTED by the caller that
	 * owns the arguments (`resolveInputPaths`) — this function stays free of output.
	 */
	public static function expandInputs(specs: Array<String>, ext: String): ExpandedInputs {
		final paths: Array<String> = [];
		final unmatched: Array<String> = [];
		for (spec in specs) {
			final hits: Array<String> = Glob.expand(spec, ext);
			if (hits.length == 0) unmatched.push(spec);
			for (p in hits) if (!paths.contains(p)) paths.push(p);
		}
		final singleFile: Bool = specs.length == 1 && paths.length == 1 && paths[0] == specs[0];
		return { paths: paths, singleFile: singleFile, unmatched: unmatched };
	}

	/** `--limit`'s value as a non-negative count; anything else throws a usage failure. */
	public static function parseLimit(v: String): Int {
		final n: Null<Int> = Std.parseInt(v);
		if (n == null || n < 0) throw new UsageFailure('--limit expects a non-negative integer, got "$v"');
		return n;
	}

	/** Whether a bare argument is a position spec (`<line>[:<col>]` — starts with a digit) rather than another positional. */
	public static function isPosSpec(s: String): Bool {
		if (s.length == 0) return false;
		final c: Int = s.fastCodeAt(0);
		return c >= '0'.code && c <= '9'.code;
	}

	/**
	 * Expand a --scope dir/glob and read every file plus the extras (the
	 * op's own files), reporting read failures; null aborts the op.
	 */
	public static function collectScopeFiles(
		cmd: String, scopeDir: String, extraFiles: Array<String>
	): Null<Array<{ file: String, source: String }>> {
		final expanded: ExpandedInputs = expandInputs([scopeDir], '.hx');
		final paths: Array<String> = expanded.paths;
		// An extra file the scope walk already holds under another spelling (absolute against a relative scope) takes that
		// entry's place: the caller looks its own spelling up, and a second entry would index the file twice.
		final keys: Array<String> = [for (path in paths) FileIdentity.realPath(path)];
		for (extra in extraFiles) {
			final at: Int = keys.indexOf(FileIdentity.realPath(extra));
			if (at < 0) {
				paths.push(extra);
				keys.push(FileIdentity.realPath(extra));
			} else {
				paths[at] = extra;
			}
		}
		return ([
			for (path in paths)
				{
					file: path,
					source: (try {
						CliIo.readSourceForParse(path);
					} catch (exception: Exception) {
						CliIo.stderr('apq $cmd: $path: ${exception.message}\n');
						return null;
					}: String)
				}
		]: Array<{ file: String, source: String }>);
	}

	/**
	 * `specs` rendered for a diagnostic, one quoted argument per entry.
	 *
	 * The quotes are load-bearing rather than decorative: an argument carrying whitespace or newlines
	 * — a shell that did not word-split a file list into separate arguments — renders unquoted as
	 * something that reads like the list the tool WAS given, so the message blames the tool for
	 * losing a path it never received as its own argument.
	 */
	public static function quotedSpecs(specs: Array<String>): String {
		// The inner quotes are escaped for the same reason the outer ones are added: a spec that
		// CONTAINS a quote would otherwise render as two arguments, which is the exact misreading this
		// helper exists to prevent.
		//
		// CONCATENATED, not interpolated. Written as `'"${StringTools.replace(spec, '"', '\\"')}"'` the
		// escape is decoded by the OUTER literal before the nested one is read, so the replacement
		// argument arrives as a bare `"` and the call is a silent no-op — it compiles, and the only
		// symptom is unescaped output.
		return [for (spec in specs) '"' + spec.replace('"', '\\"') + '"'].join(', ');
	}

	/**
	 * Plugin + expanded input paths for a scope, warning about scope specs that matched
	 * no `.hx` file at all — a silent drop there is a query answered over less than the
	 * caller asked for.
	 *
	 * `suggestSeparator` adds the bare-`--` hint to that warning, and ONLY a command that
	 * has a batch form may pass it: thirteen commands share this helper and eleven refuse
	 * a bare `--` outright, so an unconditional hint sends most of its readers straight
	 * into `unknown option "--"`. A batching caller passes it only when the invocation had
	 * no separator — with one present the specs are unambiguous and the advice is noise.
	 */
	public static function resolveInputPaths(lang: String, specs: Array<String>, suggestSeparator: Bool = false): ResolvedInputs {
		final plugin: GrammarPlugin = pickPlugin(lang);
		final expanded: ExpandedInputs = expandInputs(specs, '.hx');
		if (expanded.unmatched.length > 0 && expanded.paths.length > 0)
			CliIo.stderr(
				'apq: ${expanded.unmatched.length} of ${specs.length} scope argument(s) matched no .hx files and were skipped: '
				+ quotedSpecs(expanded.unmatched)
				+ (suggestSeparator ? ' — if they are QUERIES, put a bare `--` between them and the scope' : '')
				+ '\n'
			);
		return { plugin: plugin, paths: expanded.paths, singleFile: expanded.singleFile };
	}

	/** The source-file extension the grammar plugin `--lang lang` reads — the first one it declares; the inverse of `langOfFile`. */
	public static function sourceExtensionOf(lang: String): String {
		return grammarOf(lang).extensions[0];
	}

	/** How `apq merge-file` takes the files of the grammar `lang` apart. */
	public static function mergeShapeOf(lang: String): MergeShape {
		return grammarOf(lang).merge;
	}

	/** The registry row of `--lang lang`; an unregistered name is a usage error. */
	private static function grammarOf(lang: String): GrammarEntry {
		for (entry in grammars()) if (entry.lang == lang) return entry;
		throw new UsageFailure('no grammar plugin for --lang "$lang"');
	}

	/**
	 * Drop a single trailing newline (`\r\n` or `\n`) from `s`. The span-splice ops
	 * (`replace-node` / `add-element`) pass `stripTrailing = true` so a heredoc's mandatory
	 * trailing newline does not land inside the replaced span as a stray blank line — the
	 * writer regenerates the trivia after the span. Append ops (`add-member` / `new --raw`)
	 * leave it: there the writer already normalises the trailing newline away.
	 */
	private static function withoutTrailingNewline(s: String): String {
		return if (s.endsWith('\r\n'))
			s.substring(0, s.length - 2)
		else if (s.endsWith('\n'))
			s.substring(0, s.length - 1)
		else
			s;
	}

}

/**
 * What `expandInputs` answers: the deduped `.hx` paths the specs expanded to, whether the call
 * named exactly ONE concrete file, and every spec that expanded to NOTHING.
 *
 * `unmatched` is what the union alone cannot say — a spec naming a file that is not there vanishes
 * into `paths` the moment another spec matched, and the run analyses a scope short of what it was
 * asked for. Named rather than spelled inline because the reporting seat and its pin both have to
 * write it out.
 */
typedef ExpandedInputs = {
	var paths: Array<String>;
	var singleFile: Bool;
	var unmatched: Array<String>;
};

/**
 * What `resolveInputPaths` hands a subcommand: the grammar plugin for `--lang`,
 * the `.hx` paths its file / dir / glob specs expanded to, and whether the call
 * named exactly ONE concrete file (the gofmt-style "print to stdout" case).
 * Named because three seats spell it out — the resolver itself, `shard-plan`
 * and `self-status`.
 */
typedef ResolvedInputs = {
	var plugin: GrammarPlugin;
	var paths: Array<String>;
	var singleFile: Bool;
};

/**
 * The pair every `--`-then-scope argv parser builds identically before it starts consuming
 * argv itself: an empty scope-spec accumulator and the `--` separator index `routePositional`
 * reads. Named so the shared prologue collapses to one call instead of repeating the same two
 * declarations command by command — the last residue `duplicate-code` still named after the rest of the per-command scaffold was shared.
 */
typedef PositionalScan = {
	var inputSpecs: Array<String>;
	var separator: Int;
};

/**
 * `PositionalScan` plus the two output-shaping flags (`--flat`, `--limit`) a plain
 * name-then-scope walker also carries — `RefsOpts` and `MentionsOpts` both close over
 * exactly this subset before they add their own command-specific fields. One call
 * collapses the shared five-field prologue below `duplicate-code`'s statement floor.
 */
typedef WalkerScan = {
	var flat: Bool;
	var limit: Int;
	var names: Array<String>;
	var inputSpecs: Array<String>;
	var separator: Int;
};

/** One row of `CliArgs.grammars`: what a grammar plugin declares about itself, and how to build it. */
typedef GrammarEntry = {
	/** The `--lang` name. */
	final lang: String;

	/** The file extensions, lower case with the dot, whose files are this grammar's. */
	final extensions: Array<String>;

	/**
	 * Whether a document's text is recognisably this grammar's, for stdin
	 * with no `--lang`; null when the grammar declares no such test.
	 */
	final recognises: Null<String -> Bool>;

	/** A fresh plugin instance. */
	final make: () -> GrammarPlugin;

	/** How `apq merge-file` takes the grammar's files apart: by declarations (source) or by records (data). */
	final merge: MergeShape;
};
