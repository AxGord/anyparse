package anyparse.query.cli.command;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.ExitCode.EXIT_OK;
import anyparse.query.ExitCode.EXIT_RUNTIME;
import anyparse.query.ExitCode.EXIT_USAGE;
import anyparse.query.cli.CliArgs.ResolvedInputs;

/**
 * Parsed options for `apq typed-options` — `lang`, `kit`, `write` / `reformat` and the `inputSpecs`. `errExit` non-null means arg
 * parsing hit a terminal case the caller returns immediately.
 */
typedef TypedOptionsOpts = {
	var lang: String;
	var kit: Null<String>;
	var write: Bool;
	var reformat: Bool;
	var inputSpecs: Array<String>;
	var errExit: Null<Int>;
};

/**
 * `apq typed-options` — turns each `hxformat.json` call of a Haxe test (`loadHxFormatJson(<literal>)`, `HxWriteConfig.ofJson(<literal>)`)
 * into the typed edit of an options kit, over the baseline the call started from. The rewrite is `HxTypedOptionsRewrite`'s; this is
 * the file walk and the write tail, per file like `resolve-define`: a file that refuses is reported and left as it is.
 */
@:nullSafety(Strict)
final class TypedOptionsCommand implements CliCommand {

	private static final OP: String = 'typed-options';

	public function new() {}

	public function name(): String {
		return OP;
	}

	public function summary(): String {
		return 'Turn a Haxe test\'s hxformat.json calls into the typed edit of an options kit';
	}

	public function flags(): CliFlags {
		return new CliFlags(['--reformat', '--write', '-w'], ['--kit']);
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runTypedOptions(args, ctx.ledger);
	}

	public function usage(): Void {
		printUsage();
	}

	private static function runTypedOptions(args: Array<String>, ledger: RunLedger): Int {
		final o: TypedOptionsOpts = parseArgs(args);
		if (o.errExit != null) return o.errExit;
		final kit: Null<String> = o.kit;
		if (kit == null || o.inputSpecs.length == 0) {
			CliIo.stderr('apq typed-options: expected --kit <Type> <file/dir/glob>...\n');
			printUsage();
			return EXIT_USAGE;
		}
		final io: ResolvedInputs = CliArgs.resolveInputPaths(o.lang, o.inputSpecs);
		if (io.paths.length == 0) {
			CliIo.stderr('apq typed-options: ${CliArgs.noFilesMatched(o.lang, o.inputSpecs)}\n');
			return EXIT_RUNTIME;
		}
		var changed: Int = 0;
		var sites: Int = 0;
		var failed: Int = 0;
		for (path in io.paths) {
			final source: String = try {
				CliIo.readFile(path);
			} catch (exception: Exception) {
				CliIo.stderr('apq typed-options: $path: ${exception.message}\n');
				failed++;
				continue;
			};
			final subjects: Array<String> = [];
			final answer: EditResult = io.plugin.typedOptionsRewrite(
				source, kit, o.reformat, CliArgs.discoverFormatConfig(path, ledger), subjects
			) ?? Err('the ${io.plugin.langName()} grammar has no configuration document to type');
			for (note in subjects) CliIo.stderr('apq typed-options: $path: $note\n');
			switch answer {
				case Ok(text, rewrites):
					if (text == source) continue;
					sites += rewrites ?? 0;
					CliEdit.warnRewrites(OP, path, rewrites);
					if (o.write) {
						try {
							CliIo.writeFile(path, text);
							changed++;
						} catch (exception: WriteFailure) {
							CliIo.stderr('apq typed-options: ${exception.message}\n');
							failed++;
						}
					} else if (io.singleFile) {
						CliEdit.previewEdit(OP, path, text);
						changed++;
					} else {
						CliIo.sysPrint('$path\n');
						changed++;
					}
				case Err(message):
					CliIo.stderr('apq typed-options: $path: $message\n');
					failed++;
			}
		}
		CliIo.stderr(
			'apq typed-options: ${o.write ? 'rewrote' : 'would rewrite'} $changed file(s), $sites call(s)'
			+ (failed > 0 ? ', $failed failed' : '')
			+ '\n'
		);
		return failed > 0 ? EXIT_RUNTIME : EXIT_OK;
	}

