package anyparse.query.cli.command;

import anyparse.query.MutationSchema.SchemaArm;
import anyparse.query.MutationSchema.SchemaFile;
import anyparse.query.cli.CliContext;
import haxe.Exception;
import anyparse.query.ExitCode.*;

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
		final files: Array<String> = [];
		final armsOf: Map<String, Array<SchemaArm>> = [];
		final rows: Array<{ id: Int, file: String }> = [];
		for (line in plan.split('\n')) if (line.trim() != '') {
			final cells: Array<String> = line.split('\t');
			final id: Int = Std.parseInt(cells[0]) ?? 0;
			if (cells.length != 4 || id <= 0) {
				CliIo.stderr('apq mutation-schema: a plan row is <id>\\t<file>\\t<selector>\\t<mutated-file>, got "$line"\n');
				return EXIT_USAGE;
			}
			final file: String = cells[1];
			final mutated: String = try CliIo.readFile(cells[3]) catch (exception: Exception) {
				CliIo.stderr('apq mutation-schema: read failed: ${exception.message}\n');
				return EXIT_RUNTIME;
			}
			if (!armsOf.exists(file)) {
				files.push(file);
				armsOf[file] = [];
			}
			armsOf[file]?.push({ id: id, select: cells[2], mutated: mutated });
			rows.push({ id: id, file: file });
		}
		final plugin: GrammarPlugin = CliArgs.pickPlugin('haxe');
		final placed: Map<Int, String> = [];
		for (file in files) {
			final arms: Array<SchemaArm> = armsOf[file] ?? [];
			final source: String = try CliIo.readFile(file) catch (exception: Exception) {
				CliIo.stderr('apq mutation-schema: read failed: ${exception.message}\n');
				return EXIT_RUNTIME;
			}
			final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: Exception) null;
			if (tree == null) {
				for (arm in arms) placed[arm.id] = 'skip\t$file\tthe file does not parse';
				continue;
			}
			final composed: SchemaFile = MutationSchema.compose(source, tree, plugin, arms);
			for (at in composed.placements) placed[at.id] = if (at.skip != null)
				'skip\t$file\t${at.skip}'
			else
				'ok\t$file\t${at.dispatch}\t${at.copyFrom}\t${at.copyTo}\t${at.owner}';
			if (composed.text != source) CliIo.writeFile(file, composed.text);
		}
		for (row in rows) CliIo.sysPrint('${row.id}\t${placed[row.id] ?? 'skip\t${row.file}\tnot composed'}\n');
		return EXIT_OK;
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
