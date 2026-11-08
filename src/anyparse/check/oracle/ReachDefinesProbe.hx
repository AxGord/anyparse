package anyparse.check.oracle;

import anyparse.core.PhaseTimings;
import anyparse.core.TempScratch;
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.proc.PendingRuns;
import anyparse.proc.ProcessRun;
import anyparse.proc.ProcessSpawn;
import anyparse.proc.SpawnJob;
import anyparse.query.FileIdentity;
import anyparse.query.ReachLiveness.ReachBuilds;
import anyparse.query.ReachLiveness.ReachConfiguration;
import haxe.Exception;
import haxe.io.Path;

/**
 * A batch of define probes `ReachDefinesProbe.start` began: the configurations, the build of each the run already held
 * (`OracleRunMemo.builds`), and the probe directories and compiles of the rest.
 */
typedef DefinesProbe = {
	oracles: Array<OracleConfig>,
	held: Array<Null<ReachConfiguration>>,
	ready: Null<Array<{ dir: String, args: Array<String> }>>,
	runs: Null<PendingRuns>
};

/**
 * Another probe's hook riding the define probe's compile (`ReachDefinesProbe.prepare`): it joins the compile's arm after
 * the probe's own macros, so one compile answers both.
 */
typedef ProbeRider = {

	/** The defines the hook needs, set right after the probe read the first define set. */
	defines: Array<String>,

	/** The hook's class path, added after the build's own: a module of it shadows the build's module of that path. */
	dir: String,

	/** The files of `dir`, by class-path-relative path. */
	files: Array<{ path: String, text: String }>,

	/** The hook's arguments, appended after the probe's. */
	tail: Array<String>,

	/** The dotted name of the hook's initialization macro: the hook's own loads end where it exits. */
	hook: String

};

/**
 * What a compile carrying a `ProbeRider` answers apart from the rider (`ReachDefinesProbe.readRidden`): its compile arms,
 * the `-v` typecheck it stands for (`OracleCoverage.probeArgs`) and the build the probe reports — both null when the
 * rider may have changed either.
 */
typedef RiddenReading = {
	arms: Int,
	verbose: Null<ProcessRun>,
	configuration: Null<ReachConfiguration>
};

/**
 * What each configured compiler oracle DEFINES, for the reach analysis to decide conditional compilation with
 * (`anyparse.query.ReachLiveness`). Asked of the compiler, never modelled: one compile of the configuration's own
 * hxml with two probe macros. The FIRST initialization macro of the compile prints the define set before any other
 * initialization macro runs — an earlier one may type a module, and a later one define a name that module's `#if` did
 * not see — so only the command line's defines and the target's count as defined for every file. The second prints the
 * set once typing ended, when it holds every define the build ever set; the compiler never removes one, so a name
 * outside it was never defined, and one between the two sets is undecided either way. Each prints every define's
 * value as well: a define of the first set whose value the second still gives it held that value for every file
 * (`ReachConfiguration.values`), which decides a comparison such as `haxe_ver >= 4.2` (`CondValues`) — save a value a
 * macro changed and changed back in between, which no probe can see. It also names every type the
 * build typed and its file: the index the analysis reads must declare
 * each, or a type it cannot see may exist. `-v` counts the compile's arms:
 * the macros join the last arm only, so an hxml of several arms answers nothing, and so does any probe that fails. An
 * answer must hold in every configuration, so one unanswered configuration leaves the analysis with none (`probeAll`).
 * Another probe's hook may ride the compile (`ProbeRider`), which then answers both (`readRidden`); a build a run already
 * holds that way (`OracleRunMemo.builds`) is not compiled again.
 */
@:nullSafety(Strict)
final class ReachDefinesProbe {

	/** Spawn buffer, in bytes: `-v` names every parsed module. */
	public static inline final BUFFER: Int = 256 * 1024 * 1024;

	/** The class name of the probe macro, written to a directory of its own. */
	private static inline final MACRO_CLASS: String = 'AnyparseReachDefinesProbe';

	private static inline final EARLY_PREFIX: String = 'APQ-REACH-EARLY-DEFINES ';
	private static inline final FINAL_PREFIX: String = 'APQ-REACH-FINAL-DEFINES ';

	/** The probe's line naming one define and its value, as a JSON pair, at the first initialization macro. */
	private static inline final EARLY_VALUE_PREFIX: String = 'APQ-REACH-EARLY-VALUE ';

