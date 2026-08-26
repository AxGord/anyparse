package anyparse.check;

import haxe.io.Path;

using StringTools;

#if nodejs
import js.node.ChildProcess.ChildProcessSpawnSyncResult;
#end

/**
 * WHICH FILES the configured compiler oracle actually compiles — the question a
 * `RiskyFix` verdict depends on and nothing used to ask.
 *
 * `FixVerifier` proves a risky edit safe by writing it and running
 * `haxe <hxml> --no-output`: exit 0 keeps the edit, non-zero reverts it. That proof
 * is only worth anything for a file the compiler READ. An hxml routinely compiles a
 * SUBSET of the tree a lint run walks — a `--macro include(pkg, true, [ignored…])`
 * list, a `-main` that reaches part of the sources, per-target arms that exclude
 * whole packages. For a file outside that subset the typecheck cannot fail no matter
 * what the edit did, so a green oracle proves exactly nothing, and reporting it as
 * `risky-fix verified` is a claim about a control that could not have fired.
 *
 * Measured on one real tree (Pony @ `b6b94e37`, `lint-oracle.hxml`): the compile reads
 * 915 source files in all, of which 196 are the project's own — 196 of the 679 under
 * `src`, leaving 483, 71 % of the tree, invisible to the oracle. A deliberate
 * `var x:Int = "not an int"` inside `src/pony/unity3d/UTools.hx` leaves
 * `haxe lint-oracle.hxml --no-output` at exit 0; the same edit in `src/pony/Byte.hx`
 * fails it. Same hxml, opposite answers, and only the second one is a verification.
 *
 * ## How the set is determined
 *
 * By ASKING THE COMPILER, not by modelling the hxml. `haxe -v` prints one
 * `Parsed <path>` line per source file it reads, and `--each` pushes the flags in
 * front of it into EVERY `--next` arm. Without it only one arm answers: on Pony's
 * two-arm hxml a leading `-v` reported 175 distinct `src` files and a trailing one
 * 196 (194 and 215 raw lines — a module is parsed again for the macro context), and
 * which arm you get depends on where the flag sits, not on what the oracle compiles.
 * So one `haxe -v --no-output --each <hxml>` from the oracle's own directory names
 * the whole compiled set, across arms, through include chains, through
 * `--macro include(…)` ignore lists, and through any other hxml mechanism this class
 * would otherwise have to model.
 *
 * Cost is one compile: 17.45s against 17.37s for the plain oracle typecheck on this
 * project, 3.6s on Pony — `-v` is a print flag, not extra work. The probe pays for
 * itself the moment one uncovered file is declined, because that file's own full
 * typecheck is then never spawned.
 *
 * ## The answer is THREE-valued
 *
 * `covers` says yes or no, and `known` says whether it may be believed at all. A
 * probe that could not run (no `haxe`, a non-zero status, output with no `Parsed`
 * line, a target with no filesystem) yields an UNKNOWN coverage, and unknown coverage
 * is not coverage: `covers` answers false for every file, so a caller that reads it
 * as permission is refused rather than misled. An oracle whose compiled set cannot be
 * established is, for the purposes of a safety gate, no oracle at all — which is
 * exactly how a project with no `compilerOracle` key is already treated.
 *
 * ## What it does NOT establish — the residual holes, plainly
 *
 * - **FILE granularity, not REGION.** A `#if` region the oracle's defines exclude is
 *   skipped at lex time, so the file still gets its `Parsed` line while that region is
 *   never typechecked. A risky fix landing inside one is `covers`-TRUE and still
 *   unverified — the same vacuity this class exists to refuse, one level down. It
 *   reaches this repo: the oracle here is `test-js.hxml`, so the native-sys `#else`
 *   branch of `probeOutput` below is compiled by nothing. Closing it means comparing
 *   an edit's span against the file's ACTIVE regions, which is a slice of its own.
 * - **`--each` changes the compile the probe runs**, pushing `--no-output` into every
 *   arm where the plain oracle passes it only to the last. An hxml whose later arm
 *   consumes an earlier arm's OUTPUT can therefore fail the probe while passing the
 *   oracle; that is fail-safe (the phase declines and names its reason) but it is a
 *   behaviour change for such a project.
 * - **The set is a SNAPSHOT.** `FixVerifier` probes once per run; a fix that removes
 *   the last reference to a module can drop it out of the compiled set afterwards.
 * - **`size` counts every source the compile reads**, standard library and haxelibs
 *   included — 915 on Pony, where the project's own share is 196. It is a scale, not
 *   a project file count.
 */
@:nullSafety(Strict)
final class OracleCoverage {

	/** The `haxe -v` line prefix that names a source file the compiler read. */
	private static inline final PARSED_PREFIX: String = 'Parsed ';

