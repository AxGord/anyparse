package anyparse.query.cli;

import haxe.Constraints.Function;
import haxe.Resource;
import js.Node;
import js.node.Buffer;
import js.node.ChildProcess;
import js.node.Crypto;
import js.node.Fs;
import js.node.Module;
import js.node.Os;
import js.node.Path;
import js.node.Process;
import js.node.fs.Stats;

/**
 * The launcher a build writes beside `apq.js` as `apq-launch.js`: it compiles the engine through a V8 code cache kept in
 * a file beside the binary, so a call deserializes bytecode instead of parsing the engine's source. A cache that is
 * missing, stale, foreign or damaged is never offered to V8 — the engine then compiles from source as plain `node`
 * would, and the cache is rewritten when that run ends.
 *
 * `apq-launch.js <apq.js> <args…>` runs the engine; `apq-launch.js --warm <apq.js>` writes its cache from one run of each
 * command family over a bundled fixture, which is what a build does so the first call is already fast.
 */
@:nullSafety(Strict)
final class CodeCacheLauncher {

	/** The suffix the cache file adds to the binary's path. */
	public static inline final SUFFIX: String = '.v8cache';

	/** The first argument that makes this a warm run. */
	public static inline final WARM: String = '--warm';

	/** Set to `1`, every call says on stderr whether its cache was a hit, a miss or refused by V8. */
	public static inline final TRACE_ENV: String = 'APQ_CODE_CACHE_TRACE';

	/** The bytes every cache file opens with; bump the digit on any change to the layout `writeCache` documents. */
	private static inline final MAGIC: String = 'apq-cc1\n';

	/** The length of a SHA-256 digest: the cache key and the payload's checksum. */
	private static inline final DIGEST_LENGTH: Int = 32;

	private static inline final SHA256: String = 'sha256';

	/** The wrapper node's own module loader puts around a CommonJS module (`Module.wrap`). */
	private static inline final WRAP_HEAD: String = '(function (exports, require, module, __filename, __dirname) { ';

	private static inline final WRAP_TAIL: String = '\n});';

	/** The `-resource` name of the Haxe source a warm run drives the engine over (`bin/apq-launch-common.hxml`). */
	private static inline final FIXTURE_RESOURCE: String = 'warm-fixture';

	/** The first argument of the child process a warm run drives the engine in. */
	private static inline final WARM_RUN: String = '--warm-run';

	/** How long a warm run may take before the build goes on without its cache. */
	private static inline final WARM_TIMEOUT_MS: Int = 120000;

	/** The placeholder `WARM_RUNS` writes for the fixture's path. */
	private static inline final FIXTURE: String = '<fixture>';

	/**
	 * The command lines of a warm run, each given `--lang haxe` after its subcommand as the `hxq` shim gives it. V8
	 * caches only the functions a run compiled, so each command family a call is likely to be gets one run: parse,
	 * format, read, lint.
	 */
	private static final WARM_RUNS: Array<Array<String>> = [
		['ast', FIXTURE],
		['fmt', FIXTURE],
		['source', FIXTURE, '--range', '1:20'],
		['lint', FIXTURE, '--no-oracle']
	];

	/** The cache file of the engine at `binary`. */
	public static inline function cachePath(binary: String): String {
		return binary + SUFFIX;
	}

	public static function main(): Void {
		final process: Process = Node.process;
		final args: Array<String> = process.argv.slice(2);
		final given: Null<String> = args[0];
		if (given == null) {
			process.stderr.write('usage: apq-launch.js <apq.js> <args…> | apq-launch.js $WARM <apq.js>\n');
			process.exitCode = 2;
			return;
		}
		if (given == WARM) {
			warm(args[1]);
			return;
		}
		if (given == WARM_RUN) {
			warmRun(Fs.realpathSync(Path.resolve(args[1])), args[2]);
			return;
		}
		final resolved: String = Path.resolve(given);
		process.argv = [process.argv[0], resolved].concat(args.slice(1));
		// the real path, as node's own loader names a main module: V8 keeps it in the cache and in every stack
		final binary: String = Fs.realpathSync(resolved);
		final engine: CompiledEngine = compile(binary, true);
		if (Sys.getEnv(TRACE_ENV) == '1') process.stderr.write('apq-launch: code cache ${engine.cache} (${cachePath(binary)})\n');
		if (engine.cache != Hit) process.once(ProcessEvent.Exit, (_: Int) -> persistQuietly(engine, binary));
		run(engine.script, binary);
	}

