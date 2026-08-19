package anyparse.check;

import anyparse.check.CompilerOracle.OracleOutcome;
import haxe.io.Path;

using StringTools;

#if nodejs
import js.node.ChildProcess.ChildProcessSpawnSyncResult;
#end

/**
 * The compile-input tokens one hxml's TEXT declares: its `-cp` classpath roots, its
 * `-lib` library names (version suffix stripped) and the further hxml files it
 * includes. Paths are returned exactly as written — resolving them is the caller's
 * job, because a bare hxml-include line and a `-cp` entry both resolve against the
 * process CWD rather than the including file's directory.
 */
typedef HxmlRefs = {
	var classPaths: Array<String>;
	var libs: Array<String>;
	var includes: Array<String>;
}

/**
 * One persisted oracle verdict: the fingerprint it was observed under, the verdict
 * itself (`confirmed` / `rejected`) and the compiler's error text for a rejection.
 *
 * Every field is OPTIONAL so that `@:nullSafety(Strict)` types it `Null<String>`
 * honestly — the record comes off disk through `haxe.Json.parse`, which will happily
 * produce a structure missing any of them, and a reader that trusted the declared
 * types would dereference null on the first hand-edited or truncated file.
 */
typedef OracleVerdictRecord = {
	var ?fingerprint: String;
	var ?verdict: String;
	var ?errors: String;
}

/**
 * What one `haxe -v … --interp` probe reported about the toolchain: the classpath
 * directories the compiler itself named and its `Defines:` line. `ok` is false for
 * every probe that could not be believed (no `haxe`, a non-zero status, a missing
 * line) — a failed probe is memoised exactly like a successful one, so a machine
 * without a compiler pays the spawn once per process instead of once per lookup.
 */
private typedef CompilerProbe = {
	var ok: Bool;
	var dirs: Array<String>;
	var defines: String;
}

/**
 * The hxml include chain of one compile input: a manifest line per hxml visited (in
 * discovery order) plus the union of the classpath roots and library names the chain
 * declares. Roots are absolute and normalised; library names are bare.
 */
private typedef HxmlChain = {
	var lines: Array<String>;
	var classPaths: Array<String>;
	var libs: Array<String>;
}

/**
 * A CONTENT-ADDRESSED verdict cache for the report-mode compiler oracle: one
 * fingerprint over everything `haxe <hxml> --no-output` would read, and one persisted
 * verdict per (hxml, cwd) pair. On a hit no compiler is spawned at all.
 *
 * ## Why it exists (measured)
 *
 * The oracle is a PROJECT-WIDE typecheck on every invocation, regardless of how narrow
 * the lint scope is — 16.1s of a 43s `lint src --all` run on this project, and
 * `tools/battery.sh` paid it twice, since its `build` step had typechecked the same
 * hxml a minute earlier. Deriving the whole fingerprint instead costs ~0.28s: 0.12s for
 * the compiler probe below plus 0.154s to hash 3991 files. That ratio is the entire
 * argument for this class.
 *
 * ## What the fingerprint covers
 *
 *  - a format tag, so a change to the scheme itself invalidates every stored record;
 *  - the compiler's own `Defines:` line, which carries the Haxe version and the
 *    resolved version of every library on the command line;
 *  - every hxml in the include chain, by path AND content hash;
 *  - every `.hx` file under every classpath directory, by path and content hash,
 *    sorted by path. The directory list is the chain's own `-cp` roots UNION the
 *    entries of the `Classpath:` line the compiler reports for the chain's `-lib` set.
 *
 * That last union is what closes the haxelib hole: the library directories are not
 * guessed from a naming convention, the COMPILER names them, so transitive
 * dependencies, `extraLibs` and the Haxe std all enter the key by content. One
 * `haxe -v <-lib …> --interp Std` spawn buys it: `Std` only gives the compiler a
 * module to type, and with no `-main` nothing is ever executed.
 *
 * ## What it does NOT cover — the residual holes, plainly
 *
 *  - NON-`.hx` inputs a macro reads at compile time: an `-resource` payload, a
 *    compile-time `File.getContent`, a JSON/table file a `@:build` macro parses. Their
 *    content is invisible to the key, so editing one leaves a hit stale.
 *  - a classpath added at compile time by a `--macro` call: the probe sees the command
 *    line's classpath, not one the macro appends while typing.
 *  - environment-supplied defines (a `-D` computed by the caller's shell, a define a
 *    macro sets from `Sys.getEnv`): the `Defines:` line is captured from the PROBE's
 *    environment, which need not be the lint run's.
 *  - a source tree nested deeper than 32 directories below a classpath root: the walk
 *    caps its recursion there so a symlink loop terminates, and anything past the cap is
 *    simply absent from the key.
 *
 * Each of those is a hole that would make a hit stale, and together they are the whole
 * reason this cache is a REPORT-MODE fast path and nothing more. `--fix` never consults
 * it: `FixVerifier` writes files and then asks whether the project still compiles, a
 * question only a real compiler run may answer, so it calls `CompilerOracle` directly
 * and stays on the cold path by construction.
 *
 * ## Why mtime is banned here
 *
 * Only content is hashed — never a modification time, never a size. This project has
 * already paid for the alternative: the compilation server decides staleness by mtime
 * at ONE-SECOND granularity, so a write landing in the same second as the compile that
 * read the file is invisible and stays invisible, freezing a module at its previous
 * content indefinitely. Measured at 9 wrong verdicts in 10 iterations, including a
 * broken build reported as clean — see the `CompilerServer` class doc, section "Why
 * linted files are invalidated first". A content hash cannot have that failure mode.
 *
 * ## Every doubt falls through
 *
 * `fingerprint` returns null and `lookup` returns null for EVERY condition they cannot
 * answer under: an unreadable hxml, a probe that did not run or did not report, a
 * missing or corrupt record, a fingerprint that does not match, a target with no
 * filesystem. The caller then runs the real oracle, so the cache can only ever change
 * what a verdict COSTS. `Unavailable` is never stored — it says the oracle could not
 * run, which is not a fact about the tree.
 */
