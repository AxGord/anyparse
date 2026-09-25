package anyparse.check;

import anyparse.check.HaxeSpawn.HaxeRun;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.LintConfig.OracleGenerate;
import anyparse.check.OracleCache.HxmlRefs;
import anyparse.core.TempScratch;
import haxe.io.Path;

using Lambda;
using StringTools;

/**
 * The `compilerOracle` entries that say how to OBTAIN their hxml: each one's `generate` command is run to (re)create
 * the hxml before the configuration is used, so a project whose build tool writes the hxml (lime, a code generator)
 * declares the whole recipe in `apqlint.json` instead of a script every caller has to remember to run first.
 *
 * ## When a command runs
 *
 * Staleness is decided by CONTENT, never by a modification time (`OracleCache` records why). A generation is current
 * only while all of these hold:
 *
 *  - every hxml the command produces exists and hashes as it did right after the last generation;
 *  - the command string is the one that generation ran;
 *  - every `generateInputs` path hashes as it did BEFORE that generation started (a directory as its whole tree, a
 *    missing path as missing);
 *  - every implicit input (`implicitInputs`: included hxmls and the library state the hxml resolves to) hashes as it
 *    did right after it.
 *
 * An entry with no inputs cannot be shown current by anything, so its command runs once per `prepare` call — once per
 * `apq` run. The record lives beside the oracle verdict records (`TempScratch.root`), is deleted before a stale command
 * starts and written only after it succeeded, so a generation killed half way is never read as current.
 *
 * ## Failure and concurrency
 *
 * A command that fails, times out, or leaves an hxml missing makes every configuration it serves UNAVAILABLE with its
 * output quoted; a stale hxml is never used in its place. Entries naming one command in one directory are ONE
 * generation over the union of their inputs; distinct commands run concurrently (`HaxeSpawn.runAll`), so two of them
 * must not write a common path. Each generation is serialised across processes by a lock (`acquire`) held until this
 * process exits, so another run cannot regenerate a tree this one is still compiling.
 */
@:nullSafety(Strict)
final class OracleGeneration {

	/** Output buffer for one generate command, in bytes. */
	private static inline final BUFFER: Int = 64 * 1024 * 1024;

	/** How much of a failed command's output an unavailability reason quotes, from its END (where the error is). */
	private static inline final QUOTED_TAIL: Int = 4000;

	/** The scheme tag in every record: bump it and every recorded generation is stale. */
	private static inline final FORMAT_TAG: String = 'apq-oracle-generate v1';

	/** What a missing file hashes as, so its appearance or disappearance is a change like any other. */
	private static inline final MISSING: String = 'missing';

	/**
	 * `oracles` made ready to use: every `generate` entry whose recorded generation is not current has its command run
	 * (the stale ones concurrently), a probed compile directory is probed again against the fresh hxml, and a failed
	 * generation marks its configurations `unavailable`. Entries without `generate` pass through untouched, in place.
	 * `notes` names each command that ran and why, for the caller to print.
	 *
	 * Every group's lock is taken first (`acquire`, waiting at most `lockWaitMs`) and held until this process exits, so
	 * no other `apq` run regenerates a tree this run is still compiling; a lock that cannot be had makes that group's
	 * configurations unavailable. A stale group's record is deleted BEFORE its command runs — a generation killed half
	 * way leaves no record, so the next run regenerates instead of trusting a partial tree — and its explicit inputs are
	 * hashed BEFORE it runs too, so an edit landing during the generation reads as a change next time.
	 */
	public static function prepare(oracles: Array<OracleConfig>, ?lockWaitMs: Int): PreparedOracles {
		final groups: Array<GenerationGroup> = groupsOf(oracles);
		final notes: Array<String> = [];
		if (groups.length == 0) return { oracles: oracles, notes: notes };
		final failures: Map<String, String> = [];
		final stale: Array<{ group: GenerationGroup, why: String, inputs: Array<FileHash> }> = [];
		for (group in groups) {
			final blocked: Null<String> = acquire(group, lockWaitMs ?? LOCK_WAIT);
			if (blocked != null) {
				failures[group.key] = blocked;
				notes.push('could NOT use ${group.hxmls.join(', ')}: $blocked');
				continue;
			}
			final why: Null<String> = staleness(group);
			if (why == null) continue;
			stale.push({ group: group, why: why, inputs: hashAll(group.inputs ?? []) });
			deleteRecord(group);
		}
		#if nodejs
		// one listener per run releases every lock this process holds; `release` leaves another owner's alone
		final me: Int = js.Node.process.pid;
		js.Node.process.once('exit', () -> for (group in groups) release(lockDir(group), me));
		#end
		final runs: Array<HaxeRun> = HaxeSpawn.runAll([
			for (s in stale)
				{
					args: [],
					cwd: s.group.generate.root,
					shell: s.group.generate.command,
					timeout: GENERATE_TIMEOUT
				}
		], BUFFER, HaxeSpawn.parallelism());
		for (i => s in stale) {
			final failure: Null<String> = failureOf(s.group, runs[i]);
			if (failure == null) {
				writeRecord(s.group, s.inputs, hashAll(implicitInputs(s.group)));
				notes.push('regenerated ${s.group.hxmls.join(', ')} (${s.why})');
			} else {
				failures[s.group.key] = 'its generate command failed — $failure';
				notes.push('could NOT regenerate ${s.group.hxmls.join(', ')} (${s.why}): $failure');
			}
		}
		return { oracles: [for (oracle in oracles) ready(oracle, failures)], notes: notes };
	}

