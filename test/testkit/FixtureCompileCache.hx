package testkit;

import haxe.Exception;
import haxe.Json;
import haxe.io.Path;
import js.Node;
import js.node.Buffer;
import js.node.ChildProcess;
import js.node.Crypto;
import js.node.Fs;
import js.node.Zlib;
import js.node.fs.Stats;

using StringTools;

/**
 * A content-addressed REPLAY of the fixture compiles the reach probes run, for `tools/mutation-check.sh`.
 *
 * A mutation track that pins `unit.query.MemberReachFactsTest` spent 63 of its 66 seconds in ~290 `haxe` compiles of
 * tiny fixtures (`TypedFactsProbe`, `ReachDefinesProbe`), and every track of a sweep compiled the SAME fixtures: a
 * mutation of the engine changes what the engine does with the compiler's answer, not the answer. So the runner puts a
 * `haxe` shim ahead of the real compiler on the tracks' PATH, and this class answers a compile it has seen before —
 * the same arguments, the same bytes in every directory the compile reads — with what that compile printed, exited with
 * and wrote, instead of running it.
 *
 * What makes the replay sound, and each part is load-bearing:
 *
 * - **The key is every input, by content.** The compiler identity (`stamp`: its resolved path and version), the
 *   environment haxe reads, the arguments, and every file under every ROOT — the compile's cwd and each absolute
 *   class-path directory on the command line, which is where the probe macros live. A mutation of the facts macro
 *   (`TypedFactsWalk`, carried into the probe directory by `EmbeddedSource`) is a different file there, so a different
 *   key: it compiles for real.
 * - **Paths are the one thing that differs between two runs of one fixture**, so they are keyed and stored as
 *   placeholders (`encode`) and replayed as THIS call's (`decode`). A macOS temp path has two spellings
 *   (`/var/folders/…` and its real path `/private/var/folders/…`); both are placeheld.
 * - **A positive whitelist decides what may be replayed at all** (`plan`): a `--no-output` compile that runs one of the
 *   probe macros, whose every flag — on the command line and in every hxml it includes — is one this class knows, and
 *   whose every path stays inside a root. A library (`-lib`), a class path outside the roots, a symlink, an unknown flag
 *   or a root past `MAX_ROOT_FILES` / `MAX_ROOT_BYTES` runs the real compiler, unrecorded.
 * - **What the compile wrote is a diff of the roots**, taken around the real run; a file outside the roots cannot be
 *   written by a whitelisted compile, because no whitelisted path leads there.
 *
 * `tools/mutation-check.sh` and `tools/suite-shard.sh` share one store kept across runs, renewing
 * an entry on every hit and dropping one unused for a week (`tools/fixture-cache.sh`). A cache that outlives a run
 * outlives the compiler install it recorded, so that runner's stamp names the binary by path, version, size and mtime.
 */
@:nullSafety(Strict)
final class FixtureCompileCache {

	/** A `--macro` naming one of these is a probe compile; nothing else is replayed. */
	private static final PROBE_MACROS: Array<String> = ['anyparse.check.TypedFactsMacro.run(', 'AnyparseReachDefinesProbe.'];

	/** Environment variables the compiler reads. */
	private static final HAXE_ENV: Array<String> = ['HAXE_STD_PATH', 'HAXEPATH', 'HAXELIB_PATH', 'HAXE_LIBRARY_PATH'];

	/** Flags taking no value. */
	private static final BARE_FLAGS: Array<String> = [
		'--no-output',
		'-v',
		'--verbose',
		'--each',
		'--next',
		'--times',
		'--no-inline',
		'--no-opt',
		'--no-traces',
		'-debug',
		'--debug',
		'--interp'
	];

	/** Flags whose value is not a path. */
	private static final VALUE_FLAGS: Array<String> = ['-D', '--define', '--macro', '-main', '-m', '--main', '-dce', '--dce'];

	/** Flags whose value is a class path. */
	private static final CLASS_PATH_FLAGS: Array<String> = ['-cp', '-p', '--class-path'];

	/** Target flags, whose value is the output path. */
	private static final TARGET_FLAGS: Array<String> = [
		'-js',
		'--js',
		'-neko',
		'--neko',
		'-cpp',
		'--cpp',
		'-hl',
		'--hl',
		'-lua',
		'--lua',
		'-python',
		'--python',
		'-php',
		'--php',
		'--jvm',
		'-java',
		'--java',
		'-cs',
		'--cs',
		'-swf',
		'--swf'
	];