	/** The probe's line naming one define and its value, as a JSON pair, once typing ended. */
	private static inline final FINAL_VALUE_PREFIX: String = 'APQ-REACH-FINAL-VALUE ';

	/** The `haxe -v` line that opens one compile arm. */
	private static inline final DEFINES_PREFIX: String = 'Defines:';

	/** The `haxe -v` line naming every class path, the one the compiler searches first leading. */
	private static inline final CLASSPATH_PREFIX: String = 'Classpath: ';

	/** The `haxe -v` line naming one file the compile parsed. */
	private static inline final PARSED_PREFIX: String = 'Parsed ';

	/** The `haxe -v` line closing one macro call. */
	private static inline final EXIT_PREFIX: String = 'Exiting macro ';

	/** The prefix every line the probe macro prints opens with. */
	private static inline final PROBE_LINE: String = 'APQ-REACH-';

	/** The compiler flag running an initialization macro. */
	private static inline final MACRO_FLAG: String = '--macro';

	/** The probe's line naming one type the build's runtime context typed, then the file that declares it. */
	private static inline final TYPE_PREFIX: String = 'APQ-REACH-TYPE ';

	/** The bound of the random suffix that keeps two runs' probe directories apart. */
	private static inline final DIRECTORY_SUFFIX_BOUND: Int = 0x7fffffff;

	/**
	 * The builds of `oracles`, each probed once — the compiles overlap (`ProcessSpawn.parallelism`) — with the source of every file
	 * any of them compiles (one that cannot be read is left out); null when any of them cannot be probed.
	 */
	public static function probeAll(oracles: Array<OracleConfig>): Null<ReachBuilds> {
		final probe: DefinesProbe = prepared(oracles);
		final jobs: Null<Array<SpawnJob>> = jobsFor(probe);
		return PhaseTimings.measure(
			'reach defines probe',
			() ->
				answerAll(
					oracles, probe.held, probe.ready, jobs == null ? [] : ProcessSpawn.runAll(jobs, BUFFER, ProcessSpawn.parallelism())
				)
		);
	}

	/**
	 * `probeAll`'s compiles started in the background, to overlap compiles the run is waiting on anyway (the facts): a run
	 * that will ask the builds starts them as soon as it knows, and `finish` answers what `probeAll` would have answered
	 * once they end. The library sources are read at `finish`, as `probeAll` reads them after its compiles.
	 */
	public static function start(oracles: Array<OracleConfig>): DefinesProbe {
		final probe: DefinesProbe = prepared(oracles);
		final jobs: Null<Array<SpawnJob>> = jobsFor(probe);
		probe.runs = jobs == null || jobs.length == 0 ? null : ProcessSpawn.startAll(jobs, BUFFER, ProcessSpawn.parallelism());
		return probe;
	}

	/** What the compiles `start` began answer: `probeAll`'s answer for the same configurations. */
	public static function finish(probe: DefinesProbe): Null<ReachBuilds> {
		final runs: Null<PendingRuns> = probe.runs;
		return PhaseTimings.measure(
			'reach defines probe (started ahead)',
			() -> answerAll(probe.oracles, probe.held, probe.ready, runs == null ? [] : runs.await())
		);
	}

	/** End the compiles `start` began, unread, and delete their probe directories: a run that never asked the builds. */
	public static function abandon(probe: DefinesProbe): Void {
		probe.runs?.cancel();
		for (p in probe.ready ?? []) discard(p.dir);
	}

