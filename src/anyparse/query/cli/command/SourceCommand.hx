package anyparse.query.cli.command;

import anyparse.query.Address.AddressIndex;
import anyparse.query.SourceText;
import anyparse.query.cli.CliContext;
import anyparse.query.cli.CliEdit;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;
using Lambda;

#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * Parsed options for `apq source` — `lang` selects the grammar plugin, the rest carry
 * the address (`range` / `selectExprs` / `atSpec`) and output flags (`number` / `raw` /
 * `all`). `selectExprs` is a LIST: `--select` is repeatable and the nodes print in
 * document order. `all` lifts the narrow-the-read refusal on a long whole-file read.
 * `errExit` non-null means arg parsing hit a terminal case the caller returns
 * immediately.
 */
typedef SourceOpts = {
	var lang: String;
	var range: Null<String>;
	var selectExprs: Array<String>;
	var atSpec: Null<String>;
	var number: Bool;
	var raw: Bool;
	var all: Bool;
	var file: Null<String>;
	var errExit: Null<Int>;
};

/**
 * A 1-based INCLUSIVE line window of a file — what every address form in `source`
 * (`--range`, `--select`, `--at`) resolves to before anything is printed, and what
 * a selector-menu entry advertises.
 */
typedef LineRange = { var from: Int; var to: Int; };

