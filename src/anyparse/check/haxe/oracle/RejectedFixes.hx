package anyparse.check.haxe.oracle;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.core.ContentHash;
import anyparse.util.Compare;

/**
 * The one answer to "did the compiler already reject exactly this edit of this file, under these builds' current
 * inputs, in an earlier run": a persisted, CONTENT-KEYED ledger of rejected `--fix` candidates, one file per project.
 *
 * A key is the file's path, the hash of its bytes before the edit and of its bytes after it, and — per build that
 * judged it — the build's identity and `OracleCache.inputsFingerprint`. A candidate that no build rejected, a changed
 * byte, a changed hxml, define, library or compiler is a miss, so a stale record can only withhold a fix, never apply
 * one. It does NOT see another source file: an edit rejected because of a caller elsewhere stays recorded after that
 * caller is repaired, until `forget` (`apq oracle` calls it) or a changed input drops it. Every doubt answers "not
 * recorded", and an unwritable temp dir costs a compile, never a verdict.
 *
 * It lives beside `OracleCache`'s verdict records in the OS temp dir, and is bounded: the oldest key goes past `MAX_RECORDED`.
 */
@:nullSafety(Strict)
final class RejectedFixes {

	private static inline final MAX_RECORDED: Int = 4096;
	private static final FORMAT_TAG: String = 'apq-rejected-fixes v1';

	/** Whether `oracles` rejected the edit that turns `before` into `after` in an earlier run, under their current inputs. */
	public static function recorded(oracles: Array<OracleConfig>, file: String, before: String, after: String): Bool {
		#if (sys || nodejs)
		final key: Null<String> = keyOf(oracles, file, before, after);
		return key != null && ledgers(oracles).filter(path -> !OracleCache.rejectedKeys(path).contains(key)).length == 0;
		#else
		return false;
		#end
	}

	/** Remember that `oracles` rejected the edit that turns `before` into `after`; nothing is kept when a build's inputs cannot be told. */
	public static function record(oracles: Array<OracleConfig>, file: String, before: String, after: String): Void {
		#if (sys || nodejs)
		final key: Null<String> = keyOf(oracles, file, before, after);
		if (key == null) return;
		for (path in ledgers(oracles)) {
			final kept: Array<String> = OracleCache.rejectedKeys(path);
			if (kept.contains(key)) continue;
			kept.push(key);
			OracleCache.storeRejectedKeys(path, kept.length > MAX_RECORDED ? kept.slice(kept.length - MAX_RECORDED) : kept);
		}
		#end
	}

	/** Drop every recorded rejection of this project — what a cold, observed typecheck makes of a remembered "no". */
	public static function forget(oracles: Array<OracleConfig>): Void {
		#if (sys || nodejs)
		for (path in ledgers(oracles)) OracleCache.dropRejectedKeys(path);
		#end
	}

	#if (sys || nodejs)
	/** The distinct project ledgers `oracles` belong to: a candidate is recorded in, and answered from, every one of them. */
	private static function ledgers(oracles: Array<OracleConfig>): Array<String> {
		final paths: Array<String> = oracles.map(OracleCache.rejectsFile);
		return [ for (i => path in paths) if (paths.indexOf(path) == i) path ];
	}

	private static function keyOf(oracles: Array<OracleConfig>, file: String, before: String, after: String): Null<String> {
		if (oracles.length == 0) return null;
		final builds: Array<String> = [];
		for (oracle in oracles) {
			final inputs: Null<String> = OracleCache.inputsFingerprint(oracle.hxml, oracle.dir, oracle.defines);
			if (inputs == null) return null;
			builds.push('${OracleDeclaration.oracleKey(oracle)}\n$inputs');
		}
		builds.sort(Compare.compareString);
		return ContentHash.md5([FORMAT_TAG, file, ContentHash.md5(before), ContentHash.md5(after)].concat(builds).join('\n'));
	}
	#end

}