	/**
	 * What a cache compiled by this process depends on besides the source: node and V8 versions, platform, and the flags V8
	 * hashes into a cache, since one made under other flags would only be refused. One file holds one tag: a call under
	 * another tag rewrites it.
	 */
	public static function runtimeTag(): String {
		final process: Process = Node.process;
		return [
			process.version,
			process.execPath,
			process.arch,
			process.platform,
			process.versions['v8'],
			process.execArgv.join(' '),
			Sys.getEnv('NODE_OPTIONS') ?? ''
		].join('\n');
	}

	/**
	 * The key the cache of `source` compiled under `runtime` is filed under. It hashes the source's CONTENT because V8
	 * checks only its length: a same-length rebuild offered the old cache runs the OLD engine's code.
	 */
	public static function cacheKey(source: Buffer, runtime: String): Buffer {
		return Crypto.createHash(SHA256).update(source).update(runtime).digest();
	}

	/**
	 * The payload of the cache at `path` when it is filed under `key` and intact, else null — missing, foreign, stale,
	 * truncated and corrupt alike. The checksum is load-bearing: V8 does not verify a payload, and a damaged one can abort
	 * the process.
	 */
	public static function readCache(path: String, key: Buffer): Null<Buffer> {
		if (!Fs.existsSync(path)) return null;
		final data: Buffer = Fs.readFileSync(path);
		final head: Int = MAGIC.length + DIGEST_LENGTH * 2;
		if (data.length < head || data.toString('latin1', 0, MAGIC.length) != MAGIC) return null;
		if (!data.slice(MAGIC.length, MAGIC.length + DIGEST_LENGTH).equals(key)) return null;
		final payload: Buffer = data.slice(head);
		return sha256(payload).equals(data.slice(MAGIC.length + DIGEST_LENGTH, head)) ? payload : null;
	}

	/**
	 * Writes the cache file: `MAGIC`, `key`, the payload's SHA-256, the payload. It is written whole under a temporary
	 * name and renamed over `path`, so a process reading it at the same time sees the old file or the new one, never a
	 * part.
	 */
	public static function writeCache(path: String, key: Buffer, payload: Buffer): Void {
		final temp: String = '$path.${Node.process.pid}.tmp';
		try {
			Fs.writeFileSync(temp, Buffer.concat([Buffer.from(MAGIC, 'latin1'), key, sha256(payload), payload]));
			Fs.renameSync(temp, path);
		} catch (exception: Exception) {
			if (Fs.existsSync(temp)) Fs.unlinkSync(temp);
			throw exception;
		}
	}

	/**
	 * The engine at `binary` (a real path) compiled, offered its cache when `useCache` and the cache is valid for it. The key
	 * carries the path because V8 keeps the script name in a cache: a hit would name the path the cache was written from.
	 */
	public static function compile(binary: String, useCache: Bool): CompiledEngine {
		final stamp: String = stampOf(binary);
		final source: Buffer = Fs.readFileSync(binary);
		final key: Buffer = cacheKey(source, '${runtimeTag()}\n$binary');
		final cached: Null<Buffer> = useCache ? readCache(cachePath(binary), key) : null;
		final options: CachedScriptOptions = { filename: binary };
		if (cached != null) options.cachedData = cached;
		final script: CachedScript = new CachedScript(WRAP_HEAD + source.toString('utf8') + WRAP_TAIL, options);
		final cache: CacheUse = if (cached == null)
			Miss
		else if (script.cachedDataRejected == true)
			Rejected
		else
			Hit;
		return {
			script: script,
			key: key,
			stamp: stamp,
			cache: cache
		};
	}

	/** Runs a compiled engine as node's module loader would: the same wrapper arguments, `require` resolving beside `binary`. */
	public static function run(script: CachedScript, binary: String): Void {
		final wrapper: Function = script.runInThisContext();
		final exports: {} = {};
		Reflect.callMethod(exports, wrapper, [
			exports,
			Module.createRequire(binary),
			{ exports: exports },
			binary,
			Path.dirname(binary)
		]);
	}

	/**
	 * Saves the cache of `engine` beside `binary` and answers true, unless the binary changed on disk since it was read:
	 * an old engine's run must not replace the cache a fresh build just warmed.
	 */
	public static function persist(engine: CompiledEngine, binary: String): Bool {
		if (stampOf(binary) != engine.stamp) return false;
		writeCache(cachePath(binary), engine.key, engine.script.createCachedData());
		return true;
	}

	private static inline function sha256(data: Buffer): Buffer {
		return Crypto.createHash(SHA256).update(data).digest();
	}

	/** `persist` at the end of a call, whose own outcome a cache that could not be saved must not change. */
	private static function persistQuietly(engine: CompiledEngine, binary: String): Void {
		try {
			persist(engine, binary);
		} catch (exception: Exception) {
			if (Sys.getEnv(TRACE_ENV) == '1') Node.process.stderr.write('apq-launch: code cache not saved: ${exception.message}\n');
		}
	}