@:nullSafety(Strict)
final class OracleCache {

	/** Cap on hxml files followed through include lines — a cycle guard's partner, so a pathological chain cannot spin. */
	private static inline final MAX_HXML_CHAIN: Int = 32;

	/** Cap on classpath-walk recursion depth, so a symlink loop terminates instead of hanging the lint. */
	private static inline final MAX_DIR_DEPTH: Int = 32;

	/** The scheme tag in every manifest: bump it and every stored record misses, which is the point. */
	private static final FORMAT_TAG: String = 'apq-oracle-cache v1';

	/** Per-process memo of the compiler probe, keyed by compile root + library set — it depends on the toolchain, never on the tree under lint. */
	private static final probeMemo: Map<String, CompilerProbe> = [];

	/** Per-process memo of a directory's `.hx` content hashes, populated ONLY for the compiler's own installation dirs — see `mergeDir`. */
	private static final dirMemo: Map<String, Map<String, String>> = [];

	/**
	 * The whole `Defines: …` line of a `haxe -v` stdout — one string carrying the
	 * compiler version and every resolved library version — or null when it is absent.
	 * Pure.
	 */
	public static inline function probeDefines(verboseStdout: String): Null<String> {
		return firstLineStartingWith(verboseStdout, 'Defines:');
	}

	/**
	 * The content fingerprint of everything `haxe <hxml> --no-output` would read, or
	 * null when it cannot be computed honestly — an unreadable first hxml, a compiler
	 * probe that did not answer, or a target with no filesystem. Null means "no cache",
	 * never "unchanged".
	 */
	public static function fingerprint(hxml: String, cwd: Null<String>): Null<String> {
		#if (sys || nodejs)
		final root: String = cwd ?? Sys.getCwd();
		final chain: Null<HxmlChain> = scanHxmlChain(root, hxml);
		if (chain == null) return null;
		final probe: CompilerProbe = compilerProbe(root, chain.libs);
		return probe.ok ? md5(buildManifest(root, chain, probe).join('\n')) : null;
		#else
		return null;
		#end
	}

