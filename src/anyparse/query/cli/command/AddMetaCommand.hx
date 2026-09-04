package anyparse.query.cli.command;

import anyparse.query.ReplaceNode;
import anyparse.query.cli.CliContext;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

#if (sys || nodejs)
import sys.io.File;
#end

/**
 * Parsed options for `apq add-meta` — `lang`, `write` / `reformat`, the address
 * (`selectExpr` / `atSpec` / `matchExpr` / `nth` / `kind`) and the `meta` entry to add.
 * `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef AddMetaOpts = {
	var lang: String;
	var write: Bool;
	var reformat: Bool;
	var selectExpr: Null<String>;
	var atSpec: Null<String>;
	var matchExpr: Null<String>;
	var nth: Null<Int>;
	var kind: Null<String>;
	var file: Null<String>;
	var meta: Null<String>;
	// Non-null = parsing hit a terminal case; the caller returns it immediately.
	var errExit: Null<Int>;
};

/**
 * `apq add-meta` — add one @:metadata entry to a type or member (canonical-gated).
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class AddMetaCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'add-meta';
	}

	public function summary(): String {
		return 'Add one @:metadata entry to a type or member (canonical-gated)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runAddMeta(args);
	}

	public function usage(): Void {
		printAddMetaUsage();
	}

	/**
	 * `apq add-meta <file> (--select | --match | --at) '<@:meta>'` — add one
	 * metadata entry to the addressed declaration, type or member. It lands at the
	 * END of the run already there: below the doc comment, above the modifiers and
	 * the declaration keyword. A duplicate NAME is refused. See `AddMeta` for why
	 * neither `patch` nor `add-element` can reach that position.
	 */
	private static function runAddMeta(args: Array<String>): Int {
		final o: AddMetaOpts = parseAddMetaArgs(args);
		if (o.errExit != null) return o.errExit;
		final file: Null<String> = o.file;
		final meta: Null<String> = o.meta;
		if (file == null || meta == null) {
			CliIo.stderr("apq add-meta: expected <file> (--select '<sel>' | --match '<pattern>' | --at <line>[:<col>]) '<@:meta>'\n");
			printAddMetaUsage();
			return EXIT_USAGE;
		}
		final filePath: String = file;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq add-meta: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(o.lang));
		final target: Null<ReplaceTarget> = CliEdit.resolveEditTarget(
			'add-meta', source, filePath, plugin, o.selectExpr, o.matchExpr, o.atSpec, o.nth, o.kind
		);
		if (target == null) return EXIT_RUNTIME;
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(filePath);
		return CliEdit.finishEdit('add-meta', filePath, o.write, AddMeta.addMeta(source, target, meta, o.reformat, plugin, optsJson));
	}

	/** The all-default `AddMetaOpts` carrying a terminal exit code, for the `-h` / bad-flag arms. */
	private static function addMetaParseExit(code: Int): AddMetaOpts {
		return {
			lang: 'haxe',
			write: false,
			reformat: false,
			selectExpr: null,
			atSpec: null,
			matchExpr: null,
			nth: null,
			kind: null,
			file: null,
			meta: null,
			errExit: code
		};
	}

	/** Parse `apq add-meta` arguments: the address options, `<file>` and the `<@:meta>` entry. */
	private static function parseAddMetaArgs(args: Array<String>): AddMetaOpts {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var selectExpr: Null<String> = null;
		var atSpec: Null<String> = null;
		var matchExpr: Null<String> = null;
		var nth: Null<Int> = null;
		var kind: Null<String> = null;
		var file: Null<String> = null;
		var meta: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--select':
					selectExpr = CliArgs.expectValue(args, ++i, '--select');
				case '--at':
					atSpec = CliArgs.expectValue(args, ++i, '--at');
				case '--match':
					matchExpr = CliArgs.expectValue(args, ++i, '--match');
				case '--nth':
					nth = Std.parseInt(CliArgs.expectValue(args, ++i, '--nth'));
				case '--kind':
					kind = CliArgs.expectValue(args, ++i, '--kind');
				case '--write':
					write = true;
				case '--reformat':
					reformat = true;
				case '-h', '--help':
					printAddMetaUsage();
					return addMetaParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq add-meta: unknown option "$a"\n');
						return addMetaParseExit(EXIT_USAGE);
					}
					if (file == null)
						file = a;
					else if (meta == null)
						meta = a;
					else {
						CliIo.stderr('apq add-meta: unexpected extra argument "$a"\n');
						return addMetaParseExit(EXIT_USAGE);
					}
			}
			i++;
		}
		return {
			lang: lang,
			write: write,
			reformat: reformat,
			selectExpr: selectExpr,
			atSpec: atSpec,
			matchExpr: matchExpr,
			nth: nth,
			kind: kind,
			file: file,
			meta: meta,
			errExit: null
		};
	}

	/** `apq add-meta --help`. */
	private static function printAddMetaUsage(): Void {
		CliIo.sysPrint(
			"Usage: apq add-meta <file> (--select '<sel>' | --match '<pattern>' | --at <line>[:<col>]) '<@:meta>' [--reformat] "
			+ '[--write]\n'
		);
		CliUsage.printSelectorAddressingOptions();
		CliIo.sysPrint('  --kind <Kind>       With --at: narrow; with --select / --match: LIFT\n');
		CliIo.sysPrint('  --reformat          Canonicalise the whole file (allow a non-canonical input)\n');
		CliUsage.printWriteLangHelp();
		CliIo.sysPrint('Add one metadata entry to the addressed declaration — a type or a member:\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint("  apq add-meta File.hx --select 'ClassDecl:Foo' '@:nullSafety(Strict)' --write\n");
		CliIo.sysPrint("  apq add-meta File.hx --select 'FnMember:go' '@:noCompletion' --write\n");
		CliIo.sysPrint('\n');
		CliIo.sysPrint('The entry lands at the END of the run already there — BELOW the doc comment,\n');
		CliIo.sysPrint('above `public` / `static` / `final` and the declaration keyword. An entry of\n');
		CliIo.sysPrint('the same name already present is refused. Writer-formatted and re-parse-\n');
		CliIo.sysPrint('validated; the file must be canonical unless --reformat is given.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint("To REMOVE one: apq remove-element <file> --select 'MetaCall:@:name' --write\n");
		CliIo.sysPrint("(or 'Meta:@:name' for an entry with no arguments).\n");
	}

}