	/** Why `group`'s recorded generation is not current, or null when it is. */
	public static function staleness(group: GenerationGroup): Null<String> {
		#if (sys || nodejs)
		for (hxml in group.hxmls) if (!sys.FileSystem.exists(hxml)) return '$hxml is missing';
		final inputs: Null<Array<String>> = group.inputs;
		if (inputs == null) return 'it declares no generateInputs, so it regenerates every run';
		final record: Null<GenerationRecord> = readRecord(recordFile(group));
		if (record == null) return 'no generation of it is recorded';
		if (record.command != group.generate.command) return 'its generate command changed';
		final recordedInputs: Array<FileHash> = record.inputs ?? [];
		for (input in inputs) if (hashIn(recordedInputs, input) != hashOf(input)) return '$input changed';
		final recordedOutputs: Array<FileHash> = record.outputs ?? [];
		for (hxml in group.hxmls) if (hashIn(recordedOutputs, hxml) != hashOf(hxml)) return '$hxml changed since it was generated';
		for (held in record.implicit ?? []) if (hashOf(held.path) != held.hash) return '${held.path} changed';
		return null;
		#else
		return 'no filesystem on this target';
		#end
	}

	/**
	 * The generations `oracles` declare, one per distinct (directory, command), each listing every hxml it serves with
	 * the directory that hxml compiles from, and the UNION of the inputs its entries declare — or null when any of them
	 * declares none, since that entry asked to regenerate every run.
	 */
	public static function groupsOf(oracles: Array<OracleConfig>): Array<GenerationGroup> {
		final groups: Array<GenerationGroup> = [];
		for (oracle in oracles) {
			final declared: Null<OracleGenerate> = oracle.generate;
			if (declared == null) continue;
			// re-bound: strict null-safety does not carry a narrowed local into a structure literal
			final generate: OracleGenerate = declared;
			final key: String = keyOf(generate);
			final held: Null<GenerationGroup> = groups.find(g -> g.key == key);
			if (held == null) {
				groups.push({
					key: key,
					generate: generate,
					hxmls: [oracle.hxml],
					dirs: [oracle.dir ?? generate.root],
					inputs: generate.inputs?.copy()
				});
				continue;
			}
			if (!held.hxmls.contains(oracle.hxml)) {
				held.hxmls.push(oracle.hxml);
				held.dirs.push(oracle.dir ?? generate.root);
			}
			final mine: Null<Array<String>> = generate.inputs;
			final theirs: Null<Array<String>> = held.inputs;
			held.inputs = mine == null || theirs == null ? null : theirs.concat([for (input in mine) if (!theirs.contains(input)) input]);
		}
		return groups;
	}

