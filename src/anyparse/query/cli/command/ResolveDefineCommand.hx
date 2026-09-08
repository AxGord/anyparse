package anyparse.query.cli.command;

import anyparse.query.CondResolve;
import anyparse.query.cli.CliArgs.ResolvedInputs;
import anyparse.query.cli.CliContext;
import anyparse.runtime.Span.Position;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * Parsed options for `apq resolve-define` — `lang`, `write` / `list` / `reformat`, the `undefined`
 * polarity, the queried `define` and `inputSpecs`. `errExit` non-null means arg parsing hit a
 * terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef ResolveDefineOpts = {
	var lang: String;
	var write: Bool;
	var list: Bool;
	var reformat: Bool;
	// The negative hypothesis: the define is asserted ABSENT rather than set. An assertion an
	// OPERATOR signs for — no compile output can prove a flag undefined.
	var undefined: Bool;
	var define: Null<String>;
	var inputSpecs: Array<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};

/**
 * `apq resolve-define` — fold every `#if` region a define DECIDES, keeping the live branch.
 *
 * The write-twin of `apq cond`, the same relation `comment-rewrite` has to `lit`: `cond` shows
 * which branch of each region a define selects, and this retires the region by making that
 * selection permanent. Retiring a flag is a one-time procedure rather than a standing policy,
 * which is why it is an op and not a lint rule — and why no `--fix` reaches these shapes: the
 * `if-false` check matches only a literal `#if true` / `#if false`, and withholds its fix when the
 * eliminated branch is non-trivial.
 *
 * The mechanism, the DECIDED / undecided split and every refusal are `CondResolve`'s; this module
 * is the argument surface plus the per-file walk, whose shape is `comment-rewrite`'s (single file
 * without `--write` previews on stdout, a directory lists changed paths, `--write` rewrites in
 * place with per-file failures counted).
 */