	/**
	 * The verdict stored for this (hxml, cwd) pair, but ONLY when it was recorded under
	 * the very fingerprint passed in. Null for a missing file, unparseable JSON, a
	 * record missing a field, an unknown verdict word, or any fingerprint mismatch —
	 * each of which means the caller must ask the compiler itself.
	 */
	public static function lookup(hxml: String, cwd: Null<String>, fingerprint: String): Null<OracleOutcome> {
		#if (sys || nodejs)
		final record: Null<OracleVerdictRecord> = readRecord(cacheFile(hxml, cwd));
		return record != null && record.fingerprint == fingerprint ? storedOutcome(record) : null;
		#else
		return null;
		#end
	}

	/**
	 * Persist an OBSERVED verdict under `fingerprint`, overwriting whatever this pair
	 * held — one file per (hxml, cwd), so the temp dir cannot grow without bound.
	 * `Unavailable` is never written: it reports that the oracle could not run, which
	 * says nothing about the tree. A write failure is swallowed, because an unwritable
	 * temp dir may cost the next run a typecheck but must never cost it a verdict.
	 */
	public static function store(hxml: String, cwd: Null<String>, fingerprint: String, outcome: OracleOutcome): Void {
		#if (sys || nodejs)
		final record: Null<OracleVerdictRecord> = switch (outcome) {
			case Confirmed: { fingerprint: fingerprint, verdict: 'confirmed', errors: '' };
			case Rejected(errors): { fingerprint: fingerprint, verdict: 'rejected', errors: errors };
			case Unavailable(_): null;
		};
		if (record == null) return;
		final path: String = cacheFile(hxml, cwd);
		if (path == '') return;
		try sys.io.File.saveContent(path, haxe.Json.stringify(record)) catch (_exception: haxe.Exception) {
			// Swallowed on purpose: see the doc comment above.
		}
		#end
	}

	/**
	 * Where this (hxml, cwd) pair's record lives — one file under the OS temp dir, named
	 * by a hash of the pair. Mirrors `CompilerServer.stateFile`; `''` on a target with
	 * no filesystem, which every caller here reads as "no store".
	 */
	public static function cacheFile(hxml: String, cwd: Null<String>): String {
		#if (sys || nodejs)
		final key: String = '${absolute(cwd ?? Sys.getCwd(), hxml)}|${cwd ?? ''}';
		return Path.join([tempDir(), 'apq-oracle-verdict-${md5(key)}.json']);
		#else
		return '';
		#end
	}

	/**
	 * The `-cp` / `-lib` / hxml-include tokens of one hxml's text. Pure — no filesystem,
	 * no process — so the token grammar is unit-testable on its own. Comment lines (a
	 * first non-space `#`) are skipped, tokens are whitespace-separated and one line may
	 * carry several of them.
	 */
	public static function hxmlRefs(text: String): HxmlRefs {
		final classPaths: Array<String> = [];
		final libs: Array<String> = [];
		final includes: Array<String> = [];
		for (rawLine in text.split('\n')) {
			final line: String = rawLine.trim();
			if (line == '' || line.startsWith('#')) continue;
			final tokens: Array<String> = [for (token in line.replace('\t', ' ').split(' ')) if (token != '') token];
			var i: Int = 0;
			while (i < tokens.length) {
				final token: String = tokens[i];
				final value: Null<String> = i + 1 < tokens.length ? tokens[i + 1] : null;
				switch token {
					case '-cp', '-p', '--class-path':
						if (value != null) classPaths.push(value);
						i += 2;
					case '-lib', '-L', '--library':
						if (value != null) libs.push(libName(value));
						i += 2;
					case _:
						if (!token.startsWith('-') && token.endsWith('.hxml')) includes.push(token);
						i++;
				}
			}
		}
		return { classPaths: classPaths, libs: libs, includes: includes };
	}

	/**
	 * The non-empty entries of a `haxe -v` `Classpath:` line, split on `;` — the
	 * compiler's own account of where it will look for sources. Empty array when the
	 * line is absent, so an unrecognised compiler output degrades to "nothing probed"
	 * rather than to a wrong key. Pure.
	 */
	public static function probeDirs(verboseStdout: String): Array<String> {
		final line: Null<String> = firstLineStartingWith(verboseStdout, 'Classpath:');
		if (line == null) return [];
		final payload: String = line.substr('Classpath:'.length);
		return [for (entry in payload.split(';')) if (entry.trim() != '') entry.trim()];
	}

