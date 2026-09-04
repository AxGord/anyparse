package anyparse.query.cli.command;

import anyparse.query.MoveSymbol;
import anyparse.query.cli.CliContext;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;
using Lambda;

#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * `apq extract-interface` — generate an interface from a class's public methods + implement it.
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class ExtractInterfaceCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'extract-interface';
	}

	public function summary(): String {
		return 'Generate an interface from a class\'s public methods + implement it';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runExtractInterface(args);
	}

	public function usage(): Void {
		printExtractInterfaceUsage();
	}

	/**
	 * True — after saying so on stderr — when `path` already holds a file, for the two
	 * ops that GENERATE a whole module and hand it to `writeFiles`.
	 *
	 * `extract-interface` and `extract-superclass` build the destination's complete
	 * text; an occupied path is therefore overwritten, never merged. Measured on the
	 * base commit: `apq extract-interface C.hx Helper` with a sibling `Helper.hx`
	 * present replaced that class, its doc and its members with the generated
	 * interface, reported `wrote 2 file(s)` at rc 0, and the preview had called the
	 * same file `created`. No flag was needed — the default `--out` is the type name,
	 * so any name that collides with a sibling module destroys it.
	 *
	 * The rule is the create-only one `apq new` already states; these two are the only
	 * file-generating ops that do not go through it. Merging into an existing module is
	 * a different feature and it has a different spelling — `extract-constant --into`,
	 * which reads the destination first and names the intent in the flag.
	 */
	public static function refuseOccupiedDestination(op: String, path: String): Bool {
		if (!FileSystem.exists(path)) return false;
		CliIo.stderr(
			'apq $op: $path already exists — $op generates a whole module and would overwrite it '
			+ '(create-only, as `apq new` is); pass --out <path> naming a free file, or move that one aside\n'
		);
		return true;
	}

	private static function runExtractInterface(args: Array<String>): Int {
		var lang: String = 'haxe';
		var srcType: Null<String> = null;
		var members: Null<String> = null;
		var out: Null<String> = null;
		var write: Bool = false;
		var srcFile: Null<String> = null;
		var ifaceName: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--type':
					srcType = CliArgs.expectValue(args, ++i, '--type');
				case '--members':
					members = CliArgs.expectValue(args, ++i, '--members');
				case '--out':
					out = CliArgs.expectValue(args, ++i, '--out');
				case '--write':
					write = true;
				case '-h', '--help':
					printExtractInterfaceUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq extract-interface: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (srcFile == null)
						srcFile = a;
					else if (ifaceName == null)
						ifaceName = a;
					else {
						CliIo.stderr('apq extract-interface: unexpected argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (srcFile == null || ifaceName == null) {
			CliIo.stderr('apq extract-interface: missing required arguments\n');
			printExtractInterfaceUsage();
			return EXIT_USAGE;
		}
		final srcFileNN: String = srcFile;
		final ifaceNameNN: String = ifaceName;
		final srcTypeName: String = srcType ?? RefactorSupport.baseNameOf(srcFileNN);
		final memberNames: Null<Array<String>> = members?.split(',').map(StringTools.trim).filter(n -> n != '');
		final slash: Int = srcFileNN.lastIndexOf('/');
		final dir: String = slash < 0 ? '' : srcFileNN.substring(0, slash + 1);
		final ifaceFile: String = out ?? '$dir$ifaceNameNN.hx';
		if (refuseOccupiedDestination('extract-interface', ifaceFile)) return EXIT_RUNTIME;

		final source: String = try CliIo.readFile(srcFileNN) catch (exception: Exception) {
			CliIo.stderr('apq extract-interface: $srcFileNN: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));
		// One config per FILE, because each is judged by the one that governs where IT lands
		// and `--out` can put the interface under a different `hxformat.json` from the class.
		// Passing null for the created file styled it by compiled defaults, so `fmt --list`
		// called it drifted the moment it was written; passing null for the source would make
		// a project-canonical class read as drifted and silently forfeit the canonical-out
		// half of the edit.
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(ifaceFile);
		final srcOptsJson: Null<String> = CliArgs.discoverFormatConfig(srcFileNN);
		final result: MoveResult = ExtractInterface.extract(
			srcFileNN, srcTypeName, ifaceNameNN, ifaceFile, memberNames, source, plugin, optsJson, srcOptsJson
		);
		switch result {
			case Ok(changes, advisory):
				if (write) {
					CliIo.writeFiles([for (c in changes) { path: c.file, content: c.newSource }]);
					CliIo.stderr('apq extract-interface: wrote ${changes.length} file(s)\n');
				} else {
					for (c in changes) CliIo.sysPrint('${c.file}: ${c.file == ifaceFile ? 'created' : 'updated'}\n');
					CliIo.sysPrint('total: ${changes.length} file(s)\n');
					CliIo.stderr('apq extract-interface: NOTHING written — this is a preview; re-run with --write to apply\n');
				}
				if (advisory != null) CliIo.stderr('apq extract-interface: $advisory\n');
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq extract-interface: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printExtractInterfaceUsage(): Void {
		CliIo.sysPrint('Usage: apq extract-interface <srcFile> <IfaceName> [options]\n\n');
		CliIo.sysPrint('Generate an interface from a class\'s public instance methods and make\n');
		CliIo.sysPrint('the class implement it. The interface lands in the source type\'s package\n');
		CliIo.sysPrint('(sibling file <IfaceName>.hx by default), carrying the imports its\n');
		CliIo.sysPrint('signatures reference; the class gains an "implements <IfaceName>" clause.\n');
		CliIo.sysPrint('No call sites change (an interface is additive).\n\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --type <Src>       Source class name (default: the file\'s main type)\n');
		CliIo.sysPrint('  --members m1,m2    Only these methods (default: every public method)\n');
		CliIo.sysPrint('  --out <path>       Interface file path (default: sibling <IfaceName>.hx)\n');
		CliIo.sysPrint('  --write            Apply in place (default: print a per-file summary)\n');
		CliIo.sysPrint('  --lang <name>      Grammar plugin (default haxe)\n');
	}

}
