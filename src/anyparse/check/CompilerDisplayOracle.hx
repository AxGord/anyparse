package anyparse.check;

import anyparse.check.Check.TypeOracle;
import haxe.io.Path;

using StringTools;

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

	private final _hxml: String;
	private final _cwd: Null<String>;
	private final _port: Int;

	#if nodejs
	private final _child: Dynamic;

	/** Source text per queried file, read once and kept for the rest of this oracle's life — `answerAt` needs it to turn a reply's line/column position back into a byte offset. */
	private final _sources: Map<String, String> = [];
	#end

	/** Cached winning display-path form index (see `pathForms`); -1 until the first successful query probes it. */
	private var _pathForm: Int = -1;

	#if nodejs
	private function new(hxml: String, cwd: Null<String>, port: Int, child: Dynamic) {
		_hxml = hxml;
		_cwd = cwd;
		_port = port;
		_child = child;
	}
	#else
	private function new(hxml: String, cwd: Null<String>, port: Int) {
		_hxml = hxml;
		_cwd = cwd;
		_port = port;
	}
	#end

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
			final cached: Null<String> = queryReply(forms[_pathForm], bytePos);
			if (cached != null) return answerAt(cached, file, bytePos);
		}
		for (i in 0...forms.length) {
			final out: Null<String> = queryReply(forms[i], bytePos);
			if (out == null) continue;
			_pathForm = i;
			return answerAt(out, file, bytePos);
		}
		return null;
		#else
		return null;
		#end
	}

	/** Reap the background server. Idempotent and exception-safe. */
	public function stop(): Void {
		#if nodejs
		CompilerServer.killChild(_child);
		#end
	}

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
			final child: Dynamic = CompilerServer.spawnServer(port, false);
			if (child == null) continue;
			if (CompilerServer.warm(port, hxml, cwd)) return new CompilerDisplayOracle(hxml, cwd, port, child);
			CompilerServer.killChild(child);
		}
		return null;
		#else
		return null;
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
		final body: String = raw.substring(gt + 1, close).htmlUnescape();
		final trimmed: String = body.trim();
		return trimmed == '' ? null : trimmed;
	}

	/**
	 * The `p="<file>:<line>: …"` attribute of a display `<type>` reply — WHICH expression the
	 * compiler answered about — or null when the reply carries none or spells it in a form this
	 * does not know. The two spellings Haxe emits are `characters <a>-<b>` (1-based columns on
	 * one line) and `lines <a>-<b>` (a whole-line range, when the expression spans several).
	 * PURE: no process, no file, unit-testable.
	 *
	 * `p` is read as the FIRST `p="` inside the opening tag, which is where Haxe writes it — the
	 * documentation attribute `d` follows it, and attribute values are entity-escaped, so neither
	 * a `>` nor a stray `p="` from the doc text can be reached before it.
	 */
	public static function parseTypePosition(raw: String): Null<TypeReplyPosition> {
		final open: Int = raw.indexOf('<type');
		if (open < 0) return null;
		final gt: Int = raw.indexOf('>', open);
		if (gt < 0) return null;
		final head: String = raw.substring(open, gt);
		final pAt: Int = head.indexOf('p="');
		if (pAt < 0) return null;
		final endQuote: Int = head.indexOf('"', pAt + 3);
		if (endQuote < 0) return null;
		final payload: String = head.substring(pAt + 3, endQuote).htmlUnescape();
		final byLine: Bool = payload.lastIndexOf(': lines ') > payload.lastIndexOf(': characters ');
		final marker: String = byLine ? ': lines ' : ': characters ';
		final at: Int = payload.lastIndexOf(marker);
		if (at < 0) return null;
		final colon: Int = payload.lastIndexOf(':', at - 1);
		if (colon < 0) return null;
		final line: Null<Int> = Std.parseInt(payload.substring(colon + 1, at));
		final dash: Int = payload.indexOf('-', at + marker.length);
		if (line == null || dash < 0) return null;
		final first: Null<Int> = Std.parseInt(payload.substring(at + marker.length, dash));
		final last: Null<Int> = Std.parseInt(payload.substring(dash + 1));
		if (first == null || last == null) return null;
		return {
			file: payload.substring(0, colon),
			line: line,
			first: first,
			last: last,
			byLine: byLine
		};
	}

	/**
	 * Whether the region `pos` names in `source` COVERS `bytePos` — the query offset the reply
	 * is supposed to answer for. A `@type` request whose offset the compiler cannot map to an
	 * expression is not refused: it is answered for a DIFFERENT, usually enclosing, expression,
	 * and the reply is indistinguishable from a good one until its own position is read.
	 * (Measured: `install/src/NpmInstall.hx@1305@type`, the `a` of a local inside a map
	 * comprehension's body, replies `p="…:43: lines 43-44"` — the enclosing comprehension two
	 * lines up — with `haxe.ds.Map<haxe.ds.Map.K, haxe.ds.Map.V>`, type parameters and all.)
	 *
	 * The end is INCLUSIVE: `pmax` bounds the expression, and one byte of slack costs at most an
	 * answer about a construct ending exactly at the cursor, while a strict end would abstain on
	 * any off-by-one this spelling picks up across compiler versions. Out-of-range line numbers
	 * yield true — nothing about them refutes the reply. PURE: no process, unit-testable.
	 */
	public static function replyCovers(source: String, pos: TypeReplyPosition, bytePos: Int): Bool {
		final starts: Array<Int> = lineStarts(source);
		final head: Int = (pos.byLine ? pos.first : pos.line) - 1;
		if (head < 0 || head >= starts.length) return true;
		final from: Int = pos.byLine ? starts[head] : starts[head] + pos.first - 1;
		final to: Int = pos.byLine ? (pos.last < starts.length ? starts[pos.last] : source.length) : starts[head] + pos.last - 1;
		return bytePos >= from && bytePos <= to;
	}

	/** Byte offset of each line start in `source`, index 0 being line 1. */
	public static function lineStarts(source: String): Array<Int> {
		final out: Array<Int> = [0];
		final n: Int = source.length;
		for (i in 0...n) if (source.fastCodeAt(i) == '\n'.code) out.push(i + 1);
		return out;
	}

	#if nodejs
	private inline function connectRun(extra: Array<String>): Null<String> {
		return CompilerServer.connect(_port, _hxml, _cwd, extra)?.output;
	}

	/**
	 * The raw display reply for `path` when it carries a `<type>` element, else null. The
	 * path-form probe in `typeAt` reads only THAT — a reply the position check goes on to
	 * reject still proves the form resolves, so the winning form is cached once either way.
	 */
	private function queryReply(path: String, bytePos: Int): Null<String> {
		final out: Null<String> = connectRun(['--display', '$path@$bytePos@type']);
		return out != null && parseTypeResponse(out) != null ? out : null;
	}

	/** The reply's type text when the reply DESCRIBES `bytePos` (`replyCovers`), else null. */
	private function answerAt(raw: String, file: String, bytePos: Int): Null<String> {
		final pos: Null<TypeReplyPosition> = parseTypePosition(raw);
		if (pos == null) return parseTypeResponse(raw);
		if (Path.withoutDirectory(pos.file) != Path.withoutDirectory(file)) return null;
		final src: Null<String> = sourceOf(file);
		// Unreadable source cannot refute the reply, and refusing on that would turn every
		// query on a file the linter holds only in memory into an abstention.
		if (src == null) return parseTypeResponse(raw);
		return replyCovers(src, pos, bytePos) ? parseTypeResponse(raw) : null;
	}

	/** `file`'s bytes as the compiler read them, cached per file; null when it cannot be read through any of its `pathForms`. */
	private function sourceOf(file: String): Null<String> {
		final cached: Null<String> = _sources[file];
		if (cached != null) return cached;
		for (form in pathForms(file)) {
			final text: Null<String> = try sys.io.File.getContent(form) catch (e: haxe.Exception) null;
			if (text == null) continue;
			_sources[file] = text;
			return text;
		}
		return null;
	}

	/**
	 * Candidate display paths for `file` — the compiler matches the module by the path form its
	 * classpath used, which we cannot know, so we try each and cache the winner. For a relative
	 * `file`: the oracleDir-joined absolute, the process-cwd absolute (`absPath`, when oracleDir
	 * differs from the process cwd), the cwd-relative, and the raw path. Deduped, order = likeliest first.
	 */
	private function pathForms(file: String): Array<String> {
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

	/** `file` made relative to `cwd` (the compile-server client cwd) so the display path matches the module the compiler registered; unchanged when `cwd` is null or not a prefix. */
	private static function relativeToCwd(file: String, cwd: Null<String>): String {
		if (cwd == null) return file;
		final prefix: String = StringTools.endsWith(cwd, '/') ? cwd : '$cwd/';
		return file.startsWith(prefix) ? file.substring(prefix.length) : file;
	}

	private static function addForm(out: Array<String>, p: String): Void {
		if (!out.contains(p)) out.push(p);
	}

	/** `file` resolved against the process cwd (node-normalised, NOT symlink-followed), or `file` on failure. */
	private static function absPath(file: String): String {
		return try sys.FileSystem.absolutePath(file) catch (e: haxe.Exception) file;
	}

	/** `cwd`/`file` joined (single slash), or `file` when `cwd` is null. */
	private static function joinCwd(cwd: Null<String>, file: String): String {
		if (cwd == null) return file;
		final base: String = StringTools.endsWith(cwd, '/') ? cwd.substring(0, cwd.length - 1) : cwd;
		return '$base/$file';
	}
	#end

}

/**
 * The `p="…"` position of a display `<type>` reply — the region the compiler says its answer
 * describes, in the compiler's own 1-based line / column coordinates. `byLine` marks the
 * multi-line spelling (`lines A-B`), whose bounds are whole LINES (`first`..`last`); otherwise
 * `first`/`last` are the column bounds of `characters A-B` on `line`.
 */
typedef TypeReplyPosition = {
	file: String,
	line: Int,
	first: Int,
	last: Int,
	byLine: Bool
};
