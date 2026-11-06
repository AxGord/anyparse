package anyparse.check.oracle;

import anyparse.check.LintConfig.OracleGenerate;
import anyparse.check.oracle.OracleCache.OracleScan;
import anyparse.core.PhaseTimings;
import anyparse.core.ReachBuildsEngine;
import anyparse.core.TempScratch;
import anyparse.query.ReachLiveness.ReachBuilds;
import anyparse.query.ReachLiveness.ReachConfiguration;
import haxe.Exception;
import haxe.io.Path;
import sys.io.File;

/**
 * The key one list of configurations' builds is stored under: one hash over the engine code a record's answer depends
 * on and each configuration's identity and `OracleCache` fingerprint; and per configuration the directory it compiles
 * from and every source that fingerprint hashed.
 */
typedef ReachBuildsKey = {
	var key: String;
	var bases: Array<String>;
	var hashed: Array<Map<String, String>>;
}

/**
 * The builds an oracle run probed (`ReachDefinesProbe`), kept in a file beside the verdict cache (`OracleCache`) under the
 * content fingerprint of every configuration's compile input, so a run that compiles nothing (`--no-oracle`) over the very
 * same input reads what the compiler answered instead of knowing no build. A build is kept only when every file it parsed
 * is one the fingerprint hashed, and read only under the fingerprint the input hashes to now, with every generation it
 * needs current and every library source hashing as it was read; any doubt is a miss, and a miss is a run that knows no
 * build. The record is a file, read per run: nothing is kept in the process.
 */
@:nullSafety(Strict)
final class ReachBuildsCache {

	/** The scheme tag in every record: bump it and every stored record misses. */
	private static inline final FORMAT_TAG: String = 'apq-reach-builds v2';

	/** The engine code a record's answer depends on, hashed when the engine compiles: another engine's record misses. */
	private static final ENGINE: String = ReachBuildsEngine.digest();

	/**
	 * The key the builds of `oracles` are stored under (`ReachBuildsKey`); null when any configuration is unavailable or
	 * its generation raced, a generation one needs is not current, or a fingerprint cannot be taken.
	 */
	public static function fingerprint(oracles: Array<OracleConfig>): Null<ReachBuildsKey> {
		return PhaseTimings.measure('reach builds fingerprint', keyOf.bind(oracles));
	}

	/**
	 * Store `builds`, probed of `oracles` whose input hashed to `before` before the compiles began, when it hashes so still
	 * and every file each build parsed is one its fingerprint hashed (`OracleCache.readsHashed`): any other can change with
	 * no fingerprint changing. With the record go the sizes and times of the hashed files, which let a read that will miss
	 * miss without hashing. A failed write stores nothing and is no error: the next run that compiles nothing knows no
	 * build.
	 */
	public static function store(oracles: Array<OracleConfig>, before: Null<ReachBuildsKey>, builds: Null<ReachBuilds>): Void {
		#if (sys || nodejs)
		if (before == null || builds == null) return;
		final key: ReachBuildsKey = before;
		final configurations: Array<ReachConfiguration> = builds.configurations;
		if (configurations.length != oracles.length) return;
		for (i in 0...oracles.length) if (!OracleCache.readsHashed(key.bases[i], configurations[i].parsed, key.hashed[i])) return;
		if (fingerprint(oracles)?.key != key.key) return;
		final stats: Map<String, String> = [];
		for (hashed in key.hashed) for (file in hashed.keys()) if (!stats.exists(file)) stats[file] = statOf(file) ?? '';
		final record: ReachBuildsRecord = {
			format: FORMAT_TAG,
			key: key.key,
			stats: [for (file => stat in stats) [file, stat]],
			configurations: configurations.map(recordOf),
			library: builds.library.map(f -> {file: f.file, hash: OracleCache.md5(f.source) })
		};
		final path: String = cacheFile(oracles);
		// staged under this process's name and renamed, so a concurrent reader meets the old record or the new one whole
		final staged: String = TempScratch.slot(stem(oracles), '.staged');
		try {
			// recordOf builds the record in the schema's key order with no held null, the compact document's own: the engine's
			// writer spells it without the generated writer's key-ordered copy
			sys.io.File.saveContent(staged, haxe.Json.stringify(record)); // noqa: avoid-haxe-json
			sys.FileSystem.rename(staged, path);
		} catch (exception: Exception) { // noqa: swallowed-exception
			// a record that cannot be written costs the next run its builds, never this run its answer
		}
		#end
	}

	/**
	 * The builds stored for `oracles` under the fingerprint their input hashes to now, every library source read afresh
	 * and hashing as it did when they were probed; null otherwise, and for a record of any other shape. A hashed file whose
	 * size or modification time moved misses before anything is hashed.
	 */
	public static function load(oracles: Array<OracleConfig>): Null<ReachBuilds> {
		#if (sys || nodejs)
		final path: String = cacheFile(oracles);
		if (oracles.length == 0 || !sys.FileSystem.exists(path)) return null;
		return try loadFrom(oracles, path) catch (exception: Exception) null;
		#else
		return null;
		#end
	}

	/**
	 * Where the builds of `oracles` are stored: one file under the OS temp root, named by a hash of the configurations'
	 * hxmls and defines, so a list of configurations holds one record however often its input changes.
	 */
	public static function cacheFile(oracles: Array<OracleConfig>): String {
		return #if (sys || nodejs) Path.join([TempScratch.root(), '${stem(oracles)}.json']) #else '' #end;
	}

