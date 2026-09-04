package anyparse.query.cli;

using StringTools;
using Lambda;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SourceText;
import anyparse.query.cli.CliArgs.ExpandedInputs;
import anyparse.query.cli.CliArgs.ResolvedInputs;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * The argument door of the `apq` CLI: everything that turns argv and the path
 * specs on it into the values a command actually runs on — one flag's value,
 * a `--limit`, a `<line>:<col>`, the grammar plugin `--lang` names, the
 * `hxformat.json` a file is governed by, and the expansion of a glob or
 * directory into the file list a walk visits.
 *
 * These are the members `hxq clusters` reports with the highest fan-in after
 * IO (`expectValue` 67, `pickPlugin` 51), for the obvious reason: every one of
 * the 69 commands parses arguments before it does anything. Reaching them from
 * outside `Cli` is what lets a command move onto the `CliCommand` registry
 * without dragging the whole god type behind it.
 *
 * Every member is a pure function of its arguments — no state, so a run holds
 * nothing that a second run in the same process could observe.
 */
@:nullSafety(Strict)
final class CliArgs {

	/**
	 * The nearest ancestor `hxformat.json` content for `filePath`, or null. Thin alias
	 * for `FormatConfigDiscovery.discover` — the CLI keeps the short local name its
	 * ~20 call sites use.
	 */
	public static inline function discoverFormatConfig(filePath: String): Null<String> {
		return FormatConfigDiscovery.discover(filePath);
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

	public static function pickPlugin(lang: String): GrammarPlugin {
		return switch lang {
			case 'haxe': new HaxeQueryPlugin();
			case _: throw 'apq: no grammar plugin for --lang "$lang"';
		};
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

	public static function expectValue(args: Array<String>, idx: Int, flag: String): String {
		if (idx >= args.length) throw 'apq: $flag requires a value';
		return args[idx];
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

	/**
	 * Parse `--limit <n>` at position `i` (the flag itself already
	 * matched). Returns the parsed non-negative count, or throws the
	 * same way `expectValue` does on a missing/!int value — callers
	 * surface it as a usage error.
	 */
	public static function parseLimit(args: Array<String>, idx: Int): Int {
		final v: String = expectValue(args, idx, '--limit');
		final n: Null<Int> = Std.parseInt(v);
		if (n == null || n < 0) throw 'apq: --limit expects a non-negative integer, got "$v"';
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
		for (extra in extraFiles) if (!paths.contains(extra)) paths.push(extra);
		return ([
			for (path in paths)
				{
					file: path,
					source: (try CliIo.readSourceForParse(path) catch (exception: Exception) {
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
	 * The plugin plus the `.hx` paths `specs` name, and the place a spec that named nothing is
	 * reported.
	 *
	 * The empty case has always been reported by the caller (`<specs> matched no .hx files`); what was
	 * silent is the MIXED one — a spec that matched nothing beside one that did, which vanishes into
	 * the union and leaves the run analysing less than it was asked for with no word about it. Each
	 * unmatched spec is QUOTED: an argument carrying whitespace or newlines (a shell that failed to
	 * word-split a file list into separate arguments) is otherwise indistinguishable from a list of
	 * paths the tool was given, which is exactly how one such invocation read as a tool defect.
	 *
	 * SCOPE OF THAT REPORT: this covers the twelve commands that resolve their scope THROUGH
	 * here. THIRTEEN other call sites reach `expandInputs` directly and still drop an unmatched spec in
	 * silence — `refs`, `uses`, `meta`, `search`, `blast`, `mentions`, `gates`, `rename --scope`, the
	 * call-graph builder, `extract-constant`, `collectScopeFiles`, `collectPermissiveCandidates`, and
	 * `readResolutionLibrary`. The last is the one to fix next: a `resolutionRoots` entry that matches
	 * no `.hx` is dropped there in exactly the silence this function just closed for the report scope,
	 * one screen away. `unmatched` is computed for all of them — they simply do not read it yet.
	 */
	public static function resolveInputPaths(lang: String, specs: Array<String>): ResolvedInputs {
		final plugin: GrammarPlugin = pickPlugin(lang);
		final expanded: ExpandedInputs = expandInputs(specs, '.hx');
		if (expanded.unmatched.length > 0 && expanded.paths.length > 0)
			CliIo.stderr(
				'apq: ${expanded.unmatched.length} of ${specs.length} scope argument(s) matched no .hx files and were skipped: '
				+ '${quotedSpecs(expanded.unmatched)}\n'
			);
		return { plugin: plugin, paths: expanded.paths, singleFile: expanded.singleFile };
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

	public static inline function stripQuotes(s: String): String {
		final t: String = s.trim();
		if (t.length < 2) return t;
		final first: String = t.charAt(0);
		final last: String = t.charAt(t.length - 1);
		return (first == "'" && last == "'") || (first == '"' && last == '"') ? t.substring(1, t.length - 1) : t;
	}

	/** The maximum 32-bit signed integer — a null-span sort sentinel and the unbounded `--top` / `--all` count. */
	public static inline final MAX_INT: Int = 0x7FFFFFFF;

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
