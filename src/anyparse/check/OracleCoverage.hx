package anyparse.check;

import anyparse.check.HaxeSpawn.HaxeRun;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;
import haxe.io.Path;

using StringTools;

/**
 * WHICH FILES and WHICH REGIONS of them the configured compiler oracle actually
 * compiles — the question a `RiskyFix` verdict depends on and nothing used to ask.
 *
 * `FixVerifier` proves a risky edit safe by writing it and running
 * `haxe <hxml> --no-output`: exit 0 keeps the edit, non-zero reverts it. That proof
 * is only worth anything for code the compiler TYPECHECKED. An hxml routinely compiles a
 * SUBSET of the tree a lint run walks — a `--macro include(pkg, true, [ignored…])`
 * list, a `-main` that reaches part of the sources, per-target arms that exclude
 * whole packages. For anything outside that subset the typecheck cannot fail no matter
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
 * The same hole exists one level down, INSIDE a compiled file: a `#if` branch the arm's
 * defines exclude is skipped at lex time, so the file still earns its `Parsed` line while
 * that branch is typechecked by nothing. Measured in THIS repo, whose oracle is
 * `test-js.hxml`: `final _planted: Int = 'not an int';` planted in the native-sys
 * `#elseif sys` branch of `HaxeSpawn.run` leaves `haxe test-js.hxml --no-output` at exit
 * 0, and the same line in the `#if nodejs` branch above it fails with
 * `String should be Int`.
 * `covers` answers TRUE for both, which is why `uncovered` — the answer a caller should
 * be asking — takes the edit's own offsets and hands the region half to
 * `CondRegionLiveness`.
 *
 * ## How the set is determined
 *
 * By ASKING THE COMPILER, not by modelling the hxml. `haxe -v` prints one
 * `Parsed <path>` line per source file it reads, a `Defines:` line opening each arm, and
 * a `Calling macro haxe.macro.Compiler.define (--macro define('x'))` line for an init
 * macro that adds one after that. `--each` pushes the flags in front of it into EVERY
 * `--next` arm. Without it only one arm answers: on Pony's two-arm hxml a leading `-v`
 * reported 175 distinct `src` files and a trailing one 196 (194 and 215 raw lines — a
 * module is parsed again for the macro context), and which arm you get depends on where
 * the flag sits, not on what the oracle compiles. So one
 * `haxe -v --each <hxml> --no-output` from the oracle's own directory names the whole
 * compiled set, across arms, through include chains, through `--macro include(…)` ignore
 * lists, and through any other hxml mechanism this class would otherwise have to model.
 *
 * `--no-output` sits AFTER the hxml on purpose — see `probe`, where the difference from
 * the oracle's own compile is measured.
 *
 * Cost is one compile: 17.45s against 17.37s for the plain oracle typecheck on this
 * project, 3.6s on Pony — `-v` is a print flag, not extra work. The probe pays for
 * itself the moment one uncovered file is declined, because that file's own full
 * typecheck is then never spawned.
 *
 * ## The answer is THREE-valued
 *
 * `covers` / `uncovered` say yes or no, and `known` says whether it may be believed at
 * all. A probe that could not run (no `haxe`, a non-zero status, output with no `Parsed`
 * line, a target with no filesystem) yields an UNKNOWN coverage, and unknown coverage
 * is not coverage: `covers` answers false for every file, so a caller that reads it
 * as permission is refused rather than misled. An oracle whose compiled set cannot be
 * established is, for the purposes of a safety gate, no oracle at all — which is
 * exactly how a project with no `compilerOracle` key is already treated.
 *
 * The region half is three-valued for its own reason, spelled out in
 * `CondRegionLiveness`: the define list is POSITIVE-ONLY, so an unlisted flag is unknown
 * rather than undefined, and every unknown costs a decline instead of a permission.
 *
 * ## What it does NOT establish — the residual holes, plainly
 *
 * - **A define this cannot SEE costs a decline, and there are two kinds.** An arm's
 *   define list is the compiler's `Defines:` line plus the `--macro define(...)` calls
 *   the same transcript reports. A define set from inside a BUILD macro appears in
 *   neither, and a condition comparing a define's VALUE (`haxe_ver >= 4.0`) has nothing
 *   to compare against. Both leave the region unknown and the edit report-only. Never
 *   the other way round: absence is never read as "not defined".
 * - **The set is a SNAPSHOT, in both halves.** `FixVerifier` probes once per run; a fix
 *   that removes the last reference to a module can drop it out of the compiled set
 *   afterwards, and one that changes which arm compiles a file is outside what a single
 *   probe can describe.
 * - **`size` counts every source the compile reads**, standard library and haxelibs
 *   included — 915 on Pony, where the project's own share is 196. It is a scale, not
 *   a project file count.
 */
