package anyparse.query.cli.command;

import anyparse.query.Diff;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.cli.CliContext;
import anyparse.query.format.Json;
import anyparse.query.format.Text;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;
import haxe.io.Path;
import anyparse.query.ExitCode.*;

using StringTools;
using Lambda;

/**
 * Parsed options for `apq ast` / `apq probe` — `lang`, `json`, `depth`, the address (`selectExpr` / `atExpr`), output toggles, child-count filters, and the inline-source channels (`codeArg` / `stdinFlag`). `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef AstOpts = {
	var lang: String;
	var json: Bool;
	var depth: Int;
	var selectExpr: Null<String>;
	var atExpr: Null<String>;
	var wantDoc: Bool;
	var wantSource: Bool;
	var writerOutput: Bool;
	var writerOutputPlain: Bool;
	var writerDiff: Bool;
	var minChildren: Int;
	var maxChildren: Int;
	var childrenLimit: Int;
	var spans: Bool;
	var countOnly: Bool;
	// `--type-refs`: render the plugin's type-position projection
	// (`parseFileTypeRefs`) instead of the default `parseFile` tree.
	// Same renderers, same --select/--at/--depth/--json plumbing —
	// only the parsed tree differs.
	var typeRefs: Bool;
	var file: Null<String>;
	// Inline source (`apq probe '<code>'` -> `--code <s>`) or stdin
	// (`apq ast --stdin`) bypass the file read for micro-probes
	// without a /tmp scratch file. Mutually exclusive with each
	// other and with a file argument; checked after arg parsing.
	var codeArg: Null<String>;
	var stdinFlag: Bool;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag / validation
	// failure -> EXIT_USAGE); the caller returns this immediately and ignores the rest.
	var errExit: Null<Int>;
};

/**
 * `apq ast` — dump parsed AST (S-expr or JSON).
 *
 * A multi-file WALK: the path specs go through `CliArgs`, the files through `CliWalk`,
 * and an empty result answers `ctx.emptyExit` so a script can tell "found nothing"
 * from "ran fine".
 */