	/** A root holding more files than this is not a fixture: the compile runs for real. */
	private static inline final MAX_ROOT_FILES: Int = 400;

	/** A root holding more bytes than this is not a fixture either. */
	private static inline final MAX_ROOT_BYTES: Int = 16 * 1024 * 1024;

	/** How deep hxml includes are followed before the compile is left to the compiler. */
	private static inline final MAX_HXML_DEPTH: Int = 4;

	/** Buffer of the real compile: the defines probe's `-v` names every parsed module. */
	private static inline final MAX_BUFFER: Int = 1024 * 1024 * 1024;

	/** The placeholder bracket: a byte no path and no compiler output carries. */
	private static inline final MARK: String = '\x01';

	/**
	 * The version of the key and entry layout, bumped whenever what may be recorded changes, since a kept cache outlives
	 * the rule it was written under: 2 gzips an entry, 3 records no compile
	 * that writes into its cwd, 4 records the mutant switches a compile ran.
	 */
	private static inline final LAYOUT: Int = 4;

	/** How long a process waits on another's compile of the same key before compiling it itself. */
	private static inline final AWAIT_MS: Float = 10 * 60 * 1000;

	/** How often a waiting process looks for the record. */
	private static inline final AWAIT_POLL_MS: Int = 50;

	/**
	 * The shim's entry point: `APQ_FIXTURE_CACHE_HAXE` is the real compiler, `APQ_FIXTURE_CACHE_STAMP` its identity,
	 * `APQ_FIXTURE_CACHE_DIR` the cache. Answers exactly as the compiler would: its streams, then its status.
	 */
	public static function main(): Void {
		final real: String = Sys.getEnv('APQ_FIXTURE_CACHE_HAXE') ?? 'haxe';
		final outcome: CompileOutcome = run(
			real, Sys.getEnv('APQ_FIXTURE_CACHE_STAMP') ?? '', Sys.getEnv('APQ_FIXTURE_CACHE_DIR'), Sys.getCwd(), Sys.args()
		);
		// stream writes, never `Fs.writeSync`: a pipe to the test process is non-blocking and a sync write can EAGAIN
		Node.process.stdout.write(outcome.out);
		Node.process.stderr.write(outcome.err);
		Node.process.exitCode = outcome.status;
	}