	/** Where `group`'s generation record lives: one file per (directory, hxml set) under the oracle scratch root. */
	public static function recordFile(group: GenerationGroup): String {
		#if (sys || nodejs)
		final hxmls: Array<String> = group.hxmls.copy();
		hxmls.sort(Reflect.compare);
		final key: String = '$FORMAT_TAG\n${group.generate.root}\n${hxmls.join('\n')}';
		return Path.join([TempScratch.root(), 'apq-oracle-generate-${md5(key)}.json']);
		#else
		return '';
		#end
	}

	/** `oracle` as it may be used after this run's generations: unavailable, re-probed, or untouched. */
	private static function ready(oracle: OracleConfig, failures: Map<String, String>): OracleConfig {
		final generate: Null<OracleGenerate> = oracle.generate;
		if (generate == null) return oracle;
		final failure: Null<String> = failures[keyOf(generate)];
		final dir: Null<String> = generate.probeDir && failure == null
			? OracleDeclaration.compileDir(oracle.hxml, generate.root)
			: oracle.dir;
		final out: OracleConfig = {
			hxml: oracle.hxml,
			dir: dir,
			defines: oracle.defines,
			generate: generate
		};
		if (failure != null) out.unavailable = failure;
		return out;
	}

	/** Why `run` of `group`'s command is not a usable generation, or null when it is. */
	private static function failureOf(group: GenerationGroup, run: HaxeRun): Null<String> {
		final output: String = quoted(('${run.out}\n${run.err}').trim());
		if (run.failure != '') return '${run.failure}$output';
		if (run.status != 0) return '`${group.generate.command}` exited ${run.status}$output';
		#if (sys || nodejs)
		for (hxml in group.hxmls) if (!sys.FileSystem.exists(hxml))
			return '`${group.generate.command}` succeeded but wrote no $hxml$output';
		#end
		return null;
	}

	/** `output` as the tail of a reason: empty for none, else its last `QUOTED_TAIL` characters after a colon. */
	private static function quoted(output: String): String {
		return output == '' ? '' : ':\n' + (output.length > QUOTED_TAIL ? '...${output.substr(output.length - QUOTED_TAIL)}' : output);
	}

	/** The hash `hashes` records for `path`, or null when it records none. */
	private static function hashIn(hashes: Array<FileHash>, path: String): Null<String> {
		final held: Null<FileHash> = hashes.find(h -> h.path == path);
		return held?.hash;
	}

	/**
	 * Record `group`'s generation as current: its command, its explicit inputs as hashed BEFORE the command ran, every
	 * hxml as the command left it, and the `implicit` inputs read off those hxmls.
	 */
	private static function writeRecord(group: GenerationGroup, inputs: Array<FileHash>, implicit: Array<FileHash>): Void {
		#if (sys || nodejs)
		final record: GenerationRecord = {
			command: group.generate.command,
			inputs: inputs,
			outputs: hashAll(group.hxmls),
			implicit: implicit
		};
		try sys.io.File.saveContent(recordFile(group), haxe.Json.stringify(record)) catch (exception: haxe.Exception) {
			// an unwritable record costs the next run a regeneration, never a wrong answer
		}
		#end
	}

	/** Forget `group`'s generation, so a failed one is retried rather than read as current. */
	private static function deleteRecord(group: GenerationGroup): Void {
		#if (sys || nodejs)
		final path: String = recordFile(group);
		try if (sys.FileSystem.exists(path)) sys.FileSystem.deleteFile(path) catch (exception: haxe.Exception) {
			// a record that cannot be deleted still names a missing or changed hxml, which is stale
		}
		#end
	}

	/** md5 of `text`. */
	private static function md5(text: String): String {
		return #if nodejs js.node.Crypto.createHash('md5').update(text, 'utf8').digest('hex') #else haxe.crypto.Md5.encode(text) #end;
	}

	#if (sys || nodejs)
	/** The record at `path`, or null when there is none or it is not JSON. */
	private static function readRecord(path: String): Null<GenerationRecord> {
		if (!sys.FileSystem.exists(path)) return null;
		return try haxe.Json.parse(sys.io.File.getContent(path)) catch (exception: haxe.Exception) null;
	}