@:nullSafety(Strict)
final class OracleCoverage {

	/** The `haxe -v` line prefix that names a source file the compiler read. */
	private static inline final PARSED_PREFIX: String = 'Parsed ';

	/** The `haxe -v` line that OPENS one compile arm and names the defines it starts with. */
	private static inline final DEFINES_PREFIX: String = 'Defines:';

	/**
	 * The `haxe -v` line shape of an init macro that ADDS a define after the `Defines:`
	 * line was printed — `Calling macro haxe.macro.Compiler.define (--macro
	 * define('nodejs'):1)`.
	 *
	 * Without it the define set is not merely incomplete, it misses the one that matters
	 * most: hxnodejs declares `nodejs` from its `extraParams.hxml` exactly this way, so on
	 * this project every `#if nodejs` region — which is most of the process-touching code —
	 * would be unprovable and every risky fix in one declined. A `Compiler.define` called
	 * from INSIDE a build macro prints its call site rather than its argument and stays
	 * invisible, which costs a decline and never a wrong permission.
	 */
	private static inline final MACRO_DEFINE_PREFIX: String = 'Calling macro haxe.macro.Compiler.define (--macro define(';

	/** The one sentence every target-without-a-process arm of this class answers with. */
	private static inline final UNSUPPORTED_TARGET: String = 'compiler oracle coverage requires a sys or nodejs target';

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

	/**
	 * The compile ARMS behind that union — see `CompiledArm`. Empty when the set is
	 * unknown, and empty is the answer that proves no region live.
	 */
	private final _arms: Array<CompiledArm>;

