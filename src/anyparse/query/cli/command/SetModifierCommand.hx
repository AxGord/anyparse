package anyparse.query.cli.command;

import anyparse.check.CheckScan;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.cli.CliContext;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq set-modifier` — flip visibility / add-remove modifiers at a cursor (no retype).
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class SetModifierCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'set-modifier';
	}

	public function summary(): String {
		return 'Flip visibility / add-remove modifiers at a cursor (no retype)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runSetModifier(args);
	}

	public function usage(): Void {
		printSetModifierUsage();
	}

	/**
	 * `apq set-modifier <file> <line>:<col> <change>... [--reformat] [--write]` —
	 * flip the visibility / add or remove boolean modifiers of the declaration at
	 * the cursor without retyping it (see `SetModifier`). Each change is
	 * `public` / `private` or `+<mod>` / `-<mod>`. Change tokens may begin with a
	 * single `-` (e.g. `-inline`); only a leading `--` is treated as an option.
	 * Writer-formatted + re-parse-validated (canonical-gated unless `--reformat`).
	 */
	private static function runSetModifier(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var file: Null<String> = null;
		var pos: Null<String> = null;
		var selectExpr: Null<String> = null;
		var matchExpr: Null<String> = null;
		var nth: Null<Int> = null;
		final changes: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--select':
					selectExpr = CliArgs.expectValue(args, ++i, '--select');
				case '--match':
					matchExpr = CliArgs.expectValue(args, ++i, '--match');
				case '--nth':
					nth = Std.parseInt(CliArgs.expectValue(args, ++i, '--nth'));
				case '--reformat':
					reformat = true;
				case '--write':
					write = true;
				case '-h', '--help':
					printSetModifierUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq set-modifier: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (pos == null && selectExpr == null && matchExpr == null && CliArgs.isPosSpec(a))
						pos = a;
					else
						changes.push(a);
			}
			i++;
		}
		if (file == null || (pos == null && selectExpr == null && matchExpr == null) || changes.length == 0) {
			CliIo.stderr(
				"apq set-modifier: expected <file> (<line>[:<col>] | --select '<sel>' | --match '<pattern>') <change>... ("
				+ 'e.g. public, +static, -inline)\n'
			);
			printSetModifierUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq set-modifier: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));
		final op: String = 'set-modifier';
		final loc: Null<Position> = CliEdit.resolveAddressPos(op, source, plugin, pos, selectExpr, matchExpr, nth);
		if (loc == null) return EXIT_RUNTIME;
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(filePath);
		switch SetModifier.setModifier(source, loc.line, loc.col, changes, reformat, plugin, optsJson) {
			case Ok(text, rewrites):
				CliEdit.warnRewrites(op, filePath, rewrites);
				if (write) {
					CliIo.writeFile(filePath, text);
					CliIo.stderr('apq set-modifier: wrote $filePath\n');
				} else
					CliEdit.previewEdit(op, filePath, text);
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq set-modifier: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printSetModifierUsage(): Void {
		CliIo.sysPrint(
			"Usage: apq set-modifier <file> (<line>[:<col>] | --select '<sel>' | --match '<pattern>') <change>... [--reformat] [--write]\n"
		);
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Changes:\n');
		CliIo.sysPrint('  public | private    Set the visibility\n');
		CliIo.sysPrint('  +<mod> | -<mod>     Add / remove a boolean modifier\n');
		// Read off the DEFAULT grammar's own set rather than spelled here: a seventh hand-copy of
		// the modifier vocabulary is how `overload` and `abstract` stayed unmentioned while the
		// grammar projected them.
		final shape: RefShape = CliArgs.pickPlugin('haxe').refShape();
		final visibility: Array<String> = [for (kind in shape.visibilityModifierKinds ?? []) kind.toLowerCase()];
		final booleans: Array<String> = [
			for (kind in CheckScan.modifierKinds(shape)) if (!visibility.contains(kind.toLowerCase())) kind.toLowerCase()
		];
		CliIo.sysPrint('                      (${booleans.join(', ')})\n');
		CliUsage.printSelectorAddressingSection();
		CliIo.sysPrint('  --reformat          Canonicalise the whole file (allow a non-canonical input)\n');
		CliUsage.printWriteLangHelp();
		CliIo.sysPrint('Flip the visibility / add or remove modifiers of the addressed declaration\n');
		CliIo.sysPrint('without retyping it — the safe replacement for replace-node on a modifier.\n');
		CliIo.sysPrint('`final` is not handled (it wraps the declaration; use replace-node).\n');
		CliIo.sysPrint('The result is WRITER-FORMATTED + re-parse-validated.\n');
	}

}
