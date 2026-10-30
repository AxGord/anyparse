package anyparse.query.cli.command;

import anyparse.query.Address.AddressSpec;
import anyparse.query.ExitCode.*;
import anyparse.query.MoveElements;
import haxe.ds.Either;

/**
 * `apq move-elements` — move a slice of one array literal's elements into another array literal.
 *
 * A TWO-FILE edit when `--into` names another module: both files are written together or neither is
 * (`CliIo.writeFiles`), and `--dry-run` prints the moved entries and their digest without writing.
 */
@:nullSafety(Strict)
final class MoveElementsCommand implements CliCommand {

	private static inline final OP: String = 'move-elements';

	public function new() {}

	public function name(): String {
		return OP;
	}

	public function summary(): String {
		return 'Move a slice of an array literal\'s elements into another array literal (--append / --sorted)';
	}

	public function flags(): CliFlags {
		return new CliFlags(
			['--dry-run', '--reformat', '--write'], ['--append', '--into', '--match', '--nth', '--range', '--select', '--sorted']
		);
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runMoveElements(args);
	}

	public function usage(): Void {
		printMoveElementsUsage();
	}

	private static function runMoveElements(args: Array<String>): Int {
		final o: MoveElementsOpts = switch parseArgs(args) {
			case Left(code): return code;
			case Right(opts): opts;
		};
		final sourceFile: String = o.file;
		final source: String = try CliIo.readFile(sourceFile) catch (exception: Exception) {
			CliIo.stderr('apq $OP: $sourceFile: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final into: Null<String> = o.into;
		final destFile: Null<String> = into == null || FileIdentity.same(into, sourceFile) ? null : into;
		final destSource: Null<String> = if (destFile == null)
			null
		else
			try CliIo.readFile(destFile) catch (exception: Exception) {
				CliIo.stderr('apq $OP: $destFile: ${exception.message}\n');
				return EXIT_RUNTIME;
			};
		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(o.lang));
		final request: MoveElementsRequest = {
			source: source,
			sourceFile: sourceFile,
			address: o.address,
			first: o.first,
			last: o.last,
			destSource: destSource,
			target: o.target,
			sorted: o.sorted,
			reformat: o.reformat,
			optsJson: CliArgs.discoverFormatConfig(sourceFile),
			destOptsJson: destFile == null ? null : CliArgs.discoverFormatConfig(destFile)
		};
		switch MoveElements.moveElements(request, plugin) {
			case Ok(newSource, newDest, entries, digest):
				final where: String = destFile ?? sourceFile;
				final mode: String = o.sorted ? 'sorted' : 'append';
				if (o.dryRun) {
					CliIo.sysPrint('$sourceFile [${o.first}..${o.last}] -> $where ($mode): ${entries.length} element(s)\n');
					for (i => entry in entries) CliIo.sysPrint('${o.first + i}\t$entry\n');
					CliIo.sysPrint('digest $digest\n');
					CliIo.stderr('apq $OP: NOTHING written — a dry run; re-run with --write to apply\n');
				} else if (o.write) {
					final writes: Array<{ path: String, content: String }> = [{ path: sourceFile, content: newSource }];
					if (destFile != null && newDest != null) writes.push({ path: destFile, content: newDest });
					CliIo.writeFiles(writes);
					CliIo.stderr('apq $OP: wrote ${writes.length} file(s); moved ${entries.length} element(s) to $where, digest $digest\n');
				} else {
					CliEdit.previewEdit(OP, sourceFile, newSource);
					if (destFile != null && newDest != null) CliEdit.previewEdit(OP, destFile, newDest);
				}
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq $OP: $message\n');
				return EXIT_RUNTIME;
		}
	}

	/** The options of one run, or `Left` with the exit code a terminal case (`--help`, a usage error) ends it with. */
	private static function parseArgs(args: Array<String>): Either<Int, MoveElementsOpts> {
		// noqa: complexity
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var dryRun: Bool = false;
		var file: Null<String> = null;
		var at: Null<String> = null;
		var select: Null<String> = null;
		var matchPattern: Null<String> = null;
		var nth: Null<Int> = null;
		var range: Null<String> = null;
		var into: Null<String> = null;
		var appendTo: Null<String> = null;
		var sortedInto: Null<String> = null;
		for (arg in new MoveElementsCommand().flags().walk(args)) {
			final a: String = arg.token;
			switch arg.flag {
				case '--lang':
					lang = arg.value();
				case '--select':
					select = arg.value();
				case '--match':
					matchPattern = arg.value();
				case '--nth':
					nth = Std.parseInt(arg.value());
				case '--range':
					range = arg.value();
				case '--into':
					into = arg.value();
				case '--append':
					appendTo = arg.value();
				case '--sorted':
					sortedInto = arg.value();
				case '--dry-run':
					dryRun = true;
				case '--write':
					write = true;
				case '--reformat':
					reformat = true;
				case '-h', '--help':
					printMoveElementsUsage();
					return Left(EXIT_OK);
				case null:
					if (file == null)
						file = a;
					else if (at == null && CliArgs.isPosSpec(a))
						at = a;
					else
						return usageError('unexpected extra argument "$a"');
			}
		}
		if (file == null) return usageError('expected <file>');
		final sourceFile: String = file;
		if ((appendTo == null) == (sortedInto == null)) return usageError("give exactly one of --append '<target>' / --sorted '<target>'");
		if (dryRun && write) return usageError('--dry-run and --write exclude each other');
		final bounds: Null<Array<Int>> = range == null ? null : parseRange(range);
		if (bounds == null) return usageError('expected --range <first>..<last> (1-based, inclusive) or --range <n>');
		final address: AddressSpec = {
			at: at,
			select: select,
			match: matchPattern,
			nth: nth
		};
		final targetSel: String = appendTo ?? sortedInto ?? '';
		return Right({
			lang: lang,
			write: write,
			reformat: reformat,
			dryRun: dryRun,
			file: sourceFile,
			address: address,
			first: bounds[0],
			last: bounds[1],
			into: into,
			target: targetAddress(targetSel),
			sorted: sortedInto != null
		});
	}

	/** A target given as `match:<pattern>` is a pattern; anything else is a selector. */
	private static function targetAddress(text: String): AddressSpec {
		return text.startsWith('match:') ? { match: text.substr('match:'.length) } : { select: text };
	}

	/** `<first>..<last>` or `<n>` as `[first, last]`, or null when it is neither. */
	private static function parseRange(text: String): Null<Array<Int>> {
		final parts: Array<String> = text.split('..');
		final first: Null<Int> = Std.parseInt(parts[0]);
		final last: Null<Int> = switch parts.length {
			case 1: first;
			case 2: Std.parseInt(parts[1]);
			case _: null;
		};
		return first == null || last == null ? null : [first, last];
	}

	private static function usageError(message: String): Either<Int, MoveElementsOpts> {
		CliIo.stderr('apq $OP: $message\n');
		printMoveElementsUsage();
		return Left(EXIT_USAGE);
	}

	private static function printMoveElementsUsage(): Void {
		CliIo.sysPrint(
			"Usage: apq move-elements <file> (<l>[:<c>] | --select '<sel>' | --match '<pattern>') --range <first>..<last>\n"
			+ "         (--append '<target>' | --sorted '<target>') [--into <destFile>] [--dry-run | --write] [--reformat]\n"
		);
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Move elements <first>..<last> (1-based, inclusive) of the addressed array literal — or of the\n');
		CliIo.sysPrint('array a declaration is initialised with — into the <target> array: appended in order (--append)\n');
		CliIo.sysPrint('or each string entry at its sorted place (--sorted, as add-element --sorted). <target> is a\n');
		CliIo.sysPrint("selector ('FinalMember:PINS'), or a pattern spelled 'match:<pattern>', resolved in --into <destFile>\n");
		CliIo.sysPrint('(default: the source file). The slice keeps its order and text; the writer formats both files.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Refused: an element that reads a local, `this` or a member; across modules, an element naming a\n');
		CliIo.sysPrint('type the destination may not see; a range outside the array; source and target that are one\n');
		CliIo.sysPrint('array or nest. The result is checked before it is written: the source must hold its old entries\n');
		CliIo.sysPrint('without the slice and the target its old entries plus the slice.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('  --dry-run   print the moved entries (whitespace collapsed) and their digest (MD5 of the\n');
		CliIo.sysPrint('              entries joined by newlines), write nothing\n');
		CliIo.sysPrint('  --write     write the source and the destination together (default: print both results)\n');
		CliIo.sysPrint('  --reformat  canonicalise a file that is not already canonical\n');
		CliIo.sysPrint('  --lang <name>  grammar plugin (default: haxe)\n');
	}

}

/** Parsed options of `apq move-elements`. */
@:nullSafety(Strict)
typedef MoveElementsOpts = {
	final lang: String;
	final write: Bool;
	final reformat: Bool;
	final dryRun: Bool;
	final file: String;
	final address: AddressSpec;
	final first: Int;
	final last: Int;
	final into: Null<String>;
	final target: AddressSpec;
	final sorted: Bool;
}
