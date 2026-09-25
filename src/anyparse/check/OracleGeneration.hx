package anyparse.check;

import anyparse.check.HaxeSpawn.HaxeRun;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.LintConfig.OracleGenerate;
import anyparse.check.OracleCache.HxmlRefs;
import anyparse.check.OracleGenerationLock.Holder;
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
 * must not write a common path. Each generation is guarded across processes by a reader/writer lock:
 * runs compiling a current tree share it and never wait for each other, and only a regeneration
 * takes it exclusively, after every other live reader is done (`holdShared`, `holdExclusive`).
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
	 * Each group is guarded by a reader/writer lock across `apq` processes, waiting at most `lockWaitMs` for it. This run
	 * takes a SHARED hold on every group it will compile — readers never wait for each other, so a current group never
	 * blocks — and swaps it for the EXCLUSIVE hold only to regenerate, which waits until no other live run holds the group
	 * shared (and makes new readers wait). Staleness is decided again under the exclusive hold, since another run may
	 * have regenerated meanwhile. The shared holds last until `release` or process exit. A hold that cannot be had makes
	 * that group's configurations unavailable.
	 *
	 * A stale group's record is deleted BEFORE its command runs, so a generation killed half way leaves nothing that
	 * reads as current. Its explicit inputs, and the implicit ones its previous record named, are hashed before the command
	 * too; an implicit input seen before AND after keeps its pre-run hash, and one that moved while the command ran leaves
	 * the generation unrecorded, so the next run regenerates.
	 */
	public static function prepare(oracles: Array<OracleConfig>, ?lockWaitMs: Int): PreparedOracles {
		final groups: Array<GenerationGroup> = groupsOf(oracles);
		final notes: Array<String> = [];
		if (groups.length == 0) return { oracles: oracles, notes: notes };
		final failures: Map<String, String> = [];
		final me: Holder = OracleGenerationLock.holder();
		final declaredWait: Null<Int> = Std.parseInt(Sys.getEnv('APQ_ORACLE_LOCK_WAIT') ?? '');
		final deadline: Float = Date.now().getTime() + (lockWaitMs ?? declaredWait ?? LOCK_WAIT);
		#if nodejs
		js.Node.process.once('exit', () -> releaseGroups(groups, me));
		#end
		inline function refuse(group: GenerationGroup, why: String): Void {
			failures[group.key] = why;
			notes.push('could NOT use ${group.hxmls.join(', ')}: $why');
		}
		final seen: Map<String, String> = [];
		final candidates: Array<GenerationGroup> = [];
		for (group in groups) {
			final blocked: Null<String> = OracleGenerationLock.holdShared(lockDir(group), me, deadline);
			if (blocked != null)
				refuse(group, blocked)
			else if (staleness(group, seen) != null)
				candidates.push(group);
		}
		final fresh: Map<String, String> = [];
		final stale: Array<StaleGroup> = [];
		for (group in candidates) {
			final lock: String = lockDir(group);
			OracleGenerationLock.dropShared(lock, me);
			final blocked: Null<String> = OracleGenerationLock.holdExclusive(lock, me, deadline);
			if (blocked != null) {
				refuse(group, blocked);
				continue;
			}
			final judged: Null<String> = staleness(group, fresh);
			if (judged == null) {
				// another run regenerated it while this one waited
				OracleGenerationLock.holdShared(lock, me, deadline);
				OracleGenerationLock.dropExclusive(lock, me);
				continue;
			}
			final why: String = judged;
			final previous: Null<GenerationRecord> = readRecord(recordFile(group));
			stale.push({
				group: group,
				why: why,
				inputs: hashAll(group.inputs ?? [], fresh),
				implicitBefore: hashAll([for (held in previous?.implicit ?? []) held.path], fresh)
			});
			deleteRecord(group);
		}
		final runs: Array<HaxeRun> = HaxeSpawn.runAll([
			for (s in stale)
				{
					args: [],
					cwd: s.group.generate.root,
					shell: s.group.generate.command,
					timeout: GENERATE_TIMEOUT
				}
		], BUFFER, HaxeSpawn.parallelism());
		final libraries: LibraryIndex = libraryIndex(groups);
		for (i => s in stale) {
			final lock: String = lockDir(s.group);
			final failure: Null<String> = failureOf(s.group, runs[i]);
			if (failure == null) {
				notes.push('regenerated ${s.group.hxmls.join(', ')} (${s.why})${record(s, libraries)}');
				OracleGenerationLock.holdShared(lock, me, deadline);
			} else {
				failures[s.group.key] = 'its generate command failed — $failure';
				notes.push('could NOT regenerate ${s.group.hxmls.join(', ')} (${s.why}): $failure');
			}
			OracleGenerationLock.dropExclusive(lock, me);
		}
		return { oracles: [for (oracle in oracles) ready(oracle, failures)], notes: notes };
	}

	/** Why `group`'s recorded generation is not current, or null when it is. */
	public static function staleness(group: GenerationGroup, memo: Map<String, String>): Null<String> {
		#if (sys || nodejs)
		for (hxml in group.hxmls) if (!sys.FileSystem.exists(hxml)) return '$hxml is missing';
		final inputs: Null<Array<String>> = group.inputs;
		if (inputs == null) return 'it declares no generateInputs, so it regenerates every run';
		final record: Null<GenerationRecord> = readRecord(recordFile(group));
		if (record == null) return 'no generation of it is recorded';
		if (record.command != group.generate.command) return 'its generate command changed';
		final recordedInputs: Array<FileHash> = record.inputs ?? [];
		for (input in inputs) if (hashIn(recordedInputs, input) != hashOf(input, memo)) return '$input changed';
		final recordedOutputs: Array<FileHash> = record.outputs ?? [];
		for (hxml in group.hxmls) if (hashIn(recordedOutputs, hxml) != hashOf(hxml, memo)) return '$hxml changed since it was generated';
		for (held in record.implicit ?? []) if (hashOf(held.path, memo) != held.hash) return '${held.path} changed';
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
	private static function writeRecord(
		group: GenerationGroup, inputs: Array<FileHash>, implicit: Array<FileHash>, memo: Map<String, String>
	): Void {
		#if (sys || nodejs)
		final record: GenerationRecord = {
			command: group.generate.command,
			inputs: inputs,
			outputs: hashAll(group.hxmls, memo),
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
	 * Answered from `memo` when it already holds `path`, and recorded there — one `prepare` step reads each file once,
	 * however many groups name it. Content only: a memo lives for one step and never stands in for a later read.
	 */
	private static function hashOf(path: String, memo: Map<String, String>): String {
		final held: Null<String> = memo[path];
		if (held != null) return held;
		final hash: String = if (!sys.FileSystem.exists(path))
			MISSING
		else if (sys.FileSystem.isDirectory(path)) {
			final lines: Array<String> = [];
			listTree(path, '', lines, 0, memo);
			lines.sort(Reflect.compare);
			md5('dir\n${lines.join('\n')}');
		} else {
			hashReads++;
			try
				md5Bytes(sys.io.File.getBytes(path))
			catch (exception: haxe.Exception)
				MISSING;
		};
		memo[path] = hash;
		return hash;
	}

	/** One `relative-path hash` line per file under `dir`, recursing at most `MAX_TREE_DEPTH` levels so a symlink loop ends. */
	private static function listTree(dir: String, relative: String, into: Array<String>, depth: Int, memo: Map<String, String>): Void {
		if (depth > MAX_TREE_DEPTH) return;
		final entries: Array<String> = try sys.FileSystem.readDirectory(dir) catch (exception: haxe.Exception) [];
		for (entry in entries) {
			final full: String = Path.join([dir, entry]);
			final rel: String = relative == '' ? entry : '$relative/$entry';
			if (sys.FileSystem.isDirectory(full))
				listTree(full, rel, into, depth + 1, memo);
			else
				into.push('$rel ${hashOf(full, memo)}');
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

	/** Recursion cap for a directory input and for the walk up to a library root. */
	private static inline final MAX_TREE_DEPTH: Int = 32;

	/** Cap on nested hxml includes `implicitInputs` follows. */
	private static inline final MAX_INCLUDE_DEPTH: Int = 8;

	/** The generation a declaration belongs to: its directory and its command. */
	private static inline function keyOf(generate: OracleGenerate): String {
		return '${generate.root}\n${generate.command}';
	}

	/** Every path of `paths` with its content hash, through `memo`. */
	private static function hashAll(paths: Array<String>, memo: Map<String, String>): Array<FileHash> {
		#if (sys || nodejs)
		return [for (path in paths) { path: path, hash: hashOf(path, memo) }];
		#else
		return [];
		#end
	}

	/**
	 * The files the hxmls `group` just generated depend on without the entry declaring them: every hxml they include,
	 * and for every classpath OUTSIDE the generation's directory the library that holds it — its `haxelib.json`,
	 * `include.xml` and `templates/haxe` (the code templates a build-tool library renders the generated sources from) at
	 * the nearest ancestor carrying a `haxelib.json`, and the haxelib repository's `.current` / `.dev` for it, as for
	 * every `-lib` the hxml names. A library switched to another version or dev path therefore makes the generation
	 * stale, without the project listing machine paths. The repository directory is found from the PATH (`libraries`),
	 * never from the name a `haxelib.json` declares, which need not match it. Generic over build tools: it reads only
	 * the hxml and the haxelib repository layout.
	 */
	public static function implicitInputs(group: GenerationGroup, libraries: LibraryIndex): Array<String> {
		final paths: Array<String> = [];
		#if (sys || nodejs)
		final root: String = absolute(Sys.getCwd(), group.generate.root);
		final names: Array<String> = [];
		for (i => hxml in group.hxmls) collectHxml(hxml, absolute(root, group.dirs[i]), root, paths, names, libraries, 0);
		final repo: Null<String> = libraries.repo;
		if (repo != null) for (name in names) {
			final lower: String = Path.join([repo, name.toLowerCase().replace('.', ',')]);
			final dir: String = sys.FileSystem.exists(lower) ? lower : Path.join([repo, name.replace('.', ',')]);
			for (marker in ['.current', '.dev']) addOnce(paths, Path.join([dir, marker]));
		}
		#end
		return paths;
	}

	#if (sys || nodejs)
	/** Fold one hxml's includes, library classpaths and `-lib` names into the accumulators — see `implicitInputs`. */
	private static function collectHxml(
		hxml: String, cwd: String, root: String, paths: Array<String>, names: Array<String>, libraries: LibraryIndex, depth: Int
	): Void {
		if (depth > MAX_INCLUDE_DEPTH) return;
		final text: Null<String> = try sys.io.File.getContent(hxml) catch (exception: haxe.Exception) null;
		if (text == null) return;
		final refs: HxmlRefs = OracleCache.hxmlRefs(text);
		for (include in refs.includes) {
			final path: String = absolute(cwd, include);
			if (!paths.contains(path)) {
				paths.push(path);
				collectHxml(path, cwd, root, paths, names, libraries, depth + 1);
			}
		}
		for (lib in refs.libs) if (!names.contains(lib)) names.push(lib);
		for (classPath in refs.classPaths) {
			final dir: String = absolute(cwd, classPath);
			if (dir == root || dir.startsWith('$root/')) continue;
			final library: Null<String> = libraryRoot(dir);
			if (library == null) continue;
			for (file in ['haxelib.json', 'include.xml', 'templates/haxe']) addOnce(paths, Path.join([library, file]));
			final installed: Null<String> = repositoryDir(libraries, library);
			if (installed != null) for (marker in ['.current', '.dev']) addOnce(paths, Path.join([installed, marker]));
		}
	}

	/**
	 * The haxelib repository directory `library` (a library root) is selected through: the directory directly under the
	 * repository for a versioned install, the one whose `.dev` points at it for a dev install, or — with no repository
	 * known — a parent carrying `.current`. Null when none applies.
	 */
	private static function repositoryDir(libraries: LibraryIndex, library: String): Null<String> {
		final repo: Null<String> = libraries.repo;
		if (repo != null && library.startsWith('$repo/')) return Path.join([repo, library.substr(repo.length + 1).split('/')[0]]);
		final dev: Null<String> = libraries.devs[library];
		if (repo != null && dev != null) return Path.join([repo, dev]);
		final parent: String = Path.directory(library);
		return sys.FileSystem.exists(Path.join([parent, '.current'])) ? parent : null;
	}

	/**
	 * The haxelib repository the generations in `groups` resolve libraries from (`haxelib config` in the first one's
	 * directory, which honours a local `.haxelib`) and every dev install in it, dev path to repository directory. Taken
	 * once per `prepare`.
	 */
	private static function libraryIndex(groups: Array<GenerationGroup>): LibraryIndex {
		final devs: Map<String, String> = [];
		final repo: Null<String> = groups.length == 0 ? null : haxelibRepository(absolute(Sys.getCwd(), groups[0].generate.root));
		if (repo != null) {
			final entries: Array<String> = try sys.FileSystem.readDirectory(repo) catch (exception: haxe.Exception) [];
			for (entry in entries) {
				final marker: String = Path.join([repo, entry, '.dev']);
				if (!sys.FileSystem.exists(marker)) continue;
				final target: Null<String> = try sys.io.File.getContent(marker).trim() catch (exception: haxe.Exception) null;
				if (target != null && target != '') devs[absolute(repo, target)] = entry;
			}
		}
		return { repo: repo, devs: devs };
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

	/** Files read (not answered from a memo) by `hashOf` in this process — tests read it to prove a file is read once per step. */
	public static var hashReads(default, null): Int = 0;

	/**
	 * Drop this process's holds on the generations `oracles` declare, once its compiles of them are done. Idempotent;
	 * process exit does the same for a caller that never gets here.
	 */
	public static function release(oracles: Array<OracleConfig>): Void {
		releaseGroups(groupsOf(oracles), OracleGenerationLock.holder());
	}

	/** Drop `me`'s shared and exclusive holds on every group of `groups`. */
	private static function releaseGroups(groups: Array<GenerationGroup>, me: Holder): Void {
		for (group in groups) {
			OracleGenerationLock.dropShared(lockDir(group), me);
			OracleGenerationLock.dropExclusive(lockDir(group), me);
		}
	}

	/**
	 * Record the successful generation `s`: an implicit input seen before the command keeps its pre-run hash, a new one
	 * gets its hash now, and a generation during which a previously-recorded implicit input MOVED is not recorded at all.
	 * Answers the clause the generation's note ends with — empty when it was recorded.
	 */
	private static function record(s: StaleGroup, libraries: LibraryIndex): String {
		final after: Map<String, String> = [];
		final moved: Null<FileHash> = s.implicitBefore.find(held -> hashOf(held.path, after) != held.hash);
		final implicit: Array<FileHash> = [
			for (path in implicitInputs(s.group, libraries)) { path: path, hash: hashIn(s.implicitBefore, path) ?? hashOf(path, after) }
		];
		if (moved == null) writeRecord(s.group, s.inputs, implicit, after);
		return moved == null ? '' : ' — NOT recorded: ${moved.path} changed while it ran, so the next run regenerates';
	}

}

/** `OracleGeneration.prepare`'s answer: the configurations ready to use, and a line per command that ran. */
typedef PreparedOracles = {
	var oracles: Array<OracleConfig>;
	var notes: Array<String>;
}

/** A stale generation about to run: its group, why, and its explicit and previously-recorded implicit inputs as hashed before the command. */
typedef StaleGroup = {
	var group: GenerationGroup;
	var why: String;
	var inputs: Array<FileHash>;
	var implicitBefore: Array<FileHash>;
}

/** The haxelib repository generations resolve libraries from, and each dev install in it as dev path to repository directory. */
typedef LibraryIndex = {
	var repo: Null<String>;
	var devs: Map<String, String>;
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
