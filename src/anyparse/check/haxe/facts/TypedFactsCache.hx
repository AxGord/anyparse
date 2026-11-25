package anyparse.check.haxe.facts;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.haxe.oracle.OracleCache;
import anyparse.check.haxe.oracle.OracleCoverage;
import anyparse.check.haxe.oracle.OracleDeclaration;
import anyparse.check.haxe.oracle.OracleGeneration;
import anyparse.check.haxe.oracle.ReachBuildsCache;
import anyparse.core.ContentHash;
import anyparse.core.PhaseTimings;
import anyparse.core.TempScratch;
import anyparse.proc.ProcessRun;
import anyparse.query.ReachLiveness.ReachConfiguration;
import haxe.Exception;
import haxe.io.Path;
import sys.io.File;

/** The key one configuration's facts compile is stored under, the directory it compiles from, and every source its fingerprint hashed. */
typedef TypedFactsKey = { var key: String; var base: String; var hashed: Map<String, String>; }

/** What the compile that carried a facts hook answered besides the facts: its `-v` typecheck and its build. */
typedef TypedFactsRidden = { var verbose: ProcessRun; var configuration: ReachConfiguration; }

/** A stored facts compile as its record names it: the md5 of its dump, and what the compile answered besides (`TypedFactsRidden`). */
typedef TypedFactsStored = { var digest: String; var ridden: TypedFactsRidden; }

/**
 * The one answer to "has an earlier run already compiled the facts of this very input": one configuration's facts compile kept
 * under the OS temp root as the dump the hook wrote and a record naming the dump's md5 beside the `-v` typecheck and the build the
 * same compile answered, under the content fingerprint of its input (`OracleCache.scanned`) joined with a hash of the code that
 * wrote it. Stored only when the input hashed alike before and after the compile and every file the compile parsed is one the
 * fingerprint hashed; read only under the fingerprint the input hashes to now. A report-mode fast path with the verdict cache's
 * holes (`OracleCache`), never asked by a `--fix` run; nothing is kept in the process.
 */
@:nullSafety(Strict)
final class TypedFactsCache {

	/** The scheme tag in every record: bump it and every stored record misses. */
	private static final FORMAT_TAG: String = 'apq-typed-facts v1';

	/**
	 * The key of each configuration of `oracles` in order, `engine` naming the code that writes the facts, a source every
	 * configuration reads hashed once; null for one that is unavailable, raced its generation, or cannot be fingerprinted,
	 * and for every one when a generation the list needs is not current.
	 */
	public static function keys(oracles: Array<OracleConfig>, engine: String): Array<Null<TypedFactsKey>> {
		return PhaseTimings.measure('typed facts fingerprint', keysOf.bind(oracles, engine));
	}

	/**
	 * The record stored for `oracle` under `key`, its dump left unread (`dump`) so a run holds one dump at a time; null otherwise
	 * and for a record of any other shape.
	 */
	public static function load(oracle: OracleConfig, key: TypedFactsKey): Null<TypedFactsStored> {
		#if (sys || nodejs)
		final path: String = recordFile(oracle);
		if (!sys.FileSystem.exists(path)) return null;
		return try loadFrom(path, key) catch (exception: Exception) null;
		#else
		return null;
		#end
	}

	/** The dump `stored` names for `oracle`, or null when the file now there hashes otherwise — another run replaced it. */
	public static function dump(oracle: OracleConfig, stored: TypedFactsStored): Null<String> {
		#if (sys || nodejs)
		final text: Null<String> = try File.getContent(dumpFile(oracle)) catch (exception: Exception) null;
		return text != null && ContentHash.md5(text) == stored.digest ? text : null;
		#else
		return null;
		#end
	}

	/**
	 * Store `text`, the facts the compile of `oracle` wrote, with what it answered besides (`ridden`), when its input had the key
	 * `before` when the compile began and `after` once it ended, the two agree, and every file the compile parsed is one that key
	 * hashed: any other can change with no key changing. A failed write stores nothing and is no error: the next run compiles again.
	 */
	public static function store(
		oracle: OracleConfig, before: Null<TypedFactsKey>, after: Null<TypedFactsKey>, text: String, ridden: TypedFactsRidden
	): Void {
		#if (sys || nodejs)
		if (before == null || after == null) return;
		final key: TypedFactsKey = before;
		final now: TypedFactsKey = after;
		if (key.key == now.key && OracleCache.readsHashed(key.base, OracleCoverage.parsedPaths(ridden.verbose.out), key.hashed))
			write(oracle, key.key, text, ridden);
		#end
	}