	/**
	 * The compile `real args` in `cwd`: replayed from `dir` when it was recorded under the same key, else run and — when it
	 * is a whitelisted probe compile that exited — recorded. `dir` null runs everything for real.
	 */
	public static function run(real: String, stamp: String, dir: Null<String>, cwd: String, args: Array<String>): CompileOutcome {
		final compile: Null<CompilePlan> = dir == null ? null : plan(cwd, args);
		if (dir == null || compile == null) {
			final passed: CompileOutcome = spawn(real, cwd, args);
			if (dir != null) note(dir, 'pass');
			return passed;
		}
		final before: Null<Array<Map<String, String>>> = trees(compile.roots);
		if (before == null) {
			note(dir, 'pass');
			return spawn(real, cwd, args);
		}
		final id: String = key(stamp, compile, before);
		final entry: String = Path.join([dir, '$id.json.gz']);
		// A schema build's probe macro carries every embedded arm's switch, and the one `APQ_MUTANT` names is live in this
		// compile. An entry answers for it only when its compile never ran that switch — then the mutated method never ran
		// there either, and the answer is the unmutated one every arm shares; one that ran it is compiled for real.
		final active: Int = Std.parseInt(Sys.getEnv('APQ_MUTANT') ?? '') ?? 0;
		// where the CALLER collects the switches its compiles run — a cache in front of this one: answered as the compiler
		// would have, a replay included
		final callerLog: Null<String> = Sys.getEnv('APQ_MUTANT_MACRO_LOG');
		final stored: Null<String> = readEntry(entry);
		if (stored != null) {
			final hit: CompileEntry = Json.parse(stored);
			if (hit.reached.contains(active)) {
				note(dir, 'armed');
				return spawn(real, cwd, args);
			}
			// a hit renews the entry, so a cache that outlives one run ages out by disuse (`tools/fixture-cache.sh`)
			try Fs.utimesSync(entry, Date.now(), Date.now()) catch (exception: Exception) {} // noqa: swallowed-exception
			note(dir, 'hit');
			forward(callerLog, hit.reached);
			return replay(hit, compile.roots);
		}
		// One compile of a key at a time: the suite processes of one run ask for the same fixture TOGETHER — a sweep's
		// tracks pin the same tests — and each used to compile it, since none had recorded it yet. A process that finds the
		// key claimed waits for the holder's record and replays it; one whose holder recorded nothing compiles for real.
		final lock: String = '$entry.lock';
		if (!claim(lock)) {
			final shared: Null<String> = awaited(entry, lock);
			final sharedEntry: Null<CompileEntry> = shared == null ? null : Json.parse(shared);
			if (sharedEntry != null && !sharedEntry.reached.contains(active)) {
				note(dir, 'shared');
				forward(callerLog, sharedEntry.reached);
				return replay(sharedEntry, compile.roots);
			}
			final unshared: CompileOutcome = spawn(real, cwd, args);
			note(dir, 'pass');
			return unshared;
		}
		// the switches the compile runs, recorded by the probe macro's own `__mutOn` (`MutationSchema`)
		final reachedLog: String = '$entry.${Node.process.pid}.reached';
		final outcome: CompileOutcome = spawn(real, cwd, args, reachedLog);
		final reached: Array<Int> = readReached(reachedLog);
		forward(callerLog, reached);
		final after: Null<Array<Map<String, String>>> = trees(compile.roots);
		// a compile that ran the live arm's switch answered for that arm alone: not recorded
		final recorded: Null<CompileEntry> = after == null || !outcome.exited || reached.contains(active)
			? null
			: record(outcome, compile.roots, before, after, reached);
		if (recorded != null) {
			final temporary: String = '$entry.${Node.process.pid}.tmp';
			// gzipped: a probe's `-v` names every std module it parsed, ~240 KB of JSON a cache kept across runs pays per entry
			Fs.writeFileSync(temporary, Zlib.gzipSync(Json.stringify(recorded)));
			Fs.renameSync(temporary, entry);
		}
		release(lock);
		note(dir, recorded == null ? 'pass' : 'miss');
		return outcome;
	}

	/** The recorded entry at `entry`, unzipped, or null. */
	private static function readEntry(entry: String): Null<String> {
		return try Zlib.gunzipSync(Fs.readFileSync(entry)).toString('utf8') catch (exception: Exception) null;
	}

	/** Claims the compile of one key for this process (`lock` holds its pid); false when another process holds it. */
	private static function claim(lock: String): Bool {
		try {
			Fs.mkdirSync(lock);
		} catch (exception: Exception) {
			return false;
		}
		try Fs.writeFileSync(
			Path.join([lock, 'pid']), Std.string(Node.process.pid)
		) catch (exception: Exception) {} // noqa: swallowed-exception
		return true;
	}

	private static function release(lock: String): Void {
		try Fs.unlinkSync(Path.join([lock, 'pid'])) catch (exception: Exception) {} // noqa: swallowed-exception
		try Fs.rmdirSync(lock) catch (exception: Exception) {} // noqa: swallowed-exception
	}

	/**
	 * The entry the holder of `lock` records at `entry`, waited for; null once the holder released the key without one
	 * (a compile this class does not record), died holding it, or held it past `AWAIT_MS`.
	 */
	private static function awaited(entry: String, lock: String): Null<String> {
		final until: Float = Date.now().getTime() + AWAIT_MS;
		while (Date.now().getTime() < until) {
			final shared: Null<String> = readEntry(entry);
			if (shared != null) return shared;
			if (!Fs.existsSync(lock)) return readEntry(entry);
			final holder: Null<Int> = try Std.parseInt(Fs.readFileSync(Path.join([lock, 'pid']))
				.toString('utf8')) catch (exception: Exception) null;
			if (holder != null && !alive(holder)) {
				release(lock);
				return null;
			}
			js.Syntax.code('Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, {0})', AWAIT_POLL_MS);
		}
		return null;
	}

	/** Whether a process `pid` exists. */
	private static function alive(pid: Int): Bool {
		return try {
			// signal 0 probes without sending; the extern types the signal as a name
			js.Syntax.code('process.kill({0}, 0)', pid);
			true;
		} catch (exception: Exception) false;
	}