	/**
	 * The content hash of `path`: a file's bytes; a directory's recursive listing with every file's own hash, so an
	 * added, removed, renamed or edited file under it is a change; `MISSING` when it does not exist or cannot be read.
	 */
	private static function hashOf(path: String): String {
		if (!sys.FileSystem.exists(path)) return MISSING;
		if (!sys.FileSystem.isDirectory(path)) return try md5Bytes(sys.io.File.getBytes(path)) catch (exception: haxe.Exception) MISSING;
		final lines: Array<String> = [];
		listTree(path, '', lines, 0);
		lines.sort(Reflect.compare);
		return md5('dir\n${lines.join('\n')}');
	}

	/** One `relative-path hash` line per file under `dir`, recursing at most `MAX_TREE_DEPTH` levels so a symlink loop ends. */
	private static function listTree(dir: String, relative: String, into: Array<String>, depth: Int): Void {
		if (depth > MAX_TREE_DEPTH) return;
		final entries: Array<String> = try sys.FileSystem.readDirectory(dir) catch (exception: haxe.Exception) [];
		for (entry in entries) {
			final full: String = Path.join([dir, entry]);
			final rel: String = relative == '' ? entry : '$relative/$entry';
			if (sys.FileSystem.isDirectory(full))
				listTree(full, rel, into, depth + 1);
			else
				into.push('$rel ${hashOf(full)}');
		}
	}

	/** md5 of `bytes` — through node's native digest there, since an input may be a multi-megabyte binary asset. */
	private static function md5Bytes(bytes: haxe.io.Bytes): String {
		return #if nodejs js.node.Crypto.createHash('md5')
			.update(js.node.Buffer.hxFromBytes(bytes))
			.digest('hex') #else haxe.crypto.Md5.make(bytes).toHex() #end;
	}
	#end

	/** How long `prepare` waits for another run's generation lock by default, in ms. */
	private static inline final LOCK_WAIT: Int = 10 * 60 * 1000;

	/** How long one generate command may run before its whole process group is killed, in ms. */
	private static inline final GENERATE_TIMEOUT: Int = 30 * 60 * 1000;

	/** A lock older than this is taken over even when its pid is alive — a pid the system reused for something else. */
	private static inline final MAX_LOCK_AGE: Float = 6 * 60 * 60 * 1000;

	/** How long a lock directory may exist without its owner file before it counts as abandoned, in ms. */
	private static inline final OWNERLESS_GRACE: Float = 10 * 1000;

	/** How often a waiting `acquire` looks again, in ms. */
	private static inline final LOCK_POLL: Int = 250;

	/** Recursion cap for a directory input and for the walk up to a library root. */
	private static inline final MAX_TREE_DEPTH: Int = 32;

	/** Cap on nested hxml includes `implicitInputs` follows. */
	private static inline final MAX_INCLUDE_DEPTH: Int = 8;

	/** The generation a declaration belongs to: its directory and its command. */
	private static inline function keyOf(generate: OracleGenerate): String {
		return '${generate.root}\n${generate.command}';
	}

	/** Every path of `paths` with its content hash now. */
	private static function hashAll(paths: Array<String>): Array<FileHash> {
		#if (sys || nodejs)
		return [for (path in paths) { path: path, hash: hashOf(path) }];
		#else
		return [];
		#end
	}

	/**
	 * The files the hxmls `group` just generated depend on without the entry declaring them: every hxml they include,
	 * and for every classpath OUTSIDE the generation's directory the library that holds it — its `haxelib.json` and
	 * `include.xml` at the nearest ancestor carrying a `haxelib.json`, and the haxelib repository's `.current` / `.dev`
	 * for it (the version or dev path that library resolves to), as for every `-lib` the hxml names. A library switched to
	 * another version or dev path therefore makes the generation stale, without the project listing machine paths.
	 * Generic over build tools: it reads only the hxml.
	 */
	public static function implicitInputs(group: GenerationGroup): Array<String> {
		final paths: Array<String> = [];
		#if (sys || nodejs)
		final root: String = absolute(Sys.getCwd(), group.generate.root);
		final names: Array<String> = [];
		final repo: Null<String> = haxelibRepository(root);
		for (i => hxml in group.hxmls) collectHxml(hxml, absolute(root, group.dirs[i]), root, paths, names, 0);
		for (name in names)
			if (repo != null)
				for (marker in ['.current', '.dev']) addOnce(paths, Path.join([repo, name.replace('.', ','), marker]));
		#end
		return paths;
	}