	/**
	 * The configuration a probe transcript reports: exactly one compile arm, the define set the first initialization
	 * macro saw, the last one printed once typing ended, the value of each define of the first set both gave alike, and
	 * every type the runtime context typed with the file that declares it, and every file the compile parsed, as the
	 * compiler spells the paths. Null for anything else, a value line that is no pair of strings included. Pure.
	 */
	public static function parse(name: String, transcript: String): Null<ReachConfiguration> {
		var arms: Int = 0;
		var defined: Null<Array<String>> = null;
		var everDefined: Null<Array<String>> = null;
		final compiled: Array<String> = [];
		final types: Array<{ name: String, file: String }> = [];
		final seen: Map<String, Bool> = [];
		final earlyValues: Map<String, String> = [];
		final finalValues: Map<String, String> = [];
		for (raw in transcript.split('\n')) {
			final line: String = raw.trim();
			if (line.startsWith(EARLY_VALUE_PREFIX) || line.startsWith(FINAL_VALUE_PREFIX)) {
				final early: Bool = line.startsWith(EARLY_VALUE_PREFIX);
				final pair: Null<{ name: String, value: String }> =
					valuePair(line.substr((early ? EARLY_VALUE_PREFIX : FINAL_VALUE_PREFIX).length));
				if (pair == null) return null;
				(early ? earlyValues : finalValues)[pair.name] = pair.value;
			} else if (line.startsWith(TYPE_PREFIX)) {
				final rest: String = line.substr(TYPE_PREFIX.length);
				final gap: Int = rest.indexOf(' ');
				if (gap <= 0) return null;
				final type: { name: String, file: String } = { name: rest.substr(0, gap), file: rest.substr(gap + 1) };
				if (seen.exists(line)) continue;
				seen[line] = true;
				types.push(type);
				if (!compiled.contains(type.file)) compiled.push(type.file);
			} else if (line.startsWith(DEFINES_PREFIX)) {
				arms++;
			} else if (line.startsWith(EARLY_PREFIX)) {
				defined = defines(line.substr(EARLY_PREFIX.length));
			} else if (line.startsWith(FINAL_PREFIX)) {
				everDefined = defines(line.substr(FINAL_PREFIX.length));
			}
		}
		final early: Null<Array<String>> = defined;
		final all: Null<Array<String>> = everDefined;
		if (arms != 1 || early == null || all == null) return null;
		final values: Map<String, String> = [];
		for (d in early) {
			final value: Null<String> = earlyValues[d];
			if (value != null && finalValues[d] == value) values[d] = value;
		}
		return {
			name: name,
			defined: early,
			everDefined: all,
			values: values,
			compiled: compiled,
			types: types,
			parsed: OracleCoverage.parsedPaths(transcript)
		};
	}

	/**
	 * The directory holding the probe macro for `oracle`'s compile (numbered `index` among the run's), and the arguments
	 * that compile takes; null when the directory cannot be written. A `rider` joins the compile: its defines are set right
	 * after the first define set is read, so that set stays the build's own, and its arguments follow the probe's.
	 */
	public static function prepare(oracle: OracleConfig, index: Int, ?rider: ProbeRider): Null<{ dir: String, args: Array<String> }> {
		#if (sys || nodejs)
		// a configuration that cannot be asked answers nothing, and one unanswered configuration answers for all
		if (oracle.unavailable != null) return null;
		final dir: String = Path.join([
			TempScratch.root(),
			'anyparse-reach-defines-${Std.random(DIRECTORY_SUFFIX_BOUND)}-$index'
		]);
		try {
			sys.FileSystem.createDirectory(dir);
			sys.io.File.saveContent(Path.join([dir, '$MACRO_CLASS.hx']), macroSource());
		} catch (exception: Exception) {
			return null;
		}
		// `early` ahead of `--each`, so it is the first initialization macro of the arm, ahead of every one the hxml declares
		final args: Array<String> = ['-v'].concat(CompilerOracle.defineFlags(oracle.defines))
			.concat(['-cp', dir, MACRO_FLAG, '$MACRO_CLASS.early()']);
		for (d in rider?.defines ?? []) {
			args.push(MACRO_FLAG);
			args.push('$MACRO_CLASS.define(\'$d\')');
		}
		return {
			dir: dir,
			args: args.concat(['--each', oracle.hxml, '--no-output', MACRO_FLAG, '$MACRO_CLASS.run()']).concat(rider?.tail ?? [])
		};
		#else
		return null;
		#end
	}