	/**
	 * The roots and placeheld arguments of the compile `args` in `cwd`, or null when it is not one this class may replay:
	 * see the class doc. Roots are real paths, the cwd first.
	 */
	public static function plan(cwd: String, args: Array<String>): Null<CompilePlan> {
		final base: Null<String> = realPath(cwd);
		if (base == null) return null;
		final roots: Array<String> = [base];
		var i: Int = 0;
		while (i < args.length) {
			final taken: Int = argument(base, args, i, roots);
			if (taken == 0) return null;
			i += taken;
		}
		final probe: Bool = Lambda.exists(
			[for (k in 1...args.length) if (args[k - 1] == '--macro') args[k]], m -> Lambda.exists(PROBE_MACROS, p -> m.indexOf(p) >= 0)
		);
		if (!probe || !args.contains('--no-output')) return null;
		// a root inside another is walked twice, and a compile running beside this one would write into both
		for (a in roots) for (b in roots) if (a != b && a.startsWith('$b/')) return null;
		return { roots: roots, args: [for (a in args) encode(a, roots)] };
	}

	/**
	 * How many of `args` the argument at `i` spans when `plan` allows it — 0 when it does not — with an absolute class
	 * path added to `roots`.
	 */
	private static function argument(base: String, args: Array<String>, i: Int, roots: Array<String>): Int {
		final flag: String = args[i];
		if (BARE_FLAGS.contains(flag)) return 1;
		if (!VALUE_FLAGS.contains(flag) && !CLASS_PATH_FLAGS.contains(flag))
			return flag.endsWith('.hxml') && inside(flag) && hxmlAllowed(base, flag, 0) ? 1 : 0;
		if (i + 1 >= args.length) return 0;
		final value: String = args[i + 1];
		if (!CLASS_PATH_FLAGS.contains(flag)) return 2;
		if (!Path.isAbsolute(value)) return inside(value) ? 2 : 0;
		final root: Null<String> = realPath(value);
		if (root == null || !Fs.statSync(root).isDirectory()) return 0;
		if (!roots.contains(root)) roots.push(root);
		return 2;
	}

	/**
	 * `text` with every spelling of every root in `roots` replaced by a placeholder naming the root and the spelling.
	 * The order is free: an alias is its real path's own tail (`/private` + `/var/x`), so either one replaced first
	 * decodes to the same text, and `plan` refuses a root inside another.
	 */
	public static function encode(text: String, roots: Array<String>): String {
		final spelled: Array<{ path: String, mark: String }> = [];
		for (r in 0...roots.length) {
			final forms: Array<String> = spellings(roots[r]);
			for (s in 0...forms.length) spelled.push({ path: forms[s], mark: '$MARK$r.$s$MARK' });
		}
		var out: String = text;
		for (s in spelled) out = out.split(s.path).join(s.mark);
		return out;
	}

	/** `text` with every placeholder `encode` wrote replaced by that root's spelling in `roots`. */
	public static function decode(text: String, roots: Array<String>): String {
		var out: String = text;
		for (r in 0...roots.length) {
			final forms: Array<String> = spellings(roots[r]);
			for (s in 0...forms.length) out = out.split('$MARK$r.$s$MARK').join(forms[s]);
		}
		return out;
	}

	/** The spellings of the real path `root`: itself, and on macOS the `/private`-less form a temp path is handed out as. */
	private static function spellings(root: String): Array<String> {
		return root.startsWith('/private/') ? [root, root.substr('/private'.length)] : [root];
	}

	/** Whether the relative `path` stays inside the directory it is relative to. */
	private static function inside(path: String): Bool {
		if (Path.isAbsolute(path) || path.indexOf(MARK) >= 0) return false;
		final normal: String = Path.normalize(path);
		return normal != '..' && !normal.startsWith('../');
	}

	/** Whether every line of the hxml `file` (relative to `base`) is one `plan` allows, includes followed. */
	private static function hxmlAllowed(base: String, file: String, depth: Int): Bool {
		if (depth > MAX_HXML_DEPTH) return false;
		final text: Null<String> = try Fs.readFileSync(Path.join([base, file]), { encoding: 'utf8' }) catch (exception: Exception) null;
		if (text == null) return false;
		for (raw in text.split('\n')) {
			final line: String = raw.trim();
			if (line == '' || line.startsWith('#')) continue;
			final space: Int = line.indexOf(' ');
			final flag: String = space < 0 ? line : line.substr(0, space);
			final value: String = space < 0 ? '' : line.substr(space + 1).trim();
			final allowed: Bool = if (BARE_FLAGS.contains(flag))
				value == ''
			else if (VALUE_FLAGS.contains(flag))
				value != ''
			else if (CLASS_PATH_FLAGS.contains(flag) || TARGET_FLAGS.contains(flag))
				value != '' && inside(value)
			else
				value == '' && flag.endsWith('.hxml') && inside(flag) && hxmlAllowed(base, flag, depth + 1);
			if (!allowed) return false;
		}
		return true;
	}

