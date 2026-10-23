package anyparse.check;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.LintConfig.OracleGenerate;
import anyparse.core.PhaseTimings;
import anyparse.core.TempScratch;
import anyparse.query.ReachLiveness.ReachBuilds;
import anyparse.query.ReachLiveness.ReachConfiguration;
import haxe.Exception;
import haxe.io.Path;

using Lambda;
using StringTools;

/**
 * What a persisted builds record holds. Every field is optional, since the record comes off disk through
 * `haxe.Json.parse` and a reader trusting the declared types would dereference null on a truncated file.
 */
typedef ReachBuildsRecord = {
	var ?format: String;
	var ?key: String;
	var ?configurations: Array<ReachConfigurationRecord>;
	var ?library: Array<{ ?file: String, ?hash: String }>;
}

/** One build of a persisted record: a `ReachConfiguration`, its define values as pairs. */
typedef ReachConfigurationRecord = {
	var ?name: String;
	var ?defined: Array<String>;
	var ?everDefined: Array<String>;
	var ?values: Array<Array<String>>;
	var ?compiled: Array<String>;
	var ?types: Array<{ ?name: String, ?file: String }>;
}

/**
 * The key one list of configurations' builds is stored under: one hash over the probe's own macro and each
 * configuration's identity and `OracleCache` fingerprint, and per configuration the directories that fingerprint walked.
 */
typedef ReachBuildsKey = {
	var key: String;
	var roots: Array<Array<String>>;
}

/**
 * The builds an oracle run probed (`ReachDefinesProbe`), kept in a file beside the verdict cache (`OracleCache`) under the
 * content fingerprint of every configuration's compile input, so a run that compiles nothing (`--no-oracle`) over the very
 * same input reads what the compiler answered instead of knowing no build. A record is read only under the fingerprint
 * the input hashes to now, with every generation it needs current and every library source hashing as it was read; any
 * doubt is a miss, and a miss is a run that knows no build. The record is a file, read per run: nothing is kept in the
 * process.
 */
@:nullSafety(Strict)
final class ReachBuildsCache {

	/** The scheme tag in every record: bump it and every stored record misses. */
	private static inline final FORMAT_TAG: String = 'apq-reach-builds v1';

	/**
	 * The key the builds of `oracles` are stored under (`ReachBuildsKey`); null when any configuration is unavailable or
	 * its generation raced, a generation one needs is not current, or a fingerprint cannot be taken.
	 */
	public static function fingerprint(oracles: Array<OracleConfig>): Null<ReachBuildsKey> {
		return PhaseTimings.measure('reach builds fingerprint', keyOf.bind(oracles));
	}

	/**
	 * Store `builds`, probed of `oracles` whose input hashed to `before` before the compiles began, when it hashes so still
	 * and every file each build parsed lies inside the directories its fingerprint walked: a file outside them can change
	 * with no fingerprint changing. A failed write stores nothing and is no error: the next run that compiles nothing knows
	 * no build.
	 */
	public static function store(oracles: Array<OracleConfig>, before: Null<ReachBuildsKey>, builds: Null<ReachBuilds>): Void {
		#if (sys || nodejs)
		if (before == null || builds == null) return;
		final key: ReachBuildsKey = before;
		final configurations: Array<ReachConfiguration> = builds.configurations;
		if (configurations.length != oracles.length) return;
		for (i in 0...oracles.length) if (!readsInside(configurations[i].parsed, key.roots[i])) return;
		if (fingerprint(oracles)?.key != key.key) return;
		final record: ReachBuildsRecord = {
			format: FORMAT_TAG,
			key: key.key,
			configurations: [for (c in configurations) recordOf(c)],
			library: [for (f in builds.library) { file: f.file, hash: OracleCache.md5(f.source) }]
		};
		final path: String = cacheFile(oracles);
		// staged under this process's name and renamed, so a concurrent reader meets the old record or the new one whole
		final staged: String = TempScratch.slot(stem(oracles), '.staged');
		try {
			sys.io.File.saveContent(staged, haxe.Json.stringify(record));
			sys.FileSystem.rename(staged, path);
		} catch (exception: Exception) { // noqa: swallowed-exception
			// a record that cannot be written costs the next run its builds, never this run its answer
		}
		#end
	}