	/**
	 * What the compile `run` of `oracle`, prepared with `rider`, answers apart from the rider: the build the probe reports
	 * and the `-v` typecheck the compile stands for, read off one transcript cleared of the rider. Its own loads go —
	 * every line between the probe's last macro and the rider's — and a module of the rider's directory the build reached
	 * itself is read at the class path the build would have found it on without the rider, which must hold the same text;
	 * the rider's defines leave the final set; and no file the build parsed may read one (`DefineReads`). Anything else —
	 * a failed compile, several arms, a module only the rider holds, a reader — answers neither, so the caller compiles
	 * the plain probes instead and never takes the rider's compile for the build's.
	 */
	public static function readRidden(
		oracle: OracleConfig, run: ProcessRun, rider: ProbeRider, grammar: GrammarPlugin, known: Map<String, Bool>
	): RiddenReading {
		final lines: Array<String> = run.out.split('\n');
		final arms: Int = [for (line in lines) if (line.trim().startsWith(DEFINES_PREFIX)) line].length;
		final none: RiddenReading = { arms: arms, verbose: null, configuration: null };
		if (run.failure != '' || run.status != 0 || arms != 1) return none;
		final kept: Null<Array<String>> = cleared(lines, oracle.dir ?? Sys.getCwd(), rider);
		if (kept == null) return none;
		final configuration: Null<ReachConfiguration> = answer(oracle, {
			status: run.status,
			out: kept.join('\n'),
			err: run.err,
			failure: run.failure,
			overflowed: run.overflowed
		});
		if (configuration == null) return none;
		final early: Array<String> = configuration.defined;
		final added: Array<String> = [
			for (d in rider.defines) {
				final spelled: Array<String> = DefineReads.spellings(d);
				if (!spelled.exists(s -> early.contains(s))) for (s in spelled) s;
			}
		];
		if (DefineReads.anyReads(configuration.parsed ?? [], added, grammar, known)) return none;
		configuration.everDefined = [for (d in configuration.everDefined) if (!added.contains(d)) d];
		final verbose: ProcessRun = {
			status: run.status,
			out: [for (line in kept) if (!ownLine(line.trim())) line].join('\n'),
			err: run.err,
			failure: run.failure,
			overflowed: run.overflowed
		};
		return { arms: arms, verbose: verbose, configuration: configuration };
	}

	/** Delete the probe directory `dir`. */
	public static function discard(dir: String): Void {
		#if (sys || nodejs)
		try {
			sys.FileSystem.deleteFile(Path.join([dir, '$MACRO_CLASS.hx']));
			sys.FileSystem.deleteDirectory(dir);
		} catch (exception: Exception) { // noqa: swallowed-exception
			// a leftover probe directory costs nothing but disk: the answer does not depend on it
		}
		#end
	}

	/** A batch of `oracles` not started yet: the build of each the run holds, and the probe directories of the rest. */
	private static function prepared(oracles: Array<OracleConfig>): DefinesProbe {
		final held: Array<Null<ReachConfiguration>> = OracleRunMemo.of(oracles)?.builds(oracles) ?? [for (_ in oracles) null];
		return {
			oracles: oracles,
			held: held,
			ready: prepareAll(unheld(oracles, held)),
			runs: null
		};
	}

	/** The configurations of `oracles` whose build `held` lacks, in order: the ones a batch compiles. */
	private static function unheld(oracles: Array<OracleConfig>, held: Array<Null<ReachConfiguration>>): Array<OracleConfig> {
		return [for (i in 0...oracles.length) if (held[i] == null) oracles[i]];
	}

	/** Every configuration's probe directory and arguments, or null when any of them cannot be prepared (and none is kept). */
	private static function prepareAll(oracles: Array<OracleConfig>): Null<Array<{ dir: String, args: Array<String> }>> {
		final prepared: Array<Null<{ dir: String, args: Array<String> }>> = [for (i in 0...oracles.length) prepare(oracles[i], i)];
		final ready: Array<{ dir: String, args: Array<String> }> = [for (p in prepared) if (p != null) p];
		if (ready.length == oracles.length) return ready;
		for (p in ready) discard(p.dir);
		return null;
	}

	/** The compiles of the configurations `probe` does not hold, or null when their probe directories could not be prepared. */
	private static function jobsFor(probe: DefinesProbe): Null<Array<SpawnJob>> {
		final ready: Null<Array<{ dir: String, args: Array<String> }>> = probe.ready;
		if (ready == null) return null;
		final asked: Array<OracleConfig> = unheld(probe.oracles, probe.held);
		return [for (i in 0...ready.length) { args: ready[i].args, cwd: asked[i].dir }];
	}