	/** Each root's files as relative path to content hash, or null when one is not a fixture (see `plan`). */
	private static function trees(roots: Array<String>): Null<Array<Map<String, String>>> {
		final out: Array<Map<String, String>> = [];
		for (root in roots) {
			final files: Map<String, String> = [];
			final budget: { files: Int, bytes: Int } = { files: MAX_ROOT_FILES, bytes: MAX_ROOT_BYTES };
			if (!walk(root, '', files, budget)) return null;
			out.push(files);
		}
		return out;
	}

	private static function walk(root: String, rel: String, files: Map<String, String>, budget: { files: Int, bytes: Int }): Bool {
		final here: String = rel == '' ? root : Path.join([root, rel]);
		for (name in Fs.readdirSync(here)) {
			final child: String = rel == '' ? name : '$rel/$name';
			final stat: Stats = Fs.lstatSync(Path.join([root, child]));
			if (stat.isDirectory()) {
				if (!walk(root, child, files, budget)) return false;
			} else if (stat.isFile()) {
				budget.files--;
				budget.bytes -= Std.int(stat.size);
				if (budget.files < 0 || budget.bytes < 0) return false;
				files[child] = hash(Fs.readFileSync(Path.join([root, child])));
			} else
				return false;
		}
		return true;
	}

	/** The cache key: the compiler, the environment it reads, the placeheld arguments and every root's content. */
	private static function key(stamp: String, compile: CompilePlan, contents: Array<Map<String, String>>): String {
		final described: Array<Array<String>> = [
			for (files in contents) {
				final names: Array<String> = [for (name in files.keys()) name];
				names.sort(Reflect.compare);
				[for (name in names) '$name\t${files[name]}'];
			}
		];
		final env: Array<String> = [for (name in HAXE_ENV) '$name=${Sys.getEnv(name) ?? ''}'];
		return hash(Buffer.from(Json.stringify({
			layout: LAYOUT,
			stamp: stamp,
			env: env,
			args: compile.args,
			roots: described
		})));
	}

	/**
	 * The entry for `outcome`: its placeheld streams and status, and every file of the roots it created, changed or
	 * deleted. Null when a stream or a written file is not UTF-8, which a placeholder cannot be spliced into.
	 */
	private static function record(
		outcome: CompileOutcome, roots: Array<String>, before: Array<Map<String, String>>, after: Array<Map<String, String>>,
		reached: Array<Int>
	): Null<CompileEntry> {
		final out: Null<String> = text(outcome.out);
		final err: Null<String> = text(outcome.err);
		if (out == null || err == null) return null;
		final files: Array<{ root: Int, path: String, text: Null<String> }> = [];
		for (r in 0...roots.length) {
			// the compile's cwd is the fixture, which the test and the compiles beside this one write too: a replay writes a
			// whole file where the compile may have appended to it, losing a concurrent writer's lines, so a compile writing
			// there is not recorded — the probes write only into their own directories
			if (r == 0 && changed(before[0], after[0])) return null;
			for (path => sum in after[r]) if (before[r][path] != sum) {
				final content: Null<String> = text(Fs.readFileSync(Path.join([roots[r], path])));
				if (content == null) return null;
				files.push({ root: r, path: path, text: encode(content, roots) });
			}
			for (path in before[r].keys()) if (!after[r].exists(path)) files.push({ root: r, path: path, text: null });
		}
		return {
			status: outcome.status,
			out: encode(out, roots),
			err: encode(err, roots),
			files: files,
			reached: reached
		};
	}

	/** What the compile recorded as `entry` answers at `roots`: its files written, its streams and status returned. */
	private static function replay(entry: CompileEntry, roots: Array<String>): CompileOutcome {
		for (f in entry.files) {
			final path: String = Path.join([roots[f.root], f.path]);
			final content: Null<String> = f.text;
			if (content == null) {
				try Fs.unlinkSync(path) catch (exception: Exception) {} // noqa: swallowed-exception
				continue;
			}
			sys.FileSystem.createDirectory(Path.directory(path));
			Fs.writeFileSync(path, decode(content, roots));
		}
		return {
			status: entry.status,
			out: Buffer.from(decode(entry.out, roots)),
			err: Buffer.from(decode(entry.err, roots)),
			exited: true
		};
	}