@:nullSafety(Strict)
final class ResolveDefineCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'resolve-define';
	}

	public function summary(): String {
		return 'Fold every #if region a define decides: keep the live branch (write-twin of cond)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runResolveDefine(args);
	}

	public function usage(): Void {
		printUsage();
	}

	private static inline function parseExit(code: Int): ResolveDefineOpts {
		return {
			lang: '',
			write: false,
			list: false,
			reformat: false,
			undefined: false,
			define: null,
			inputSpecs: [],
			errExit: code
		};
	}

	private static function runResolveDefine(args: Array<String>): Int {
		final o: ResolveDefineOpts = parseArgs(args);
		if (o.errExit != null) return o.errExit;
		final define: Null<String> = o.define;
		if (define == null || o.inputSpecs.length == 0) {
			CliIo.stderr('apq resolve-define: expected <DEFINE> <file/dir/glob>...\n');
			printUsage();
			return EXIT_USAGE;
		}

		final defineStr: String = define;
		final io: ResolvedInputs = CliArgs.resolveInputPaths(o.lang, o.inputSpecs);
		final paths: Array<String> = io.paths;
		if (paths.length == 0) {
			CliIo.stderr('apq resolve-define: ${CliArgs.quotedSpecs(o.inputSpecs)} matched no .hx files\n');
			return EXIT_RUNTIME;
		}

		final listMode: Bool = o.list || (!o.write && !io.singleFile);
		final tally: ResolveTally = resolveFiles(paths, defineStr, io.plugin, io.singleFile, listMode, o);

		// The undecided report comes AFTER the walk so it is not interleaved with a preview's own
		// stdout, and one line per region rather than one per file: the position is what the reader
		// has to open, and a region left standing is the residue this op deliberately does not touch.
		for (line in tally.undecided) CliIo.stderr('$line\n');
		final failed: Int = tally.failed;
		final left: Int = tally.undecided.length;
		final verb: String = o.write ? 'rewrote' : 'would rewrite';
		CliIo.stderr(
			'apq resolve-define: $verb ${tally.changed} file(s), ${tally.regions} region(s)' + (failed > 0 ? ', $failed failed' : '')
			+ (left > 0 ? ', $left region(s) left undecided' : '') + '\n'
		);
		// "0 region(s)" reads as "the regions were already folded", which is the one thing it never
		// means. Say that nothing MATCHED, and say what the matching question was: a region answers
		// on the define its CONDITION mentions, so a define spelled differently in the source — or
		// only ever mentioned outside a directive — yields nothing.
		if (tally.regions == 0 && left == 0 && failed == 0) {
			CliIo.stderr('apq resolve-define: no #if region in ${paths.length} file(s) mentions "$defineStr"\n');
			CliIo.stderr('apq resolve-define: (a region matches on its own #if / #elseif CONDITION — check with `apq cond`)\n');
		}
		return failed > 0 ? EXIT_RUNTIME : EXIT_OK;
	}

	private static function printUsage(): Void {
		CliIo.sysPrint('Usage: apq resolve-define <DEFINE> <file/dir/glob>... [--undefined] [--write] [--list]\n');
		CliIo.sysPrint('       [--reformat] [--lang <name>]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Retire a conditional-compilation define. Every #if region whose own #if /\n');
		CliIo.sysPrint('#elseif conditions mention <DEFINE> and whose branches are ALL decided under\n');
		CliIo.sysPrint('the stated hypothesis is replaced, from its #if marker to the end of its\n');
		CliIo.sysPrint('#end, by the body of its one live branch — or deleted when no branch is live.\n');
		CliIo.sysPrint('The write-twin of apq cond, which shows the same regions read-only.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('DECIDED vs UNDECIDED. A branch is decided when it is provably taken or\n');
		CliIo.sysPrint('provably not; a region is decided when every one of its branches is. A region\n');
		CliIo.sysPrint('with a `maybe` branch — a flag outside the query decides, as in\n');
		CliIo.sysPrint('`#if (mobile && X)` or an `#elseif X` after an unrefuted `#if other` — is\n');
		CliIo.sysPrint('LEFT AS IS and reported by position on stderr. Conditions are never\n');
		CliIo.sysPrint('SIMPLIFIED: `(mobile && X)` does not become `mobile`. That is a rewrite of\n');
		CliIo.sysPrint('the condition text, a separate job, and mixing it in would make a refusal\n');
		CliIo.sysPrint('indistinguishable from a partial edit.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('A decided region NESTED in a decided one is folded into its parent in the\n');
		CliIo.sysPrint('same pass; a decided region nested in an UNDECIDED one is folded on its own,\n');
		CliIo.sysPrint('and the parent stays.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('WHOLE-LINE DELETION. A region whose #if starts its line and whose #end ends\n');
		CliIo.sysPrint('one takes those lines with it when nothing is live, so no blank line is left\n');
		CliIo.sysPrint('behind. A region sharing its lines with code keeps them, and the replacement\n');
		CliIo.sysPrint('is re-indented by the writer like any other emitted code.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --undefined    Assert the define is NOT defined instead of defined — the\n');
		CliIo.sysPrint('                 polarity a never-set flag needs. An assertion the operator\n');
		CliIo.sysPrint('                 signs for: no compile output can prove a flag absent\n');
		CliIo.sysPrint('  --write, -w    Rewrite each file in place (default: stdout for one file,\n');
		CliIo.sysPrint('                 list of changed paths for a dir / multiple files)\n');
		CliIo.sysPrint('  --list, -l     Print paths that would change; no rewrite\n');
		CliIo.sysPrint('  --reformat     Canonicalise the whole file (allow a non-canonical input)\n');
		CliIo.sysPrint('  --lang <name>  Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('  -h, --help     Show this help\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('The result goes through the shared write gate, so three refusals are the\n');
		CliIo.sysPrint('same ones every writer-emit op answers: a region that was the whole body slot\n');
		CliIo.sysPrint('of a brace-less `if` (folding it would silently hand that `if` the next\n');
		CliIo.sysPrint('statement), a file that is not in canonical form (format it with\n');
		CliIo.sysPrint('`apq fmt --write`, or pass --reformat), and a source the grammar cannot\n');
		CliIo.sysPrint('parse. Unlike apq cond, an unparseable file is an error here rather than a\n');
		CliIo.sysPrint('walk: reading a region needs no tree, writing one needs a re-parse.\n');
	}

	private static function parseArgs(args: Array<String>): ResolveDefineOpts {
		var lang: String = 'haxe';
		var write: Bool = false;
		var list: Bool = false;
		var reformat: Bool = false;
		var undefined: Bool = false;
		var define: Null<String> = null;
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--write', '-w':
					write = true;
				case '--list', '-l':
					list = true;
				case '--reformat':
					reformat = true;
				case '--undefined':
					undefined = true;
				case '-h', '--help':
					printUsage();
					return parseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq resolve-define: unknown option "$a"\n');
						return parseExit(EXIT_USAGE);
					}
					if (define == null)
						define = a;
					else
						inputSpecs.push(a);
			}
			i++;
		}
		return {
			lang: lang,
			write: write,
			list: list,
			reformat: reformat,
			undefined: undefined,
			define: define,
			inputSpecs: inputSpecs,
			errExit: null
		};
	}

	private static function resolveFiles(
		paths: Array<String>, define: String, plugin: GrammarPlugin, singleFile: Bool, listMode: Bool, o: ResolveDefineOpts
	): ResolveTally {
		final op: String = 'resolve-define';
		final undecided: Array<String> = [];
		var changed: Int = 0;
		var failed: Int = 0;
		var regions: Int = 0;
		for (path in paths) {
			final source: String = try CliIo.readFile(path) catch (exception: Exception) {
				CliIo.stderr('apq resolve-define: $path: ${exception.message}\n');
				failed++;
				continue;
			};
			// The same pre-filter `apq cond` applies: a define must appear verbatim in the directive
			// that mentions it, so a file whose bytes do not hold the word cannot yield a region —
			// and skipping it here also skips the canonical gate, which would otherwise refuse a
			// drifted file this op was never going to touch.
			if (!singleFile && source.indexOf(define) < 0) continue;
			final optsJson: Null<String> = CliArgs.discoverFormatConfig(path);
			final answer: CondResolveResult = CondResolve.resolve(source, plugin, define, o.undefined, o.reformat, optsJson);
			// Reported for a file that FAILED too: a region left standing is a fact about the file,
			// and the write it failed would not have touched it either way.
			for (region in answer.undecided) undecided.push(undecidedLine(path, source, region));
			switch answer.result {
				case Ok(text, rewrites):
					// Counted on the `Ok` arm only. A refused write folded nothing, and
					// `0 file(s), 1 region(s), 1 failed` reads as a partial application — the one
					// thing the gate exists to make impossible.
					regions += answer.resolved;
					CliEdit.warnRewrites(op, path, rewrites);
					final isChanged: Bool = text != source;
					// A per-file failure like an unreadable one: this op walks a file set, so one
					// unwritable member is no reason to abandon the rest, and a failed write leaves
					// its own file byte-identical.
					if (o.write) {
						if (isChanged) try {
							CliIo.writeFile(path, text);
							changed++;
						} catch (failure: WriteFailure) {
							CliIo.stderr('apq resolve-define: ${failure.message}\n');
							failed++;
						}
					} else if (listMode) {
						if (isChanged) {
							CliIo.sysPrint('$path\n');
							changed++;
						}
					} else {
						CliEdit.previewEdit(op, path, text);
						if (isChanged) changed++;
					}
				case Err(message):
					CliIo.stderr('apq resolve-define: $path: $message\n');
					failed++;
			}
		}
		return {
			changed: changed,
			failed: failed,
			regions: regions,
			undecided: undecided
		};
	}

	/** One undecided region as the reader has to see it: where it is, what it says, and why it was left. */
	private static function undecidedLine(path: String, source: String, region: UndecidedRegion): String {
		final at: Position = region.at.lineCol(source);
		return '$path:${at.line}:${at.col}: ${region.directive} - left as is: a flag outside the query decides';
	}

}

/**
 * What the per-file walk accumulated: files `changed`, files that `failed`, `regions` folded
 * (nested ones counted individually) and one rendered stderr line per region left standing.
 */
private typedef ResolveTally = {
	final changed: Int;
	final failed: Int;
	final regions: Int;
	final undecided: Array<String>;
};
