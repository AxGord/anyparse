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
 * Parsed options for `apq patch` — `lang`, `write` / `reformat`, the address (`selectExpr` / `atSpec` / `matchExpr` / `nth` / `kind`), the old/new `sep`, and the `payload` (or `fromFile`). `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef PatchOpts = {
	var lang: String;
	var write: Bool;
	var reformat: Bool;
	var selectExpr: Null<String>;
	var atSpec: Null<String>;
	var matchExpr: Null<String>;
	var nth: Null<Int>;
	var kind: Null<String>;
	var sep: String;

	/** Rewrite EVERY occurrence of each old fragment instead of demanding a unique one. */
	var all: Bool;
	var file: Null<String>;
	var payload: Null<String>;
	var fromFile: Null<String>;
	// Non-null = parsing hit a terminal case; the caller returns it immediately.
	var errExit: Null<Int>;
};

/**
 * `apq patch` — replace ONE unique fragment inside a node (old ==== new, stdin).
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class PatchCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'patch';
	}

	public function summary(): String {
		return 'Replace ONE unique fragment inside a node (old ==== new, stdin)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runPatch(args);
	}

	public function usage(): Void {
		printPatchUsage();
	}

	/**
	 * `apq patch <file> (--select | --match | --at) (- | --from-file <path>)` —
	 * replace ONE unique fragment inside the addressed node. The payload holds
	 * the old fragment, a separator line (`====` by default, `--sep` overrides),
	 * and the new fragment — so a small edit does not resend the whole
	 * declaration. The old fragment must occur exactly once within the resolved
	 * node's source. Finalized like replace-node: writer-formatted, re-parse
	 * validated, canonical-gated unless `--reformat`.
	 */
	private static function runPatch(args: Array<String>): Int {
		final o: PatchOpts = parsePatchArgs(args);
		if (o.errExit != null) return o.errExit;
		var payload: Null<String> = o.payload;
		if (o.fromFile != null || payload == '-') {
			final resolved: Null<String> = CliArgs.resolveCodeArg('patch', payload, o.fromFile, true);
			if (resolved == null) return EXIT_RUNTIME;
			payload = resolved;
		}
		final file: Null<String> = o.file;
		if (file == null || payload == null) {
			CliIo.stderr(
				"apq patch: expected <file> (--select '<sel>' | --match '<pattern>' | --at <line>[:<col>]) (- | --from-file <path>)\n"
			);
			printPatchUsage();
			return EXIT_USAGE;
		}
		final pairs: Null<Array<{ oldText: String, newText: String }>> = splitPatchPayload(payload, o.sep);
		if (pairs == null) {
			CliIo.stderr(
				'apq patch: the payload must alternate old / new fragments separated by "${o.sep}'
				+ '" lines — an EVEN number of sections (2 = one pair, 4 = two pairs, …)\n'
			);
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq patch: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(o.lang));
		final target: Null<ReplaceTarget> = CliEdit.resolveEditTarget(
			'patch', source, filePath, plugin, o.selectExpr, o.matchExpr, o.atSpec, o.nth, o.kind
		);
		if (target == null) return EXIT_RUNTIME;

		final optsJson: Null<String> = CliArgs.discoverFormatConfig(filePath);
		// A multi-pair call is all-or-nothing, so a success line that names the count is
		// the one thing that settles "did all of them land?" without re-reading the file.
		return CliEdit.finishEdit(
			'patch', filePath, o.write, Patch.patchNodeMany(source, target, pairs, o.reformat, plugin, optsJson, o.all),
			pairs.length > 1 ? '${pairs.length} fragment pairs applied' : null
		);
	}

	/**
	 * Split a patch payload into (old, new) fragment pairs on the lines whose
	 * trimmed content equals `sep`: two sections = one pair, 2N sections = N
	 * pairs. Returns null when there is no separator line or the section count
	 * is odd. The fragments keep their internal newlines verbatim; the newline
	 * on each side of a separator line belongs to the separator. A new fragment
	 * that must itself contain separator-looking lines needs `--sep`.
	 */
	private static function splitPatchPayload(payload: String, sep: String): Null<Array<{ oldText: String, newText: String }>> {
		final lines: Array<String> = payload.split('\n');
		final sections: Array<Array<String>> = [[]];
		for (l in lines) if (l.trim() == sep)
			sections.push([]);
		else
			sections[sections.length - 1].push(l);
		return sections.length < 2 || sections.length % 2 != 0 ? null : [
			for (i in 0...(sections.length >> 1))
				{ oldText: sections[i * 2].join('\n'), newText: sections[i * 2 + 1].join('\n') }
		];
	}

	private static function parsePatchArgs(args: Array<String>): PatchOpts {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var selectExpr: Null<String> = null;
		var atSpec: Null<String> = null;
		var matchExpr: Null<String> = null;
		var nth: Null<Int> = null;
		var kind: Null<String> = null;
		var sep: String = '====';
		var all: Bool = false;
		var file: Null<String> = null;
		var payload: Null<String> = null;
		var fromFile: Null<String> = null;

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
				case '--sep':
					sep = CliArgs.expectValue(args, ++i, '--sep');
				case '--from-file':
					fromFile = CliArgs.expectValue(args, ++i, '--from-file');
				case '--write':
					write = true;
				case '--reformat':
					reformat = true;
				case '--all':
					all = true;
				case '-h', '--help':
					printPatchUsage();
					return patchParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq patch: unknown option "$a"\n');
						return patchParseExit(EXIT_USAGE);
					}
					if (file == null)
						file = a;
					else if (payload == null)
						payload = a;
					else {
						CliIo.stderr('apq patch: unexpected extra argument "$a"\n');
						return patchParseExit(EXIT_USAGE);
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
			sep: sep,
			all: all,
			file: file,
			payload: payload,
			fromFile: fromFile,
			errExit: null
		};
	}

	private static function patchParseExit(code: Int): PatchOpts {
		return {
			lang: 'haxe',
			write: false,
			reformat: false,
			selectExpr: null,
			atSpec: null,
			matchExpr: null,
			nth: null,
			kind: null,
			sep: '====',
			all: false,
			file: null,
			payload: null,
			fromFile: null,
			errExit: code
		};
	}

	private static function printPatchUsage(): Void {
		CliIo.sysPrint(
			"Usage: apq patch <file> (--select '<sel>' | --match '<pattern>' | --at <line>[:<col>]) (- | --from-file <path>) ["
			+ '--sep <marker>] [--all] [--reformat] [--write]\n'
		);
		CliUsage.printSelectorAddressingOptions();
		CliIo.sysPrint('  --kind <Kind>       With --at: narrow; with --select / --match: LIFT\n');
		CliIo.sysPrint('  --sep <marker>      Separator line between the fragments (default: ====)\n');
		CliIo.sysPrint('  --from-file <path>  Read the payload from a file instead of stdin\n');
		CliIo.sysPrint('  --all               Rewrite EVERY occurrence of each old fragment, not just a unique one\n');
		CliIo.sysPrint('  --reformat          Canonicalise the whole file (allow a non-canonical input)\n');
		CliUsage.printWriteLangHelp();
		CliIo.sysPrint('Replace ONE unique fragment inside the addressed node without resending\n');
		CliIo.sysPrint('the whole declaration. The payload is the OLD fragment, a separator line\n');
		CliIo.sysPrint('(a line that is exactly the marker, default `====`), and the NEW fragment:\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint("  apq patch File.hx --select 'FnMember:walk' --write - <<'EOF'\n");
		CliIo.sysPrint('  old line;\n');
		CliIo.sysPrint('  ====\n');
		CliIo.sysPrint('  new line;\n');
		CliIo.sysPrint('  EOF\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Copy the old fragment VERBATIM from `apq source --select` — it must occur\n');
		CliIo.sysPrint('exactly once within the resolved node (widen it until unique, or pass --all\n');
		CliIo.sysPrint('to rewrite every occurrence — for a fan-out you mean, such as the same arm\n');
		CliIo.sysPrint('added to every switch that lists a sister enum ctor); a multi-line\n');
		CliIo.sysPrint('fragment is matched with per-line indentation ignored, so the dedented\n');
		CliIo.sysPrint('`apq source --select` output works as-is. SEVERAL pairs may be applied in\n');
		CliIo.sysPrint('one call: alternate old / new sections (an even count) — old1 ==== new1\n');
		CliIo.sysPrint('==== old2 ==== new2 — matched against the ORIGINAL node text, ranges must\n');
		CliIo.sysPrint('not overlap. The result is writer-formatted and re-parse-validated like\n');
		CliIo.sysPrint('replace-node; the file must already be canonical unless --reformat is given.\n');
	}

}
