package anyparse.query.cli.command;

import anyparse.query.ExitCode.*;
import anyparse.query.MoveSymbol;
import anyparse.runtime.ParseError;

using Lambda;

/**
 * `apq move-to-helper` — move members of a class into a static helper type that takes the class as its first parameter.
 *
 * A `--scope` EDIT like `move-member`: the scope is collected first, the op (`MoveToHelper`) is pure, and the result
 * leaves through `MoveCommand`'s canonical write. Two outputs of its own: `--dry-run` prints every rewritten file as it
 * would be written, and `--arms <registry.json>` prints the mutation-arm retarget hint (`MoveToHelperArms`).
 */
@:nullSafety(Strict)
final class MoveToHelperCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'move-to-helper';
	}

	public function summary(): String {
		return 'Move class members into a static helper taking the class as first parameter';
	}

	public function flags(): CliFlags {
		return new CliFlags(['--dry-run', '--write'], ['--arms', '--file', '--param', '--scope', '--to', '--type']);
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runMoveToHelper(args);
	}

	public function usage(): Void {
		printUsage();
	}

	private static function runMoveToHelper(args: Array<String>): Int {
		final opts: Map<String, String> = [];
		final flags: Array<String> = [];
		final positional: Array<String> = [];
		for (arg in new MoveToHelperCommand().flags().walk(args)) {
			final a: String = arg.token;
			switch arg.flag {
				case '--lang', '--type', '--to', '--scope', '--file', '--param', '--arms':
					opts[a] = arg.value();
				case '--write', '--dry-run':
					flags.push(a);
				case '-h', '--help':
					printUsage();
					return EXIT_OK;
				case null:
					positional.push(a);
			}
		}
		final helper: Null<String> = opts['--to'];
		final scopeDir: Null<String> = opts['--scope'];
		if (positional.length != 2 || helper == null || scopeDir == null) {
			CliIo.stderr('apq move-to-helper: missing or extra arguments\n');
			printUsage();
			return EXIT_USAGE;
		}
		final srcFile: String = positional[0];
		final names: Array<String> = positional[1].split(',').map(StringTools.trim).filter(n -> n != '');
		final lang: String = opts['--lang'] ?? 'haxe';
		final srcTypeName: String = opts['--type'] ?? CliArgs.typeNameOfFile(lang, srcFile);
		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));
		if (CliArgs.refuseDataGrammar('move-to-helper', plugin)) return EXIT_RUNTIME;
		final scopeFiles: Null<Array<{ file: String, source: String }>> = CliArgs.collectScopeFiles(
			'move-to-helper', plugin.langName(), scopeDir, [srcFile]
		);
		if (scopeFiles == null) return EXIT_RUNTIME;
		final helperFile: Null<String> = opts['--file'];
		if (helperFile != null && !scopeFiles.exists(e -> e.file == helperFile) && exists(helperFile)) {
			CliIo.stderr('apq move-to-helper: $helperFile exists but is not under --scope\n');
			return EXIT_USAGE;
		}
		final slash: Int = srcFile.lastIndexOf('/');
		final defaultHelperFile: String = '${slash < 0 ? '' : srcFile.substring(0, slash + 1)}$helper${CliArgs.sourceExtensionOf(lang)}';
		final result: MoveResult = MoveToHelper.move(
			srcFile, srcTypeName, names, helper, helperFile ?? defaultHelperFile, opts['--param'], scopeFiles, plugin,
			plugin.typeRefShape()
		);
		return emit(result, scopeFiles, srcTypeName, helper, opts['--arms'], flags, plugin);
	}

	/**
	 * Prints or writes the move. Every output is the CANONICAL bytes the write lands (`MoveCommand.fixedPointChange` for the
	 * created helper, the move family's canonical-in / canonical-out rule for every other file), so the dry run and the arm
	 * hint read what will be on disk.
	 */
	@:access(anyparse.query.cli.command.MoveCommand)
	private static function emit(
		result: MoveResult, scopeFiles: Array<{ file: String, source: String }>, srcTypeName: String, helper: String,
		armsFile: Null<String>, flags: Array<String>, plugin: GrammarPlugin
	): Int {
		switch result {
			case Err(message):
				CliIo.stderr('apq move-to-helper: $message\n');
				return EXIT_RUNTIME;
			case Ok(raw, advisory):
				final created: Array<String> = [for (c in raw) if (!scopeFiles.exists(e -> e.file == c.file)) c.file];
				final changes: Array<MoveChange> = [
					for (c in raw)
						created.contains(c.file)
							? MoveCommand.fixedPointChange('move-to-helper', c, plugin, CliArgs.discoverFormatConfig(c.file))
							: MoveCommand.canonicalMoveChange('move-to-helper', c, plugin)
				];
				final write: Bool = flags.contains('--write') && !flags.contains('--dry-run');
				for (c in changes) {
					final tag: String = created.contains(c.file) ? 'created' : 'updated';
					if (flags.contains('--dry-run'))
						CliIo.sysPrint('=== ${c.file} ($tag) ===\n${c.newSource}');
					else if (!write)
						CliIo.sysPrint('${c.file}: $tag\n');
				}
				if (armsFile != null && !printArmHints(armsFile, changes, srcTypeName, helper, plugin)) return EXIT_RUNTIME;
				if (write) {
					CliIo.writeFiles(changes.map(c -> {path: c.file, content: c.newSource }));
					CliIo.stderr('apq move-to-helper: wrote ${changes.length} file(s)\n');
				} else {
					CliIo.sysPrint('total: ${changes.length} file(s)\n');
					CliIo.stderr('apq move-to-helper: NOTHING written — re-run with --write to apply\n');
				}
				if (advisory != null) CliIo.stderr('apq move-to-helper: $advisory\n');
				return EXIT_OK;
		}
	}

	/**
	 * Print the retarget hints of the registry `armsFile` names; false,
	 * after saying why on stderr, when a document does not read as one.
	 */
	private static function printArmHints(
		armsFile: String, changes: Array<MoveChange>, srcTypeName: String, helper: String, plugin: GrammarPlugin
	): Bool {
		final armsFiles: Array<String> = RegistryFiles.of(armsFile);
		if (armsFiles.length == 0) {
			CliIo.stderr('apq move-to-helper: cannot read the arm registry $armsFile\n');
			return false;
		}
		for (file in armsFiles) {
			final armsText: Null<String> = try CliIo.readFile(file) catch (exception: Exception) null;
			if (armsText == null) {
				CliIo.stderr('apq move-to-helper: cannot read the arm registry $file\n');
				return false;
			}
			final hints: Array<String> = try {
				MoveToHelperArms.hints(armsText, changes, srcTypeName, helper, plugin);
			} catch (exception: ParseError) {
				CliIo.stderr('apq move-to-helper: $file: ${exception.message}\n');
				return false;
			};
			for (line in hints) CliIo.sysPrint('$line\n');
		}
		return true;
	}

	private static function exists(path: String): Bool {
		return try {
			CliIo.readFile(path);
			true;
		} catch (exception: Exception) {
			false;
		};
	}

	private static function printUsage(): Void {
		CliIo.sysPrint('Usage: apq move-to-helper <srcFile> <member[,member...]> --to <Helper> --scope <dir> [options]\n\n');
		CliIo.sysPrint('Move members of a class into a static helper type that takes the class as an\n');
		CliIo.sysPrint('explicit first parameter: a moved instance member becomes static with a first\n');
		CliIo.sysPrint('parameter <param>: <Src>, its reads of the class become <param>.x, a bare this\n');
		CliIo.sysPrint('becomes <param>, calls between moved members gain <param>, and every caller\n');
		CliIo.sysPrint('becomes Helper.m(this, ...) / Helper.m(recv, ...). Private constants and\n');
		CliIo.sysPrint('module-private types only the moved code uses move along; private members the\n');
		CliIo.sysPrint('helper reads are granted with @:access(<pkg>.<Src>). A missing helper is\n');
		CliIo.sysPrint('created beside the source. Atomic (all files re-parse or none).\n\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --type <Src>   Source type name (default: the file\'s main type)\n');
		CliIo.sysPrint('  --to <Helper>  Helper type (existing under --scope, or created)\n');
		CliIo.sysPrint('  --scope <dir>  Rewrite scope (dir/glob; srcFile auto-included)\n');
		CliIo.sysPrint('  --file <path>  Where a NEW helper module goes (default: <srcDir>/<Helper>.hx)\n');
		CliIo.sysPrint('  --param <name> The source parameter (default: <Src> with a lower-case initial)\n');
		CliIo.sysPrint('  --arms <json>  Print the mutation-arm retarget hint for this registry\n');
		CliIo.sysPrint('  --dry-run      Print every rewritten file as it would be written\n');
		CliIo.sysPrint('  --write        Apply in place (default: per-file summary)\n');
		CliIo.sysPrint('  --lang <name>  Grammar plugin (default: by file extension)\n');
	}

}