	/** The library name of a `-lib` token, with any `:version` suffix stripped. */
	private static function libName(token: String): String {
		final colon: Int = token.indexOf(':');
		return colon < 0 ? token : token.substr(0, colon);
	}

	/** The first trimmed line of `text` starting with `prefix`, or null when there is none. */
	private static function firstLineStartingWith(text: String, prefix: String): Null<String> {
		for (raw in text.split('\n')) {
			final line: String = raw.trim();
			if (line.startsWith(prefix)) return line;
		}
		return null;
	}

	/** Lexicographic comparator for the manifest's file lines, which start with the path, so line order IS path order. */
	private static function compareStrings(a: String, b: String): Int {
		return if (a < b)
			-1
		else if (a > b)
			1
		else
			0;
	}

	/**
	 * md5 of `data`. Node's native digest is roughly 100x the pure-Haxe implementation,
	 * and that difference is what makes hashing 3991 files cost 0.154s instead of
	 * dominating the very typecheck this cache exists to avoid.
	 */
	private static function md5(data: String): String {
		return #if nodejs js.node.Crypto.createHash('md5').update(data, 'utf8').digest('hex') #else haxe.crypto.Md5.encode(data) #end;
	}

	#if (sys || nodejs)
	/** The record stored at `path`, or null when there is none, it cannot be read, or its bytes are not JSON at all. */
	private static function readRecord(path: String): Null<OracleVerdictRecord> {
		if (path == '' || !fileExists(path)) return null;
		final text: Null<String> = readText(path);
		return text == null ? null : parseRecord(text);
	}

	/** `haxe.Json.parse` narrowed to the record shape, null for bytes that do not parse. */
	private static function parseRecord(text: String): Null<OracleVerdictRecord> {
		return try haxe.Json.parse(text) catch (_exception: haxe.Exception) null;
	}

	/**
	 * The outcome one record carries — null for an unknown verdict word or a rejection
	 * with no error text, so a truncated or hand-edited record falls through to the real
	 * compiler instead of being believed.
	 */
	private static function storedOutcome(record: OracleVerdictRecord): Null<OracleOutcome> {
		return switch (record.verdict) {
			case 'confirmed':
				Confirmed;
			case 'rejected':
				final errors: Null<String> = record.errors;
				errors == null ? null : Rejected(errors);
			case _:
				null;
		};
	}

	/**
	 * Follow the hxml include chain from `hxml`, collecting a manifest line per file
	 * plus the classpath roots and library names declared anywhere in it. Both a `-cp`
	 * entry and a bare hxml-include line resolve against the compile ROOT, not against
	 * the including file's directory — that is how the compiler resolves them, verified.
	 * Null only when the FIRST hxml cannot be read: it IS the compile input, so without
	 * it there is nothing to key on. A missing include below it is the compiler's
	 * problem to report, not the key's to guess at.
	 */
	private static function scanHxmlChain(root: String, hxml: String): Null<HxmlChain> {
		final queue: Array<String> = [absolute(root, hxml)];
		final lines: Array<String> = [];
		final classPaths: Array<String> = [];
		final libs: Array<String> = [];
		var i: Int = 0;
		while (i < queue.length) {
			// A truncated chain would key on only part of the compile input, which is a stale
			// hit waiting to happen — so an absurdly long chain refuses the whole fingerprint
			// rather than hashing a prefix of it.
			if (i >= MAX_HXML_CHAIN) return null;
			final path: String = queue[i];
			i++;
			final text: Null<String> = readText(path);
			if (text == null) {
				if (lines.length == 0) return null;
				continue;
			}
			lines.push('hxml $path ${md5(text)}');
			mergeRefs(root, hxmlRefs(text), queue, classPaths, libs);
		}
		return { lines: lines, classPaths: classPaths, libs: libs };
	}

	/** Fold one hxml's refs into the chain's accumulators, absolutising paths against the compile root and deduping — the queue's dedupe is also the include-cycle guard. */
	private static function mergeRefs(
		root: String, refs: HxmlRefs, queue: Array<String>, classPaths: Array<String>, libs: Array<String>
	): Void {
		for (classPath in refs.classPaths) {
			final dir: String = absolute(root, classPath);
			if (!classPaths.contains(dir)) classPaths.push(dir);
		}
		for (lib in refs.libs) if (!libs.contains(lib)) libs.push(lib);
		for (include in refs.includes) {
			final next: String = absolute(root, include);
			if (!queue.contains(next)) queue.push(next);
		}
	}

