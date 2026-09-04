package anyparse.query.cli.command;

import anyparse.format.comment.CommentLossException;
import anyparse.query.CanonicalEdit;
import anyparse.query.FormatFixedPoint.FormatFixedPointResult;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.MoveSymbol;
import anyparse.query.cli.CliContext;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * Parsed options for `apq move` — `lang`, `write`, the `scope` to search, the source address (`posSpec` / `selectExpr` / `matchExpr` / `nth`), and the `destFile`. `errExit` non-null means arg parsing hit a terminal case (incl. missing --scope / address) the caller returns immediately.
 */
@:nullSafety(Strict)
typedef MoveOpts = {
	var lang: String;
	var write: Bool;
	var scope: Null<String>;
	var file: Null<String>;
	var posSpec: Null<String>;
	var selectExpr: Null<String>;
	var matchExpr: Null<String>;
	var nth: Null<Int>;
	var destFile: Null<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag / missing
	// --scope / missing address -> EXIT_USAGE); the caller returns this immediately.
	var errExit: Null<Int>;
};

/**
 * `apq move` — move a type declaration to another file (same package).
 *
 * A `--scope` EDIT: the answer depends on files other than the one it rewrites, so the
 * scope is collected first and the result leaves through `CliEdit`'s write / preview tail.
 */
