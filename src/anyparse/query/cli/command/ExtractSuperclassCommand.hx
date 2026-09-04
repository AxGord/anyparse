package anyparse.query.cli.command;

import anyparse.query.MoveSymbol;
import anyparse.query.cli.CliContext;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq extract-superclass` — generate a superclass, pull members up into it + extend it.
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class ExtractSuperclassCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'extract-superclass';
	}

	public function summary(): String {
		return 'Generate a superclass, pull members up into it + extend it';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runExtractSuperclass(args);
	}

	public function usage(): Void {
		printExtractSuperclassUsage();
	}

	private static function runExtractSuperclass(args: Array<String>): Int {
		var lang: String = 'haxe';
		var srcType: Null<String> = null;
		var members: Null<String> = null;
		var out: Null<String> = null;
		var write: Bool = false;
		var srcFile: Null<String> = null;
		var superName: Null<String> = null;

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
					printExtractSuperclassUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq extract-superclass: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (srcFile == null)
						srcFile = a;
					else if (superName == null)
						superName = a;
					else {
						CliIo.stderr('apq extract-superclass: unexpected argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (srcFile == null || superName == null || members == null) {
			CliIo.stderr('apq extract-superclass: missing required arguments (need <srcFile> <SuperName> --members m1,m2)\n');
			printExtractSuperclassUsage();
			return EXIT_USAGE;
		}
		final srcFileNN: String = srcFile;
		final superNameNN: String = superName;
		final membersNN: String = members;
		final srcTypeName: String = srcType ?? RefactorSupport.baseNameOf(srcFileNN);
		final memberNames: Array<String> = membersNN.split(',').map(StringTools.trim).filter(n -> n != '');
		final slash: Int = srcFileNN.lastIndexOf('/');
		final dir: String = slash < 0 ? '' : srcFileNN.substring(0, slash + 1);
		final superFile: String = out ?? '$dir$superNameNN.hx';
		if (ExtractInterfaceCommand.refuseOccupiedDestination('extract-superclass', superFile)) return EXIT_RUNTIME;

		final source: String = try CliIo.readFile(srcFileNN) catch (exception: Exception) {
			CliIo.stderr('apq extract-superclass: $srcFileNN: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));
		// One config per FILE — see `runExtractInterface` for why each needs its own.
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(superFile);
		final srcOptsJson: Null<String> = CliArgs.discoverFormatConfig(srcFileNN);
		final result: MoveResult = ExtractSuperclass.extract(
			srcFileNN, srcTypeName, superNameNN, superFile, memberNames, source, plugin, optsJson, srcOptsJson
		);
		switch result {
			case Ok(changes, advisory):
				if (write) {
					CliIo.writeFiles([for (c in changes) { path: c.file, content: c.newSource }]);
					CliIo.stderr('apq extract-superclass: wrote ${changes.length} file(s)\n');
				} else {
					for (c in changes) CliIo.sysPrint('${c.file}: ${c.file == superFile ? 'created' : 'updated'}\n');
					CliIo.sysPrint('total: ${changes.length} file(s)\n');
					CliIo.stderr('apq extract-superclass: NOTHING written — this is a preview; re-run with --write to apply\n');
				}
				if (advisory != null) CliIo.stderr('apq extract-superclass: $advisory\n');
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq extract-superclass: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printExtractSuperclassUsage(): Void {
		CliIo.sysPrint('Usage: apq extract-superclass <srcFile> <SuperName> --members m1,m2 [options]\n\n');
		CliIo.sysPrint('Generate a superclass, pull the named instance members up into it, and\n');
		CliIo.sysPrint('make the class extend it. The superclass lands in the source package\n');
		CliIo.sysPrint('(sibling <SuperName>.hx by default) with no constructor, carrying the\n');
		CliIo.sysPrint('imports the moved bodies reference. No call sites change (inheritance).\n\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --members m1,m2    Members to pull up (required)\n');
		CliIo.sysPrint('  --type <Src>       Source class name (default: the file\'s main type)\n');
		CliIo.sysPrint('  --out <path>       Superclass file path (default: sibling <SuperName>.hx)\n');
		CliIo.sysPrint('  --write            Apply in place (default: print a per-file summary)\n');
		CliIo.sysPrint('  --lang <name>      Grammar plugin (default haxe)\n');
	}

}