	/** The manifest the fingerprint hashes: the tag, the compiler's defines, the hxml chain, then every reachable `.hx` file by path and content hash, sorted by path. */
	private static function buildManifest(root: String, chain: HxmlChain, probe: CompilerProbe): Array<String> {
		final files: Map<String, String> = [];
		// The compile directory is on the compiler's classpath IMPLICITLY — it is the empty
		// entry in the `Classpath:` line, which `probeDirs` drops. A module dropped next to the
		// hxml is compiled like any other, so it has to enter the key; walking the root first
		// also means the declared `-cp` roots beneath it cost only their directory scan.
		mergeDir(files, root, false);
		for (dir in chain.classPaths) mergeDir(files, dir, false);
		for (dir in probe.dirs) mergeDir(files, absolute(root, dir), true);
		final fileLines: Array<String> = [for (path => hash in files) '$path $hash'];
		fileLines.sort(compareStrings);
		return [FORMAT_TAG, probe.defines].concat(chain.lines).concat(fileLines);
	}

	/**
	 * Merge one directory's `.hx` content hashes into the manifest set.
	 *
	 * `memoise` is true ONLY for directories the compiler probe named — the Haxe std,
	 * `extraLibs`, the haxelib installs. Those are the toolchain's own installation,
	 * which a single lint process never edits, so hashing them once per process is
	 * honest and is what keeps the test suite from re-reading the 2625-file std for
	 * every oracle test. The hxml's own `-cp` roots are never memoised: they ARE the
	 * tree under lint, and re-reading them every time is the whole point of the key.
	 */
	private static function mergeDir(into: Map<String, String>, dir: String, memoise: Bool): Void {
		if (!memoise) {
			// Straight into the shared set, so a file an enclosing root already hashed is
			// skipped instead of read a second time — which is what makes NESTED roots (the
			// compile directory and the `-cp` entries under it) cost a directory scan and
			// nothing more.
			walkDir(dir, into, 0);
			return;
		}
		for (path => hash in memoDir(dir)) into[path] = hash;
	}

	/** `collectDir` behind the per-process memo. */
	private static function memoDir(dir: String): Map<String, String> {
		final memo: Null<Map<String, String>> = dirMemo[dir];
		if (memo != null) return memo;
		final collected: Map<String, String> = collectDir(dir);
		dirMemo[dir] = collected;
		return collected;
	}

	/** Every `.hx` under `dir`, as absolute normalised path to content hash. An unreadable directory contributes nothing rather than failing the key. */
	private static function collectDir(dir: String): Map<String, String> {
		final collected: Map<String, String> = [];
		walkDir(dir, collected, 0);
		return collected;
	}

	/** The recursive half of `collectDir`: dot-prefixed entries are skipped (which keeps `.git` out), depth is capped so a symlink loop terminates, unreadable entries are skipped. */
	private static function walkDir(dir: String, into: Map<String, String>, depth: Int): Void {
		if (depth > MAX_DIR_DEPTH) return;
		final entries: Null<Array<String>> = try sys.FileSystem.readDirectory(dir) catch (_exception: haxe.Exception) null;
		if (entries == null) return;
		for (entry in entries) if (!entry.startsWith('.')) {
			final full: String = Path.normalize(Path.join([dir, entry]));
			if (isDirectory(full))
				walkDir(full, into, depth + 1);
			else if (full.endsWith('.hx') && !into.exists(full)) {
				final text: Null<String> = readText(full);
				if (text != null) into[full] = md5(text);
			}
		}
	}

	/** The compiler probe behind its per-process memo, keyed by compile root plus library set — the two things it actually depends on. */
	private static function compilerProbe(root: String, libs: Array<String>): CompilerProbe {
		final key: String = '$root\n${libs.join(' ')}';
		final memo: Null<CompilerProbe> = probeMemo[key];
		if (memo != null) return memo;
		final probe: CompilerProbe = runCompilerProbe(root, libs);
		probeMemo[key] = probe;
		return probe;
	}