	/** Where the record of `oracle`'s facts is kept (`stem`). */
	public static function recordFile(oracle: OracleConfig): String {
		return #if (sys || nodejs) Path.join([TempScratch.root(), '${stem(oracle)}.json']) #else '' #end;
	}

	/** Where the dump of `oracle`'s facts is kept (`stem`). */
	public static function dumpFile(oracle: OracleConfig): String {
		return #if (sys || nodejs) Path.join([TempScratch.root(), '${stem(oracle)}.jsonl']) #else '' #end;
	}

	/** `keys`'s answer. */
	private static function keysOf(oracles: Array<OracleConfig>, engine: String): Array<Null<TypedFactsKey>> {
		#if (sys || nodejs)
		final hashes: Map<String, String> = [];
		for (group in OracleGeneration.groupsOf(oracles)) if (OracleGeneration.staleness(group, hashes) != null)
			return [ for (_ in oracles) null ];
		final contents: Map<String, String> = [];
		final walks: Map<String, Map<String, String>> = [];
		return [ for (oracle in oracles) {
			final scan: Null<OracleScan> = oracle.unavailable == null && oracle.raced == null
				? OracleCache.scanned(oracle.hxml, oracle.dir, oracle.defines, contents, walks)
				: null;
			scan == null
				? null
				: {
					key: ContentHash.md5([FORMAT_TAG, engine, OracleDeclaration.oracleKey(oracle), scan.fingerprint].join('\n')),
					base: oracle.dir ?? Sys.getCwd(),
					hashed: scan.hashed
				};
		} ];
		#else
		return [ for (_ in oracles) null ];
		#end
	}

	/**
	 * The name, without extension, of `oracle`'s files: a hash of its hxml's file name and its defines, not of its directory, so
	 * the trees of one project share one record per configuration and the disk holds one dump per configuration however many
	 * trees ran; the key, which names the directory, keeps one tree from reading another's.
	 */
	private static function stem(oracle: OracleConfig): String {
		return 'apq-typed-facts-${ContentHash.md5([Path.withoutDirectory(oracle.hxml)].concat(oracle.defines).join(' '))}';
	}

	#if (sys || nodejs)
	/** `load`'s answer from the record at `path`; it may throw on a record of no shape the parser foresaw. */
	private static function loadFrom(path: String, key: TypedFactsKey): Null<TypedFactsStored> {
		final record: TypedFactsRecord = TypedFactsRecordParser.parse(File.getContent(path));
		if (record.format != FORMAT_TAG || record.key != key.key) return null;
		final configuration: Null<ReachConfiguration> = ReachBuildsCache.configurationOf(record.configuration);
		if (configuration == null) return null;
		final run: ProcessRun = record.verbose;
		return {
			digest: record.facts,
			ridden: {
				verbose: {
					status: run.status,
					out: run.out,
					err: run.err,
					failure: run.failure,
					overflowed: run.overflowed
				},
				configuration: configuration
			}
		};
	}

	/**
	 * Write `text` as `oracle`'s facts under `key`, the dump first and the record naming its md5 after, each staged under this
	 * process's name and renamed: a reader meets each file old or new and whole, and a record beside another run's dump misses.
	 */
	private static function write(oracle: OracleConfig, key: String, text: String, ridden: TypedFactsRidden): Void {
		final run: ProcessRun = ridden.verbose;
		// in the schema's key order, with no held null: the engine's writer spells it without the generated writer's copy
		final record: TypedFactsRecord = {
			format: FORMAT_TAG,
			key: key,
			facts: ContentHash.md5(text),
			verbose: {
				status: run.status ?? -1,
				out: run.out,
				err: run.err,
				failure: run.failure,
				overflowed: run.overflowed
			},
			configuration: ReachBuildsCache.recordOf(ridden.configuration)
		};
		try {
			final dump: String = TempScratch.slot(stem(oracle), '.jsonl.staged');
			File.saveContent(dump, text);
			sys.FileSystem.rename(dump, dumpFile(oracle));
			final staged: String = TempScratch.slot(stem(oracle), '.staged');
			File.saveContent(staged, haxe.Json.stringify(record)); // noqa: avoid-haxe-json
			sys.FileSystem.rename(staged, recordFile(oracle));
		} catch (exception: Exception) { // noqa: swallowed-exception
			// a record that cannot be written costs the next run a compile, never this run its answer
		}
	}
	#end

}