	/**
	 * Spawn buffer for the probe, in bytes. Node's default is 1 MiB and a real project
	 * blows straight through it — 815 KB of `-v` output for Pony's two arms, 2.1 MB for
	 * this project's own `test-js.hxml`. What an overflow costs is the WHOLE risky phase,
	 * not a wrong decline: node reports it as a spawn error with a null status and a
	 * truncated stdout, which `probe` reads as an UNKNOWN compiled set.
	 */
	private static inline final PROBE_BUFFER: Int = 256 * 1024 * 1024;

	/**
	 * How many source files the oracle's compile READS — standard library and haxelibs
	 * included, so it is a scale rather than a project file count (915 on Pony, whose own
	 * share of that is 196). 0 when the set is unknown.
	 */
	public var size(get, never): Int;

	/** Whether the compiled set could be established at all — false makes every `covers` answer false. */
	public var known(get, never): Bool;

	/** Why the compiled set is unknown; empty when it is known. */
	public final reason: String;

	/**
	 * Absolute, symlink-resolved paths of every source file the oracle's compile read, or
	 * null when the probe could not answer — the two states `known` distinguishes.
	 */
	private final _compiled: Null<Array<String>>;

	private function new(compiled: Null<Array<String>>, reason: String) {
		_compiled = compiled;
		this.reason = reason;
	}

	private inline function get_known(): Bool {
		return _compiled != null;
	}

	private function get_size(): Int {
		final paths: Null<Array<String>> = _compiled;
		return paths == null ? 0 : paths.length;
	}

	/**
	 * Does the oracle's compile READ `file`? False for a file outside the compiled set AND
	 * for every file when the set is unknown — the caller must not be able to turn a
	 * missing answer into a permission.
	 */
	public function covers(file: String): Bool {
		#if (sys || nodejs)
		final paths: Null<Array<String>> = _compiled;
		return paths != null && paths.contains(canonical(Sys.getCwd(), file));
		#else
		return false;
		#end
	}

	/**
	 * The compiled set of `hxml` as run from `cwd`, established by one
	 * `haxe -v --no-output --each <hxml>` spawn. Every condition the probe cannot answer
	 * under returns an UNKNOWN coverage carrying its own diagnostic, never an empty set
	 * pretending to be an answer.
	 */
	public static function probe(hxml: String, cwd: Null<String>): OracleCoverage {
		#if (sys || nodejs)
		final root: String = cwd ?? Sys.getCwd();
		final result: ProbeRun = probeOutput(root, ['-v', '--no-output', '--each', hxml]);
		if (result.failure != '') return unknown(result.failure);
		final status: Null<Int> = result.status;
		if (status == null) return unknown('the coverage probe produced no exit status');
		if (status != 0) return unknown('`haxe -v --no-output --each $hxml` exited $status');
		final tokens: Array<String> = parsedPaths(result.out);
		return tokens.length == 0
			? unknown('`haxe -v` named no parsed source file')
			: new OracleCoverage([for (token in tokens) canonical(root, token)], '');
		#else
		return unknown('compiler oracle coverage requires a sys or nodejs target');
		#end
	}

	/** A coverage that declines to answer, carrying `reason` — the shape every failed probe returns. */
	public static function unknown(reason: String): OracleCoverage {
		return new OracleCoverage(null, reason);
	}

