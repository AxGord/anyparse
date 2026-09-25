package anyparse.check;

import anyparse.check.HaxeSpawn.HaxeRun;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.LintConfig.OracleGenerate;
import anyparse.check.OracleCache.HxmlRefs;
import anyparse.check.OracleGenerationLock.Holder;
import anyparse.query.ConfigFinder;
import haxe.Exception;
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
 * `apq` run. The record lives in the project, at the root of the tree it guards (`stateDir`), is deleted before a stale command
 * starts and written only after it succeeded, so a generation killed half way is never read as current.
 *
 * ## Failure and concurrency
 *
 * A command that fails, times out, or leaves an hxml missing makes every configuration it serves UNAVAILABLE with its output
 * quoted; a stale hxml is never used in its place. So does a root where the generation state cannot be created (a read-only
 * checkout): without a record and a lock nothing proves an hxml current. Entries naming one command in one directory are ONE
 * generation over the union of their inputs; distinct commands run concurrently (`HaxeSpawn.runAll`), so two of them must not
 * write a common path (an hxml two commands claim is dropped when the config is read, `OracleDeclaration`). Each generation
 * is guarded across processes by a reader/writer lock: runs compiling a current tree share it and never wait for each other,
 * and only a regeneration takes it exclusively, after every other live reader is done (`holdShared`, `holdExclusive`).
 */
@:nullSafety(Strict)
final class OracleGeneration {

	/** Output buffer for one generate command, in bytes. */
	private static inline final BUFFER: Int = 64 * 1024 * 1024;

	/** How much of a failed command's output an unavailability reason quotes, from its END (where the error is). */
	private static inline final QUOTED_TAIL: Int = 4000;

	/** The scheme tag in every record: bump it and every recorded generation is stale. */
	private static inline final FORMAT_TAG: String = 'apq-oracle-generate v2';

	/** What a missing file hashes as, so its appearance or disappearance is a change like any other. */
	private static inline final MISSING: String = 'missing';

	/**
	 * `oracles` made ready to use: every `generate` entry whose recorded generation is not current has its command run
	 * (the stale ones concurrently), a probed compile directory is probed again against the fresh hxml, and a failed
	 * generation marks its configurations `unavailable`. Entries without `generate` pass through untouched, in place.
	 * `notes` names each command that ran and why, for the caller to print.
	 *
	 * Each group is guarded by a reader/writer lock across `apq` processes (`OracleGenerationLock`), waiting at most
	 * `lockWaitMs` for it, in three phases. Every group is JUDGED under a momentary shared hold, nothing held across
	 * groups; the stale ones are REGENERATED under the exclusive hold (`regenerate`); then every usable group is SHARED
	 * for the compiles that follow — and looked at again under that hold, since another run may have wiped the tree after
	 * this one judged it (a generation it then failed, or was killed during). The question there is whether anything
	 * MOVED since this run observed the group (`observe`), not whether it is current: an entry with no inputs is never
	 * current, yet the generation this run just made is exactly what it compiles. A moved group goes back through
	 * regeneration, all shares dropped first, at most `MAX_REJUDGE` times, and is unavailable after that; one moved to
	 * the record of ANOTHER command is unavailable at once (`share`). Every wait follows ONE global order (`lockOrder`),
	 * so two runs cannot deadlock. The shared holds last until `release` or process exit. A hold that cannot be had —
	 * including state that cannot be created under a read-only root — makes that group's configurations unavailable.
	 */
	public static function prepare(oracles: Array<OracleConfig>, ?lockWaitMs: Int): PreparedOracles {
		final groups: Array<GenerationGroup> = groupsOf(oracles);
		final notes: Array<String> = [];
		if (groups.length == 0) return { oracles: oracles, notes: notes };
		final declaredWait: Null<Int> = Std.parseInt(Sys.getEnv('APQ_ORACLE_LOCK_WAIT') ?? '');
		final run: GenerationRun = {
			me: OracleGenerationLock.holder(),
			deadline: Date.now().getTime() + (lockWaitMs ?? declaredWait ?? LOCK_WAIT),
			failures: [],
			notes: notes,
			observed: [],
			raced: []
		};
		#if nodejs
		js.Node.process.once('exit', () -> releaseGroups(groups, run.me));
		#end
		final ordered: Array<GenerationGroup> = lockOrder(groups);
		final seen: Map<String, String> = [];
		var candidates: Array<GenerationGroup> = [];
		for (group in ordered) {
			final lock: String = lockDir(group);
			final blocked: Null<String> = hold(run, group, false);
			if (blocked != null)
				refuse(run, group, blocked)
			else if (staleness(group, seen) != null)
				candidates.push(group)
			else
				run.observed[group.key] = observe(group, seen);
			OracleGenerationLock.dropShared(lock, run.me);
		}
		var attempts: Int = 0;
		while (true) {
			regenerate(run, candidates, groups);
			final moved: Array<GenerationGroup> = share(run, ordered);
			if (moved.length == 0) break;
			attempts++;
			if (attempts >= MAX_REJUDGE) {
				for (group in moved) {
					OracleGenerationLock.dropShared(lockDir(group), run.me);
					refuse(run, group, 'it went stale again $attempts time(s) while this run waited — another run keeps moving it');
				}
				break;
			}
			for (group in ordered) OracleGenerationLock.dropShared(lockDir(group), run.me);
			candidates = moved;
		}
		return { oracles: [for (oracle in oracles) ready(oracle, run)], notes: notes };
	}