	/**
	 * Ask the compiler to name its own classpath and defines: `haxe -v <-lib …>
	 * --interp` from the compile root. No `-main`, so nothing runs; measured at 0.12s.
	 * Deliberately NOT routed through `CompilerOracle`, whose `invocations` counter is a
	 * pure spawn counter for `haxe <hxml> --no-output` and is asserted on by the
	 * no-key gate tests.
	 *
	 * Status 0 AND both lines present, or the probe is not believed. The native `sys`
	 * branch cannot set a working directory (`sys.io.Process` has none), so it runs in
	 * the process CWD — the same limitation `CompilerOracle` documents, and it only
	 * matters for a project with a local `.haxelib`.
	 */
	private static function runCompilerProbe(root: String, libs: Array<String>): CompilerProbe {
		final failed: CompilerProbe = { ok: false, dirs: [], defines: '' };
		final args: Array<String> = ['-v'];
		for (lib in libs) {
			args.push('-lib');
			args.push(lib);
		}
		args.push('--interp');
		// `Std` is a DOT PATH, not a flag: without something to type, `haxe -v --interp`
		// prints its usage screen and exits 0, so the two lines below would be absent and
		// every library-less project would silently lose its cache. `Std` is a std module
		// every target defines, it costs nothing to type, and it leaves the reported
		// classpath and defines byte-identical to a probe without it (verified).
		args.push('Std');
		final out: String = probeOutput(root, args);
		final defines: Null<String> = probeDefines(out);
		final dirs: Array<String> = probeDirs(out);
		return defines == null || dirs.length == 0 ? failed : { ok: true, dirs: dirs, defines: defines };
	}

	/** One `haxe` spawn for the probe; `''` for every launch failure and every non-zero status, which `runCompilerProbe` then reads as "not believed". */
	private static function probeOutput(root: String, args: Array<String>): String {
		#if nodejs
		final options: Dynamic = { encoding: 'utf8', cwd: root };
		final res: ChildProcessSpawnSyncResult = js.node.ChildProcess.spawnSync('haxe', args, options);
		final launchError: Null<Dynamic> = (res.error: Dynamic);
		if (launchError != null) return '';
		final status: Null<Int> = (res.status: Null<Int>);
		final out: Dynamic = res.stdout;
		return status == 0 && out != null ? '$out' : '';
		#elseif sys
		try {
			final process: sys.io.Process = new sys.io.Process('haxe', args);
			// Drained BEFORE `exitCode()`: the probe writes a line per parsed module, far
			// more than a pipe buffer holds, and waiting on exit first would deadlock.
			final text: String = process.stdout.readAll().toString();
			final code: Null<Int> = process.exitCode();
			process.close();
			return code == 0 ? text : '';
		} catch (_exception: haxe.Exception) {
			return '';
		}
		#else
		return '';
		#end
	}

	/** `path` resolved against the compile root when relative, normalised either way — the one spelling every key and memo is written in. */
	private static function absolute(root: String, path: String): String {
		return Path.normalize(Path.isAbsolute(path) ? path : Path.join([root, path]));
	}

	/** Whether `path` exists, false for a filesystem that refuses to answer. */
	private static function fileExists(path: String): Bool {
		return try sys.FileSystem.exists(path) catch (_exception: haxe.Exception) false;
	}

	/** Whether `path` is a directory, false for an entry the filesystem refuses to stat. */
	private static function isDirectory(path: String): Bool {
		return try sys.FileSystem.isDirectory(path) catch (_exception: haxe.Exception) false;
	}

	/** `path`'s content, or null when it cannot be read — the caller decides what an unreadable file means. */
	private static function readText(path: String): Null<String> {
		return try sys.io.File.getContent(path) catch (_exception: haxe.Exception) null;
	}

	/** The OS temp dir the record lives in, mirroring `CompilerServer.stateFile`. */
	private static function tempDir(): String {
		#if nodejs
		return js.node.Os.tmpdir();
		#elseif sys
		return Sys.getEnv('TMPDIR') ?? '/tmp';
		#end
	}
	#end

}
