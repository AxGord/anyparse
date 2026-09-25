package anyparse.check;

import anyparse.check.HaxeSpawn.HaxeRun;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.core.TempScratch;
import anyparse.query.ReachLiveness.ReachBuilds;
import anyparse.query.ReachLiveness.ReachConfiguration;
import haxe.io.Path;

using Lambda;
using StringTools;

/**
 * What each configured compiler oracle DEFINES, for the reach analysis to decide conditional compilation with
 * (`anyparse.query.ReachLiveness`). Asked of the compiler, never modelled: one compile of the configuration's own
 * hxml with two probe macros. The FIRST initialization macro of the compile prints the define set before any other
 * initialization macro runs — an earlier one may type a module, and a later one define a name that module's `#if` did
 * not see — so only the command line's defines and the target's count as defined for every file. The second prints the
 * set once typing ended, when it holds every define the build ever set; the compiler never removes one, so a name
 * outside it was never defined, and one between the two sets is undecided either way. It also names every type the
 * build typed and its file: the index the analysis reads must declare each, or a type it cannot see may exist. `-v` counts the compile's arms:
 * the macros join the last arm only, so an hxml of several arms answers nothing, and so does any probe that fails. An
 * answer must hold in every configuration, so one unanswered configuration leaves the analysis with none (`probeAll`).
 */
@:nullSafety(Strict)
final class ReachDefinesProbe {

	/** The class name of the probe macro, written to a directory of its own. */
	private static inline final MACRO_CLASS: String = 'AnyparseReachDefinesProbe';

	private static inline final EARLY_PREFIX: String = 'APQ-REACH-EARLY-DEFINES ';
	private static inline final FINAL_PREFIX: String = 'APQ-REACH-FINAL-DEFINES ';

	/** The `haxe -v` line that opens one compile arm. */
	private static inline final DEFINES_PREFIX: String = 'Defines:';

	/** The probe's line naming one type the build's runtime context typed, then the file that declares it. */
	private static inline final TYPE_PREFIX: String = 'APQ-REACH-TYPE ';

	/** The bound of the random suffix that keeps two runs' probe directories apart. */
	private static inline final DIRECTORY_SUFFIX_BOUND: Int = 0x7fffffff;

	/** The most probe compiles `parallelism` runs at once. */
	private static inline final MAX_PARALLEL: Int = 4;

	/** Spawn buffer, in bytes: `-v` names every parsed module. */
	private static inline final BUFFER: Int = 256 * 1024 * 1024;

	/**
	 * The builds of `oracles`, each probed once — the compiles overlap (`parallelism`) — with the source of every file
	 * any of them compiles (one that cannot be read is left out); null when any of them cannot be probed.
	 */
	public static function probeAll(oracles: Array<OracleConfig>): Null<ReachBuilds> {
		final prepared: Array<Null<{ dir: String, args: Array<String> }>> = [for (i in 0...oracles.length) prepare(oracles[i], i)];
		final ready: Array<{ dir: String, args: Array<String> }> = [for (p in prepared) if (p != null) p];
		final runs: Array<HaxeRun> = ready.length == oracles.length
			? HaxeSpawn.runAll([for (i in 0...ready.length) { args: ready[i].args, cwd: oracles[i].dir }], BUFFER, parallelism())
			: [];
		for (p in ready) discard(p.dir);
		if (runs.length != oracles.length || oracles.length == 0) return null;
		final out: Array<ReachConfiguration> = [];
		for (i in 0...oracles.length) {
			final configuration: Null<ReachConfiguration> = answer(oracles[i], runs[i]);
			if (configuration == null) return null;
			out.push(configuration);
		}
		final seen: Map<String, Bool> = [];
		final library: Array<{ file: String, source: String }> = [];
		#if (sys || nodejs)
		for (c in out) for (path in c.compiled) if (!seen.exists(path)) {
			seen[path] = true;
			// a file that cannot be read declares nothing the walk resolves against: a call into it stays a blind spot
			final source: Null<String> = try sys.io.File.getContent(path) catch (exception: haxe.Exception) null;
			if (source != null) library.push({ file: path, source: source });
		}
		#end
		return { configurations: out, library: library };
	}