	/** Why `group`'s recorded generation is not current, or null when it is. */
	public static function staleness(group: GenerationGroup, memo: Map<String, String>): Null<String> {
		#if (sys || nodejs)
		for (hxml in group.hxmls) if (!sys.FileSystem.exists(hxml)) return '$hxml is missing';
		final inputs: Null<Array<String>> = group.inputs;
		if (inputs == null) return 'it declares no generateInputs, so it regenerates every run';
		final record: Null<GenerationRecord> = readRecord(recordFile(group));
		if (record == null) return 'no generation of it is recorded';
		if (record.format != FORMAT_TAG) return 'its generation was recorded by an older engine';
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

	/** Where `group`'s generation record lives: `record.json` in its state directory (`stateDir`). */
	public static function recordFile(group: GenerationGroup): String {
		return Path.join([stateDir(group), 'record.json']);
	}

	/** `oracle` as it may be used after `run`'s generations: unavailable, re-probed, or untouched — and marked when it raced. */
	private static function ready(oracle: OracleConfig, run: GenerationRun): OracleConfig {
		final generate: Null<OracleGenerate> = oracle.generate;
		if (generate == null) return oracle;
		final failure: Null<String> = run.failures[keyOf(generate)];
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
		final raced: Null<String> = run.raced[keyOf(generate)];
		if (raced != null && failure == null) out.raced = raced;
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
			format: FORMAT_TAG,
			command: group.generate.command,
			inputs: inputs,
			outputs: hashAll(group.hxmls, memo),
			implicit: implicit
		};
		try {
			sys.FileSystem.createDirectory(stateDir(group));
			sys.io.File.saveContent(recordFile(group), haxe.Json.stringify(record));
		} catch (exception: haxe.Exception) { // noqa: swallowed-exception
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
		// hxq's own generation state is never an input: every generation writes it
		for (entry in entries) if (entry != STATE_DIR) {
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

	/** The directory that holds `group`'s generation lock, in its state directory beside its record. */
	public static function lockDir(group: GenerationGroup): String {
		return Path.join([stateDir(group), 'lock']);
	}

	/**
	 * The directory holding `group`'s record, lock and epoch: `<project root>/.apq/oracle-generate/<md5>/`, keyed by the
	 * TREE the generation writes — the real paths of its hxmls — and by nothing about the config or process asking. Every
	 * config over that tree (a nested `apqlint.json` naming the same hxml included) therefore meets the same lock and the
	 * same record, whatever its `TMPDIR` or engine version (a record's own `format` answers the version). The project root is
	 * the nearest directory at or above the DECLARING config's directory holding a project marker (`ConfigFinder.projectRoot`),
	 * else that directory itself: never a walk from the hxml, which could stop at a marker the generation writes into the tree
	 * it deletes, or climb past a top-level hxml's own project into an enclosing one. Nothing in it is `.hx`, so no scan of
	 * the project reads it, and a directory input never hashes it (`listTree`); a project keeps it out of version control
	 * (`.apq/` in its ignore file).
	 */
	public static function stateDir(group: GenerationGroup): String {
		#if (sys || nodejs)
		final hxmls: Array<String> = group.hxmls.map(OracleDeclaration.realPath);
		hxmls.sort(Reflect.compare);
		final declaring: String = OracleDeclaration.realPath(absolute(Sys.getCwd(), group.generate.root));
		final home: String = ConfigFinder.projectRoot(declaring) ?? declaring;
		return Path.join([home, STATE_DIR, 'oracle-generate', md5(hxmls.join('\n'))]);
		#else
		return '';
		#end
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
	 * Answers the clause the generation's note ends with — empty when it was recorded from inputs that held still. An
	 * explicit input that moved while the command ran is recorded as it was before, so the next run regenerates; this
	 * run uses the generation as its snapshot of the tree.
	 */
	private static function record(s: StaleGroup, libraries: LibraryIndex): String {
		final after: Map<String, String> = [];
		final moved: Null<FileHash> = s.implicitBefore.find(held -> hashOf(held.path, after) != held.hash);
		final implicit: Array<FileHash> = [
			for (path in implicitInputs(s.group, libraries)) { path: path, hash: hashIn(s.implicitBefore, path) ?? hashOf(path, after) }
		];
		if (moved != null) return ' — NOT recorded: ${moved.path} changed while it ran, so the next run regenerates';
		writeRecord(s.group, s.inputs, implicit, after);
		final raced: Null<FileHash> = s.inputs.find(held -> hashOf(held.path, after) != held.hash);
		return raced == null ? '' : ' — ${raced.path} changed while it ran, so the next run regenerates';
	}

	/**
	 * Whether `path` lies in the output tree of one of `group`'s hxmls — the directory the command wrote that hxml into
	 * — where an include (lime's iOS `Build.hxml`) is PRODUCED by the generation: hashed as the command left it, never
	 * read as an input that moved while the command ran. Anything else, the rest of the project included, is compared
	 * across the run.
	 */
	private static function isProduced(group: GenerationGroup, path: String): Bool {
		for (hxml in group.hxmls) {
			final tree: String = Path.directory(hxml);
			if (tree != '' && path.startsWith('$tree/')) return true;
		}
		return false;
	}

	/**
	 * `group`, held exclusively by `me`, readied to regenerate: staleness is decided again under the hold (another run
	 * may have regenerated it while this one waited — then the hold is dropped and null answered), its inputs and the
	 * implicit inputs its previous record named are hashed BEFORE the command, and that record is deleted so a
	 * generation killed half way leaves nothing that reads as current.
	 */
	private static function claim(run: GenerationRun, group: GenerationGroup, fresh: Map<String, String>): Null<StaleGroup> {
		final judged: Null<String> = staleness(group, fresh);
		if (judged == null) {
			run.observed[group.key] = observe(group, fresh);
			OracleGenerationLock.dropExclusive(lockDir(group), run.me);
			return null;
		}
		final why: String = judged;
		final previous: Null<GenerationRecord> = readRecord(recordFile(group));
		final claimed: StaleGroup = {
			group: group,
			why: why,
			inputs: hashAll(group.inputs ?? [], fresh),
			implicitBefore: hashAll([
				for (held in previous?.implicit ?? []) if (!isProduced(group, held.path)) held.path
			], fresh)
		};
		deleteRecord(group);
		sys.io.File.saveContent(epochFile(group), '${run.me.pid} ${Date.now().getTime()} ${Math.random()}');
		return claimed;
	}

	/** The per-project directory, directly under a generation's root, that holds hxq's generation state. */
	public static inline final STATE_DIR: String = '.apq';

	/** How often `prepare` sends a group found stale under its compile hold back through regeneration. */
	private static inline final MAX_REJUDGE: Int = 3;

	/**
	 * `groups` in the ONE order every wait follows: by lock directory, the identity two runs actually contend on (two
	 * declarations of one tree share it, whatever their commands).
	 */
	public static function lockOrder(groups: Array<GenerationGroup>): Array<GenerationGroup> {
		final ordered: Array<GenerationGroup> = groups.copy();
		ordered.sort((a, b) -> Reflect.compare(lockDir(a), lockDir(b)));
		return ordered;
	}

	/** Mark `group`'s configurations unavailable for `why`, with a note. */
	private static function refuse(run: GenerationRun, group: GenerationGroup, why: String): Void {
		run.failures[group.key] = why;
		run.notes.push('could NOT use ${group.hxmls.join(', ')}: $why');
	}

	/**
	 * Regenerate the stale `candidates` (in lock order): each is held exclusively and re-judged there (`claim`), the
	 * ones still stale run concurrently, each success is recorded, and every exclusive hold is dropped again.
	 */
	private static function regenerate(run: GenerationRun, candidates: Array<GenerationGroup>, groups: Array<GenerationGroup>): Void {
		final fresh: Map<String, String> = [];
		final stale: Array<StaleGroup> = [];
		for (group in candidates) {
			final blocked: Null<String> = hold(run, group, true);
			if (blocked != null)
				refuse(run, group, blocked)
			else {
				final claimed: Null<StaleGroup> = claim(run, group, fresh);
				if (claimed != null) stale.push(claimed);
			}
		}
		if (stale.length == 0) return;
		final runs: Array<HaxeRun> = HaxeSpawn.runAll([
			for (s in stale)
				{
					args: [],
					cwd: s.group.generate.root,
					shell: s.group.generate.command,
					timeout: GENERATE_TIMEOUT,
					groupFile: OracleGenerationLock.jobFile(lockDir(s.group))
				}
		], BUFFER, HaxeSpawn.parallelism());
		final libraries: LibraryIndex = libraryIndex(groups);
		final settled: Map<String, String> = [];
		for (i => s in stale) {
			final failure: Null<String> = failureOf(s.group, runs[i]);
			if (failure == null) {
				final clause: String = record(s, libraries);
				run.notes.push('regenerated ${s.group.hxmls.join(', ')} (${s.why})$clause');
				if (clause == '')
					run.raced.remove(s.group.key)
				else
					run.raced[s.group.key] = 'this run regenerated it while an input moved$clause';
				run.observed[s.group.key] = observe(s.group, settled);
			} else {
				run.failures[s.group.key] = 'its generate command failed — $failure';
				run.notes.push('could NOT regenerate ${s.group.hxmls.join(', ')} (${s.why}): $failure');
			}
			OracleGenerationLock.dropExclusive(lockDir(s.group), run.me);
		}
	}

	/**
	 * Take the shared hold on every usable group of `ordered`, in order, and look at each again under it: answers the
	 * groups that MOVED since this run observed them (`observe`) — a tree another run wiped or regenerated meanwhile —
	 * which `prepare` sends back through regeneration. Moved to a record of a DIFFERENT command, a group is refused at
	 * once instead: another configuration regenerates the same tree, and every retry would only hand it back.
	 */
	private static function share(run: GenerationRun, ordered: Array<GenerationGroup>): Array<GenerationGroup> {
		final judged: Map<String, String> = [];
		final moved: Array<GenerationGroup> = [];
		for (group in ordered) if (!run.failures.exists(group.key)) {
			final blocked: Null<String> = hold(run, group, false);
			if (blocked != null) {
				refuse(run, group, blocked);
				continue;
			}
			final seen: Null<String> = run.observed[group.key];
			if (seen == null) throw new Exception('${group.hxmls.join(', ')} reached its compile hold unobserved');
			if (observe(group, judged) == seen) continue;
			final record: Null<GenerationRecord> = #if (sys || nodejs) readRecord(recordFile(group)) #else null #end;
			final rival: Null<String> = record?.format == FORMAT_TAG && record?.command != group.generate.command ? record?.command : null;
			if (rival == null)
				moved.push(group)
			else {
				OracleGenerationLock.dropShared(lockDir(group), run.me);
				refuse(run, group, 'another config regenerates this tree with a different command (`$rival`)');
			}
		}
		return moved;
	}

	/**
	 * What this run sees of `group` right now, as one string: its record as written, and the hash of every hxml, every
	 * explicit input and every implicit input that record names. Taken when the group is judged current or regenerated,
	 * and compared under the compile hold (`share`), which therefore asks "did anything move since THIS run looked" — not
	 * "is it current", which an entry with no inputs, or one whose command writes its own input, never is.
	 */
	private static function observe(group: GenerationGroup, memo: Map<String, String>): String {
		#if (sys || nodejs)
		final written: String = try sys.io.File.getContent(recordFile(group)) catch (exception: haxe.Exception) MISSING;
		final record: Null<GenerationRecord> = try haxe.Json.parse(written) catch (exception: haxe.Exception) null;
		final paths: Array<String> = group.hxmls.concat(group.inputs ?? []).concat([for (held in record?.implicit ?? []) held.path]);
		final epoch: String = try sys.io.File.getContent(epochFile(group)) catch (exception: haxe.Exception) MISSING;
		return [epoch, written].concat([for (hash in hashAll(paths, memo)) '${hash.path} ${hash.hash}']).join('\n');
		#else
		return '';
		#end
	}

	/**
	 * Take `group`'s shared or exclusive hold for `run`: null when held, else why not. A generation root where the state
	 * cannot be created (a read-only checkout) is a reason too, never a crash: with no record and no lock nothing shows
	 * the hxml current, so its configurations are unavailable.
	 */
	private static function hold(run: GenerationRun, group: GenerationGroup, exclusive: Bool): Null<String> {
		final lock: String = lockDir(group);
		try {
			if (exclusive) return OracleGenerationLock.holdExclusive(lock, run.me, run.deadline);
			return OracleGenerationLock.holdShared(lock, run.me, run.deadline);
		} catch (exception: Exception) {
			return 'cannot create its generation state under ${Path.directory(Path.directory(stateDir(group)))}: ${exception.message}';
		}
	}

	/**
	 * Where `group`'s epoch lives: a nonce every regeneration writes before its command starts, successful or not. Part of
	 * what `observe` sees, so a generation by any run moves the snapshot even when the record and the hxml end up as they
	 * were — a failed one leaves no record to compare, and the tree it half rewrote is more than the hxml.
	 */
	public static function epochFile(group: GenerationGroup): String {
		return Path.join([stateDir(group), 'epoch']);
	}

}

/** One `prepare` call's state: who holds the locks, until when it waits, and what it has refused and said, and what it saw. */
typedef GenerationRun = {
	var me: Holder;
	var deadline: Float;
	var failures: Map<String, String>;
	var notes: Array<String>;

	/** What this run last saw of each usable group, by key (`OracleGeneration.observe`). */
	var observed: Map<String, String>;

	/** Why each group this run regenerated while an input moved is no snapshot of the tree, by key. */
	var raced: Map<String, String>;
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
	/** The record scheme it was written under (`FORMAT_TAG`): a record of another scheme is never current. */
	var ?format: String;
	var ?command: String;
	var ?inputs: Array<FileHash>;
	var ?outputs: Array<FileHash>;

	/** The files the generated hxml depends on without declaring them — see `implicitInputs`. */
	var ?implicit: Array<FileHash>;
}