	private static function parseArgs(args: Array<String>): TypedOptionsOpts {
		var lang: String = 'haxe';
		var kit: Null<String> = null;
		var write: Bool = false;
		var reformat: Bool = false;
		final inputSpecs: Array<String> = [];
		for (arg in new TypedOptionsCommand().flags().walk(args)) switch arg.flag {
			case '--lang':
				lang = arg.value();
			case '--kit':
				kit = arg.value();
			case '--write', '-w':
				write = true;
			case '--reformat':
				reformat = true;
			case '-h', '--help':
				printUsage();
				return {
					lang: lang,
					kit: kit,
					write: write,
					reformat: reformat,
					inputSpecs: inputSpecs,
					errExit: EXIT_OK
				};
			case null:
				inputSpecs.push(arg.token);
		}
		return {
			lang: lang,
			kit: kit,
			write: write,
			reformat: reformat,
			inputSpecs: inputSpecs,
			errExit: null
		};
	}

	private static function printUsage(): Void {
		CliIo.sysPrint('Usage: apq typed-options --kit <Type> <file/dir/glob>... [--reformat] [--write]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Rewrite each loadHxFormatJson(<literal>) / HaxeFormatConfigLoader.loadHxFormatJson(<literal>) /\n');
		CliIo.sysPrint('<Type>.strictJson(<literal>) and\n');
		CliIo.sysPrint(
			'HxWriteConfig.ofJson(<literal>) of a Haxe test into <Type>.forkWith(edited -> edited.<knob> = <value>) ('
			+ 'a block for several knobs)\n'
		);
		CliIo.sysPrint('(ofJson keeps its wrapper: HxWriteConfig.ofOptions(<Type>.forkWith(...))). <Type> is the qualified options kit;\n');
		CliIo.sysPrint('its import is added where the file is in another package, with the import of each type a value names.\n');
		CliIo.sysPrint('HxWriteFixture.triviaWrite / plainWrite(<source>, <literal>) have only the configuration argument replaced,\n');
		CliIo.sysPrint('by the bare <Type>.forkWith(...), fixture calls nested in the source argument included. A configuration that is\n');
		CliIo.sysPrint('<Type>.forkWith(...), <Type>.rawWith(...) or HxWriteConfig.ofOptions(...), or a value the file types as\n');
		CliIo.sysPrint('HxModuleWriteOptions (an annotated variable or parameter), is left as it is.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('A literal argument may be a concatenation of literals. An argument naming a local final holding such a\n');
		CliIo.sysPrint('constant, or a member final no other module can read (in a final class, not public under any define, no\n');
		CliIo.sysPrint('access-granting meta on it or its class; an access-taking meta elsewhere stays out of reach), is rewritten\n');
		CliIo.sysPrint('at its declaration, once: it becomes\n');
		CliIo.sysPrint('final <name>: HxModuleWriteOptions = <Type>.forkWith(...) (an inline modifier dropped), a loader call reading\n');
		CliIo.sysPrint('it becomes the bare name, ofJson(<name>) becomes HxWriteConfig.ofOptions(<name>), a fixture call keeps it.\n');
		CliIo.sysPrint('Every read of such a final must be one of these calls, else the file is refused.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('HxWriteFixture.listsKeepSource(<constant or final>) around a document is read as the document plus the list\n');
		CliIo.sysPrint('wraps the wrapper adds: the edit starts with HxListsKeepSource.keep(edited), then assigns what the document\n');
		CliIo.sysPrint('changes from the wrapped baseline; the wrapper argument of a fixture call is replaced too. A final read both\n');
		CliIo.sysPrint('under the wrapper and outside it is refused. An unqualified listsKeepSource(...) is a test\'s own helper.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint("A knob is assigned when the document changed it from loadHxFormatJson('{}'), so a key that sets several\n");
		CliIo.sysPrint('knobs becomes each of them. A file is left untouched, and reported, when a call holds an argument that is not\n');
		CliIo.sysPrint('a constant string nor a final holding one, a final read elsewhere, a setting the loader does not act on (the\n');
		CliIo.sysPrint('key is named), a document that does not load, or a knob changed to a value with no source spelling.\n');
		CliIo.sysPrint("A document equal to that baseline becomes HaxeFormatConfigLoader.loadHxFormatJson('{}'). A loader call whose\n");
		CliIo.sysPrint('options are only read by field (inline or through the local they initialise) is the test\'s subject: it stays\n');
		CliIo.sysPrint('on its document and is reported as `loader subject: <method>`.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --kit <Type>  The options kit, with forkWith(HxModuleWriteOptions -> Void)\n');
		CliIo.sysPrint('  --reformat    Canonicalise the whole file (allow a non-canonical input)\n');
		CliIo.sysPrint('  --write       Overwrite the files in place (default: a file prints, several list)\n');
	}

}