	/** `load`'s answer from the record at `path`; it may throw on a record of no shape `buildsOf` foresaw. */
	private static function loadFrom(oracles: Array<OracleConfig>, path: String): Null<ReachBuilds> {
		final record: ReachBuildsRecord = ReachBuildsRecordParser.parse(File.getContent(path));
		if (record.format != FORMAT_TAG || !statsHold(record.stats)) return null;
		final now: Null<ReachBuildsKey> = fingerprint(oracles);
		return now == null || now.key != record.key ? null : buildsOf(record);
	}

	/** `fingerprint`'s answer. */
	private static function keyOf(oracles: Array<OracleConfig>): Null<ReachBuildsKey> {
		#if (sys || nodejs)
		if (oracles.length == 0 || oracles.exists(o -> o.unavailable != null || o.raced != null)) return null;
		final hashes: Map<String, String> = [];
		for (group in OracleGeneration.groupsOf(oracles)) if (OracleGeneration.staleness(group, hashes) != null) return null;
		final contents: Map<String, String> = [];
		final walks: Map<String, Map<String, String>> = [];
		final lines: Array<String> = [FORMAT_TAG, ENGINE];
		final bases: Array<String> = [];
		final hashed: Array<Map<String, String>> = [];
		for (oracle in oracles) {
			final dir: Null<String> = compileDir(oracle);
			final scan: Null<OracleScan> = OracleCache.scanned(oracle.hxml, dir, oracle.defines, contents, walks);
			if (scan == null) return null;
			bases.push(dir ?? Sys.getCwd());
			hashed.push(scan.hashed);
			lines.push(OracleDeclaration.oracleKey({ hxml: oracle.hxml, dir: dir, defines: oracle.defines }));
			lines.push(scan.fingerprint);
		}
		return { key: OracleCache.md5(lines.join('\n')), bases: bases, hashed: hashed };
		#else
		return null;
		#end
	}

	/** The name, without extension, of the record of `oracles`' builds. */
	private static function stem(oracles: Array<OracleConfig>): String {
		return 'apq-reach-builds-${OracleCache.md5(oracles.map(o -> [o.hxml].concat(o.defines).join(' ')).join('\n'))}';
	}

	/** The directory `oracle` compiles from: the one its generation probes, as a prepared configuration carries it. */
	private static function compileDir(oracle: OracleConfig): Null<String> {
		final generate: Null<OracleGenerate> = oracle.generate;
		return generate != null && generate.probeDir ? OracleDeclaration.compileDir(oracle.hxml, generate.root) : oracle.dir;
	}

	/** The size and modification time of `file`, or null when it cannot be read. */
	private static function statOf(file: String): Null<String> {
		return #if (sys || nodejs) try {
			final stat: sys.FileStat = sys.FileSystem.stat(file);
			'${stat.size} ${stat.mtime.getTime()}';
		} catch (exception: Exception) {
			null;
		} #else null #end;
	}

	/** Whether every `[file, stat]` pair of `stats` names a file whose size and modification time are as recorded. */
	private static function statsHold(stats: Array<Array<String>>): Bool {
		return stats.foreach(pair -> pair.length == 2 && pair[1] != '' && statOf(pair[0]) == pair[1]);
	}

	/** `c` as its record, in the schema's key order; an absent `parsed` is left out, never held as null. */
	private static function recordOf(c: ReachConfiguration): ReachConfigurationRecord {
		final record: ReachConfigurationRecord = {
			name: c.name,
			defined: c.defined,
			everDefined: c.everDefined,
			values: [for (name => value in c.values) [name, value]],
			compiled: c.compiled,
			types: c.types.map(t -> {name: t.name, file: t.file })
		};
		final parsed: Null<Array<String>> = c.parsed;
		if (parsed != null) record.parsed = parsed;
		return record;
	}

	/** The builds `record` holds, every library source read and checked against its hash; null for any field of no shape. */
	private static function buildsOf(record: ReachBuildsRecord): Null<ReachBuilds> {
		final configurations: Array<ReachConfiguration> = [];
		for (c in record.configurations) {
			final read: Null<ReachConfiguration> = configurationOf(c);
			if (read == null) return null;
			configurations.push(read);
		}
		if (configurations.length == 0) return null;
		final library: Array<{ file: String, source: String }> = [];
		for (entry in record.library) {
			final source: Null<String> = try File.getContent(entry.file) catch (exception: Exception) null;
			if (source == null) return null;
			final read: String = source;
			if (OracleCache.md5(read) != entry.hash) return null;
			library.push({ file: entry.file, source: read });
		}
		return { configurations: configurations, library: library };
	}

	/** The build one record entry holds, or null for an entry of any other shape. */
	private static function configurationOf(c: ReachConfigurationRecord): Null<ReachConfiguration> {
		final values: Map<String, String> = [];
		for (pair in c.values) {
			if (pair.length != 2) return null;
			values[pair[0]] = pair[1];
		}
		final read: ReachConfiguration = {
			name: c.name,
			defined: c.defined,
			everDefined: c.everDefined,
			values: values,
			compiled: c.compiled,
			types: c.types.map(t -> {name: t.name, file: t.file })
		};
		final parsed: Null<Array<String>> = c.parsed;
		if (parsed != null) read.parsed = parsed;
		return read;
	}

}
