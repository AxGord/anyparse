package anyparse.check;

import anyparse.check.Check.TypeOracle;

/**
 * A `TypeOracle` backed by the Haxe DISPLAY protocol against a warm compilation
 * server — the compiler-oracle TAIL for a resolver-unreachable autofix (the
 * generics / inference locals `explicit-local-type`'s structural arm cannot pin).
 * Lifecycle: `start` spawns `haxe --wait <port>` in the background, WARMS it with
 * one `haxe --connect <port> <hxml> --no-output`, and returns a handle; `typeAt`
 * queries `haxe --connect <port> <hxml> --display <file>@<bytePos>@type` per finding
 * and parses the `<type>...</type>` reply; `stop` kills the server. The server keeps
 * the compilation cached, so each query is a fast incremental round-trip rather than
 * a fresh full compile — the difference that makes hundreds of queries practical.
 *
 * ## Why the server is queries-only, never post-write verification
 *
 * The Haxe compilation server invalidates a module by mtime at ONE-SECOND
 * granularity, so a write-then-reverify within the same second reads the STALE
 * module (verified: a fresh write reverting a break is not re-picked-up until >1s
 * later). This oracle therefore does READ-ONLY type queries against files unchanged
 * since the warm; the caller applies edits and verifies with a FRESH
 * `CompilerOracle.typecheck` (a new process always reads current bytes). Never route
 * a post-edit typecheck through this server.
 *
 * ## Target
 *
 * The query path is `#if nodejs` (the target `apq` ships on) — `spawn` for the
 * background server, `spawnSync` for each `--connect`. On any other target `start`
 * returns null (the oracle is unavailable and the assisted pass degrades to
 * report-only), so the class type-checks everywhere while only the nodejs path runs.
 * A missing `haxe`, a port that never comes up, or a spawn error all yield a null
 * `start` / a null `typeAt` — the oracle degrades, never throws.
 */
@:nullSafety(Strict)
final class CompilerDisplayOracle implements TypeOracle {

	/** Total `typeAt` queries this process — a spawn counter tests read to prove the no-config gate. */
	public static var invocations(default, null): Int = 0;

	/** Ephemeral-port search: try this many random high ports before giving up on a free one. */
	private static inline final MAX_PORT_ATTEMPTS: Int = 8;

	/** Random server port range: `[PORT_BASE, PORT_BASE + PORT_SPAN)`. */
	private static inline final PORT_BASE: Int = 20000;

	private static inline final PORT_SPAN: Int = 40000;

	/** Warm poll budget: `--connect` attempts (each ~0.3s apart) to let the server boot and run its first compile. */
	private static inline final MAX_WARM_ATTEMPTS: Int = 40;

	private final _hxml: String;
	private final _cwd: Null<String>;
	private final _port: Int;

	/** Cached winning display-path form index (see `pathForms`); -1 until the first successful query probes it. */
	private var _pathForm: Int = -1;

	#if nodejs
	private final _child: Dynamic;

	function new(hxml: String, cwd: Null<String>, port: Int, child: Dynamic) {
		_hxml = hxml;
		_cwd = cwd;
		_port = port;
		_child = child;
	}
	#else
	function new(hxml: String, cwd: Null<String>, port: Int) {
		_hxml = hxml;
		_cwd = cwd;
		_port = port;
	}
	#end

	/**
	 * Start a warm display server for `hxml` (run from `cwd`) and return a handle, or
	 * null when one could not be brought up — no `haxe`, no free port after several
	 * tries, or a non-nodejs target. A returned handle MUST be `stop`ped to reap the
	 * server process.
	 */
	public static function start(hxml: String, ?cwd: String): Null<CompilerDisplayOracle> {
		#if nodejs
		var attempt: Int = 0;
		while (attempt < MAX_PORT_ATTEMPTS) {
			attempt++;
			final port: Int = PORT_BASE + Std.random(PORT_SPAN);
			final child: Dynamic = spawnServer(port);
			if (child == null) continue;
			if (warm(port, hxml, cwd)) return new CompilerDisplayOracle(hxml, cwd, port, child);
			killChild(child);
		}
		return null;
		#else
		return null;
		#end
	}

	public function typeAt(file: String, bytePos: Int): Null<String> {
		invocations++;
		#if nodejs
		// The server matches the display path against the module path AS THE COMPILER RECORDED
		// IT, which mirrors the `-cp` form: a relative classpath (`-cp .`) records cwd-relative,
		// an absolute one (`-cp /abs/src`) records that absolute string (NOT symlink-resolved).
		// We cannot parse the hxml, so try both forms and cache the one that resolves — every
		// file in a run shares a classpath convention, so this probes once.
		final forms: Array<String> = pathForms(file);
		if (_pathForm >= 0 && _pathForm < forms.length) {
			final cached: Null<String> = queryType(forms[_pathForm], bytePos);
			if (cached != null) return cached;
		}
		for (i in 0...forms.length) {
			final out: Null<String> = queryType(forms[i], bytePos);
			if (out != null) {
				_pathForm = i;
				return out;
			}
		}
		return null;
		#else
		return null;
		#end
	}

	/** Reap the background server. Idempotent and exception-safe. */
	public function stop(): Void {
		#if nodejs
		killChild(_child);
		#end
	}

