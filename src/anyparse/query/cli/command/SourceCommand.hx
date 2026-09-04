package anyparse.query.cli.command;

import anyparse.query.cli.CliContext;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;
using Lambda;

#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * Parsed options for `apq source` — `lang` selects the grammar plugin, the rest carry the address (`range` / `selectExpr` / `atSpec`) and output flags (`number` / `raw`). `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
typedef SourceOpts = {
	var lang: String;
	var range: Null<String>;
	var selectExpr: Null<String>;
	var atSpec: Null<String>;
	var number: Bool;
	var raw: Bool;
	var file: Null<String>;
	var errExit: Null<Int>;
};

/**
 * `apq source` — emit RAW verbatim file lines (no parse; --range L:L2).
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class SourceCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'source';
	}

	public function summary(): String {
		return 'Emit RAW verbatim file lines (no parse; --range L:L2)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		#if (sys || nodejs)
		return runSource(args);
		#else
		CliIo.stderr('apq source: requires a sys target (file read)\n');
		return EXIT_USAGE;
		#end
	}

	public function usage(): Void {
		#if (sys || nodejs)
		printSourceUsage();
		#end
	}

	/**
	 * Common leading-whitespace prefix length (chars) shared by every
	 * non-blank line of `lines` in the 1-based inclusive `[from, to]` range
	 * (textwrap.dedent semantics). Blank / whitespace-only lines are ignored.
	 * Returns 0 when the lines share no leading whitespace or the range holds
	 * only blanks.
	 */
	public static function commonIndentWidth(lines: Array<String>, from: Int, to: Int): Int {
		var common: Null<String> = null;
		for (n in from ... to + 1) {
			final line: String = lines[n - 1];
			if (line.trim().length == 0) continue;
			final lead: String = leadingWhitespace(line);
			common = common == null ? lead : sharedPrefix(common, lead);
			if (common.length == 0) return 0;
		}
		return common == null ? 0 : common.length;
	}

	/** The leading run of spaces / tabs at the start of `s`. */
	private static function leadingWhitespace(s: String): String {
		var i: Int = 0;
		while (i < s.length) {
			final c: Int = s.fastCodeAt(i);
			if (c != ' '.code && c != '\t'.code) break;
			i++;
		}
		return s.substr(0, i);
	}

	/** The longest common prefix of `a` and `b`. */
	private static function sharedPrefix(a: String, b: String): String {
		final limit: Int = a.length < b.length ? a.length : b.length;
		var i: Int = 0;
		while (i < limit && a.fastCodeAt(i) == b.fastCodeAt(i)) i++;
		return a.substr(0, i);
	}

	/**
	 * Drop the first `strip` chars (the verified common indent) of `line`; a
	 * blank / whitespace-only line collapses to empty instead of keeping stray
	 * trailing indent.
	 */
	public static function dedentLine(line: String, strip: Int): String {
		return line.trim().length == 0 ? '' : line.substr(strip);
	}

	/**
	 * Resolve a `source --select <sel>` / `--at <line>:<col>` address to the 1-based inclusive
	 * line range spanning the matched node WITH its modifier / annotation / conditional-prefix
	 * run — the same `declGroupSpan` fold `patch` searches and `replace-node` overwrites, so text
	 * copied out of this read goes back into either op unchanged. An annotation addressed on its
	 * own still spans only itself, and the fold never reaches the doc block above the run.
	 *
	 * Parses `content` with the `lang` plugin (so it works only on a parseable file, unlike the
	 * raw `--range` reader). Returns `null` after printing a specific `apq source: …` diagnostic
	 * (no match / ambiguous selector / position not on a node / parse failure).
	 */
	public static function resolveNodeLineBounds(
		path: String, content: String, lang: String, selectExpr: Null<String>, atSpec: Null<String>
	): Null<{ from: Int, to: Int }> {
		final plugin: GrammarPlugin = CliArgs.pickPlugin(lang);
		final tree: QueryNode = try plugin.parseFile(content) catch (exception: Exception) {
			CliIo.stderr('apq source: $path does not parse: ${exception.message}\n');
			return null;
		};

		var node: Null<QueryNode>;
		if (selectExpr != null) {
			final selector: Selector = try Selector.parse(selectExpr) catch (exception: Exception) {
				CliIo.stderr('apq source: malformed selector "$selectExpr": ${exception.message}\n');
				return null;
			};
			final matches: Array<QueryNode> = Engine.select(tree, selector, plugin.selectKindEquivalence());
			if (matches.length == 0) {
				CliIo.stderr('apq source: no node matched --select "$selectExpr"\n');
				return null;
			}
			if (matches.length > 1) {
				CliIo.stderr('apq source: --select "$selectExpr" matched ${matches.length} nodes — narrow it (e.g. Kind:name)\n');
				return null;
			}
			node = matches[0];
		} else if (atSpec != null) {
			final pos: Null<Position> = CliArgs.parseLineCol(atSpec);
			if (pos == null) {
				CliIo.stderr('apq source: malformed position "$atSpec" — expected <line>:<col>\n');
				return null;
			}
			node = Engine.at(tree, Span.offsetOf(content, pos.line, pos.col));
			if (node == null) {
				CliIo.stderr('apq source: no node at $atSpec\n');
				return null;
			}
		} else {
			CliIo.stderr('apq source: provide --select <sel> or --at <line>:<col>\n');
			return null;
		}

		final resolved: Null<QueryNode> = node;
		if (resolved == null) {
			CliIo.stderr('apq source: could not resolve a node from the address\n');
			return null;
		}
		final rawSpan: Null<Span> = resolved.span;
		if (rawSpan == null) {
			CliIo.stderr('apq source: the matched node has no source span\n');
			return null;
		}
		// The printed window must be the bytes the node OWNS: a `@:trailOpt` decl whose
		// optional trail is absent parses with a span running on to the next declaration,
		// and printing that showed a neighbour's doc comment as part of this node — the
		// same range `patch` searches, which is where a fragment is copied from.
		//
		// `declGroupSpan` FIRST, in `Patch`'s own order: the range `patch` searches and the
		// span `replace-node` overwrites are the MODIFIER-FOLDED one, and printing the bare
		// node span made the read disagree with both. A one-line prefix hid it — the window
		// is widened to whole LINES, so `@:keep public function f()` printed the annotation
		// anyway — but with the prefix on its own line the read handed back a declaration
		// WITHOUT its `@:keep` / `#if (haxe_ver >= 4.2) enum #end`, and feeding that straight
		// back to `replace-node` dropped it at rc 0. An ANNOTATION addressed on its own still
		// prints alone: `declGroupSpan` stops at one (S36), so the read follows the ops there
		// too. The fold also stops BELOW the doc block, which plain `replace-node` leaves
		// alone as well — its `--with-doc` arm and a replacement opening with a block comment
		// are the two that do reach it.
		final span: Span = CliEdit.sourceWindows(tree, [resolved], content, plugin.lexicalRegions.bind(content))[0] ?? rawSpan;
		final endOffset: Int = span.to > span.from ? span.to - 1 : span.from;
		return { from: span.lineCol(content).line, to: new Span(endOffset, endOffset).lineCol(content).line };
	}

	/**
	 * Parse `source` argv. `errExit` carries the exit code when -h
	 * (EXIT_OK) or a usage error (EXIT_USAGE — unknown option / extra file)
	 * short-circuits; null = proceed.
	 */
	private static function parseSourceArgs(args: Array<String>): SourceOpts {
		final opts: SourceOpts = {
			lang: 'haxe',
			range: null,
			selectExpr: null,
			atSpec: null,
			number: false,
			raw: false,
			file: null,
			errExit: null
		};
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--range':
					opts.range = CliArgs.expectValue(args, ++i, '--range');
				case '--select':
					opts.selectExpr = CliArgs.expectValue(args, ++i, '--select');
				case '--at':
					opts.atSpec = CliArgs.expectValue(args, ++i, '--at');
				case '--number', '-n':
					opts.number = true;
				case '--raw':
					opts.raw = true;
				case '--lang':
					opts.lang = CliArgs.expectValue(args, ++i, '--lang');
				case '-h', '--help':
					printSourceUsage();
					opts.errExit = EXIT_OK;
					return opts;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq source: unknown option "$a"\n');
						opts.errExit = EXIT_USAGE;
						return opts;
					}
					if (opts.file != null) {
						CliIo.stderr('apq source: only one file argument supported (got "${opts.file}" and "$a")\n');
						opts.errExit = EXIT_USAGE;
						return opts;
					}
					opts.file = a;
			}
			i++;
		}
		return opts;
	}

	/**
	 * Print lines [from, to] (1-based inclusive). Unless `raw`, strip the
	 * common leading-whitespace prefix shared by every non-blank line in the
	 * range (textwrap.dedent) so a deeply-nested slice reads without its
	 * indentation tax; `raw` keeps bytes verbatim — required when the output
	 * anchors an Edit or feeds column coordinates, since dedent shifts both.
	 */
	private static function emitSourceLines(lines: Array<String>, from: Int, to: Int, number: Bool, raw: Bool): Void {
		final strip: Int = raw ? 0 : commonIndentWidth(lines, from, to);
		final buf: StringBuf = new StringBuf();
		for (n in from ... to + 1) {
			final line: String = lines[n - 1];
			if (number) buf.add('$n\t');
			buf.add(strip > 0 ? dedentLine(line, strip) : line);
			buf.add('\n');
		}
		CliIo.sysPrint(buf.toString());
	}

	#if (sys || nodejs)
	/**
	 * `apq source <file> [--range SPEC] [--number]` — emit a file's RAW
	 * verbatim lines with NO AST parse, so it works on ANY file (parseable
	 * or skip-parse). Default output is unprefixed lines — directly usable
	 * for anchoring an Edit — replacing the `git show … > /tmp/.txt` /
	 * `node readFileSync` dance (the Read tool fabricates `.hx` past the
	 * first lines; cat/sed/grep are gated; this hxq subcommand is allowed).
	 *
	 * `--range SPEC` is 1-based inclusive: `L` (single line), `L:L2`
	 * (range), `L:` (L to EOF), `:L2` (start to L2). Out-of-range bounds
	 * clamp to the file (friendly, no crash). `--number` / `-n` switches to
	 * `cat -n`-style `<lineno>\t<line>` output for navigation.
	 */
	public static function runSource(args: Array<String>): Int {
		final opts: SourceOpts = parseSourceArgs(args);
		if (opts.errExit != null) return opts.errExit;

		final file: Null<String> = opts.file;
		if (file == null) {
			CliIo.stderr('apq source: missing <file> argument\n');
			printSourceUsage();
			return EXIT_USAGE;
		}
		final modes: Int = (opts.range != null ? 1 : 0) + (opts.selectExpr != null ? 1 : 0) + (opts.atSpec != null ? 1 : 0);
		if (modes > 1) {
			CliIo.stderr('apq source: --range, --select and --at are mutually exclusive — pick one\n');
			return EXIT_USAGE;
		}
		final path: String = file;
		if (!FileSystem.exists(path)) {
			CliIo.stderr('apq source: no such file "$path"\n');
			return EXIT_RUNTIME;
		}
		if (FileSystem.isDirectory(path)) {
			CliIo.stderr('apq source: "$path" is a directory (source views one file)\n');
			return EXIT_RUNTIME;
		}

		final content: String = CliIo.readFile(path);
		// Split on `\n` so a trailing newline does not synthesise a spurious
		// empty final line — the standard "lines = N+1 splits, last empty"
		// is dropped to keep line numbers aligned with an editor's view.
		final lines: Array<String> = content.split('\n');
		if (lines.length > 0 && lines[lines.length - 1] == '') lines.pop();

		// `--select` / `--at` resolve a NODE's span to its line range (these
		// parse the file — unlike the raw, parse-free `--range` / whole-file
		// path, which still works on a skip-parse file).
		final bounds: Null<{ from: Int, to: Int }> = opts.selectExpr != null || opts.atSpec != null
			? resolveNodeLineBounds(path, content, opts.lang, opts.selectExpr, opts.atSpec)
			: parseRangeSpec(opts.range, lines.length);
		if (bounds == null) {
			if (opts.selectExpr != null || opts.atSpec != null) return EXIT_RUNTIME;
			CliIo.stderr('apq source: bad --range "${opts.range}" (use L, L:L2, L:, or :L2 — 1-based)\n');
			return EXIT_USAGE;
		}

		emitSourceLines(lines, bounds.from, bounds.to, opts.number, opts.raw);
		return EXIT_OK;
	}

	/**
	 * Parse a `source --range` spec into a 1-based inclusive `{from, to}`
	 * line pair, clamped to `[1, lineCount]`. Forms: `null`/`""` → whole
	 * file; `L` → single line; `L:L2` → range; `L:` → L to EOF; `:L2` →
	 * start to L2. Returns `null` on a malformed spec (non-int part, or an
	 * inverted range after clamping). An empty file (`lineCount == 0`)
	 * yields an empty `{1, 0}` range so the caller prints nothing.
	 */
	private static function parseRangeSpec(spec: Null<String>, lineCount: Int): Null<{ from: Int, to: Int }> {
		if (lineCount == 0) return { from: 1, to: 0 };
		if (spec == null || spec.length == 0) return { from: 1, to: lineCount };
		final colon: Int = spec.indexOf(':');
		if (colon < 0) {
			final single: Null<Int> = Std.parseInt(spec);
			if (single == null) return null;
			final clamped: Int = clampLine(single, lineCount);
			return { from: clamped, to: clamped };
		}
		final loStr: String = spec.substring(0, colon);
		final hiStr: String = spec.substring(colon + 1);
		final lo: Null<Int> = loStr.length == 0 ? 1 : Std.parseInt(loStr);
		final hi: Null<Int> = hiStr.length == 0 ? lineCount : Std.parseInt(hiStr);
		if (lo == null || hi == null) return null;
		final from: Int = clampLine(lo, lineCount);
		final to: Int = clampLine(hi, lineCount);
		return from > to ? null : { from: from, to: to };
	}

	/** Clamp a 1-based line number into `[1, lineCount]`. */
	private static inline function clampLine(n: Int, lineCount: Int): Int {
		return if (n < 1)
			1
		else if (n > lineCount)
			lineCount
		else
			n;
	}

	public static function printSourceUsage(): Void {
		CliIo.sysPrint('Usage: apq source [options] <file>   (alias: apq show)\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --range <spec>     1-based inclusive lines: L | L:L2 | L: | :L2 (default: whole file)\n');
		CliIo.sysPrint('  --select <sel>     Source of the node matching <sel> (apq ast selector,\n');
		CliIo.sysPrint("                     e.g. 'FnMember:foo' / 'ClassDecl:Bar') — must match exactly one\n");
		CliIo.sysPrint('  --at <line>:<col>  Source of the innermost node at the 1-based position\n');
		CliIo.sysPrint('  --number, -n       Prefix each line with `<lineno>\\t` (cat -n style)\n');
		CliIo.sysPrint('  --raw              Keep bytes verbatim — no dedent (for Edit-anchoring / real columns)\n');
		CliIo.sysPrint('  --lang <name>      Grammar plugin for --select / --at (default: haxe)\n');
		CliIo.sysPrint('  -h, --help         Show this help\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Emits RAW lines of <file>. The default / `--range` path does NO parse and\n');
		CliIo.sysPrint('works on any file (parseable or skip-parse). `--select` / `--at` parse the\n');
		CliIo.sysPrint('file and print the full lines spanning the matched node together with its\n');
		CliIo.sysPrint('leading modifier / annotation / conditional-prefix run — the span `patch`\n');
		CliIo.sysPrint('searches and `replace-node` overwrites — the clean way to\n');
		CliIo.sysPrint("read ONE function by name (no line numbers, no S-expr): apq source f.hx --select 'FnMember:foo'.\n");
		CliIo.sysPrint('\n');
		CliIo.sysPrint('By default the common leading indentation shared by the shown lines is\n');
		CliIo.sysPrint('stripped (dedent) so nested slices read cleanly; pass `--raw` to keep exact\n');
		CliIo.sysPrint('bytes — needed when the output anchors an Edit or you need true column\n');
		CliIo.sysPrint('positions. The gate-blessed replacement for `git show` / `readFileSync`.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('`apq show` is the SAME command. A shell sandbox refuses any command carrying\n');
		CliIo.sysPrint('the token `source` (it reads as the builtin that executes a file), which made\n');
		CliIo.sysPrint('this one unusable inside one — use the alias there.\n');
	}
	#end

}