	/**
	 * The builds the probe compiles `runs` of the configurations of `oracles` the run did not hold (`held`, prepared as
	 * `ready`, null when they could not be) report beside the held ones, the probe directories deleted; null when any
	 * configuration answers nothing.
	 */
	private static function answerAll(
		oracles: Array<OracleConfig>, held: Array<Null<ReachConfiguration>>, ready: Null<Array<{ dir: String, args: Array<String> }>>,
		runs: Array<ProcessRun>
	): Null<ReachBuilds> {
		for (p in ready ?? []) discard(p.dir);
		if (runs.length != unheld(oracles, held).length || oracles.length == 0) return null;
		final out: Array<ReachConfiguration> = [];
		var next: Int = 0;
		for (i in 0...oracles.length) {
			final configuration: Null<ReachConfiguration> = held[i] ?? answer(oracles[i], runs[next++]);
			if (configuration == null) return null;
			out.push(configuration);
		}
		final seen: Map<String, Bool> = [];
		final library: Array<{ file: String, source: String }> = [];
		#if (sys || nodejs)
		for (c in out) for (path in c.compiled) if (!seen.exists(path)) {
			seen[path] = true;
			// a file that cannot be read declares nothing the walk resolves against: a call into it stays a blind spot
			final source: Null<String> = try sys.io.File.getContent(path) catch (exception: Exception) null;
			if (source != null) library.push({ file: path, source: source });
		}
		#end
		return { configurations: out, library: library };
	}

	/**
	 * The probe macros' source: the define set before any other initialization macro (`early`), and once typing ended
	 * the whole set and every type the build's runtime context typed, with its file (`run`) — each set with every
	 * define's value, one JSON pair per line (`values`) — the macro context parses
	 * files of its own, which run in no build. Only the types that carry code are listed — classes, interfaces and
	 * abstracts: an enum or a typedef runs nothing and is the supertype of nothing that does. An abstract's
	 * implementation class and a generic class's instance are not listed either: the abstract and the generic class are,
	 * and code names only those.
	 */
	private static function macroSource(): String {
		return [
			'class $MACRO_CLASS {',
			'\tpublic static function early():Void {',
			'\t\tSys.println(\'$EARLY_PREFIX\' + [for (k in haxe.macro.Context.getDefines().keys()) k].join(\';\'));',
			'\t\tvalues(\'$EARLY_VALUE_PREFIX\');',
			'\t}',
			'\tpublic static function define(name:String):Void {',
			'\t\thaxe.macro.Compiler.define(name);',
			'\t}',
			'\tstatic function values(prefix:String):Void {',
			'\t\tfor (k => v in haxe.macro.Context.getDefines()) Sys.println(prefix + haxe.Json.stringify([k, v]));',
			'\t}',
			'\tpublic static function run():Void {',
			'\t\thaxe.macro.Context.onAfterTyping(types -> {',
			'\t\t\tSys.println(\'$FINAL_PREFIX\' + [for (k in haxe.macro.Context.getDefines().keys()) k].join(\';\'));',
			'\t\t\tvalues(\'$FINAL_VALUE_PREFIX\');',
			'\t\t\tfor (t in types) {',
			'\t\t\t\tfinal named:Null<{name:String, pos:haxe.macro.Expr.Position}> = switch t {',
			'\t\t\t\t\tcase TClassDecl(c): switch c.get().kind {',
			'\t\t\t\t\t\tcase KAbstractImpl(_) | KGenericInstance(_, _): null;',
			'\t\t\t\t\t\tcase _: {name: c.get().name, pos: c.get().pos};',
			'\t\t\t\t\t}',
			'\t\t\t\t\tcase TEnumDecl(_) | TTypeDecl(_): null;',
			'\t\t\t\t\tcase TAbstract(a): {name: a.get().name, pos: a.get().pos};',
			'\t\t\t\t};',
			'\t\t\t\tif (named != null) Sys.println(\'$TYPE_PREFIX'
				+ "' + named.name + ' ' + haxe.macro.Context.getPosInfos(named.pos).file);",
			'\t\t\t}',
			'\t\t});',
			'\t}',
			'}',
			''
		].join('\n');
	}