	#if (sys || nodejs)
	/** Fold one hxml's includes, library classpaths and `-lib` names into the accumulators — see `implicitInputs`. */
	private static function collectHxml(
		hxml: String, cwd: String, root: String, paths: Array<String>, names: Array<String>, depth: Int
	): Void {
		if (depth > MAX_INCLUDE_DEPTH) return;
		final text: Null<String> = try sys.io.File.getContent(hxml) catch (exception: haxe.Exception) null;
		if (text == null) return;
		final refs: HxmlRefs = OracleCache.hxmlRefs(text);
		for (include in refs.includes) {
			final path: String = absolute(cwd, include);
			if (!paths.contains(path)) {
				paths.push(path);
				collectHxml(path, cwd, root, paths, names, depth + 1);
			}
		}
		for (lib in refs.libs) if (!names.contains(lib)) names.push(lib);
		for (classPath in refs.classPaths) {
			final dir: String = absolute(cwd, classPath);
			if (dir == root || dir.startsWith('$root/')) continue;
			final library: Null<String> = libraryRoot(dir);
			if (library == null) continue;
			addOnce(paths, Path.join([library, 'haxelib.json']));
			addOnce(paths, Path.join([library, 'include.xml']));
			final name: Null<String> = libraryName(Path.join([library, 'haxelib.json']));
			if (name != null && !names.contains(name)) names.push(name);
			// a versioned install sits in `<repo>/<lib>/<version>`, whose parent carries the selection itself
			final parent: String = Path.directory(library);
			if (sys.FileSystem.exists(Path.join([parent, '.current']))) {
				addOnce(paths, Path.join([parent, '.current']));
				addOnce(paths, Path.join([parent, '.dev']));
			}
		}
	}

	/** The nearest ancestor of `dir` (itself included) holding a `haxelib.json`, or null within `MAX_TREE_DEPTH` levels. */
	private static function libraryRoot(dir: String): Null<String> {
		var current: String = dir;
		for (_ in 0...MAX_TREE_DEPTH) {
			if (sys.FileSystem.exists(Path.join([current, 'haxelib.json']))) return current;
			final parent: String = Path.directory(current);
			if (parent == '' || parent == current) return null;
			current = parent;
		}
		return null;
	}

	/** The `name` a `haxelib.json` declares, or null when it cannot be read. */
	private static function libraryName(path: String): Null<String> {
		final text: Null<String> = try sys.io.File.getContent(path) catch (exception: haxe.Exception) null;
		if (text == null) return null;
		final parsed: Null<{ ?name: String }> = try haxe.Json.parse(text) catch (exception: haxe.Exception) null;
		return parsed?.name;
	}

	/** The haxelib repository `root` resolves libraries from (`haxelib config`, which honours a local `.haxelib`), or null. */
	private static function haxelibRepository(root: String): Null<String> {
		final runs: Array<HaxeRun> = HaxeSpawn.runAll([{ args: [], cwd: root, shell: 'haxelib config' }], BUFFER, 1);
		if (runs.length == 0 || runs[0].status != 0) return null;
		final repo: String = runs[0].out.trim();
		return repo == '' ? null : Path.removeTrailingSlashes(repo);
	}

	/** `path` resolved against `base` when relative, normalised, without a trailing slash. */
	private static function absolute(base: String, path: String): String {
		return Path.removeTrailingSlashes(Path.normalize(Path.isAbsolute(path) ? path : Path.join([base, path])));
	}

	private static inline function addOnce(paths: Array<String>, path: String): Void {
		if (!paths.contains(path)) paths.push(path);
	}
	#end

	/** The directory that holds `group`'s generation lock, beside its record. */
	public static function lockDir(group: GenerationGroup): String {
		return '${recordFile(group)}.lock';
	}