	/**
	 * A coverage over an explicit file list, each path resolved against `root`. The seam
	 * a test drives the gate through without a compiler, and the one place the
	 * probe's own output shape and the membership test meet.
	 */
	public static function of(paths: Array<String>, root: String): OracleCoverage {
		return #if (sys || nodejs) new OracleCoverage(
			[for (path in paths) canonical(root, path)], ''
		) #else unknown('compiler oracle coverage requires a sys or nodejs target') #end;
	}

	/**
	 * The path token of every `Parsed <path>` line in one `haxe -v` transcript, deduped,
	 * in first-appearance order. Pure — the compiler parses a module once per compilation
	 * context and again for the macro context, so the raw lines repeat.
	 */
	public static function parsedPaths(verboseOutput: String): Array<String> {
		final paths: Array<String> = [];
		for (rawLine in verboseOutput.split('\n')) {
			final line: String = rawLine.trim();
			if (!line.startsWith(PARSED_PREFIX)) continue;
			// Non-empty by construction: the line is already trimmed and starts with the
			// prefix's trailing space, so what follows cannot be blank.
			final path: String = line.substr(PARSED_PREFIX.length);
			if (!paths.contains(path)) paths.push(path);
		}
		return paths;
	}

	#if (sys || nodejs)
	/**
	 * One `haxe` spawn for the probe: its exit status (null when the process never ran)
	 * and its stdout. `stderr` is deliberately not merged — the probe reads a line format,
	 * and a warning interleaved into it would only add noise.
	 */
	private static function probeOutput(root: String, args: Array<String>): ProbeRun {
		#if nodejs
		final options: Dynamic = { encoding: 'utf8', cwd: root, maxBuffer: PROBE_BUFFER };
		final res: ChildProcessSpawnSyncResult = js.node.ChildProcess.spawnSync('haxe', args, options);
		final launchError: Null<Dynamic> = (res.error: Dynamic);
		// ENOBUFS is the compiler having run FINE and out-written `maxBuffer`; every other
		// spawn error means `haxe` never ran at all. Both end the probe, but they send the
		// reader to opposite places — output volume against a missing binary — so they must
		// not share one sentence. `CompilerOracle` splits the same pair for the same reason.
		if (launchError != null) {
			final code: Null<Dynamic> = Reflect.field(launchError, 'code');
			final message: Null<Dynamic> = Reflect.field(launchError, 'message');
			return code != null && '$code' == 'ENOBUFS'
				? {
					status: null,
					out: '',
					failure: 'the coverage probe out-wrote its $PROBE_BUFFER byte output buffer'
				}
				: {
					status: null,
					out: '',
					failure: 'the coverage probe could not launch haxe ($message)'
				};
		}
		final out: Dynamic = res.stdout;
		return {
			status: (res.status: Null<Int>),
			out: out == null ? '' : '$out',
			failure: ''
		};
		#else
		// `sys.io.Process` has no working directory, so this branch runs in the PROCESS cwd —
		// the same limitation `CompilerOracle` documents, and one degree worse here: the
		// compiler prints RELATIVE `Parsed` paths, and resolving them against a root the
		// compiler never ran in would build a plausible-looking set of wrong keys. Refuse when
		// the two differ instead of answering from a false premise; when they agree the branch
		// is sound. js/node is the only runner this project ships either way.
		if (Path.normalize(root) != Path.normalize(Sys.getCwd())) return {
			status: null,
			out: '',
			failure: 'the coverage probe cannot run haxe in $root on this target'
		};
		try {
			final process: sys.io.Process = new sys.io.Process('haxe', args);
			// Drained BEFORE `exitCode()`: `-v` writes a line per parsed module, far more than
			// a pipe buffer holds, and waiting on exit first would deadlock.
			final text: String = process.stdout.readAll().toString();
			final code: Null<Int> = process.exitCode();
			process.close();
			return {
				status: code,
				out: text,
				failure: ''
			};
		} catch (exception: haxe.Exception) {
			return {
				status: null,
				out: '',
				failure: 'the coverage probe could not launch haxe (${exception.message})'
			};
		}
		#end
	}

	/**
	 * `path` resolved against `root` when relative, then symlink-resolved. Both sides of
	 * the membership test go through this: the compiler prints paths against ITS working
	 * directory and the lint run names files against the PROCESS one, and on a host whose
	 * temp dir is a symlink (`/tmp` on macOS) the two spellings of one file differ. An
	 * unresolvable path keeps its normalised form rather than failing the lookup.
	 */
	private static function canonical(root: String, path: String): String {
		// `root` is absolutised FIRST, so a relative one cannot produce a key the membership
		// test can never match: `covers` resolves against the process cwd, and when the file
		// does not exist `fullPath` throws and the normalised join is all that is left — a
		// relative `pkg/C.hx` on one side against an absolute `/…/pkg/C.hx` on the other.
		final base: String = Path.isAbsolute(root) ? root : Path.join([Sys.getCwd(), root]);
		final joined: String = Path.normalize(Path.isAbsolute(path) ? path : Path.join([base, path]));
		// `fullPath` is declared `String` and RETURNS NULL on hxnodejs for a path that does
		// not exist — it does not throw, so the catch alone never sees it and `@:nullSafety`
		// trusts the declaration. Left unhandled every unresolvable path collapses to one
		// value and `covers` answers TRUE for all of them: the dangerous direction, and the
		// exact vacuity this class exists to refuse. Measured on Haxe 4.3.7 / hxnodejs.
		final resolved: Null<String> = try sys.FileSystem.fullPath(joined) catch (_exception: haxe.Exception) null;
		return resolved == null || resolved == '' ? joined : resolved;
	}
	#end

}

/**
 * One `haxe` spawn's result for the probe: its exit status, its stdout, and — the field
 * that keeps the two apart — WHY it could not run at all.
 *
 * `failure` is empty when the process ran, whatever it then exited with. Folding a
 * launch failure into a null status would make "no `haxe` on PATH" and "the compiler
 * out-wrote the output buffer" the same sentence, and those send a reader to opposite
 * places.
 */
private typedef ProbeRun = {
	var status: Null<Int>;
	var out: String;
	var failure: String;
}