@:nullSafety(Strict)
final class MoveCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'move';
	}

	public function summary(): String {
		return 'Move a type declaration to another file (same package)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runMove(args);
	}

	public function usage(): Void {
		printMoveUsage();
	}

	private static inline function moveParseExit(code: Int): MoveOpts {
		return {
			lang: '',
			write: false,
			scope: null,
			file: null,
			posSpec: null,
			selectExpr: null,
			matchExpr: null,
			nth: null,
			destFile: null,
			errExit: code
		};
	}

	/**
	 * `apq move <file> <line>:<col> <dest-file> --scope <dir> [--write]` —
	 * move the TYPE declaration at `<line>:<col>` (in `<file>`) into
	 * `<dest-file>` (same package), fixing imports across `<scope>`. Reads
	 * every scope file from disk (plus the cursor and destination files
	 * when they sit outside the scope directory), drives the pure
	 * `MoveSymbol.moveType`, and on success either writes each changed
	 * file (`--write`) or prints a per-file `moved` / `updated` summary.
	 * The whole rewrite is atomic — the pure op re-parses every rewritten
	 * file before returning, so a write either touches all changed files
	 * or none. `<line>:<col>` uses the same column convention `apq refs`
	 * prints.
	 */
	private static function runMove(args: Array<String>): Int {
		final o: MoveOpts = parseMoveArgs(args);
		if (o.errExit != null) return o.errExit;
		// parseMoveArgs proved file/destFile/scope/address non-null before
		// returning with errExit:null; Strict won't narrow struct fields, so
		// re-bind into locals and throw on the provably-unreachable null.
		final cursorFile: Null<String> = o.file;
		final destFile: Null<String> = o.destFile;
		final scopeDir: Null<String> = o.scope;
		if (cursorFile == null || destFile == null || scopeDir == null)
			throw new Exception('apq move: null arg after validation (unreachable)');
		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(o.lang));

		final cursorSource: String = try CliIo.readSourceForParse(cursorFile) catch (exception: Exception) {
			CliIo.stderr('apq move: $cursorFile: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final pos: Null<Position> = CliEdit.resolveAddressPos('move', cursorSource, plugin, o.posSpec, o.selectExpr, o.matchExpr, o.nth);
		if (pos == null) return EXIT_RUNTIME;

		// Gather scope files = expandInputs(scope) ∪ {cursorFile, destFile}.
		final scopeFiles: Null<Array<{ file: String, source: String }>> = CliArgs.collectScopeFiles(
			'move', scopeDir, [cursorFile, destFile]
		);
		if (scopeFiles == null) return EXIT_RUNTIME;

		final typeRefShape: TypeRefShape = plugin.typeRefShape();
		final result: MoveResult = MoveSymbol.moveType(cursorFile, pos.line, pos.col, destFile, scopeFiles, plugin, typeRefShape);
		return emitMoveResult('move', result, cursorFile, destFile, o.write, plugin);
	}

	private static function printMoveUsage(): Void {
		CliIo.sysPrint(
			"Usage: apq move <file> (<line>:<col> | --select 'ClassDecl:<Name>' | --match '<pattern>') <dest-file> --scope <dir> ["
			+ '--write]\n'
		);
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --scope <dir>       Directory whose .hx imports are fixed (required)\n');
		CliIo.sysPrint('  --write             Write each changed file in place (default: print summary)\n');
		CliIo.sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Move the TYPE declaration (class / interface / enum / typedef /\n');
		CliIo.sysPrint('abstract) at <line>:<col> in <file> into <dest-file>, in the same package\n');
		CliIo.sysPrint('or another one. <dest-file> must already EXIST (a bare `package p;` module\n');
		CliIo.sysPrint('is enough; create one with `apq new`). The decl is CUT and PASTED as\n');
		CliIo.sysPrint('source — its leading doc-comment, annotations and conditional modifier\n');
		CliIo.sysPrint('prefix move with it, byte for byte. What lands on disk is those bytes\n');
		CliIo.sysPrint('unless the file was ALREADY writer-canonical before the move, in which\n');
		CliIo.sysPrint('case the whole rewritten file is re-emitted through the writer under the\n');
		CliIo.sysPrint('destination\'s own hxformat.json — canonical in, canonical out. Every file\n');
		CliIo.sysPrint('under --scope that reached the type through its old module path — an\n');
		CliIo.sysPrint('import, a `using`, a wildcard or bare package visibility — is repointed\n');
		CliIo.sysPrint('or given a statement, and the imports the moved body depends on are\n');
		CliIo.sysPrint('carried into the destination — a type position, an upper-initial\n');
		CliIo.sysPrint('static receiver T.x(), and every unguarded `using` of the source file\n');
		CliIo.sysPrint('the destination lacks when the decl holds a member access at all (one\n');
		CliIo.sysPrint('whose bound type name collides at the destination is skipped; a\n');
		CliIo.sysPrint('destination whose own `using` run offers no seat above it is refused).\n');
		CliIo.sysPrint('An import the moved body needs that the source reaches only through a\n');
		CliIo.sysPrint('`#if`-guarded statement carries too: it is re-emitted at the destination\n');
		CliIo.sysPrint('under the condition that guards it at the source, merged into a region\n');
		CliIo.sysPrint('the destination already spells that condition for. Where one condition\n');
		CliIo.sysPrint('cannot carry it the move is REFUSED by name — two different regions\n');
		CliIo.sysPrint('binding one name, a statement nested in more than one region, one in an\n');
		CliIo.sysPrint('`#else` / `#elseif` branch (whose condition is the negation of the ones\n');
		CliIo.sysPrint('above it), and one sharing its line with a directive.\n');
		CliIo.sysPrint('Best-effort: a bare VALUE position (Type.createInstance(Dep, [])), a\n');
		CliIo.sysPrint('constructor pattern and a lowercase receiver are not auto-detected and\n');
		CliIo.sysPrint('may need a manual import — surfaced in the advisory. So is a dependency\n');
		CliIo.sysPrint('whose module lies OUTSIDE --scope: the scope is the resolution index as\n');
		CliIo.sysPrint('well as the rewrite set, and a module it does not hold binds nothing this\n');
		CliIo.sysPrint('op can name — widen --scope to cover the dependency roots. <line>:<col>\n');
		CliIo.sysPrint('uses the same column convention `apq refs` prints.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Refuses a scope file that names the type by its fully-qualified path in\n');
		CliIo.sysPrint('CODE or in a string literal — a mention inside a COMMENT is not one — an\n');
		CliIo.sysPrint('ambiguous / missing type, a decl that shares a source line with other code,\n');
		CliIo.sysPrint('any scope file that does not parse, or any rewritten file that fails to\n');
		CliIo.sysPrint('re-parse — naming that file and the line and column the parse stopped at.\n');
		CliIo.sysPrint('The write is atomic (all changed files or none).\n');
	}

	private static function parseMoveArgs(args: Array<String>): MoveOpts {
		var lang: String = 'haxe';
		var write: Bool = false;
		var scope: Null<String> = null;
		var file: Null<String> = null;
		var posSpec: Null<String> = null;
		var selectExpr: Null<String> = null;
		var matchExpr: Null<String> = null;
		var nth: Null<Int> = null;
		var destFileArg: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--select':
					selectExpr = CliArgs.expectValue(args, ++i, '--select');
				case '--match':
					matchExpr = CliArgs.expectValue(args, ++i, '--match');
				case '--nth':
					nth = Std.parseInt(CliArgs.expectValue(args, ++i, '--nth'));
				case '--write':
					write = true;
				case '--scope':
					scope = CliArgs.expectValue(args, ++i, '--scope');
				case '-h', '--help':
					printMoveUsage();
					return moveParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq move: unknown option "$a"\n');
						return moveParseExit(EXIT_USAGE);
					}
					if (file == null)
						file = a;
					else if (posSpec == null && selectExpr == null && matchExpr == null && destFileArg == null && CliArgs.isPosSpec(a))
						posSpec = a;
					else if (destFileArg == null)
						destFileArg = a;
					else {
						CliIo.stderr('apq move: unexpected extra argument "$a"\n');
						return moveParseExit(EXIT_USAGE);
					}
			}
			i++;
		}
		if (file == null || (posSpec == null && selectExpr == null && matchExpr == null) || destFileArg == null) {
			CliIo.stderr("apq move: expected <file> (<line>:<col> | --select '<sel>' | --match '<pattern>') <dest-file>\n");
			printMoveUsage();
			return moveParseExit(EXIT_USAGE);
		}
		if (scope != null) return {
			lang: lang,
			write: write,
			scope: scope,
			file: file,
			posSpec: posSpec,
			selectExpr: selectExpr,
			matchExpr: matchExpr,
			nth: nth,
			destFile: destFileArg,
			errExit: null
		};
		CliIo.stderr('apq move: --scope <dir> is required (imports are fixed across the scope)\n');
		printMoveUsage();
		return moveParseExit(EXIT_USAGE);
	}

	public static function emitMoveResult(
		cmd: String, result: MoveResult, cursorFile: String, destFile: String, write: Bool, plugin: GrammarPlugin
	): Int {
		switch result {
			case Ok(rawChanges, advisory):
				// Only the WRITE path consumes `newSource`; a preview prints file names and a
				// count, so canonicalising there would pay two writer passes per changed file
				// for nothing observable.
				final changes: Array<MoveChange> = write ? [for (c in rawChanges) canonicalMoveChange(cmd, c, plugin)] : rawChanges;
				if (write) {
					CliIo.writeFiles([for (c in changes) { path: c.file, content: c.newSource }]);
					CliIo.stderr('apq $cmd: wrote ${changes.length} file(s)\n');
				} else {
					for (c in changes) {
						final tag: String = c.file == cursorFile || c.file == destFile ? 'moved' : 'updated';
						CliIo.sysPrint('${c.file}: $tag\n');
					}
					CliIo.sysPrint('total: ${changes.length} file(s)\n');
					CliIo.stderr('apq $cmd: NOTHING written — this is a preview; re-run with --write to apply\n');
				}
				if (advisory != null) CliIo.stderr('apq $cmd: $advisory\n');
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq $cmd: $message\n');
				return EXIT_RUNTIME;
		}
	}

	/**
	 * One move-produced file, canonicalised when — and only when — the file it replaces was
	 * canonical to begin with.
	 *
	 * A move is a VERBATIM span splice: `MoveSymbol` cuts a declaration out with `cutEditSpan` and
	 * pastes it in, and the writer never runs. So a file that was writer-canonical before the move
	 * can come back with whitespace the writer would never emit. Measured on Pony at the base
	 * commit: cutting the last declaration out of a `#if macro … #end` region left `}` + blank +
	 * `#end`, and cutting the FIRST one left `#if macro` + blank — a blank line immediately inside
	 * a region boundary, which the writer collapses. One of 15 successful moves over the first 60
	 * modules produced a file `fmt --list` then flagged; the whole family is invisible to the op's
	 * own gate, which only re-parses.
	 *
	 * Canonical-in / canonical-out, decided PER FILE against that file's own discovered
	 * `hxformat.json` — the same config `apq fmt` would use, because canonicality asked under
	 * compiled defaults answers about a style the project does not use. A file already
	 * non-canonical on disk keeps exactly what the splice produced, so a move inside a repo whose
	 * layout another formatter owns rewrites nothing it was not asked to. That gate is also what
	 * makes this a provable no-op wherever the spliced result is already canonical — every case
	 * the census measured green.
	 *
	 * The write goes through `FormatFixedPoint`, not one round trip, because a writer whose output
	 * is not its own fixed point would leave the file one pass short of where the next `fmt --list`
	 * looks — the very symptom this exists to remove. A run that does not converge keeps the raw
	 * splice rather than writing a text no round trip reproduces.
	 */
	private static function canonicalMoveChange(cmd: String, change: MoveChange, plugin: GrammarPlugin): MoveChange {
		// `readSourceForParse`, not `readFile`: it is the reader `collectScopeFiles` used to
		// build the very sources this move was computed from, and it is `.hxtest`-aware. Reading
		// the raw three-section file instead would answer "not canonical" for every `.hxtest`
		// fixture and silently switch the gate off there.
		final original: Null<String> = try CliIo.readSourceForParse(change.file) catch (exception: Exception) null;
		if (original == null) return change;
		final opts: Null<String> = CliArgs.discoverFormatConfig(change.file);
		if (!CanonicalEdit.isWriterCanonical(original, plugin, opts)) return change;
		// The FIXED POINT, not one round trip — the same loop `apq fmt` and
		// `RefactorSupport.canonicalize` run, and for the same recorded reason: a writer whose
		// output is not its own fixed point leaves the file one pass short of where the next
		// `fmt --list` looks, which is the very symptom this gate exists to remove.
		final fixed: FormatFixedPointResult = try FormatFixedPoint.run(
			text -> plugin.writeRoundTrip(text, opts), change.newSource
		) catch (exception: CommentLossException) {
			// The one failure worth a word: the writer refuses to drop an author's comment
			// rather than emitting lossy output. Keeping the raw splice is right for a span
			// splice (the move's own re-parse already validated it), but silence here would
			// leave a file `fmt --list` flags with nothing said about why.
			CliIo.stderr(
				'apq $cmd: ${change.file} kept the raw splice — canonicalising it would lose the comment '
				+ '`${exception.comment}`; run `apq fmt --list` on it\n'
			);
			return change;
		}
		final canon: Null<String> = fixed.text;
		return fixed.converged && canon != null ? { file: change.file, newSource: canon } : change;
	}

}
