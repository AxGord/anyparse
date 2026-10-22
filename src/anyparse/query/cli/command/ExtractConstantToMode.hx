package anyparse.query.cli.command;

import anyparse.query.ExitCode.*;
import anyparse.query.ExtractConstantTo;
import haxe.Exception;
#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * `apq extract-constant` ADDRESSED mode (`--select` / `--match` / `--to`), the CLI half of `ExtractConstantTo`: move
 * the expression the address names — or the initializer of the local / field declaration it names — into a
 * `static final <NAME>` of `--to <Type>` (in the source file) or of the module `--into <module.hx>` (its main type
 * unless `--to` names another), leaving `Type.NAME` behind and adding the import. A destination module that does not
 * exist is created. Preview prints both results; `--write` writes the source and the module together.
 *
 * Its own module so that `ExtractConstantCommand` keeps the two literal modes it always had; that command routes
 * here when an addressed flag is given.
 */
@:nullSafety(Strict)
final class ExtractConstantToMode {

	private static inline final OP: String = 'extract-constant';

	public static function run(args: Array<String>): Int {
		// noqa: complexity
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var shared: Bool = false;
		var file: Null<String> = null;
		var at: Null<String> = null;
		var select: Null<String> = null;
		var matchPattern: Null<String> = null;
		var nth: Null<Int> = null;
		var name: Null<String> = null;
		var destType: Null<String> = null;
		var into: Null<String> = null;
		var annotate: Null<String> = null;
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--select':
					select = CliArgs.expectValue(args, ++i, '--select');
				case '--match':
					matchPattern = CliArgs.expectValue(args, ++i, '--match');
				case '--nth':
					nth = Std.parseInt(CliArgs.expectValue(args, ++i, '--nth'));
				case '--name':
					name = CliArgs.expectValue(args, ++i, '--name');
				case '--to':
					destType = CliArgs.expectValue(args, ++i, '--to');
				case '--into':
					into = CliArgs.expectValue(args, ++i, '--into');
				case '--annotate':
					annotate = CliArgs.expectValue(args, ++i, '--annotate');
				case '--shared':
					shared = true;
				case '--reformat':
					reformat = true;
				case '--write':
					write = true;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq $OP: "$a" is not an option of the addressed mode\n');
						return EXIT_USAGE;
					}
					if (file == null) {
						file = a;
					} else if (at == null && CliArgs.isPosSpec(a)) {
						at = a;
					} else {
						CliIo.stderr('apq $OP: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || name == null) {
			CliIo.stderr('apq $OP: expected <file> (<l>[:<c>] | --select \'<sel>\' | --match \'<pattern>\') --name <NAME>\n');
			new ExtractConstantCommand().usage();
			return EXIT_USAGE;
		}
		final filePath: String = file;
		final constantName: String = name;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq $OP: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final intoPath: Null<String> = into == null || FileSystem.absolutePath(into) == FileSystem.absolutePath(filePath) ? null : into;
		final dest: Null<ExtractToModule> = if (intoPath == null)
			null
		else
			{
				file: intoPath,
				source: FileSystem.exists(intoPath)
					? (try CliIo.readFile(intoPath) catch (exception: Exception) {
						CliIo.stderr('apq $OP: $intoPath: ${exception.message}\n');
						return EXIT_RUNTIME;
					}: String)
					: null,
				pkg: NewCommand.derivePackage(intoPath),
				base: NewCommand.newFileClassName(intoPath),
				optsJson: CliArgs.discoverFormatConfig(intoPath)
			};
		final request: ExtractToRequest = {
			source: source,
			sourceFile: filePath,
			address: {
				at: at,
				select: select,
				match: matchPattern,
				nth: nth
			},
			name: constantName,
			destType: destType,
			dest: dest,
			shared: shared,
			annotate: annotate,
			reformat: reformat,
			optsJson: CliArgs.discoverFormatConfig(filePath)
		};
		switch ExtractConstantTo.extractTo(request, new CachingGrammarPlugin(CliArgs.pickPlugin(lang))) {
			case Ok(newSource, newDest, advisories):
				for (advisory in advisories) CliIo.stderr('apq $OP: note: $advisory\n');
				final writes: Array<{ path: String, content: String }> = [{ path: filePath, content: newSource }];
				if (intoPath != null && newDest != null) writes.push({ path: intoPath, content: newDest });
				if (write) {
					CliIo.writeFiles(writes);
					CliIo.stderr('apq $OP: wrote ${writes.length} file(s)\n');
				} else {
					for (w in writes) CliEdit.previewEdit(OP, w.path, w.content);
				}
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq $OP: $message\n');
				return EXIT_RUNTIME;
		}
	}

}
