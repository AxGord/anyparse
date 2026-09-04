package anyparse.query.cli.command;

import anyparse.query.cli.CliContext;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;
using Lambda;

#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * `apq stdlib-dup` — report pure functions a differential run proves equal to a stdlib call.
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class StdlibDupCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'stdlib-dup';
	}

	public function summary(): String {
		return 'Report pure functions a differential run proves equal to a stdlib call';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		#if (sys || nodejs)
		return runStdlibDup(args);
		#else
		CliIo.stderr('apq stdlib-dup: requires a sys target (probe staging + compiler spawn)\n');
		return EXIT_USAGE;
		#end
	}

	public function usage(): Void {
		#if (sys || nodejs)
		printStdlibDupUsage();
		#end
	}

	/**
	 * `apq stdlib-dup <scope...> [--lang <name>] [--limit <n>] [--census] [--work <dir>]` --
	 * report every pure, self-contained, primitive-signature function in the scope that a
	 * differential run finds indistinguishable from a stdlib call.
	 *
	 * Two tiers, and `--census` stops after the first. Tier one is `StdlibDupScan`: pure analysis,
	 * no compiler, and its per-stage drop-off is printed to stderr on every run because that count
	 * is the measurement worth having even when nothing matches. Tier two is
	 * `StdlibDifferential`: one generated program per candidate, compiled and run on the Haxe
	 * interpreter, which is why it is opt-out rather than free.
	 *
	 * Findings are INFO by design -- agreement over a finite grid is evidence, not proof -- so this
	 * command never writes an edit and exits `EXIT_OK` whatever it finds.
	 */
	private static function runStdlibDup(args: Array<String>): Int {
		var lang: String = 'haxe';
		var limit: Int = 0;
		var censusOnly: Bool = false;
		var work: Null<String> = null;
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--limit':
					limit = Std.parseInt(CliArgs.expectValue(args, ++i, '--limit')) ?? 0;
				case '--work':
					work = CliArgs.expectValue(args, ++i, '--work');
				case '--census':
					censusOnly = true;
				case '-h', '--help':
					printStdlibDupUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq stdlib-dup: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					inputSpecs.push(a);
			}
			i++;
		}
		if (inputSpecs.length == 0) {
			CliIo.stderr('apq stdlib-dup: expected <scope> (one or more file/dir/glob specs)\n');
			printStdlibDupUsage();
			return EXIT_USAGE;
		}

		final io = CliArgs.resolveInputPaths(lang, inputSpecs);
		final paths: Array<String> = io.paths;
		if (paths.length == 0) {
			CliIo.stderr('apq stdlib-dup: ${CliArgs.quotedSpecs(inputSpecs)} matched no source files\n');
			return EXIT_RUNTIME;
		}

		final files: Array<{ file: String, source: String }> = [];
		for (path in paths) {
			final source: Null<String> = try CliIo.readSourceForParse(path) catch (exception: Exception) null;
			if (source == null)
				CliIo.stderr('apq stdlib-dup: $path: unreadable, skipped\n')
			else
				files.push({ file: path, source: source });
		}
		final scan: StdlibDupScan.ScanResult = StdlibDupScan.scanAll(files, io.plugin);
		final stages: StdlibDupScan.ScanStages = scan.stages;
		CliIo.stderr('apq stdlib-dup: ${files.length} file(s); functions ${stages.functions}');
		CliIo.stderr(' -> bodied ${stages.bodied} -> arity<=3 ${stages.arityOk}');
		CliIo.stderr(' -> primitive signature ${stages.primitiveSig} -> self-contained ${stages.selfContained}\n');
		if (censusOnly) return EXIT_OK;

		final dir: Null<String> = stdlibDupWorkDir(work);
		if (dir == null) {
			CliIo.stderr('apq stdlib-dup: could not create a work directory for the probes\n');
			return EXIT_RUNTIME;
		}
		final sourceOf: Map<String, String> = [];
		for (entry in files) sourceOf[entry.file] = entry.source;
		var driven: Int = 0;
		var found: Int = 0;
		for (candidate in scan.candidates) {
			if (limit > 0 && driven >= limit) break;
			driven++;
			final maps: Array<StdlibDifferential.Mapping> = StdlibDifferential.mappings(candidate);
			final where: String = stdlibDupPosition(candidate, sourceOf[candidate.file] ?? '');
			switch (StdlibDifferential.run(candidate, maps, dir)) {
				case Matched(hits, inputs):
					// A candidate that also agrees with a TRIVIAL baseline returns an argument or a
					// body constant unchanged over the whole grid; every stdlib call it "matches" is
					// matching that identity, not the candidate. Report the reason, never the calls.
					final trivial: Array<StdlibDifferential.Mapping> = hits.filter(StdlibDifferential.isTrivial);
					if (trivial.length > 0)
						CliIo.stderr(
							'apq stdlib-dup: $where: ${stdlibDupSubject(candidate)}: trivial — returns ${trivial[0].display}'
							+ ' unchanged over the grid\n'
						)
					else
						for (hit in hits) {
							found++;
							CliIo.sysPrint('$where: info: ${stdlibDupSubject(candidate)} looks like ${hit.display}');
							CliIo.sysPrint(' — agreed on $inputs generated inputs, ${maps.length} mapping(s) tried [stdlib-dup]\n');
						}
				case NoMatch(inputs, tried):
					CliIo.stderr('apq stdlib-dup: $where: ${stdlibDupSubject(candidate)}: no match ($tried mapping(s), $inputs inputs)\n');
				case Skipped(reason):
					CliIo.stderr('apq stdlib-dup: $where: ${stdlibDupSubject(candidate)}: skipped — $reason\n');
			}
		}
		CliIo.stderr('apq stdlib-dup: drove $driven candidate(s), $found finding(s)\n');
		return EXIT_OK;
	}

	/** `<file>:<line>:<col>` of a candidate's declaration, resolved against its own file's source. */
	private static function stdlibDupPosition(candidate: StdlibDupScan.StdlibCandidate, source: String): String {
		final pos: Position = candidate.span.lineCol(source);
		return '${candidate.file}:${pos.line}:${pos.col}';
	}

	/** How a report names a candidate: `Owner.name` when the enclosing type is known, else the bare name. */
	private static function stdlibDupSubject(candidate: StdlibDupScan.StdlibCandidate): String {
		final owner: Null<String> = candidate.owner;
		return owner == null ? candidate.name : '$owner.${candidate.name}';
	}

	/** The directory the generated probes are staged in, created on demand; null when it cannot be made. */
	private static function stdlibDupWorkDir(requested: Null<String>): Null<String> {
		#if (sys || nodejs)
		final base: String = if (requested != null)
			requested
		else {
			#if nodejs
			haxe.io.Path.join([js.node.Os.tmpdir(), 'apq-stdlib-dup']);
			#else
			haxe.io.Path.join([Sys.getEnv('TMPDIR') ?? '/tmp', 'apq-stdlib-dup']);
			#end
		}
		try {
			if (!FileSystem.exists(base)) FileSystem.createDirectory(base);
		} catch (exception: Exception) {
			return null;
		}
		return base;
		#else
		return null;
		#end
	}

	private static function printStdlibDupUsage(): Void {
		CliIo.sysPrint('Usage: apq stdlib-dup <scope...> [options]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Report pure, self-contained, primitive-signature functions that a differential\n');
		CliIo.sysPrint('run cannot tell apart from a stdlib call — "this looks like StringTools.lpad,\n');
		CliIo.sysPrint('check it". Findings are informational: nothing is ever rewritten.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('The per-stage candidate census always goes to stderr. With --census the run\n');
		CliIo.sysPrint('stops there and spawns no compiler.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --census        Candidate census only — no probe generation, no haxe spawn\n');
		CliIo.sysPrint('  --limit <n>     Drive at most n candidates through the differential\n');
		CliIo.sysPrint('  --work <dir>    Stage the generated probes here (default: a temp directory)\n');
		CliIo.sysPrint('  --lang <name>   Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('  -h, --help      Show this help\n');
	}

}