	/**
	 * Take `group`'s lock for this process, waiting at most `waitMs` for another `apq` run holding it; null when held,
	 * else why not. A lock whose owner pid is gone, whose owner file never appeared, or that is older than
	 * `MAX_LOCK_AGE` is taken over. The caller releases it when this process exits
	 * (`prepare` registers that once per run). Re-entrant within one process.
	 */
	public static function acquire(group: GenerationGroup, waitMs: Int): Null<String> {
		#if nodejs
		final dir: String = lockDir(group);
		final owner: String = Path.join([dir, 'owner']);
		final me: Int = js.Node.process.pid;
		final deadline: Float = Date.now().getTime() + waitMs;
		while (true) {
			final created: Bool = try {
				js.node.Fs.mkdirSync(dir);
				true;
			} catch (exception: haxe.Exception) false;
			if (created) {
				sys.io.File.saveContent(owner, '$me ${Date.now().getTime()}');
				return null;
			}
			final held: Null<String> = try sys.io.File.getContent(owner) catch (exception: haxe.Exception) null;
			final fields: Array<String> = (held ?? '').trim().split(' ');
			final pid: Null<Int> = Std.parseInt(fields[0]);
			final since: Float = held == null ? modified(dir) : Std.parseFloat(fields[1] ?? '0');
			final now: Float = Date.now().getTime();
			if (pid == me) return null;
			final abandoned: Bool = held == null ? now - since > OWNERLESS_GRACE : pid == null || !alive(pid) || now - since > MAX_LOCK_AGE;
			if (abandoned) {
				release(dir, pid);
				continue;
			}
			if (now > deadline) return 'another apq run (pid $pid) holds its generation lock $dir';
			js.Syntax.code('Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, {0})', LOCK_POLL);
		}
		#else
		return null;
		#end
	}

	#if nodejs
	/** Remove the lock `dir` when `pid` (null: any) still owns it. */
	private static function release(dir: String, pid: Null<Int>): Void {
		final owner: String = Path.join([dir, 'owner']);
		try {
			final held: Null<Int> = sys.FileSystem.exists(owner) ? Std.parseInt(sys.io.File.getContent(owner).trim().split(' ')[0]) : null;
			if (pid != null && held != null && held != pid) return;
			if (sys.FileSystem.exists(owner)) sys.FileSystem.deleteFile(owner);
			sys.FileSystem.deleteDirectory(dir);
		} catch (exception: haxe.Exception) { // noqa: swallowed-exception
			// a lock that cannot be removed is taken over once its owner is gone
		}
	}

	/** Whether process `pid` exists (a signal-0 probe; EPERM means it exists under another user). */
	private static function alive(pid: Int): Bool {
		return try {
			js.Syntax.code('process.kill({0}, 0)', pid);
			true;
		} catch (exception: haxe.Exception) '${Reflect.field(exception.native, 'code')}' == 'EPERM';
	}

	/** `path`'s modification time in ms, or now when it cannot be read. */
	private static function modified(path: String): Float {
		return try sys.FileSystem.stat(path).mtime.getTime() catch (exception: haxe.Exception) Date.now().getTime();
	}
	#end

}

/** `OracleGeneration.prepare`'s answer: the configurations ready to use, and a line per command that ran. */
typedef PreparedOracles = {
	var oracles: Array<OracleConfig>;
	var notes: Array<String>;
}

/**
 * One generation `prepare` may run: the key it is shared by, its declaration, every hxml it serves with the directory
 * that hxml compiles from (`dirs`, paired by position), and the inputs its staleness is decided by (null: none, so it
 * regenerates every run).
 */
typedef GenerationGroup = {
	var key: String;
	var generate: OracleGenerate;
	var hxmls: Array<String>;
	var dirs: Array<String>;
	var inputs: Null<Array<String>>;
}

/** One file's content hash in a generation record. */
typedef FileHash = {
	var path: String;
	var hash: String;
}

/**
 * The persisted record of a successful generation. Every field is optional because it comes off disk through
 * `haxe.Json.parse`, which will produce a structure missing any of them.
 */
typedef GenerationRecord = {
	var ?command: String;
	var ?inputs: Array<FileHash>;
	var ?outputs: Array<FileHash>;

	/** The files the generated hxml depends on without declaring them — see `implicitInputs`. */
	var ?implicit: Array<FileHash>;
}