	/** The real compile; with `reachedLog`, the schema switches it runs are recorded there (`APQ_MUTANT_MACRO_LOG`). */
	private static function spawn(real: String, cwd: String, args: Array<String>, ?reachedLog: String): CompileOutcome {
		// the inherited environment, copied: the compile reads everything the test process was given
		final env: haxe.DynamicAccess<String> = js.Syntax.code('Object.assign({}, process.env)');
		if (reachedLog != null) env['APQ_MUTANT_MACRO_LOG'] = reachedLog;
		final res: ChildProcessSpawnSyncResult = ChildProcess.spawnSync(real, args, { cwd: cwd, maxBuffer: MAX_BUFFER, env: env });
		final status: Null<Int> = res.status;
		final empty: Buffer = Buffer.alloc(0);
		final stdout: Null<Buffer> = res.stdout;
		final stderr: Null<Buffer> = res.stderr;
		return {
			status: status ?? 1,
			out: stdout ?? empty,
			err: stderr ?? empty,
			exited: res.error == null && status != null
		};
	}

	/** The ids a compile's switches wrote to `log`, which is then removed; none when it wrote nothing. */
	private static function readReached(log: String): Array<Int> {
		final text: Null<String> = try Fs.readFileSync(log).toString('utf8') catch (exception: Exception) null;
		try Fs.unlinkSync(log) catch (exception: Exception) {} // noqa: swallowed-exception
		return text == null ? [] : [
			for (line in text.split('\n')) if (Std.parseInt(line) != null) Std.parseInt(line) ?? 0
		];
	}

	/** `reached` appended to the caller's switch log `log`, as the compile would have written them there. */
	private static function forward(log: Null<String>, reached: Array<Int>): Void {
		if (
			log != null && reached.length > 0
		) try Fs.appendFileSync(log, [for (id in reached) '$id\n'].join('')) catch (exception: Exception) {} // noqa: swallowed-exception
	}

	/** `bytes` as a string when it is UTF-8 that round-trips, else null. */
	private static function text(bytes: Buffer): Null<String> {
		final decoded: String = bytes.toString('utf8');
		return Buffer.from(decoded).equals(bytes) ? decoded : null;
	}

	private static function hash(bytes: Buffer): String {
		return Crypto.createHash('sha256').update(bytes).digest('hex');
	}

	private static function realPath(path: String): Null<String> {
		return try Fs.realpathSync(path) catch (exception: Exception) null;
	}

	/**
	 * One line of the cache's tally — `hit`, `miss` or `pass` — for the runner's report: in `APQ_FIXTURE_CACHE_TALLY` when
	 * set (a cache kept across runs, counted per run), else beside the entries.
	 */
	private static function note(dir: String, what: String): Void {
		final tally: String = Sys.getEnv('APQ_FIXTURE_CACHE_TALLY') ?? Path.join([dir, 'tally']);
		try Fs.appendFileSync(tally, '$what\n') catch (exception: Exception) {} // noqa: swallowed-exception
	}

	/** Whether a file of the root `after` describes was created, changed or deleted since `before`. */
	private static function changed(before: Map<String, String>, after: Map<String, String>): Bool {
		for (path => sum in after) if (before[path] != sum) return true;
		for (path in before.keys()) if (!after.exists(path)) return true;
		return false;
	}

}

/** A compile `FixtureCompileCache.plan` allows: the directories it reads and writes, and its placeheld arguments. */
typedef CompilePlan = {
	var roots: Array<String>;
	var args: Array<String>;
}

/** A compile's answer. `exited`: it ran to an exit status, so it may be recorded. */
typedef CompileOutcome = {
	var status: Int;
	var out: Buffer;
	var err: Buffer;
	var exited: Bool;
}

/** A recorded compile, every path in it placeheld: its status, streams, and the files it wrote (`text` null: deleted). */
typedef CompileEntry = {
	var status: Int;
	var out: String;
	var err: String;
	var files: Array<{ root: Int, path: String, text: Null<String> }>;

	/** The mutant switches (`APQ_MUTANT` ids) the compile ran, a schema build's arms; none for any other source. */
	var reached: Array<Int>;
}