	/**
	 * The builds stored for `oracles` under the fingerprint their input hashes to now, every library source read afresh
	 * and hashing as it did when they were probed; null otherwise.
	 */
	public static function load(oracles: Array<OracleConfig>): Null<ReachBuilds> {
		#if (sys || nodejs)
		final path: String = cacheFile(oracles);
		if (oracles.length == 0 || !sys.FileSystem.exists(path)) return null;
		final record: Null<ReachBuildsRecord> = try haxe.Json.parse(sys.io.File.getContent(path)) catch (exception: Exception) null;
		if (record == null || record.format != FORMAT_TAG || record.key == null) return null;
		final now: Null<ReachBuildsKey> = fingerprint(oracles);
		return now == null || now.key != record.key ? null : buildsOf(record);
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

	/** `fingerprint`'s answer. */
	@:access(anyparse.check.ReachDefinesProbe.macroSource)
	@:access(anyparse.check.OracleRunMemo.directoryPrefix)
	private static function keyOf(oracles: Array<OracleConfig>): Null<ReachBuildsKey> {
		#if (sys || nodejs)
		if (oracles.length == 0 || oracles.exists(o -> o.unavailable != null || o.raced != null)) return null;
		final hashes: Map<String, String> = [];
		for (group in OracleGeneration.groupsOf(oracles)) if (OracleGeneration.staleness(group, hashes) != null) return null;
		final contents: Map<String, String> = [];
		final walks: Map<String, Map<String, String>> = [];
		final lines: Array<String> = [FORMAT_TAG, OracleCache.md5(ReachDefinesProbe.macroSource())];
		final roots: Array<Array<String>> = [];
		for (oracle in oracles) {
			final dir: Null<String> = compileDir(oracle);
			final scan: Null<{ fingerprint: String, roots: Array<String> }> = OracleCache.scanned(
				oracle.hxml, dir, oracle.defines, contents, walks
			);
			if (scan == null) return null;
			final base: String = dir ?? Sys.getCwd();
			roots.push([
				for (root in scan.roots) OracleRunMemo.directoryPrefix(OracleCoverage.canonical(base, root))
			]);
			lines.push(OracleDeclaration.oracleKey({ hxml: oracle.hxml, dir: dir, defines: oracle.defines }));
			lines.push(scan.fingerprint);
		}
		return { key: OracleCache.md5(lines.join('\n')), roots: roots };
		#else
		return null;
		#end
	}

	/** The name, without extension, of the record of `oracles`' builds. */
	private static function stem(oracles: Array<OracleConfig>): String {
		return 'apq-reach-builds-${OracleCache.md5([for (o in oracles) [o.hxml].concat(o.defines).join(' ')].join('\n'))}';
	}

	/** The directory `oracle` compiles from: the one its generation probes, as a prepared configuration carries it. */
	private static function compileDir(oracle: OracleConfig): Null<String> {
		final generate: Null<OracleGenerate> = oracle.generate;
		return generate != null && generate.probeDir ? OracleDeclaration.compileDir(oracle.hxml, generate.root) : oracle.dir;
	}

	/** Whether `parsed` names some file and every one lies under one of `roots`. */
	private static function readsInside(parsed: Null<Array<String>>, roots: Null<Array<String>>): Bool {
		return parsed != null && roots != null && parsed.length > 0 && parsed.foreach(path -> roots.exists(dir -> path.startsWith(dir)));
	}

	private static function recordOf(c: ReachConfiguration): ReachConfigurationRecord {
		return {
			name: c.name,
			defined: c.defined,
			everDefined: c.everDefined,
			values: [for (name => value in c.values) [name, value]],
			compiled: c.compiled,
			types: [for (t in c.types) { name: t.name, file: t.file }]
		};
	}

	/** The builds `record` holds, every library source read and checked against its hash; null for any field missing. */
	private static function buildsOf(record: ReachBuildsRecord): Null<ReachBuilds> {
		final configurations: Array<ReachConfiguration> = [];
		for (c in record.configurations ?? []) {
			final read: Null<ReachConfiguration> = configurationOf(c);
			if (read == null) return null;
			configurations.push(read);
		}
		if (configurations.length == 0) return null;
		final library: Array<{ file: String, source: String }> = [];
		for (entry in record.library ?? []) {
			final file: Null<String> = entry.file;
			if (file == null) return null;
			final source: Null<String> = try sys.io.File.getContent(file) catch (exception: Exception) null;
			if (source == null) return null;
			final read: String = source;
			if (OracleCache.md5(read) != entry.hash) return null;
			library.push({ file: file, source: read });
		}
		return { configurations: configurations, library: library };
	}

	private static function configurationOf(c: ReachConfigurationRecord): Null<ReachConfiguration> {
		final name: Null<String> = c.name;
		final defined: Null<Array<String>> = c.defined;
		final everDefined: Null<Array<String>> = c.everDefined;
		final compiled: Null<Array<String>> = c.compiled;
		if (name == null || defined == null || everDefined == null || compiled == null) return null;
		final values: Map<String, String> = [];
		for (pair in c.values ?? []) {
			if (pair.length != 2) return null;
			values[pair[0]] = pair[1];
		}
		final types: Array<{ name: String, file: String }> = [];
		for (t in c.types ?? []) {
			final typeName: Null<String> = t.name;
			final file: Null<String> = t.file;
			if (typeName == null || file == null) return null;
			types.push({ name: typeName, file: file });
		}
		return {
			name: name,
			defined: defined,
			everDefined: everDefined,
			values: values,
			compiled: compiled,
			types: types
		};
	}

}