@:nullSafety(Strict)
final class AstCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'ast';
	}

	public function summary(): String {
		return 'Dump parsed AST (S-expr or JSON)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runAst(args);
	}

	public function usage(): Void {
		printAstUsage();
	}

	/** Terminal-case AstOpts: a flag/usage path that the caller returns immediately, ignoring every other field. */
	private static inline function astParseExit(code: Int): AstOpts {
		return {
			lang: '',
			json: false,
			depth: -1,
			selectExpr: null,
			atExpr: null,
			wantDoc: false,
			wantSource: false,
			writerOutput: false,
			writerOutputPlain: false,
			writerDiff: false,
			minChildren: -1,
			maxChildren: -1,
			childrenLimit: -1,
			spans: false,
			countOnly: false,
			typeRefs: false,
			file: null,
			codeArg: null,
			stdinFlag: false,
			errExit: code
		};
	}

	public static function runAst(args: Array<String>): Int {
		final o: AstOpts = parseAstArgs(args);
		if (o.errExit != null) return o.errExit;

		// Source resolution: --code wins, then --stdin, then the file arg.
		// Exactly one of the three must be set.
		final sourceProvidersSet: Int = (o.codeArg != null ? 1 : 0) + (o.stdinFlag ? 1 : 0) + (o.file != null ? 1 : 0);
		if (sourceProvidersSet == 0) {
			CliIo.stderr('apq ast: missing <file>, --code <s>, or --stdin\n');
			printAstUsage();
			return EXIT_USAGE;
		}
		if (sourceProvidersSet > 1) {
			CliIo.stderr('apq ast: <file>, --code, and --stdin are mutually exclusive\n');
			return EXIT_USAGE;
		}
		final plugin: GrammarPlugin = CliArgs.pickPlugin(o.lang);
		// Capture nullable struct fields into locals so Strict narrows them;
		// the source/label resolution then branches once and narrows `file`
		// in its own arm. File label drives error / hit-location prefixes —
		// <probe> / <stdin> are distinct so a `probe` call still looks like a
		// probe in emitted diff headers and errors. The trailing throw is the
		// provably-unreachable arm (the mutex above proved exactly one set);
		// `var` is required because the value is assigned per-branch.
		final codeArg: Null<String> = o.codeArg;
		final file: Null<String> = o.file;
		var source: String;
		var fileLabel: String;
		if (codeArg != null) {
			source = codeArg;
			fileLabel = '<probe>';
		} else if (o.stdinFlag) {
			source = CliIo.readStdin();
			fileLabel = '<stdin>';
		} else if (file != null) {
			source = CliIo.readSourceForParse(file);
			fileLabel = file;
		} else
			throw new Exception('apq ast: no source provider after mutex check (unreachable)');

		// `--writer-output`: parse + format-write through the plugin's
		// round-trip pipeline. Independent of --select / --at / --json /
		// --depth / --doc / --source — emits the formatted source to stdout
		// and exits. Used for fast writer-bug iteration (a single command
		// vs full test runner round-trip).
		//
		// `--writer-output --diff`: instead of printing the emitted source,
		// parse it back and structurally AST-diff against the parsed input.
		// THE writer-bug iteration loop: see structurally what the writer
		// added / removed / reshaped in one shot, without a second `hxq diff`
		// call. Exit non-zero when the writer output fails to re-parse
		// (writer produced syntactically broken Haxe).
		if (o.writerOutput) {
			if (!o.typeRefs) return runAstWriterOutput(plugin, source, file, fileLabel, o.lang, o.writerOutputPlain, o.writerDiff);
			CliIo.stderr('apq ast: --type-refs cannot be combined with --writer-output (the type-ref projection is not writable)\n');
			return EXIT_USAGE;
		}
		if (o.writerDiff) {
			CliIo.stderr('apq ast: --diff requires --writer-output (it diffs input vs writer-emitted output)\n');
			return EXIT_USAGE;
		}

		// `--type-refs` swaps ONLY the projection: every downstream branch
		// (--at / --select / --count / --json / --depth) renders it through
		// the same code path the default tree uses, so the dump is directly
		// comparable with a plain `ast` run of the same file.
		final tree: QueryNode = try (o.typeRefs ? plugin.parseFileTypeRefs(source) : plugin.parseFile(source)) catch (e: ParseError) {
			CliIo.stderr('apq ast: $fileLabel: $e\n');
			return EXIT_RUNTIME;
		} catch (e: Exception) {
			CliIo.stderr('apq ast: $fileLabel: ${e.message}\n');
			return EXIT_RUNTIME;
		}

		final atExpr: Null<String> = o.atExpr;
		if (atExpr != null) return runAstAt(o, atExpr, tree, source, fileLabel, plugin.lexicalRegions(source));

		final selectExpr: Null<String> = o.selectExpr;
		if (selectExpr != null) return runAstSelect(o, selectExpr, tree, source, fileLabel, plugin);

		if (o.countOnly) {
			CliIo.sysPrint('${tree.children.length}\n');
			return EXIT_OK;
		}
		final shaped: QueryNode = shapeAstOutput(tree, o.depth, o.childrenLimit);
		CliIo.sysPrint(o.json ? Json.renderTree(fileLabel, source, shaped) : Text.render(shaped, o.spans));
		return EXIT_OK;
	}

	/**
	 * Apply `--depth N` then `--children-limit N` shaping in one place.
	 * Depth truncate first (cheaper — drops sub-trees wholesale), then
	 * per-level child cap on what remains. Both clamps are optional;
	 * negative inputs are no-ops.
	 */
	private static function shapeAstOutput(node: QueryNode, depth: Int, childrenLimit: Int): QueryNode {
		final out: QueryNode = depth < 0 ? node : Engine.truncate(node, depth);
		return childrenLimit >= 0 ? Engine.truncateChildren(out, childrenLimit) : out;
	}

	private static function printAstUsage(): Void {
		CliIo.sysPrint('Usage: apq ast [options] <file> | --code <s> | --stdin\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Source (exactly one):\n');
		CliIo.sysPrint('  <file>              Path to a parseable source file (or .hxtest — section 2 auto-extracted)\n');
		CliIo.sysPrint('  --code <s>          Inline source string (typically via the `probe` subcommand)\n');
		CliIo.sysPrint('  --stdin             Read all of stdin as source\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --json              Emit JSON instead of S-expr\n');
		CliIo.sysPrint('  --depth <n>         Truncate beyond depth n. Counted from the displayed root:\n');
		CliIo.sysPrint('                      module (default), the matched node when paired with --select / --at.\n');
		CliIo.sysPrint('                      --depth 0 prints just the root with no children.\n');
		CliIo.sysPrint('  --select <path>     Subtree(s) matching a selector (e.g. "ClassDecl > FnDecl:foo")\n');
		CliIo.sysPrint('  --at <line>:<col>   Innermost node enclosing the 1-indexed position\n');
		CliIo.sysPrint('  --doc               With --select/--at: emit the match\'s leading doc-comment\n');
		CliIo.sysPrint('  --source            With --select/--at: emit the match\'s verbatim source — the\n');
		CliIo.sysPrint('                      bytes replace-node overwrites, so a declaration arrives\n');
		CliIo.sysPrint('                      with the modifier / @:meta run the grammar projects as its\n');
		CliIo.sysPrint('                      siblings, and stopping below its doc block as replace-node\n');
		CliIo.sysPrint('                      does without --with-doc (apq source --select means the same\n');
		CliIo.sysPrint('                      declaration, widened to whole lines; --json carries it\n');
		CliIo.sysPrint('                      un-indented under the "source" key)\n');
		CliIo.sysPrint('  --min-children <n>  With --select: keep only matches with >= n direct children (e.g. multi-arg ParamCtor)\n');
		CliIo.sysPrint('  --max-children <n>  With --select: keep only matches with <= n direct children\n');
		CliIo.sysPrint(
			'  --spans             Append `@from-to` byte-range annotation to every rendered node — same-span duplicates ('
			+ 'parser bug emitting two nodes at the same position) become a trivial visual signal.\n'
		);
		CliIo.sysPrint(
			'  --count             Print just the integer direct-child count at the displayed root ('
			+ 'one line per match with --select). Sanity-check for member counts before writing a corpus-driver test assertion.\n'
		);
		CliIo.sysPrint(
			'  --type-refs         Render the type-position projection (parseFileTypeRefs) instead of the default tree — the dotted type '
			+ 'references of the file (field/var annotations, param + return types, enum-ctor params, type parameters, and the field types '
			+ 'of an anonymous structure in any of those). Field NAMES never project as TYPE REFERENCES — the raw dump still shows them as '
			+ 'node names, but uses/blast and the rewriting ops see only types.\n'
		);
		CliIo.sysPrint('  --writer-output     Parse + format-write through the plugin trivia pipeline and print the emitted source\n');
		CliIo.sysPrint(
			'  --writer-output-plain  Like --writer-output but uses the plain (non-trivia) writer — mirrors the unit-test entry '
			+ 'HxModuleWriter.write(HaxeModuleParser.parse(src)); flattens source layout, drops comments\n'
		);
		CliIo.sysPrint('  --diff              With --writer-output: AST-diff the input against the emitted output (writer-bug loop)\n');
		CliIo.sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
	}

	/**
	 * Heuristic: does the string look like a Haxe TypeName? First letter
	 * uppercase ASCII, no `/`, no `.` (eliminates relative paths like
	 * `./Foo.hx` and dotted accesses like `Foo.bar`). Used by `ast` to
	 * detect `apq ast <TypeName> <dir>` (refs/uses surface mistakenly
	 * fed to ast).
	 */
	private static function looksLikeTypeName(s: String): Bool {
		if (s.length == 0) return false;
		final c: Int = s.fastCodeAt(0);
		return c >= 'A'.code && c <= 'Z'.code && s.indexOf('/') < 0 && s.indexOf('.') < 0;
	}

	/**
	 * Heuristic: does the string look like a file/dir path? Contains `/`
	 * or `.hx` suffix, OR is an existing filesystem entry. Pairs with
	 * `looksLikeTypeName` to detect the `ast <TypeName> <dir>` shape.
	 */
	private static function looksLikePath(s: String): Bool {
		return s.indexOf('/') >= 0 || s.endsWith('.hx') || #if (sys || nodejs) sys.FileSystem.exists(s) #else false #end;
	}

	/**
	 * Extract the leading kind token from a `--select` expression for
	 * fuzzy "did you mean" lookup. Splits on `>` (chain step), `:`
	 * (Kind:name binding), `[` (future syntax), and whitespace, returns
	 * the first non-empty segment. Empty result → no suggestion line.
	 */
	private static function extractFirstKindToken(selectExpr: String): String {
		final trimmed: String = selectExpr.trim();
		if (trimmed.length == 0) return '';
		var end: Int = trimmed.length;
		for (i in 0...trimmed.length) {
			final c: Int = trimmed.fastCodeAt(i);
			if (c != '>'.code && c != ':'.code && c != '['.code && c != ' '.code && c != '\t'.code) continue;
			end = i;
			break;
		}
		return trimmed.substr(0, end).trim();
	}

	/** Distinct node-constructor kinds present in a tree, sorted — the
	* self-discovery list shown when `--select` matches nothing. */
	private static function collectKinds(root: QueryNode): Array<String> {
		final seen: Array<String> = [];
		function walk(n: QueryNode): Void {
			if (!seen.contains(n.kind)) seen.push(n.kind);
			for (c in n.children) walk(c);
		}
		walk(root);
		seen.sort((a, b) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
		return seen;
	}

	/**
	 * Report the `apq ast` "two positional arguments" usage error. Detects
	 * the `apq ast <TypeName> <dir>` miss — `ast` is single-file, while
	 * `<TypeName> <dir>` is the refs/uses/meta surface — and routes the user
	 * to the right multi-file walker; otherwise prints the plain message.
	 */
	private static function reportAstTwoFilesError(file: String, a: String): Void {
		// `apq ast <TypeName> <dir>` is a common miss — `ast` is single-
		// file, while `<TypeName> <dir>` is the refs/uses/meta surface.
		// Detect the shape (first arg looks like a TypeName, second arg
		// is an existing directory or .hx file) and route the user.
		final maybeTypeArg: String = file;
		final maybeDirArg: String = a;
		if (looksLikeTypeName(maybeTypeArg) && looksLikePath(maybeDirArg))
			CliIo.stderr(
				'apq ast: only one file argument supported (got "$maybeTypeArg" and "$maybeDirArg").\n         "$maybeTypeArg'
				+ '" looks like a TypeName and "$maybeDirArg" like a path — `ast` is single-file.\n'
				+ '         For type lookup across a directory:\n           apq refs $maybeTypeArg $maybeDirArg'
				+ ' --decls    # value bindings + decl site\n           apq uses $maybeTypeArg $maybeDirArg'
				+ '            # type-position consumers\n           apq blast $maybeTypeArg $maybeDirArg           # full change-impact ('
				+ 'uses + refs + field-access)\n           apq meta @:peg $maybeDirArg                    # all PEG decls in scope\n'
				+ '         For a subtree of one file:\n           apq ast <path-to-file.hx> --select Kind:$maybeTypeArg\n'
			);
		else
			CliIo.stderr('apq ast: only one file argument supported (got "$file" and "$a")\n');
	}

	/**
	 * Parse `ast` argv into an AstOpts. A terminal case (`-h`/`--help` or any
	 * usage error) prints its message and returns with `errExit` set; the
	 * caller returns that code immediately. The natural end returns the full
	 * struct with `errExit: null`. The source-provider mutex and source
	 * resolution stay in the caller (they depend on FS/stdin I/O).
	 */
	private static function parseAstArgs(args: Array<String>): AstOpts {
		var lang: String = 'haxe';
		var json: Bool = false;
		var depth: Int = -1;
		var selectExpr: Null<String> = null;
		var atExpr: Null<String> = null;
		var wantDoc: Bool = false;
		var wantSource: Bool = false;
		var writerOutput: Bool = false;
		var writerOutputPlain: Bool = false;
		var writerDiff: Bool = false;
		var minChildren: Int = -1;
		var maxChildren: Int = -1;
		var childrenLimit: Int = -1;
		var spans: Bool = false;
		var countOnly: Bool = false;
		var typeRefs: Bool = false;
		var file: Null<String> = null;
		// Inline source (`apq probe '<code>'` -> `--code <s>`) or stdin
		// (`apq ast --stdin`) bypass the file read for micro-probes
		// without a /tmp scratch file. Mutually exclusive with each
		// other and with a file argument; checked after arg parsing.
		var codeArg: Null<String> = null;
		var stdinFlag: Bool = false;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--json':
					json = true;
				case '--depth':
					// Depth is counted from the DISPLAYED ROOT, not from the
					// module: with `--select` / `--at`, the root is the
					// matched node (or each matched node, when --select
					// returns several); without either, the root is the
					// full module. So `--depth 0` always means "print just
					// the root, no children" regardless of mode. The three
					// `Engine.truncate` callsites below pass the right
					// subtree-root in each branch.
					final v: String = CliArgs.expectValue(args, ++i, '--depth');
					final parsed: Null<Int> = Std.parseInt(v);
					if (parsed == null) {
						CliIo.stderr('apq ast: --depth expects an integer, got "$v"\n');
						return astParseExit(EXIT_USAGE);
					}
					depth = parsed;
				case '--select':
					selectExpr = CliArgs.expectValue(args, ++i, '--select');
				case '--at':
					atExpr = CliArgs.expectValue(args, ++i, '--at');
				case '--doc':
					wantDoc = true;
				case '--source':
					wantSource = true;
				case '--writer-output':
					writerOutput = true;
				case '--writer-output-plain':
					writerOutput = true;
					writerOutputPlain = true;
				case '--diff':
					writerDiff = true;
				case '--min-children':
					final v: String = CliArgs.expectValue(args, ++i, '--min-children');
					final parsed: Null<Int> = Std.parseInt(v);
					if (parsed == null || parsed < 0) {
						CliIo.stderr('apq ast: --min-children expects a non-negative integer, got "$v"\n');
						return astParseExit(EXIT_USAGE);
					}
					minChildren = parsed;
				case '--max-children':
					final v: String = CliArgs.expectValue(args, ++i, '--max-children');
					final parsed: Null<Int> = Std.parseInt(v);
					if (parsed == null || parsed < 0) {
						CliIo.stderr('apq ast: --max-children expects a non-negative integer, got "$v"\n');
						return astParseExit(EXIT_USAGE);
					}
					maxChildren = parsed;
				case '--children-limit':
					// Cap direct-child count per node in the rendered output
					// (different beast from --max-children: that one FILTERS
					// matches by arity, this one TRUNCATES the printed tree
					// horizontally with an `(... N more)` sentinel). Composes
					// with --depth N for "first N children up to depth M".
					final v: String = CliArgs.expectValue(args, ++i, '--children-limit');
					final parsed: Null<Int> = Std.parseInt(v);
					if (parsed == null || parsed < 0) {
						CliIo.stderr('apq ast: --children-limit expects a non-negative integer, got "$v"\n');
						return astParseExit(EXIT_USAGE);
					}
					childrenLimit = parsed;
				case '--code':
					codeArg = CliArgs.expectValue(args, ++i, '--code');
				case '--stdin':
					stdinFlag = true;
				case '--spans':
					// Append `@from-to` byte-range annotation to every
					// rendered node — same-span duplicates (e.g. parser bug
					// emitting two nodes at the same source position) become
					// a trivial visual signal in the S-expr output. E.g. an
					// `^A|B` regex bug once produced `(Ternary (FloatLit 1. @4-6)
					// (FloatLit 1. @4-6) (FloatLit 2. @11-13))` — two
					// FloatLits at the same span ⇒ mid-buffer match
					// overwrote an earlier ident. Plain `(no-spans)` form
					// stays default to keep transcripts compact.
					spans = true;
				case '--type-refs':
					// ω-ast-type-refs: dump the SAME S-expr/JSON projection the
					// default `ast` prints, but over `parseFileTypeRefs` — the
					// type-position tree that until now only `uses`/`blast`
					// consumed and nothing exposed. "List every dotted type
					// reference in this file" was unanswerable through hxq
					// without it. The dump is deliberately RAW: it shows the
					// projection exactly as the consumers read it, gaps
					// included, rather than a repaired view.
					typeRefs = true;
				case '--count':
					// ω-ast-count: print just the integer direct-child count
					// at the displayed root (the module by default; each
					// matched node when paired with `--select`). Composes
					// with `--select` — one line per match. Skips writer-
					// output / json / spans / doc / source rendering; only
					// the count is emitted. Replaces hand-counting members
					// when sanity-checking a corpus-driver test assertion.
					countOnly = true;
				case '-h', '--help':
					printAstUsage();
					return astParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq ast: unknown option "$a"\n');
						return astParseExit(EXIT_USAGE);
					}
					if (file != null) {
						reportAstTwoFilesError(file, a);
						return astParseExit(EXIT_USAGE);
					}
					file = a;
			}
			i++;
		}

		return {
			lang: lang,
			json: json,
			depth: depth,
			selectExpr: selectExpr,
			atExpr: atExpr,
			wantDoc: wantDoc,
			wantSource: wantSource,
			writerOutput: writerOutput,
			writerOutputPlain: writerOutputPlain,
			writerDiff: writerDiff,
			minChildren: minChildren,
			maxChildren: maxChildren,
			childrenLimit: childrenLimit,
			spans: spans,
			countOnly: countOnly,
			typeRefs: typeRefs,
			file: file,
			codeArg: codeArg,
			stdinFlag: stdinFlag,
			errExit: null
		};
	}

	/**
	 * `--writer-output`: parse + format-write through the plugin's round-trip
	 * pipeline, then either print the emitted source or (with `--diff`)
	 * structurally AST-diff the parsed input against the re-parsed output.
	 * Independent of --select / --at / --json / --depth / --doc / --source.
	 * Returns the process exit code.
	 */
	private static function runAstWriterOutput(
		plugin: GrammarPlugin, source: String, file: Null<String>, fileLabel: String, lang: String, writerOutputPlain: Bool,
		writerDiff: Bool
	): Int {
		// `.hxtest` section-1 (writer config JSON) auto-applies for
		// the file-path mode — drives `HxModuleWriteOptions` via
		// `HaxeFormatConfigLoader` so a fixture reproduces the corpus
		// harness's writer settings in a single command. `--code` /
		// `--stdin` modes have no path → defaults stay.
		final optsJson: Null<String> = file != null ? CliArgs.readWriteOptionsJsonOrNull((file: String)) : null;
		final emitted: Null<String> = try (
			writerOutputPlain ? plugin.writeRoundTripPlain(source, optsJson) : plugin.writeRoundTrip(source, optsJson)
		) catch (e: ParseError) {
			CliIo.stderr('apq ast: $fileLabel: $e\n');
			return EXIT_RUNTIME;
		} catch (e: Exception) {
			CliIo.stderr('apq ast: $fileLabel: ${e.message}\n');
			return EXIT_RUNTIME;
		}
		if (emitted == null) {
			final flagName: String = writerOutputPlain ? '--writer-output-plain' : '--writer-output';
			CliIo.stderr('apq ast: $flagName: no writer wired up for lang "$lang"\n');
			return EXIT_USAGE;
		}
		if (!writerDiff) {
			CliIo.sysPrint(emitted);
			return EXIT_OK;
		}
		final emittedSrc: String = emitted;
		final treeIn: QueryNode = try plugin.parseFile(source) catch (e: ParseError) {
			CliIo.stderr('apq ast: --writer-output --diff: input $fileLabel: $e\n');
			return EXIT_RUNTIME;
		} catch (e: Exception) {
			CliIo.stderr('apq ast: --writer-output --diff: input $fileLabel: ${e.message}\n');
			return EXIT_RUNTIME;
		}
		final treeOut: QueryNode = try plugin.parseFile(emittedSrc) catch (e: ParseError) {
			CliIo.stderr('apq ast: --writer-output --diff: writer output failed to re-parse: $e\n');
			CliIo.stderr('--- writer output ---\n$emittedSrc\n--- end ---\n');
			return EXIT_RUNTIME;
		} catch (e: Exception) {
			CliIo.stderr('apq ast: --writer-output --diff: writer output failed to re-parse: ${e.message}\n');
			CliIo.stderr('--- writer output ---\n$emittedSrc\n--- end ---\n');
			return EXIT_RUNTIME;
		}
		final hits: Array<DiffHit> = Diff.diff(treeIn, treeOut);
		CliIo.sysPrint(Diff.render(fileLabel, source, '<writer-output>', emittedSrc, hits, false));
		return EXIT_OK;
	}

	/**
	 * `--at LINE:COL`: locate the innermost spanned node at the cursor and
	 * render it (or, with `--count`, print its direct-child count). Returns
	 * the process exit code.
	 */
	private static function runAstAt(
		o: AstOpts, atExpr: String, tree: QueryNode, source: String, fileLabel: String, regions: Array<LexRegion>
	): Int {
		final colonIdx: Int = atExpr.indexOf(':');
		if (colonIdx < 0) {
			CliIo.stderr('apq ast: --at expects LINE:COL, got "$atExpr"\n');
			return EXIT_USAGE;
		}
		final atLine: Null<Int> = Std.parseInt(atExpr.substring(0, colonIdx));
		final atCol: Null<Int> = Std.parseInt(atExpr.substring(colonIdx + 1));
		if (atLine == null || atCol == null) {
			CliIo.stderr('apq ast: --at expects integer LINE:COL, got "$atExpr"\n');
			return EXIT_USAGE;
		}
		// Capture into non-null locals immediately after the null
		// check — Strict narrows locals, not the Null<Int> bindings,
		// and `Span.offsetOf` takes plain Int.
		final atLineN: Int = atLine;
		final atColN: Int = atCol;
		if (atLineN < 1 || atColN < 1) {
			CliIo.stderr('apq ast: --at expects 1-indexed LINE:COL, got "$atExpr"\n');
			return EXIT_USAGE;
		}
		final offset: Int = Span.offsetOf(source, atLineN, atColN);
		final node: Null<QueryNode> = Engine.at(tree, offset);
		if (o.countOnly) {
			if (node != null) CliIo.sysPrint('${node.children.length}\n');
			return EXIT_OK;
		}
		final windows: Array<Null<Span>> = node == null || !(o.wantDoc || o.wantSource)
			? []
			: CliEdit.sourceWindows(tree, [node], source, () -> regions);
		final matches: Array<QueryNode> = node == null ? [] : [shapeAstOutput(node, o.depth, o.childrenLimit)];
		CliIo.sysPrint(
			o.json
				? Json.renderMatches(fileLabel, source, matches, windows, o.wantDoc, o.wantSource, regions)
				: Text.renderMatches(matches, source, windows, o.wantDoc, o.wantSource, regions, o.spans)
		);
		return EXIT_OK;
	}

	/**
	 * `--select` matched nothing: emit a self-correcting hint listing the
	 * kinds actually present, a fuzzy "did you mean", and (for a TypeName-
	 * shaped first kind) a cross-project pointer to the multi-file walkers.
	 */
	private static function reportAstSelectEmpty(
		tree: QueryNode, selectExpr: String, fileLabel: String, minChildren: Int, maxChildren: Int, preFilterLen: Int
	): Void {
		// Empty `--select` is indistinguishable from "wrong kind
		// name". Kinds are the exact node-constructor names and the
		// engine never enumerates them — so list the kinds actually
		// present in this file, turning a silent miss into a
		// self-correcting hint (no global kind table needed).
		final present: Array<String> = collectKinds(tree);
		final filterParts: Array<String> = [];
		if (minChildren >= 0) filterParts.push('--min-children=$minChildren');
		if (maxChildren >= 0) filterParts.push('--max-children=$maxChildren');
		if (preFilterLen > 0) filterParts.push('$preFilterLen pre-filter match(es) dropped by child-count');
		final filterNote: String = filterParts.length == 0 ? '' : ' (with ${filterParts.join(', ')})';
		// Kind-fuzzy "did you mean" — surface the closest match in
		// `present` for the first kind segment of `selectExpr`
		// (split on `>`, `:`, whitespace). Same `findFuzzy`
		// substring+Levenshtein two-tier shape as refs/uses on a
		// 0-hit name, so a typo like `--select ParamCtorr` →
		// `Did you mean: ParamCtor?` without re-reading the long
		// `Kinds present here:` list. Silent when nothing close.
		final firstKind: String = extractFirstKindToken(selectExpr);
		final presentMap: Map<String, Bool> = [for (k in present) k => true];
		final suggestions: Array<String> = firstKind.length > 0 ? CliWalk.findFuzzy(firstKind, presentMap) : [];
		final fuzzyLine: String = suggestions.length > 0 ? ' Did you mean: ${suggestions.join(', ')}?' : '';
		// Cross-project hint: when the first kind token starts uppercase
		// (TypeName-shaped — e.g. `HxCatchClause`, `HxModule`), the user
		// is likely hunting a decl that lives in OTHER files. `ast` is
		// single-file by design; point them at the multi-file walkers
		// (`refs --decls` / `uses` / `blast`) that DO recurse a dir.
		// Silent when the token is lowercase (field-shaped) or empty.
		final crossProjectHint: String = firstKind.length > 0 && firstKind.fastCodeAt(0) >= 'A'.code && firstKind.fastCodeAt(0) <= 'Z'.code
			? ' If "$firstKind" is a TypeName declared elsewhere, ast is single-file; try apq refs $firstKind src/ --decls ('
				+ 'declaration sites), apq uses $firstKind src/ (type positions), or apq blast $firstKind src/ (full change-impact).'
			: '';
		CliIo.stderr(
			'apq ast: --select "$selectExpr"$filterNote matched no nodes in $fileLabel. Kinds present here: ${present.join(', ')}.'
			+ '$fuzzyLine$crossProjectHint Kinds are exact node-constructor names — run `apq ast $fileLabel` to see the tree.\n'
		);
	}

	/**
	 * `--select <sel>`: resolve the selector against the tree (kind-equivalence
	 * aware), apply the optional child-count arity filter, then render the
	 * matches (or print each match's child count with `--count`). Returns the
	 * process exit code.
	 */
	private static function runAstSelect(
		o: AstOpts, selectExpr: String, tree: QueryNode, source: String, fileLabel: String, plugin: GrammarPlugin
	): Int {
		final selector: Selector = Selector.parse(selectExpr);
		// Pass the grammar's kind-equivalence so `--select ClassDecl` /
		// `--select FnMember` also match `final class` / `final function`
		// (the `final`-wrapper shapes ClassForm / FinalModifiedMember).
		final preFilter: Array<QueryNode> = Engine.select(tree, selector, plugin.selectKindEquivalence());
		// ω-ast-child-count-filter: post-filter on direct-child count so
		// "find all multi-arg ParamCtor ctors" is one query. The selector
		// grammar (`Kind` / `Kind:name` / `Kind > Child`) is deliberately
		// minimal and stays that way — arity is a numeric predicate, not
		// a structural one, and lives on the CLI instead of the path.
		final raw: Array<QueryNode> = o.minChildren < 0 && o.maxChildren < 0 ? preFilter : [
			for (m in preFilter)
				if ((o.minChildren < 0 || m.children.length >= o.minChildren) && (o.maxChildren < 0 || m.children.length <= o.maxChildren))
					m
		];
		if (raw.length == 0) reportAstSelectEmpty(tree, selectExpr, fileLabel, o.minChildren, o.maxChildren, preFilter.length);
		if (o.countOnly) {
			for (m in raw) CliIo.sysPrint('${m.children.length}\n');
			return EXIT_OK;
		}
		// The `--source` / `--doc` windows come from the RAW matches, before the reshape below: a
		// `--depth` / `--children-limit` copy has no parent in the tree, so the fold could not be
		// asked of it.
		final windows: Array<Null<Span>> = o.wantDoc || o.wantSource
			? CliEdit.sourceWindows(tree, raw, source, plugin.lexicalRegions.bind(source))
			: [];
		final matches: Array<QueryNode> = [for (m in raw) shapeAstOutput(m, o.depth, o.childrenLimit)];
		CliIo.sysPrint(
			o.json
				? Json.renderMatches(fileLabel, source, matches, windows, o.wantDoc, o.wantSource, plugin.lexicalRegions(source))
				: Text.renderMatches(matches, source, windows, o.wantDoc, o.wantSource, plugin.lexicalRegions(source), o.spans)
		);
		return EXIT_OK;
	}

}
