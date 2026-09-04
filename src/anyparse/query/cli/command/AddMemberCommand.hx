package anyparse.query.cli.command;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.cli.CliContext;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * Parsed options for `apq add-member` — `lang`, `write` / `reformat`, the target `typeName` and `file`, and the member body (`memberText` or `fromFile`). `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef AddMemberOpts = {
	var lang: String;
	var write: Bool;
	var reformat: Bool;
	var typeName: Null<String>;
	var file: Null<String>;
	var memberText: Null<String>;
	var fromFile: Null<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};

/**
 * `apq add-member` — append a member to a type body (writer-formatted, canonical-gated).
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class AddMemberCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'add-member';
	}

	public function summary(): String {
		return 'Append a member to a type body (writer-formatted, canonical-gated)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runAddMember(args);
	}

	public function usage(): Void {
		printAddMemberUsage();
	}

	private static inline function addMemberParseExit(code: Int): AddMemberOpts {
		return {
			lang: '',
			write: false,
			reformat: false,
			typeName: null,
			file: null,
			memberText: null,
			fromFile: null,
			errExit: code
		};
	}

	/**
	 * `apq add-member <file> --type <TypeName> <memberText> [--reformat] [--write]`
	 * — append `<memberText>` as a new member of the type named
	 * `<TypeName>`. The member is WRITER-FORMATTED: the raw text is placed
	 * before the body's closing `}` and the whole file is re-emitted through
	 * the writer (which also re-parse-validates). The file must already be
	 * writer-canonical, else it is refused unless `--reformat` is given.
	 * Without `--write` the rewritten source is emitted to stdout; with
	 * `--write` it overwrites the file in place. An unknown / ambiguous type
	 * name, a non-canonical file without `--reformat`, or an unparseable
	 * result, exits non-zero with the file untouched.
	 */
	private static function runAddMember(args: Array<String>): Int {
		final o: AddMemberOpts = parseAddMemberArgs(args);
		if (o.errExit != null) return o.errExit;
		var memberText: Null<String> = o.memberText;
		if (o.fromFile != null || memberText == '-') {
			final resolved: Null<String> = CliArgs.resolveCodeArg('add-member', memberText, o.fromFile);
			if (resolved == null) return EXIT_RUNTIME;
			memberText = resolved;
		}
		final file: Null<String> = o.file;
		final typeName: Null<String> = o.typeName;
		if (file == null || typeName == null || memberText == null) {
			CliIo.stderr('apq add-member: expected <file> --type <TypeName> (<memberText> | --from-file <path> | -)\n');
			printAddMemberUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final typeStr: String = typeName;
		final memberStr: String = memberText;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq add-member: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = CliArgs.pickPlugin(o.lang);
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(filePath);
		final result: EditResult = AddMember.addMember(source, typeStr, memberStr, o.reformat, plugin, optsJson);
		return CliEdit.finishEdit('add-member', filePath, o.write, result);
	}

	private static function printAddMemberUsage(): Void {
		CliIo.sysPrint('Usage: apq add-member <file> --type <TypeName> (<memberText> | --from-file <path> | -) [--reformat] [--write]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --type <TypeName>   Type whose body gains the member (required)\n');
		CliIo.sysPrint('  --from-file <path>  Read <memberText> from a file instead of the argument\n');
		CliIo.sysPrint('  --reformat          Canonicalise the whole file (allow a non-canonical input)\n');
		CliUsage.printWriteLangHelp();
		CliIo.sysPrint('The member text may be given inline, read from a file with --from-file, or\n');
		CliIo.sysPrint('read from stdin when it is the literal `-` (heredoc-friendly for code with\n');
		CliIo.sysPrint('`$` or quotes the shell would mangle). Append <memberText> as a new member\n');
		CliIo.sysPrint('of <TypeName>. The member is\n');
		CliIo.sysPrint('WRITER-FORMATTED — indented and laid out by the grammar\'s rules, not\n');
		CliIo.sysPrint('inserted as-is — by re-emitting the whole file through the writer (this\n');
		CliIo.sysPrint('also re-parse-validates). Works for class / interface / abstract / enum /\n');
		CliIo.sysPrint('typedef bodies; positioning is append-only (ordering is the formatting\n');
		CliIo.sysPrint('layer\'s job). The file must already be in canonical form (its own writer\n');
		CliIo.sysPrint('output); otherwise it is refused unless --reformat is given (which\n');
		CliIo.sysPrint('canonicalises the whole file). Quote <memberText> if it contains spaces.\n');
		CliIo.sysPrint('A name <TypeName> already declares — in ANY conditional-compilation branch —\n');
		CliIo.sysPrint('is refused: the result would not compile. An unknown / ambiguous type name,\n');
		CliIo.sysPrint('a non-canonical file without --reformat, or an unparseable result, likewise\n');
		CliIo.sysPrint('exits non-zero with the file untouched.\n');
	}

	private static function parseAddMemberArgs(args: Array<String>): AddMemberOpts {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var typeName: Null<String> = null;
		var file: Null<String> = null;
		var memberText: Null<String> = null;
		var fromFile: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--type':
					typeName = CliArgs.expectValue(args, ++i, '--type');
				case '--from-file':
					fromFile = CliArgs.expectValue(args, ++i, '--from-file');
				case '--write':
					write = true;
				case '--reformat':
					reformat = true;
				case '-h', '--help':
					printAddMemberUsage();
					return addMemberParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq add-member: unknown option "$a"\n');
						return addMemberParseExit(EXIT_USAGE);
					}
					if (file == null)
						file = a;
					else if (memberText == null)
						memberText = a;
					else {
						CliIo.stderr('apq add-member: unexpected extra argument "$a"\n');
						return addMemberParseExit(EXIT_USAGE);
					}
			}
			i++;
		}
		return {
			lang: lang,
			write: write,
			reformat: reformat,
			typeName: typeName,
			file: file,
			memberText: memberText,
			fromFile: fromFile,
			errExit: null
		};
	}

}
