package anyparse.query.cli.command;

import anyparse.query.ExitCode.*;
import anyparse.query.MutationSchema.SchemaArm;
import anyparse.query.MutationSchema.SchemaFile;
import anyparse.query.cli.CliContext;
import haxe.Exception;

using StringTools;

/**
 * `apq mutation-schema` — compose declared arms into one build behind a run-time switch, for mutation-arm.
 *
 * A WRITE command over a scratch tree: `tools/mutation-arm.sh` runs it inside a worktree of its own.
 */
@:nullSafety(Strict)
final class MutationSchemaCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'mutation-schema';
	}

	public function summary(): String {
		return 'Compose mutation arms into one build behind a run-time switch, for mutation-arm';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		#if (sys || nodejs)
		return runMutationSchema(args);
		#else
		CliIo.stderr('apq mutation-schema: requires a sys target (file read)\n');
		return EXIT_USAGE;
		#end
	}

	public function usage(): Void {
		printMutationSchemaUsage();
	}

	#if (sys || nodejs)
	/**
	 * `apq mutation-schema <plan>` — read the plan's rows, `<id>\t<file>\t<selector>\t<mutated-file>`, compose every
	 * file's arms (`MutationSchema.compose`) and write each composed file over itself, relative to the CWD. One line per
	 * row on stdout, in plan order: `<id>\tok\t<file>\t<dispatch>\t<copyFrom>\t<copyTo>\t<owner type>`, or `<id>\tskip\t<file>\t<reason>`
	 * for an arm left to a per-arm build. A file that does not parse leaves every arm of it out, never the run.
	 */
	private static function runMutationSchema(args: Array<String>): Int {
		var planPath: Null<String> = null;
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					CliArgs.expectValue(args, ++i, '--lang');
				case '-h', '--help':
					printMutationSchemaUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('-') || planPath != null) {
						CliIo.stderr('apq mutation-schema: unexpected argument "$a"\n');
						printMutationSchemaUsage();
						return EXIT_USAGE;
					}
					planPath = a;
			}
			i++;
		}
		if (planPath == null) {
			CliIo.stderr('apq mutation-schema: no plan given\n');
			printMutationSchemaUsage();
			return EXIT_USAGE;
		}
		final plan: String = try CliIo.readFile(planPath) catch (exception: Exception) {
			CliIo.stderr('apq mutation-schema: read failed: ${exception.message}\n');
			return EXIT_RUNTIME;
		}
		final rows: Array<{ id: Int, file: String, arm: SchemaArm }> = try parsePlan(plan) catch (exception: Exception) {
			CliIo.stderr('apq mutation-schema: ${exception.message}\n');
			return EXIT_USAGE;
		}
		final files: Array<String> = [];
		for (row in rows) if (!files.contains(row.file)) files.push(row.file);
		final plugin: GrammarPlugin = CliArgs.pickPlugin('haxe');
		final placed: Map<Int, String> = [];
		for (file in files)
			try composeFile(plugin, file, [for (row in rows) if (row.file == file) row.arm], placed) catch (exception: Exception) {
				CliIo.stderr('apq mutation-schema: $file: ${exception.message}\n');
				return EXIT_RUNTIME;
			}
		for (row in rows) CliIo.sysPrint('${row.id}\t${placed[row.id] ?? 'skip\t${row.file}\tnot composed'}\n');
		return EXIT_OK;
	}
	/** The plan's rows, each arm's mutated file read; throws on a malformed row or an unreadable file. */
	private static function parsePlan(plan: String): Array<{ id: Int, file: String, arm: SchemaArm }> {
		return [
			for (line in plan.split('\n')) if (line.trim() != '') {
				final cells: Array<String> = line.split('\t');
				final id: Int = Std.parseInt(cells[0]) ?? 0;
				if (cells.length != 4 || id <= 0)
					throw new Exception('a plan row is <id>\\t<file>\\t<selector>\\t<mutated-file>, got "$line"');
				{ id: id, file: cells[1], arm: { id: id, select: cells[2], mutated: CliIo.readFile(cells[3]) } };
			}
		];
	}

	/** `file`'s arms composed into it (written over it when anything changed) and each arm's placement line into `placed`. */
	private static function composeFile(plugin: GrammarPlugin, file: String, arms: Array<SchemaArm>, placed: Map<Int, String>): Void {
		final source: String = CliIo.readFile(file);
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: Exception) null;
		if (tree == null) {
			for (arm in arms) placed[arm.id] = 'skip\t$file\tthe file does not parse';
			return;
		}
		final composed: SchemaFile = MutationSchema.compose(source, tree, plugin, arms);
		for (at in composed.placements) placed[at.id] = if (at.skip != null)
			'skip\t$file\t${at.skip}'
		else
			'ok\t$file\t${at.dispatch}\t${at.copyFrom}\t${at.copyTo}\t${at.owner}';
		if (composed.text != source) CliIo.writeFile(file, composed.text);
	}
	#end

	private static function printMutationSchemaUsage(): Void {
		CliIo.sysPrint('Usage: apq mutation-schema <plan>\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Compose declared mutation arms into ONE build behind a run-time switch\n');
		CliIo.sysPrint('(tools/mutation-arm.sh). Each plan row is\n');
		CliIo.sysPrint('  <id> TAB <file> TAB <selector> TAB <mutated-file>\n');
		CliIo.sysPrint('where <mutated-file> is <file> with the arm cut applied. Every file named is\n');
		CliIo.sysPrint('rewritten IN PLACE, relative to the working directory: the arm method is\n');
		CliIo.sysPrint('copied in as __mut<id>_<name>, and the original opens with a switch that\n');
		CliIo.sysPrint('calls the copy when APQ_MUTANT=<id>. One stdout line per row:\n');
		CliIo.sysPrint('  <id> TAB ok TAB <file> TAB <dispatch line> TAB <copy from> TAB <copy to> TAB <owner type>\n');
		CliIo.sysPrint('  <id> TAB skip TAB <file> TAB <reason>     left to a per-arm build\n');
	}

}