	/** The configuration the compile `run` of `oracle` reports (`parse`), its paths made canonical, or null. */
	private static function answer(oracle: OracleConfig, run: ProcessRun): Null<ReachConfiguration> {
		if (run.failure != '' || run.status != 0) return null;
		final read: Null<ReachConfiguration> = parse(OracleDeclaration.describeOracle(oracle), run.out);
		if (read == null) return null;
		final root: String = oracle.dir ?? Sys.getCwd();
		// the probe's own macro is not the build's code
		final own: String = '$MACRO_CLASS.hx';
		read.compiled = [
			for (path in read.compiled) if (!path.endsWith(own)) FileIdentity.canonical(root, path)
		];
		read.types = [
			for (t in read.types) if (!t.file.endsWith(own)) { name: t.name, file: FileIdentity.canonical(root, t.file) }
		];
		read.parsed = [
			for (path in read.parsed ?? []) if (!path.endsWith(own)) FileIdentity.canonical(root, path)
		];
		return read;
	}

	/**
	 * The lines of the rider's compile transcript `lines` (run in `root`) with the rider's own loads left out — every
	 * line between the probe's last macro and the rider's exit — and each file of the rider's directory the build named
	 * read at its home (`homeOf`); null when one has none.
	 */
	private static function cleared(lines: Array<String>, root: String, rider: ProbeRider): Null<Array<String>> {
		final own: String = OracleCoverage.directoryPrefix(FileIdentity.canonical(root, rider.dir));
		final ownEnd: String = '$EXIT_PREFIX$MACRO_CLASS.run';
		final riderEnd: String = '$EXIT_PREFIX${rider.hook}';
		var classPaths: Array<String> = [];
		var riding: Bool = false;
		final kept: Array<String> = [];
		for (raw in lines) {
			final line: String = raw.trim();
			if (riding) {
				riding = !line.startsWith(riderEnd);
				continue;
			}
			riding = line.startsWith(ownEnd);
			if (line.startsWith(CLASSPATH_PREFIX)) classPaths = line.substr(CLASSPATH_PREFIX.length).split(';');
			final path: Null<String> = line.startsWith(PARSED_PREFIX) ? line.substr(PARSED_PREFIX.length) : null;
			final type: Null<String> = line.startsWith(TYPE_PREFIX) ? line.substr(TYPE_PREFIX.length) : null;
			final gap: Int = type?.indexOf(' ') ?? -1;
			final file: Null<String> = path ?? (gap > 0 ? type?.substr(gap + 1) : null);
			if (file == null) {
				kept.push(raw);
				continue;
			}
			final home: Null<String> = homeOf(root, file, own, classPaths, rider);
			if (home == null) return null;
			kept.push(path != null ? '$PARSED_PREFIX$home' : '$TYPE_PREFIX${type?.substr(0, gap)} $home');
		}
		return kept;
	}

	/**
	 * Where the build reads `file`, a path the rider's compile names: itself, unless it lies in the rider's directory
	 * (`own`) — then the same module at the first of `classPaths`, the compile's in search order, that holds it outside
	 * that directory; null when none does or that file's text is not the rider's, as the build would then read another.
	 */
	private static function homeOf(root: String, file: String, own: String, classPaths: Array<String>, rider: ProbeRider): Null<String> {
		final resolved: String = FileIdentity.canonical(root, file);
		if (!resolved.startsWith(own)) return file;
		final relative: String = resolved.substr(own.length);
		final text: Null<String> = rider.files.find(f -> f.path == relative)?.text;
		for (dir in classPaths) {
			final candidate: String = dir == '' ? relative : Path.join([dir, relative]);
			final at: String = FileIdentity.canonical(root, candidate);
			if (at.startsWith(own) || !sys.FileSystem.exists(at)) continue;
			final held: Null<String> = try sys.io.File.getContent(at) catch (exception: Exception) null;
			return held != null && held == text ? candidate : null;
		}
		return null;
	}

	/** Whether a transcript line is the probe's own: a line its macro printed, or the parse of its macro's file. */
	private static function ownLine(line: String): Bool {
		return line.startsWith(PROBE_LINE) || (line.startsWith(PARSED_PREFIX) && line.endsWith('$MACRO_CLASS.hx'));
	}

	/** The define and value one value line carries — a JSON array of two strings — or null for anything else. */
	private static function valuePair(json: String): Null<{ name: String, value: String }> {
		final read: Null<JValue> = try JValueParser.parse(json) catch (exception: Exception) null;
		return switch read {
			case JArray([JString(name), JString(value)]): { name: name, value: value };
			case _: null;
		};
	}

	private static function defines(list: String): Array<String> {
		return [for (d in list.split(';')) if (d.trim() != '') d.trim()];
	}

}
