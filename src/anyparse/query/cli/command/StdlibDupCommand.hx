package anyparse.query.cli.command;

import anyparse.core.TempScratch;
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

	/** Basename stem of the probe staging directory; the temp root and this process's id complete it. */
	private static inline final WORK_DIR_STEM: String = 'apq-stdlib-dup';

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
		announceWorkDir(dir, work);
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
		removeStagedWorkDir(dir, work);
		return EXIT_OK;
	}

	/**
	 * Name the staging directory on stderr.
	 *
	 * Not silent, because the generated probe is the only artifact a reader can go look at
	 * when a verdict surprises them, and the path is per PROCESS now — a constant in the
	 * docs would no longer find it. A resolved one also says it goes away again, so nobody
	 * plans to inspect it after the run.
	 */
	private static function announceWorkDir(dir: String, requested: Null<String>): Void {
		CliIo.stderr(
			requested == null
				? 'apq stdlib-dup: staging probes in $dir (removed when the run ends — pass --work <dir> to keep them)\n'
				: 'apq stdlib-dup: staging probes in $dir\n'
		);
	}

	/**
	 * Remove a work directory THIS run resolved; `--work` means the caller owns it.
	 *
	 * A per-process directory with nothing reaping it would be a leak where the shared one
	 * was merely wrong: `tools/tmp-lifecycle.sh` only sweeps a claimed `<prefix>.XXXXXX`
	 * name, which this is not, so the run that creates it is the only thing that can
	 * destroy it. A failure to remove is reported, never fatal — the findings are already
	 * out.
	 */
	private static function removeStagedWorkDir(dir: String, requested: Null<String>): Void {
		if (requested != null) return;
		#if (sys || nodejs)
		try {
			for (entry in FileSystem.readDirectory(dir)) {
				final path: String = haxe.io.Path.join([dir, entry]);
				if (!FileSystem.isDirectory(path)) FileSystem.deleteFile(path);
			}
			FileSystem.deleteDirectory(dir);
		} catch (exception: Exception) {
			CliIo.stderr('apq stdlib-dup: could not remove the work directory $dir (${exception.message})\n');
		}
		#end
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

	/**
	 * The directory the generated probes are staged in, created on demand; null when it cannot
	 * be made.
	 *
	 * PER PROCESS, and that is the whole correctness of the differential. Every probe is written
	 * to `<dir>/Probe.hx` under one fixed module name, and the run then spawns
	 * `haxe -cp <dir> --run Probe` — so two runs sharing a directory race between the write and
	 * the compile, and the loser compiles the OTHER run's program. The verdict that comes back is
	 * not a crash: it is a plausible, fully-formed finding about the wrong function, at exit 0.
	 * Measured on the machine-global `<temp root>/apq-stdlib-dup` this used to resolve to: two
	 * concurrent runs over two one-candidate scopes, 12 rounds, and the two processes reported
	 * IDENTICAL findings in every round — 7 of 12 wrong for one and 5 of 12 for the other, one of
	 * them naming `StringTools.endsWith` for a function that begins-with and claiming agreement
	 * on 484 generated inputs.
	 *
	 * `--work <dir>` still names it outright, which is what a caller wanting to keep the probes
	 * uses; the default is the one that had to stop being shared.
	 */
	private static function stdlibDupWorkDir(requested: Null<String>): Null<String> {
		#if (sys || nodejs)
		final base: String = requested ?? TempScratch.slot(WORK_DIR_STEM);
		if (!isWorkDirSafe(base)) {
			CliIo.stderr(
				'apq stdlib-dup: not staged — "$base" exists and is not a real directory (symlink, file or device); '
				+ 'pass --work <dir> to stage somewhere else.\n'
			);
			return null;
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

	/**
	 * Whether staging may own `path` as its work directory.
	 *
	 * `FileSystem.exists` FOLLOWS a symlink, so without this a link planted at the slot is
	 * ADOPTED: `File.saveContent` writes the generated probe through it, and — new in S171 —
	 * `removeStagedWorkDir` then deletes every non-directory entry of whatever it points at.
	 * The write half was always there; the delete half is what makes the guard non-optional.
	 * An absent target is fine — that is the ordinary first run.
	 *
	 * Check-then-use, so not atomic: a link planted in the window between still wins. The
	 * process token in the name is what closes the case that needs timing — an attacker has
	 * to guess the slot before the process that owns it exists — and this check is what stops
	 * the case that needs none, a link left lying at a predictable path. Same shape and same
	 * limits as `ProbeCommand.isStageTargetSafe`, which S170 shipped for the sibling command.
	 */
	private static function isWorkDirSafe(path: String): Bool {
		#if nodejs
		// `lstatSync`, not `statSync`: the latter resolves the link and would report the
		// VICTIM's kind, which is exactly what is being protected.
		final stat: Null<js.node.fs.Stats> = try js.node.Fs.lstatSync(path) catch (_: Exception) null;
		return stat == null || stat.isDirectory();
		#else
		// `sys.FileSystem` has no `lstat` and `exists` FOLLOWS the link, so this branch
		// catches a plain file and nothing else. Weaker than the contract on purpose, and
		// nothing in this repo compiles it — every hxml reaching this file passes
		// `-lib hxnodejs`, and the `--jvm` probe carries 0 of 3346 entries under
		// `anyparse/query/cli`.
		return !FileSystem.exists(path) || FileSystem.isDirectory(path);
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
		CliIo.sysPrint('  --work <dir>    Stage the generated probes here (default: a per-process\n');
		CliIo.sysPrint('                  directory under the OS temp root, announced on stderr)\n');
		CliIo.sysPrint('  --lang <name>   Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('  -h, --help      Show this help\n');
	}

}
