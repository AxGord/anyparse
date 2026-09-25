package anyparse.check;

import anyparse.check.HaxeSpawn.HaxeRun;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.LintConfig.OracleGenerate;
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
 * only while all of these hold, and the command runs again the moment any of them does not:
 *
 *  - every hxml the command produces exists and hashes as it did right after the last generation — a hxml deleted or
 *    edited by hand is regenerated rather than trusted;
 *  - the command string is the one that generation ran;
 *  - every `generateInputs` file hashes as it did then (a missing file hashes as missing, so creating or deleting one
 *    counts as a change).
 *
 * An entry that names no `generateInputs` cannot be shown current by anything, so its command runs once per call of
 * `prepare` — once per `apq` run. Correct, and as slow as the command.
 *
 * The record of the last generation lives beside the oracle verdict records (`TempScratch.root`), one file per
 * (directory, hxml set), and is written only after the command succeeded and every hxml it owes exists.
 *
 * ## Failure
 *
 * A command that fails — a non-zero status, no process at all, or a success that left an hxml missing — makes every
 * configuration it serves UNAVAILABLE with the command's own output quoted, and deletes the record, so the next run
 * tries again. A stale hxml is never used in its place: it would answer for a build nobody asked about.
 *
 * ## Sharing and overlap
 *
 * Entries naming the same command in the same directory are ONE generation — two define variants of one build run it
 * once. Distinct commands run concurrently (`HaxeSpawn.runAll`, bounded by `HaxeSpawn.parallelism`), so two of them
 * must not write a common path; that is the project's contract to keep, and the reason each lime entry names its own
 * `--app-path`.
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
	 */
	public static function prepare(oracles: Array<OracleConfig>): PreparedOracles {
		final groups: Array<GenerationGroup> = groupsOf(oracles);
		final notes: Array<String> = [];
		if (groups.length == 0) return { oracles: oracles, notes: notes };
		final stale: Array<{ group: GenerationGroup, why: String }> = [];
		for (group in groups) {
			final why: Null<String> = staleness(group);
			if (why != null) stale.push({ group: group, why: why });
		}
		final runs: Array<HaxeRun> = HaxeSpawn.runAll([
			for (s in stale) { args: [], cwd: s.group.generate.root, shell: s.group.generate.command }
		], BUFFER, HaxeSpawn.parallelism());
		final failures: Map<String, String> = [];
		for (i in 0...stale.length) {
			final group: GenerationGroup = stale[i].group;
			final why: String = stale[i].why;
			final failure: Null<String> = failureOf(group, runs[i]);
			if (failure == null) {
				writeRecord(group);
				notes.push('regenerated ${group.hxmls.join(', ')} ($why)');
			} else {
				deleteRecord(group);
				failures[group.key] = failure;
				notes.push('could NOT regenerate ${group.hxmls.join(', ')} ($why): $failure');
			}
		}
		return { oracles: [for (oracle in oracles) ready(oracle, failures)], notes: notes };
	}

	/** Why `group`'s recorded generation is not current, or null when it is. */
	public static function staleness(group: GenerationGroup): Null<String> {
		#if (sys || nodejs)
		for (hxml in group.hxmls) if (!sys.FileSystem.exists(hxml)) return '$hxml is missing';
		final inputs: Null<Array<String>> = group.generate.inputs;
		if (inputs == null) return 'it declares no generateInputs, so it regenerates every run';
		final record: Null<GenerationRecord> = readRecord(recordFile(group));
		if (record == null) return 'no generation of it is recorded';
		if (record.command != group.generate.command) return 'its generate command changed';
		final recordedInputs: Array<FileHash> = record.inputs ?? [];
		for (input in inputs) if (hashIn(recordedInputs, input) != hashOf(input)) return '$input changed';
		final recordedOutputs: Array<FileHash> = record.outputs ?? [];
		for (hxml in group.hxmls) if (hashIn(recordedOutputs, hxml) != hashOf(hxml)) return '$hxml changed since it was generated';
		return null;
		#else
		return 'no filesystem on this target';
		#end
	}

	/** The generations `oracles` declare, one per distinct (directory, command), each listing every hxml it serves. */
	public static function groupsOf(oracles: Array<OracleConfig>): Array<GenerationGroup> {
		final groups: Array<GenerationGroup> = [];
		for (oracle in oracles) {
			final declared: Null<OracleGenerate> = oracle.generate;
			if (declared == null) continue;
			// re-bound: strict null-safety does not carry a narrowed local into a structure literal
			final generate: OracleGenerate = declared;
			final key: String = '${generate.root}\n${generate.command}';
			final held: Null<GenerationGroup> = groups.find(g -> g.key == key);
			if (held == null)
				groups.push({ key: key, generate: generate, hxmls: [oracle.hxml] })
			else if (!held.hxmls.contains(oracle.hxml))
				held.hxmls.push(oracle.hxml);
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
		final failure: Null<String> = failures['${generate.root}\n${generate.command}'];
		final dir: Null<String> = generate.probeDir && failure == null
			? OracleDeclaration.compileDir(oracle.hxml, generate.root)
			: oracle.dir;
		final out: OracleConfig = {
			hxml: oracle.hxml,
			dir: dir,
			defines: oracle.defines,
			generate: generate
		};
		if (failure != null) out.unavailable = 'its generate command failed — $failure';
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

	/** Record `group`'s generation as current: its command, and every input and hxml by content. */
	private static function writeRecord(group: GenerationGroup): Void {
		#if (sys || nodejs)
		final record: GenerationRecord = {
			command: group.generate.command,
			inputs: [for (input in group.generate.inputs ?? []) { path: input, hash: hashOf(input) }],
			outputs: [for (hxml in group.hxmls) { path: hxml, hash: hashOf(hxml) }]
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

	/** The content hash of `path`, `MISSING` when it does not exist or cannot be read. */
	private static function hashOf(path: String): String {
		if (!sys.FileSystem.exists(path) || sys.FileSystem.isDirectory(path)) return MISSING;
		return try md5Bytes(sys.io.File.getBytes(path)) catch (exception: haxe.Exception) MISSING;
	}

	/** md5 of `bytes` — through node's native digest there, since an input may be a multi-megabyte binary asset. */
	private static function md5Bytes(bytes: haxe.io.Bytes): String {
		return #if nodejs js.node.Crypto.createHash('md5')
			.update(js.node.Buffer.hxFromBytes(bytes))
			.digest('hex') #else haxe.crypto.Md5.make(bytes).toHex() #end;
	}
	#end

}

/** `OracleGeneration.prepare`'s answer: the configurations ready to use, and a line per command that ran. */
typedef PreparedOracles = {
	var oracles: Array<OracleConfig>;
	var notes: Array<String>;
}

/** One generation `prepare` may run: the key it is shared by, its declaration, and every hxml it serves. */
typedef GenerationGroup = {
	var key: String;
	var generate: OracleGenerate;
	var hxmls: Array<String>;
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
}