	/**
	 * The configuration a probe transcript reports: exactly one compile arm, the define set the first initialization
	 * macro saw, the last one printed once typing ended, and every type the runtime context typed with the file that
	 * declares it, as the compiler spells the path. Null for anything else. Pure.
	 */
	public static function parse(name: String, transcript: String): Null<ReachConfiguration> {
		var arms: Int = 0;
		var defined: Null<Array<String>> = null;
		var everDefined: Null<Array<String>> = null;
		final compiled: Array<String> = [];
		final types: Array<{ name: String, file: String }> = [];
		final seen: Map<String, Bool> = [];
		for (raw in transcript.split('\n')) {
			final line: String = raw.trim();
			if (line.startsWith(TYPE_PREFIX)) {
				final rest: String = line.substr(TYPE_PREFIX.length);
				final gap: Int = rest.indexOf(' ');
				if (gap <= 0) return null;
				final type: { name: String, file: String } = { name: rest.substr(0, gap), file: rest.substr(gap + 1) };
				if (seen.exists(line)) continue;
				seen[line] = true;
				types.push(type);
				if (!compiled.contains(type.file)) compiled.push(type.file);
			} else if (line.startsWith(DEFINES_PREFIX))
				arms++;
			else if (line.startsWith(EARLY_PREFIX))
				defined = defines(line.substr(EARLY_PREFIX.length));
			else if (line.startsWith(FINAL_PREFIX))
				everDefined = defines(line.substr(FINAL_PREFIX.length));
		}
		final early: Null<Array<String>> = defined;
		final all: Null<Array<String>> = everDefined;
		if (arms != 1 || early == null || all == null) return null;
		return {
			name: name,
			defined: early,
			everDefined: all,
			compiled: compiled,
			types: types
		};
	}

	/**
	 * The probe macros' source: the define set before any other initialization macro (`early`), and once typing ended
	 * the whole set and every type the build's runtime context typed, with its file (`run`) — the macro context parses
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
			'\t}',
			'\tpublic static function run():Void {',
			'\t\thaxe.macro.Context.onAfterTyping(types -> {',
			'\t\t\tSys.println(\'$FINAL_PREFIX\' + [for (k in haxe.macro.Context.getDefines().keys()) k].join(\';\'));',
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

	/**
	 * The directory holding the probe macro for `oracle`'s compile (numbered `index` among the run's), and the arguments
	 * that compile takes; null when the directory cannot be written.
	 */
	private static function prepare(oracle: OracleConfig, index: Int): Null<{ dir: String, args: Array<String> }> {
		#if (sys || nodejs)
		final dir: String = Path.join([
			TempScratch.root(),
			'anyparse-reach-defines-${Std.random(DIRECTORY_SUFFIX_BOUND)}-$index'
		]);
		try {
			sys.FileSystem.createDirectory(dir);
			sys.io.File.saveContent(Path.join([dir, '$MACRO_CLASS.hx']), macroSource());
		} catch (exception: haxe.Exception) {
			return null;
		}
		// `early` ahead of `--each`, so it is the first initialization macro of the arm, ahead of every one the hxml declares
		final args: Array<String> = ['-v'].concat(CompilerOracle.defineFlags(oracle.defines)).concat([
			'-cp',
			dir,
			'--macro',
			'$MACRO_CLASS.early()',
			'--each',
			oracle.hxml,
			'--no-output',
			'--macro',
			'$MACRO_CLASS.run()'
		]);
		return { dir: dir, args: args };
		#else
		return null;
		#end
	}

	/** The configuration the compile `run` of `oracle` reports (`parse`), its paths made canonical, or null. */
	private static function answer(oracle: OracleConfig, run: HaxeRun): Null<ReachConfiguration> {
		if (run.failure != '' || run.status != 0) return null;
		final read: Null<ReachConfiguration> = parse(LintConfig.describeOracle(oracle), run.out);
		if (read == null) return null;
		final root: String = oracle.dir ?? Sys.getCwd();
		// the probe's own macro is not the build's code
		final own: String = '$MACRO_CLASS.hx';
		read.compiled = [
			for (path in read.compiled) if (!path.endsWith(own)) OracleCoverage.canonical(root, path)
		];
		read.types = [
			for (t in read.types) if (!t.file.endsWith(own)) { name: t.name, file: OracleCoverage.canonical(root, t.file) }
		];
		return read;
	}

	/** Delete the probe directory `dir`. */
	private static function discard(dir: String): Void {
		#if (sys || nodejs)
		try {
			sys.FileSystem.deleteFile(Path.join([dir, '$MACRO_CLASS.hx']));
			sys.FileSystem.deleteDirectory(dir);
		} catch (exception: haxe.Exception) { // noqa: swallowed-exception
			// a leftover probe directory costs nothing but disk: the answer does not depend on it
		}
		#end
	}

	/**
	 * How many probe compiles run at once: separate processes, each with its own probe directory and no output, so they
	 * share nothing but the machine — bounded, since one compile of a large project holds a gigabyte or more.
	 */
	private static function parallelism(): Int {
		#if nodejs
		return Std.int(Math.max(1, Math.min(MAX_PARALLEL, Std.int(js.node.Os.cpus().length / 2))));
		#else
		return 1;
		#end
	}

	private static function defines(list: String): Array<String> {
		return [for (d in list.split(';')) if (d.trim() != '') d.trim()];
	}

}