	/**
	 * `--warm <apq.js>`: runs `WARM_RUNS` in ONE child process (`--warm-run`) with this process's node flags, so the cache
	 * it saves matches the calls that read it, and with its output discarded. It always exits 0 — a build must not fail
	 * because its cache could not be warmed; the first call then writes one.
	 */
	private static function warm(given: Null<String>): Void {
		final process: Process = Node.process;
		final message: String = try {
			if (given == null) throw new Exception('no <apq.js> to warm');
			final binary: String = Path.resolve(given);
			final dir: String = Fs.mkdtempSync(Path.join(Os.tmpdir(), 'apq-warm-'));
			final fixture: String = Path.join(dir, 'Warm.hx');
			Fs.writeFileSync(fixture, Resource.getString(FIXTURE_RESOURCE) ?? 'class Warm {}\n');
			final args: Array<String> = process.execArgv.concat([process.argv[1], WARM_RUN, binary, fixture]);
			final result: ChildProcessSpawnSyncResult = ChildProcess.spawnSync(
				process.execPath, args, { stdio: 'ignore', timeout: WARM_TIMEOUT_MS }
			);
			Fs.unlinkSync(fixture);
			Fs.rmdirSync(dir);
			result.status == 0
				? 'warmed ${cachePath(binary)}'
				: 'code cache not warmed: the warm run ended with status ${result.status}, signal ${result.signal}';
		} catch (exception: Exception) {
			'code cache not warmed: ${exception.message}';
		};
		process.stdout.write('apq-launch: $message\n');
	}

	/**
	 * Runs the first of `runs`, then the rest once its microtask (where the engine's `main` runs a command) is done, and
	 * after the last saves the cache they all grew and exits — past whatever the engine's runs left scheduled.
	 */
	private static function warmNext(engine: CompiledEngine, binary: String, runs: Array<Array<String>>): Void {
		final process: Process = Node.process;
		final args: Null<Array<String>> = runs.shift();
		if (args == null) {
			// `warmRun` drops uncaught errors, so a cache that cannot be saved must be caught here to fail the run
			final saved: Bool = try persist(engine, binary) catch (exception: Exception) false;
			process.exit(saved ? 0 : 1);
			return;
		}
		process.argv = [process.argv[0], binary].concat(args);
		run(engine.script, binary);
		Node.setImmediate(warmNext.bind(engine, binary, runs));
	}

	/** The size and modification time of `binary`: what tells a rewritten engine from the one a run read. */
	private static function stampOf(binary: String): String {
		final stat: Stats = Fs.statSync(binary);
		return '${stat.size}:${stat.mtime.getTime()}';
	}

	/**
	 * `--warm-run <apq.js> <fixture>`: the child of `warm`. A command that throws must not end the runs after it, so an
	 * uncaught error is dropped here; the cache is saved from whatever compiled.
	 */
	private static function warmRun(binary: String, fixture: String): Void {
		final engine: CompiledEngine = compile(binary, false);
		Node.process.on(ProcessEvent.UncaughtException, (error: Any) -> {});
		final runs: Array<Array<String>> = [
			for (line in WARM_RUNS) [line[0], '--lang', 'haxe'].concat([for (arg in line.slice(1)) arg == FIXTURE ? fixture : arg])
		];
		warmNext(engine, binary, runs);
	}

}

/** What became of an engine's cache in one call. */
enum abstract CacheUse(String) to String {

	/** V8 took the cache. */
	var Hit = 'hit';

	/** No valid cache was there to offer. */
	var Miss = 'miss';

	/** V8 refused the cache it was offered. */
	var Rejected = 'rejected';

}

/** An engine compiled for one call. */
typedef CompiledEngine = {

	final script: CachedScript;

	/** The key its cache is filed under. */
	final key: Buffer;

	/** The binary's size and modification time when it was read. */
	final stamp: String;

	final cache: CacheUse;

};

/** `vm.Script` with the code-cache members the hxnodejs extern leaves out. */
@:jsRequire('vm', 'Script')
extern class CachedScript {

	/** Whether V8 refused the `cachedData` it was offered; undefined when none was. */
	public var cachedDataRejected(default, null): Null<Bool>;

	public function new(code: String, options: CachedScriptOptions);

	public function runInThisContext(): Any;

	public function createCachedData(): Buffer;

}

/**
 * The options of `CachedScript`: `cachedData` is left out, never null, when there is no cache to offer.
 */
typedef CachedScriptOptions = {

	var filename: String;

	@:optional var cachedData: Buffer;

};