/**
 * `apq source` — emit RAW verbatim file lines (no parse; --range L:L2).
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class SourceCommand implements CliCommand {

	/**
	 * Whole-file read budget in lines when `HXQ_SOURCE_MAX_LINES` says nothing.
	 *
	 * 120 is a file a reader can hold at once — roughly a small class with its doc
	 * comments. Past it the selector menu is cheaper than the bytes, measured: the
	 * session that motivated the gate dumped 1270 lines to use ~100.
	 */
	private static inline final DEFAULT_MAX_LINES: Int = 120;

	/** How many selector-menu entries a refusal prints before it defers to `apq ast --depth 2`. */
	private static inline final MENU_ENTRIES_SHOWN: Int = 60;

	/**
	 * How many NAMED ancestors a node may have and still count as top-level for the
	 * menu. `1` = the module's own declarations plus their members, which is the two
	 * levels a reader picks from; the walk prunes below it.
	 */
	private static inline final MENU_NAMED_DEPTH: Int = 1;

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
	): Null<LineRange> {
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
		return lineRange(span, content);
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
			selectExprs: [],
			atSpec: null,
			number: false,
			raw: false,
			all: false,
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
					opts.selectExprs.push(CliArgs.expectValue(args, ++i, '--select'));
				case '--at':
					opts.atSpec = CliArgs.expectValue(args, ++i, '--at');
				case '--number', '-n':
					opts.number = true;
				case '--raw':
					opts.raw = true;
				case '--all':
					opts.all = true;
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
		final modes: Int = (opts.range != null ? 1 : 0) + (opts.selectExprs.length > 0 ? 1 : 0) + (opts.atSpec != null ? 1 : 0);
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

		// `--select` / `--at` resolve NODES' spans to line ranges (these parse the
		// file — unlike the raw, parse-free `--range` / whole-file path, which still
		// works on a skip-parse file).
		if (opts.selectExprs.length > 0) return emitSelectedNodes(path, content, lines, opts);
		if (opts.atSpec != null) {
			final at: Null<LineRange> = resolveNodeLineBounds(path, content, opts.lang, null, opts.atSpec);
			if (at == null) return EXIT_RUNTIME;
			emitSourceLines(lines, at.from, at.to, opts.number, opts.raw);
			return EXIT_OK;
		}
		if (opts.range == null && !opts.all) {
			final refusal: Null<String> = wholeFileRefusal(path, content, lines.length, opts.lang);
			if (refusal != null) {
				CliIo.stderr(refusal);
				return EXIT_USAGE;
			}
		}
		final bounds: Null<LineRange> = parseRangeSpec(opts.range, lines.length);
		if (bounds == null) {
			CliIo.stderr('apq source: bad --range "${opts.range}" (use L, L:L2, L:, or :L2 — 1-based)\n');
			return EXIT_USAGE;
		}

		emitSourceLines(lines, bounds.from, bounds.to, opts.number, opts.raw);
		return EXIT_OK;
	}

	/**
	 * Print every `--select`ed node, in DOCUMENT order whatever order the flags came
	 * in, each preceded by a `=== <selector> ===` banner when there is more than one.
	 *
	 * ONE selector prints exactly what it printed before the flag was repeatable —
	 * no banner, no reordering — because that spelling is what the skill, the hooks
	 * and every existing fixture call.
	 *
	 * A selector that resolves to nothing has already said why (`resolveNodeLineBounds`
	 * prints the diagnostic); the rest are still printed and the run exits non-zero, so
	 * a batch of six is not lost to one typo.
	 */
	private static function emitSelectedNodes(path: String, content: String, lines: Array<String>, opts: SourceOpts): Int {
		final resolved: Array<{ selector: String, from: Int, to: Int }> = [];
		var failed: Bool = false;
		for (selector in opts.selectExprs) {
			final bounds: Null<LineRange> = resolveNodeLineBounds(path, content, opts.lang, selector, null);
			if (bounds == null) {
				failed = true;
				continue;
			}
			resolved.push({ selector: selector, from: bounds.from, to: bounds.to });
		}
		resolved.sort((a, b) -> a.from != b.from ? a.from - b.from : a.to - b.to);
		// Keyed on what was ASKED for, not on what resolved: a two-selector run where one
		// failed must not print byte-identically to a one-selector run, or a caller
		// splitting stdout on banners silently mis-reads a partial batch.
		final banner: Bool = opts.selectExprs.length > 1;
		for (node in resolved) {
			if (banner) CliIo.sysPrint(CliWalk.batchSection(node.selector));
			emitSourceLines(lines, node.from, node.to, opts.number, opts.raw);
		}
		return failed || resolved.length == 0 ? EXIT_RUNTIME : EXIT_OK;
	}

	/**
	 * The refusal `apq source <file>` answers with when nothing narrowed the read and
	 * the file is longer than the configured budget — or null when the read may go
	 * ahead (short enough, or the budget is switched off).
	 *
	 * WHY a gate-blessed reader refuses: `source` with no `--range` / `--select`
	 * behaves exactly like `cat`, and that is what a model reaches for. Measured on
	 * one real session: 7 files, 1270 lines dumped whole, ~100 of them needed (≈8%),
	 * two of the files needed nothing at all. And the discipline the skill states
	 * ("read the member by name") cannot be followed on first contact, because
	 * `--select` demands a name you do not have yet — so the honest fix is for the
	 * tool to hand the NAMES back instead of the bytes. On this tree the three
	 * largest `src` files cost 262 830 / 186 685 / 168 070 bytes of stdout, ~155K
	 * tokens for the three.
	 *
	 * `HXQ_SOURCE_MAX_LINES` sets the budget (default `DEFAULT_MAX_LINES`); `0`
	 * switches the gate off entirely, and `--all` prints the file whole. A file that
	 * does not parse has no menu to offer, so the refusal names `--range` and `--all`
	 * and nothing else.
	 */
	private static function wholeFileRefusal(path: String, content: String, lineCount: Int, lang: String): Null<String> {
		final budget: Int = maxWholeFileLines();
		if (budget <= 0 || lineCount <= budget) return null;
		final head: String = 'apq source: $path is $lineCount lines and nothing narrowed the read (budget $budget lines, '
			+ 'HXQ_SOURCE_MAX_LINES; 0 disables).\n';
		// `pickPlugin` THROWS on an unknown `--lang`, and this path is the only one in
		// `source` that touches a plugin at all: outside the try it turned a read of a
		// long file with a bad `--lang` into an uncaught exception, contradicting the
		// command's own pinned contract that it accepts and ignores the flag.
		final parsed: Null<{ plugin: GrammarPlugin, tree: QueryNode }> = try {
			final plugin: GrammarPlugin = CliArgs.pickPlugin(lang);
			{ plugin: plugin, tree: plugin.parseFile(content) };
		} catch (exception: Exception) null;
		if (parsed == null)
			return
				'${head}It does not parse, so there is no selector menu — read a window with `--range L:L2`, or pass `--all` to print it '
					+ 'whole.\n';
		final menu: Array<String> = topLevelSelectors(parsed.tree, content, parsed.plugin, budget);
		if (menu.length == 0)
			return '${head}It projects no named top-level node — read a window with `--range L:L2`, or pass `--all` to print it whole.\n';
		final shown: Array<String> = menu.length > MENU_ENTRIES_SHOWN ? menu.slice(0, MENU_ENTRIES_SHOWN) : menu;
		final buf: StringBuf = new StringBuf();
		buf.add(head);
		buf.add('Narrow it — `apq source $path --select \'<sel>\'` (repeatable):\n');
		for (entry in shown) buf.add('  $entry\n');
		if (menu.length > shown.length) buf.add('  … +${menu.length - shown.length} more — `apq ast $path --depth 2` lists every one\n');
		buf.add('Or read a line window with `--range L:L2`. `--all` prints the whole file.\n');
		return buf.toString();
	}

	/**
	 * The whole-file read budget in lines: `HXQ_SOURCE_MAX_LINES` when it parses as a
	 * non-negative integer, else `DEFAULT_MAX_LINES`. `0` means no budget.
	 *
	 * A malformed value falls back to the default rather than failing the read: this
	 * is a DX guard, and an unreadable env var must not make a file unreadable.
	 */
	private static function maxWholeFileLines(): Int {
		#if (sys || nodejs)
		final configured: Null<String> = Sys.getEnv('HXQ_SOURCE_MAX_LINES');
		if (configured != null && configured != '') {
			final parsed: Null<Int> = SourceText.parseStrictInt(configured);
			if (parsed != null) return parsed;
		}
		#end
		return DEFAULT_MAX_LINES;
	}

	/**
	 * The addressable top-level selectors of `tree`, in document order — each rendered
	 * as `<canonical selector>` followed by the line range it spans.
	 *
	 * "Top-level" is counted in NAMED ancestors, not in grammar kinds: a named node
	 * with at most `MENU_NAMED_DEPTH` named nodes above it qualifies. That is the
	 * module's own declarations and their members for a curly-brace language, and it
	 * stays right for a grammar this file has never heard of — which is the whole
	 * point of a plugin architecture. Anything deeper is pruned, so the walk costs the
	 * top two named levels rather than the tree.
	 *
	 * The selector text is `Address.describe`'s, so an entry is EDIT-STABLE and can be
	 * pasted into `patch` / `replace-node` unchanged, not just back into `source`.
	 */
	private static function topLevelSelectors(tree: QueryNode, source: String, plugin: GrammarPlugin, budget: Int): Array<String> {
		final index: AddressIndex = Address.describerFor(tree, plugin.selectKindEquivalence());
		final nodes: Array<QueryNode> = [];
		collectTopLevelSelectors(tree, 0, nodes);
		// The SAME window `--select` prints, not the bare node span — so a menu entry
		// states what following it costs. It also exposes a greedy one: a module-level
		// declaration whose span runs on to the next declaration reads as a
		// thousand-line entry, and an entry past the read budget is marked as such
		// rather than quietly offered as if it were a narrowing.
		final windows: Array<Null<Span>> = CliEdit.sourceWindows(tree, nodes, source, plugin.lexicalRegions.bind(source));
		final found: Array<{ selector: String, from: Int, to: Int }> = [];
		for (i => node in nodes) {
			final window: Null<Span> = windows[i] ?? node.span;
			if (window == null) continue;
			final bounds: LineRange = lineRange(window, source);
			found.push({ selector: index.describe(source, node), from: bounds.from, to: bounds.to });
		}
		// A node spanning ONE line is not worth addressing: whoever reads its
		// neighbour reads it too, and on a Haxe module the one-liners are the
		// package, every import, every modifier annotation and every typedef field —
		// 20 of the 50 entries this file yields, none of them what a reader wants.
		// A LINE COUNT is the grammar-agnostic form of that judgement; a kind list
		// would be a Haxe-shaped one, and the menu has to survive the next grammar.
		// If the filter empties the menu (a file of one-liners), the unfiltered list
		// is still better than no menu at all.
		final spanning: Array<{ selector: String, from: Int, to: Int }> = found.filter(entry -> entry.to > entry.from);
		final menu: Array<{ selector: String, from: Int, to: Int }> = spanning.length > 0 ? spanning : found;
		return [
			for (entry in menu)
				'${entry.selector}   lines ${entry.from}-${entry.to}'
					+ (entry.to - entry.from + 1 > budget ? ' (past the budget itself — prefer --range)' : '')
		];
	}

	/** The 1-based inclusive line range `span` covers in `source` — the window a reader is offered. */
	private static function lineRange(span: Span, source: String): LineRange {
		final endOffset: Int = span.to > span.from ? span.to - 1 : span.from;
		return { from: span.lineCol(source).line, to: new Span(endOffset, endOffset).lineCol(source).line };
	}

	/** `topLevelSelectors`' walk: record `node` when shallow enough, then recurse while a child still could be. */
	private static function collectTopLevelSelectors(node: QueryNode, namedAbove: Int, out: Array<QueryNode>): Void {
		// A node is addressable by selector only with BOTH a name and a span.
		final addressable: Bool = node.name != null && node.span != null;
		if (addressable && namedAbove <= MENU_NAMED_DEPTH) out.push(node);
		final below: Int = addressable ? namedAbove + 1 : namedAbove;
		if (below > MENU_NAMED_DEPTH) return;
		for (child in node.children) collectTopLevelSelectors(child, below, out);
	}


	/**
	 * `Std.parseInt` parses a PREFIX and silently ignores trailing garbage
	 * (`Std.parseInt('205,225') == 205`), which made `--range 205,225` (a
	 * comma typo for `:`) read as the single line `205` instead of a usage
	 * error. `SourceText.parseStrictInt` already closes that hole (whole-token
	 * digit check before parsing) for the `<line>:<col>` grammar, but it has no
	 * `-` case — `--range -5:2` is a deliberate idiom `clampLine` folds to `1`,
	 * so this wraps the shared digit check with the ONE extra rule this grammar
	 * needs instead of forking a second copy of the digit loop.
	 */
	private static function strictRangeInt(s: String): Null<Int> {
		final negative: Bool = s.length > 0 && s.fastCodeAt(0) == '-'.code;
		final digits: Null<Int> = SourceText.parseStrictInt(negative ? s.substring(1) : s);
		return if (digits == null)
			null
		else if (negative)
			-digits
		else
			digits;
	}

	/**
	 * Parse a `source --range` spec into a 1-based inclusive `{from, to}`
	 * line pair, clamped to `[1, lineCount]`. Forms: `null`/`""` → whole
	 * file; `L` → single line; `L:L2` → range; `L:` → L to EOF; `:L2` →
	 * start to L2. Returns `null` on a malformed spec (non-int part, or an
	 * inverted range after clamping). An empty file (`lineCount == 0`)
	 * yields an empty `{1, 0}` range so the caller prints nothing.
	 */
	private static function parseRangeSpec(spec: Null<String>, lineCount: Int): Null<LineRange> {
		if (lineCount == 0) return { from: 1, to: 0 };
		if (spec == null || spec.length == 0) return { from: 1, to: lineCount };
		final colon: Int = spec.indexOf(':');
		if (colon < 0) {
			final single: Null<Int> = strictRangeInt(spec);
			if (single == null) return null;
			final clamped: Int = clampLine(single, lineCount);
			return { from: clamped, to: clamped };
		}
		final loStr: String = spec.substring(0, colon);
		final hiStr: String = spec.substring(colon + 1);
		final lo: Null<Int> = loStr.length == 0 ? 1 : strictRangeInt(loStr);
		final hi: Null<Int> = hiStr.length == 0 ? lineCount : strictRangeInt(hiStr);
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
		CliIo.sysPrint("                     e.g. 'FnMember:foo' / 'ClassDecl:Bar') — must match exactly one.\n");
		CliIo.sysPrint('                     REPEATABLE: several nodes print in document order, each\n');
		CliIo.sysPrint('                     under a `=== <selector> ===` banner (one selector: no banner)\n');
		CliIo.sysPrint('  --at <line>:<col>  Source of the innermost node at the 1-based position\n');
		CliIo.sysPrint('  --number, -n       Prefix each line with `<lineno>\\t` (cat -n style)\n');
		CliIo.sysPrint('  --raw              Keep bytes verbatim — no dedent (for Edit-anchoring / real columns)\n');
		CliIo.sysPrint('  --all              Print the whole file past the narrow-the-read budget\n');
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
		CliIo.sysPrint('A file longer than 120 lines read with NO --range / --select / --at is\n');
		CliIo.sysPrint('REFUSED: stderr answers the line count plus a menu of top-level selectors\n');
		CliIo.sysPrint('and the run exits non-zero, because `--select` needs a name you cannot have\n');
		CliIo.sysPrint('on first contact. `--all` prints it whole; HXQ_SOURCE_MAX_LINES moves the\n');
		CliIo.sysPrint('budget and 0 switches the refusal off.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('`apq show` is the SAME command. A shell sandbox refuses any command carrying\n');
		CliIo.sysPrint('the token `source` (it reads as the builtin that executes a file), which made\n');
		CliIo.sysPrint('this one unusable inside one — use the alias there.\n');
	}
	#end

}
