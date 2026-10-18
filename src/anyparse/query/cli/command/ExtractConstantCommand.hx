package anyparse.query.cli.command;

import anyparse.query.ExitCode.*;
import anyparse.query.cli.CliContext;
import haxe.Exception;

using StringTools;
using Lambda;

#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * `apq extract-constant` — replace a repeated single-quoted literal with a named constant.
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class ExtractConstantCommand implements CliCommand {

	private static inline final SHORT_LITERAL_LEN: Int = 4;

	/** The flags that select the addressed mode (`ExtractConstantToMode`) over the two literal modes. */
	private static final ADDRESSED_FLAGS: Array<String> = ['--select', '--match', '--to'];

	public function new() {}

	public function name(): String {
		return 'extract-constant';
	}

	public function summary(): String {
		return 'Move a literal, or one addressed constant expression, into a named constant';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runExtractConstant(args);
	}

	public function usage(): Void {
		printExtractConstantUsage();
	}

	private static function runExtractConstant(args: Array<String>): Int {
		if (args.exists(a -> ADDRESSED_FLAGS.contains(a))) return ExtractConstantToMode.run(args);
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var typeName: Null<String> = null;
		var name: Null<String> = null;
		var literal: Null<String> = null;
		var intoPath: Null<String> = null;
		final scopeArgs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--type':
					typeName = CliArgs.expectValue(args, ++i, '--type');
				case '--name':
					name = CliArgs.expectValue(args, ++i, '--name');
				case '--literal':
					literal = CliArgs.expectValue(args, ++i, '--literal');
				case '--into':
					intoPath = CliArgs.expectValue(args, ++i, '--into');
				case '--reformat':
					reformat = true;
				case '--write':
					write = true;
				case '-h', '--help':
					printExtractConstantUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq extract-constant: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					scopeArgs.push(a);
			}
			i++;
		}
		if (name == null || literal == null) {
			CliIo.stderr("apq extract-constant: expected --name <NAME> --literal '<text>'\n");
			printExtractConstantUsage();
			return EXIT_USAGE;
		}
		final nameStr: String = name;
		final literalStr: String = literal;
		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));

		// --into selects cross-file mode; its absence keeps the single-file --type mode.
		final into: Null<String> = intoPath;
		if (into != null) return runExtractConstantInto(scopeArgs, into, nameStr, literalStr, reformat, write, plugin);

		if (scopeArgs.length != 1 || typeName == null) {
			CliIo.stderr(
				"apq extract-constant: expected <file> --type <Type> --name <NAME> --literal '<text>' (or --into <module> for cross-file)\n"
			);
			printExtractConstantUsage();
			return EXIT_USAGE;
		}
		final filePath: String = scopeArgs[0];
		final typeStr: String = typeName;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq extract-constant: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		// Discover the file's format config so the canonical gate matches the project's
		// writer style (e.g. space-after-colon), exactly as the --into mode does — else a
		// non-default-formatted file is wrongly rejected and --reformat rewrites its style.
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(filePath);

		final op: String = 'extract-constant';
		switch ExtractConstant.extractConstant(source, typeStr, nameStr, literalStr, reformat, plugin, optsJson) {
			case Ok(text, rewrites):
				CliEdit.warnRewrites(op, filePath, rewrites);
				if (write) {
					CliIo.writeFile(filePath, text);
					CliIo.stderr('apq extract-constant: wrote $filePath\n');
				} else
					CliEdit.previewEdit(op, filePath, text);
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq extract-constant: $message\n');
				return EXIT_RUNTIME;
		}
	}

	/**
	 * Cross-file `extract-constant --into` mode: collect every plain
	 * single-quoted `literal` across `scopeArgs`, replace each with a reference
	 * to a `public static final` on the constants module at `intoPath`
	 * (created if absent, extended otherwise). Preview (no `write`) prints
	 * per-file counts and whether the module is created or extended; `write`
	 * applies the changes and the module.
	 */
	private static function runExtractConstantInto(
		scopeArgs: Array<String>, intoPath: String, name: String, literal: String, reformat: Bool, write: Bool, plugin: GrammarPlugin
	): Int {
		if (scopeArgs.length == 0) {
			CliIo.stderr('apq extract-constant: --into mode expects one or more <scope> files/dirs/globs to search\n');
			return EXIT_USAGE;
		}
		final paths: Array<String> = CliArgs.expandInputs(scopeArgs, '.hx').paths;
		if (paths.length == 0) {
			CliIo.stderr('apq extract-constant: scope matched no .hx files\n');
			return EXIT_RUNTIME;
		}

		// The module file is not a consumer of itself: exclude it from the scan so it is
		// not both rewritten-as-consumer and written-as-module (the second write would
		// clobber the first, silently dropping the in-module occurrence).
		final intoAbs: String = FileSystem.absolutePath(intoPath);
		final scopeFiles: Array<{ file: String, source: String }> = [
			for (path in paths) if (FileSystem.absolutePath(path) != intoAbs) {
				file: path,
				source: (try CliIo.readSourceForParse(path) catch (exception: Exception) {
					CliIo.stderr('apq extract-constant: $path: ${exception.message}\n');
					return EXIT_RUNTIME;
				}: String)
			}
		];

		final moduleExists: Bool = FileSystem.exists(intoPath);
		final moduleSource: Null<String> = if (moduleExists)
			try CliIo.readFile(intoPath) catch (exception: Exception) {
				CliIo.stderr('apq extract-constant: $intoPath: ${exception.message}\n');
				return EXIT_RUNTIME;
			}
		else
			null;
		final modulePkg: String = NewCommand.derivePackage(intoPath);
		final moduleClass: String = NewCommand.newFileClassName(intoPath);
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(intoPath);

		// A short / generic literal risks coupling unrelated occurrences — warn but proceed.
		if (literal.length < SHORT_LITERAL_LEN)
			CliIo.stderr(
				'apq extract-constant: warning: literal \'$literal\' is short (<$SHORT_LITERAL_LEN'
				+ ' chars) — eyeball the preview, unrelated occurrences may be coupled\n'
			);

		switch ExtractConstant.extractInto(
			scopeFiles, modulePkg, moduleClass, moduleExists, moduleSource, name, literal, reformat, plugin, optsJson
		) {
			case Ok(changes, finalModule, created):
				var total: Int = 0;
				for (c in changes) total += c.count;
				final verb: String = created ? 'create' : 'extend';
				if (write) {
					// The module and the call sites that will reference its constant are ONE change
					// set: a run that wrote the sites and then could not write the module would
					// leave every one of them naming a constant that does not exist.
					CliIo.writeFiles([for (c in changes) { path: c.file, content: c.newSource }].concat([
						{
							path: intoPath,
							content: finalModule
						}
					]));
					CliIo.stderr('apq extract-constant: wrote ${changes.length} file(s), $total occurrence(s); module $verb $intoPath\n');
				} else {
					for (c in changes) CliIo.sysPrint('${c.file}: ${c.count} occurrence(s)\n');
					CliIo.sysPrint('total: ${changes.length} file(s), $total occurrence(s)\n');
					CliIo.sysPrint('module: $verb $intoPath\n');
					CliIo.stderr('apq extract-constant: NOTHING written — this is a preview; re-run with --write to apply\n');
				}
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq extract-constant: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printExtractConstantUsage(): Void {
		CliIo.sysPrint("Usage: apq extract-constant <file> --type <Type> --name <NAME> --literal '<text>' [--reformat] [--write]\n");
		CliIo.sysPrint(
			"       apq extract-constant <scope...> --into <module.hx> --name <NAME> --literal '<text>' [--reformat] [--write]\n"
		);
		CliIo.sysPrint(
			"       apq extract-constant <file> (<l>[:<c>] | --select '<sel>' | --match '<pattern>') --name <NAME>\n"
			+ '            (--to <Type> | --into <module.hx> [--to <Type>]) [--shared] [--annotate <Type>] [--reformat] [--write]\n'
		);
		CliUsage.printOptionsWriteLangHelp();
		CliIo.sysPrint('Single-file mode (--type): replace every plain single-quoted string\n');
		CliIo.sysPrint('literal equal to <text> inside <Type> with a reference to a fresh\n');
		CliIo.sysPrint('`private static final <NAME>`, spliced as the type\'s first member.\n');
		CliIo.sysPrint('Cross-file mode (--into): search every <scope> file/dir/glob for the\n');
		CliIo.sysPrint('literal and replace each occurrence with <Module>.<NAME>, where <Module>\n');
		CliIo.sysPrint('is the class at <module.hx> (created as a `final class` constants holder\n');
		CliIo.sysPrint('if absent, extended with a `public static final` otherwise). Files in a\n');
		CliIo.sysPrint('different package than the module gain an import; same-package files do\n');
		CliIo.sysPrint('not. Without --write, prints per-file occurrence counts and whether the\n');
		CliIo.sysPrint('module is created or extended.\n');
		CliIo.sysPrint('In both modes <text> is the literal CONTENT (no surrounding quotes); the\n');
		CliIo.sysPrint('constant reuses the first occurrence\'s verbatim source token, so escaping\n');
		CliIo.sysPrint('is preserved. Plain single- and double-quoted literals match; an\n');
		CliIo.sysPrint('interpolated literal and literals inside metadata are left untouched.\n');
		CliIo.sysPrint('Deciding the occurrences are the SAME concept is the caller\'s judgement.\n');
		CliIo.sysPrint('An invalid / colliding <NAME>, a missing type or module, or a literal\n');
		CliIo.sysPrint('that does not occur exits non-zero with nothing written. Rewrites re-parse.\n');
		CliIo.sysPrint('Addressed mode (--select / --match / a position, with --to or --into): move\n');
		CliIo.sysPrint('ONE expression — or the initializer of the local / field declaration the address\n');
		CliIo.sysPrint('names — into a `static final <NAME>` of <Type> (in this file) or of the module\n');
		CliIo.sysPrint('<module.hx> (created when absent), leaving `<Type>.<NAME>` and the import behind.\n');
		CliIo.sysPrint('It must read no local, `this` or member and be a compile-time constant (a literal,\n');
		CliIo.sysPrint('an operator or parentheses over literals); an array / object literal of them only\n');
		CliIo.sysPrint('with --shared (no reader mutates the one shared instance). A scalar literal becomes\n');
		CliIo.sysPrint('`static inline final`. Refused in metadata, a case pattern, a non-inline parameter\n');
		CliIo.sysPrint('default, and where `<Type>` would bind something else. The declared type is carried\n');
		CliIo.sysPrint('when the destination can see it; --annotate spells it otherwise.\n');
	}

}