	/**
	 * The type text of a `--display …@type` reply — the content of the first
	 * `<type …>…</type>` element, XML-decoded and trimmed — or null when the reply
	 * carries no `<type>` (an error line such as `No completion point was found`, a
	 * `Type not found`, or empty output). PURE: no process, unit-testable.
	 */
	public static function parseTypeResponse(raw: String): Null<String> {
		final open: Int = raw.indexOf('<type');
		if (open < 0) return null;
		final gt: Int = raw.indexOf('>', open);
		if (gt < 0) return null;
		final close: Int = raw.indexOf('</type>', gt);
		if (close < 0) return null;
		final body: String = StringTools.htmlUnescape(raw.substring(gt + 1, close));
		final trimmed: String = StringTools.trim(body);
		return trimmed == '' ? null : trimmed;
	}

	#if nodejs
	static function spawnServer(port: Int): Dynamic {
		try {
			final opts: Dynamic = { detached: false, stdio: 'ignore' };
			return js.node.ChildProcess.spawn('haxe', ['--wait', Std.string(port)], opts);
		} catch (e: haxe.Exception) {
			return null;
		}
	}

	static function killChild(child: Dynamic): Void {
		// child.kill() does not throw for an already-dead process (it returns false) — no guard needed.
		if (child != null) child.kill();
	}

	/**
	 * Poll `--connect` until the server answers (its first real connect drives the
	 * initial full compile and blocks until done) or the boot budget is spent. A
	 * `Could not connect` reply means the port is not listening yet — sleep and retry.
	 */
	static function warm(port: Int, hxml: String, cwd: Null<String>): Bool {
		var attempt: Int = 0;
		while (attempt < MAX_WARM_ATTEMPTS) {
			attempt++;
			final res: Null<Dynamic> = connect(port, hxml, cwd, ['--no-output']);
			if (res == null) {
				sleep();
				continue;
			}
			final combined: String = oracleText(res.stdout) + oracleText(res.stderr);
			if (combined.indexOf('Could not connect') != -1) {
				sleep();
				continue;
			}
			return true;
		}
		return false;
	}

	function connectRun(extra: Array<String>): Null<String> {
		final res: Null<Dynamic> = connect(_port, _hxml, _cwd, extra);
		if (res == null) return null;
		return oracleText(res.stdout) + oracleText(res.stderr);
	}

	static function connect(port: Int, hxml: String, cwd: Null<String>, extra: Array<String>): Null<Dynamic> {
		try {
			final args: Array<String> = ['--connect', Std.string(port), hxml].concat(extra);
			final opts: Dynamic = { encoding: 'utf8' };
			if (cwd != null) Reflect.setField(opts, 'cwd', cwd);
			final res: Dynamic = js.node.ChildProcess.spawnSync('haxe', args, opts);
			final err: Null<Dynamic> = (res.error: Dynamic);
			return err != null ? null : res;
		} catch (e: haxe.Exception) {
			return null;
		}
	}

	static function sleep(): Void {
		// spawnSync reports a missing/failed `sleep` via its result, never a throw — a tighter poll is harmless.
		js.node.ChildProcess.spawnSync('sleep', ['0.3']);
	}

	static function oracleText(value: Dynamic): String {
		return value == null ? '' : Std.string(value);
	}

	/** `file` made relative to `cwd` (the compile-server client cwd) so the display path matches the module the compiler registered; unchanged when `cwd` is null or not a prefix. */
	static function relativeToCwd(file: String, cwd: Null<String>): String {
		if (cwd == null) return file;
		final prefix: String = StringTools.endsWith(cwd, '/') ? cwd : cwd + '/';
		return StringTools.startsWith(file, prefix) ? file.substring(prefix.length) : file;
	}

	/** Run one `@type` display query for `path`, or null when it yields no `<type>`. */
	function queryType(path: String, bytePos: Int): Null<String> {
		final out: Null<String> = connectRun(['--display', '$path@$bytePos@type']);
		return out == null ? null : parseTypeResponse(out);
	}

	/**
	 * Candidate display paths for `file` — the compiler matches the module by the path form its
	 * classpath used, which we cannot know, so we try each and cache the winner. For a relative
	 * `file`: the oracleDir-joined absolute, the process-cwd absolute (`absPath`, when oracleDir
	 * differs from the process cwd), the cwd-relative, and the raw path. Deduped, order = likeliest first.
	 */
	function pathForms(file: String): Array<String> {
		final out: Array<String> = [];
		if (haxe.io.Path.isAbsolute(file)) {
			addForm(out, file);
		} else {
			if (_cwd != null) addForm(out, joinCwd(_cwd, file));
			addForm(out, absPath(file));
		}
		addForm(out, relativeToCwd(file, _cwd));
		addForm(out, file);
		return out;
	}

	static function addForm(out: Array<String>, p: String): Void {
		if (!out.contains(p)) out.push(p);
	}

	/** `file` resolved against the process cwd (node-normalised, NOT symlink-followed), or `file` on failure. */
	static function absPath(file: String): String {
		return try sys.FileSystem.absolutePath(file) catch (e: haxe.Exception) file;
	}

	/** `cwd`/`file` joined (single slash), or `file` when `cwd` is null. */
	static function joinCwd(cwd: Null<String>, file: String): String {
		if (cwd == null) return file;
		final base: String = StringTools.endsWith(cwd, '/') ? cwd.substring(0, cwd.length - 1) : cwd;
		return '$base/$file';
	}
	#end

}