	private function new(compiled: Null<Array<String>>, arms: Array<CompiledArm>, reason: String) {
		_compiled = compiled;
		_arms = arms;
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
	 * `haxe -v --each <hxml> --no-output` spawn. Every condition the probe cannot answer
	 * under returns an UNKNOWN coverage carrying its own diagnostic, never an empty set
	 * pretending to be an answer.
	 *
	 * The flag ORDER is the whole fidelity of the claim. `--each` pushes what precedes it
	 * into every `--next` arm, so `-v --no-output --each <hxml>` — what this ran until now —
	 * suppresses output in ARMS THE ORACLE LETS EMIT: the oracle's own `haxe <hxml>
	 * --no-output` appends the flag, which joins the LAST arm only. Measured on a two-arm
	 * hxml whose first arm names a `-js` output: the oracle emits that file, the old probe
	 * emitted nothing, the new spelling emits it again. The probe has to run the compile it
	 * is describing — an arm consuming an earlier arm's output would otherwise fail the
	 * probe while passing the oracle, and the whole risky phase would decline on a
	 * difference the probe invented.
	 */
	public static function probe(hxml: String, cwd: Null<String>): OracleCoverage {
		#if (sys || nodejs)
		final root: String = cwd ?? Sys.getCwd();
		final result: HaxeRun = probeOutput(root, ['-v', '--each', hxml, '--no-output']);
		if (result.failure != '') return unknown(result.failure);
		final status: Null<Int> = result.status;
		if (status == null) return unknown('the coverage probe produced no exit status');
		if (status != 0) return unknown('`haxe -v --each $hxml --no-output` exited $status');
		final tokens: Array<String> = parsedPaths(result.out);
		if (tokens.length == 0) return unknown('`haxe -v` named no parsed source file');
		final arms: Array<CompiledArm> = [
			for (arm in parseArms(result.out))
				{
					files: [for (token in arm.files) canonical(root, token)],
					defines: arm.defines
				}
		];
		return new OracleCoverage([for (token in tokens) canonical(root, token)], arms, '');
		#else
		return unknown(UNSUPPORTED_TARGET);
		#end
	}

	/** A coverage that declines to answer, carrying `reason` — the shape every failed probe returns. */
	public static function unknown(reason: String): OracleCoverage {
		return new OracleCoverage(null, [], reason);
	}


	/**
	 * A coverage over an explicit file list, each path resolved against `root`, read as ONE
	 * arm running under `defines`. The seam a test drives the gate through without a
	 * compiler, and the one place the probe's own output shape and the membership test meet.
	 *
	 * `defines` defaults to EMPTY, which proves no conditional region live — so a fixture
	 * that says nothing about defines gets the conservative answer rather than an
	 * accidental permission.
	 */
	public static function of(paths: Array<String>, root: String, ?defines: Array<String>): OracleCoverage {
		#if (sys || nodejs)
		final resolved: Array<String> = [for (path in paths) canonical(root, path)];
		return new OracleCoverage(resolved, [
			{
				files: resolved,
				defines: defines ?? []
			}
		], '');
		#else
		return unknown(UNSUPPORTED_TARGET);
		#end
	}

	/**
	 * Why an edit set covering `spans` in `file` is NOT verifiable by the oracle's
	 * compile — a sentence ready to quote in a decline — or null when it is.
	 *
	 * Two ways it can fail, and they are different facts. The FILE may sit outside the
	 * compiled set, which is what `covers` answers. Or the file may be compiled while the
	 * REGION the edit lands in is not: a `#if` branch the arm's defines exclude is skipped
	 * at lex time, so the file still earns its `Parsed` line and a typecheck after the edit
	 * cannot fail whatever the edit did. Measured in this repo, whose oracle is
	 * `test-js.hxml`: a planted `final _planted: Int = 'not an int';` in the native-sys
	 * `#elseif sys` branch of `HaxeSpawn.run` leaves the oracle at exit 0, and the same line
	 * in the `#if nodejs` branch above it fails with `String should be Int`.
	 *
	 * An arm must satisfy BOTH halves at once — read this file AND make every byte of every span live —
	 * because a region is only ever typechecked by a compile that did both.
	 */
	public function uncovered(file: String, source: String, spans: Array<Span>, shape: RefShape): Null<String> {
		#if (sys || nodejs)
		final paths: Null<Array<String>> = _compiled;
		if (paths == null) return reason;
		final key: String = canonical(Sys.getCwd(), file);
		if (!paths.contains(key)) return fileGap(paths.length);
		var regionGap: Null<String> = null;
		var claimed: Bool = false;
		for (arm in _arms) if (arm.files.contains(key)) {
			claimed = true;
			final gap: Null<String> = CondRegionLiveness.unproven(source, shape, spans, arm.defines);
			if (gap == null) return null;
			if (regionGap == null) regionGap = gap;
		}
		final gap: Null<String> = regionGap;
		// The union holds the file but no ARM claims it, so the transcript could not be read
		// apart. Saying the oracle does not compile the file would be false; this state is its
		// own, and it is unreachable while `probe` builds the union out of the arms.
		if (!claimed) return 'the compiler oracle\'s compile arms could not be told apart for this file';
		return gap == null
			? fileGap(paths.length)
			: 'the compiler oracle does not typecheck this region ($gap is live under no compiled arm)';
		#else
		return UNSUPPORTED_TARGET;
		#end
	}

	/** The decline sentence for a file the oracle's compile never reads. */
	private static function fileGap(size: Int): String {
		return 'the compiler oracle does not compile this file (its hxml reads $size source file(s), this one not among them)';
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

	/**
	 * The ARMS of one `haxe -v` transcript, in order: for each `Defines:` line, the source
	 * files parsed after it and the defines it declares — the line's own `;`-separated
	 * names plus every `--macro define(...)` the arm goes on to report. Pure.
	 *
	 * `Defines:` is what opens an arm because the compiler prints it before it parses
	 * anything, so every `Parsed` line and every init-macro line that follows belongs to
	 * the arm it opened. A `Parsed` line before any `Defines:` line — which no compiler
	 * version observed here produces — opens an arm with an EMPTY define set, so the file
	 * still counts as compiled while none of its conditional regions is provable.
	 */
	public static function parseArms(verboseOutput: String): Array<CompiledArm> {
		final arms: Array<CompiledArm> = [];
		for (rawLine in verboseOutput.split('\n')) {
			final line: String = rawLine.trim();
			if (line.startsWith(DEFINES_PREFIX)) {
				arms.push({
					files: [],
					defines: definesOf(line)
				});
				continue;
			}
			final parsed: Bool = line.startsWith(PARSED_PREFIX);
			if (!parsed && !line.startsWith(MACRO_DEFINE_PREFIX)) continue;
			if (arms.length == 0) arms.push({
				files: [],
				defines: []
			});
			final arm: CompiledArm = arms[arms.length - 1];
			if (parsed) {
				final path: String = line.substr(PARSED_PREFIX.length);
				if (!arm.files.contains(path)) arm.files.push(path);
				continue;
			}
			final name: Null<String> = macroDefineName(line);
			if (name != null && !arm.defines.contains(name)) arm.defines.push(name);
		}
		return arms;
	}

	/** The define NAMES of one `Defines:` line, `key=value` reduced to `key`. Pure. */
	public static function definesOf(definesLine: String): Array<String> {
		final names: Array<String> = [];
		for (entry in definesLine.substr(DEFINES_PREFIX.length).split(';')) {
			final token: String = entry.trim();
			if (token == '') continue;
			final equals: Int = token.indexOf('=');
			final name: String = equals < 0 ? token : token.substr(0, equals);
			if (name != '' && !names.contains(name)) names.push(name);
		}
		return names;
	}

	/**
	 * The define a `Calling macro haxe.macro.Compiler.define (--macro define('x'):1)` line
	 * names — the FIRST quoted argument, since `define('KEY', 'value')` names the key
	 * first — or null when the line carries no quoted argument at all. Pure.
	 */
	public static function macroDefineName(line: String): Null<String> {
		final open: Int = line.indexOf('\'', MACRO_DEFINE_PREFIX.length);
		final openDouble: Int = line.indexOf('"', MACRO_DEFINE_PREFIX.length);
		final quoteAt: Int = open < 0 || openDouble >= 0 && openDouble < open ? openDouble : open;
		if (quoteAt < 0) return null;
		final close: Int = line.indexOf(line.charAt(quoteAt), quoteAt + 1);
		if (close <= quoteAt + 1) return null;
		return line.substring(quoteAt + 1, close);
	}

	#if (sys || nodejs)
	/**
	 * One `haxe` spawn for the probe through the shared `HaxeSpawn` seam, refusing up front
	 * on a target that cannot honour the working directory: the compiler prints RELATIVE
	 * `Parsed` paths, and resolving them against a root it never ran in would build a
	 * plausible-looking set of wrong keys.
	 */
	private static function probeOutput(root: String, args: Array<String>): HaxeRun {
		if (!HaxeSpawn.honoursCwd() && Path.normalize(root) != Path.normalize(Sys.getCwd())) return {
			status: null,
			out: '',
			err: '',
			failure: 'the coverage probe cannot run haxe in $root on this target',
			overflowed: false
		};
		final run: HaxeRun = HaxeSpawn.run(args, root, PROBE_BUFFER);
		// Re-worded rather than passed through: `HaxeSpawn` reports what the SPAWN could not
		// do, and the caller turns every one of those into an UNKNOWN coverage, whose reader
		// needs to know which of this project's compiles went missing.
		return run.failure == '' ? run : {
			status: null,
			out: '',
			err: '',
			failure: 'the coverage probe ${run.failure}',
			overflowed: run.overflowed
		};
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
 * One arm of the probed compile: the source files that arm READ, and the define names it
 * ran under.
 *
 * An hxml is a sequence of `--next` arms and each one is its own compilation — its own
 * defines, its own set of modules. A region is typechecked when SOME arm both reads its
 * file and makes it live, so the two facts have to travel together: a union of every
 * arm's defines would prove `#if (a && b)` live for an `a` from one arm and a `b` from
 * another, which no compile ever did.
 *
 * `defines` carries NAMES only, `key=value` reduced to `key`. Positive-only: a name here
 * IS defined for that arm, a name absent from it is UNKNOWN rather than undefined — the
 * compiler prints its `Defines:` line before init macros run, and this list is that line
 * plus the `--macro define(...)` calls the same transcript goes on to report.
 */
typedef CompiledArm = {
	var files: Array<String>;
	var defines: Array<String>;
}
