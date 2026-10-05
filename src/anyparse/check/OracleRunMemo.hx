package anyparse.check;

import anyparse.check.HaxeSpawn.HaxeRun;
import anyparse.check.LintConfig.OracleConfig;

using Lambda;
using StringTools;

/**
 * What the compiler already answered in THIS run, so a compile of a tree the run has already compiled is not paid twice.
 *
 * One run asks the same question of the same tree more than once: every `--fix` phase measures its own baseline, a
 * phase's coverage probe compiles the tree its baseline just compiled, and a revert returns the tree to a state an
 * earlier compile already judged. A finished spawn is filed under its configuration, under whether it was the `-v`
 * compile (`OracleCoverage.probeArgs` — the typecheck plus a print flag, so its status IS the typecheck's) or the plain
 * one (`CompilerOracle.oracleArgs`, whose streams a rejection quotes), and under a CONTENT fingerprint of what it reads
 * (`fingerprints`), which hashes every path the run may write afresh. A configuration is answered only once a `-v`
 * compile showed it reads nothing outside the directories that fingerprint walks. A run is filed only when its input
 * hashed the same before and after the compile, and the memo never outlives the run: it hangs off the configurations the
 * lint command prepared for one run (`OracleConfig.runs`), since a verdict kept across runs is not sound for `--fix`
 * (`docs/decisions.md`).
 */
@:nullSafety(Strict)
final class OracleRunMemo {

	/**
	 * Whether this run answers a baseline from the persisted report-mode cache when it can (`OracleCache`), so a
	 * configuration that cache already answers is not compiled ahead of time.
	 */
	public final persisted: Bool;

	private final _runs: Map<String, HaxeRun> = [];

	/** The directories each configuration's fingerprint walked (`OracleCache.scanned`), by `OracleDeclaration.oracleKey`. */
	private final _roots: Map<String, Array<String>> = [];

	/** The configurations a `-v` compile of this run showed to read nothing outside the directories their fingerprint walked. */
	private final _seen: Array<String> = [];

	/** The configurations a `-v` compile of this run showed to read a file outside them — never answered from here. */
	private final _blind: Array<String> = [];

	/** Every path this run may write — its lint scope and every file it created — read afresh at each fingerprint. */
	private final _written: () -> Array<String>;

	public function new(persisted: Bool, written: () -> Array<String>) {
		this.persisted = persisted;
		_written = written;
	}

	/**
	 * The run filed for `oracle`'s `-v` (`verbose`) or plain compile of the input `fingerprint` names, or null. Null too
	 * for a configuration no `-v` compile of this run has shown to read only what its fingerprint sees (`file`): a source
	 * the fingerprint cannot see can change with no fingerprint changing.
	 */
	public function run(oracle: OracleConfig, verbose: Bool, fingerprint: Null<String>): Null<HaxeRun> {
		final config: String = OracleDeclaration.oracleKey(oracle);
		return fingerprint == null || !_seen.contains(config) || _blind.contains(config) ? null : _runs[key(oracle, verbose, fingerprint)];
	}

	/**
	 * Whether this memo holds either compile of `oracle` at `fingerprint` — what a caller compiling ahead of time asks
	 * before it spends a compile on a question already answered.
	 */
	public function holds(oracle: OracleConfig, fingerprint: Null<String>): Bool {
		return run(oracle, true, fingerprint) != null || run(oracle, false, fingerprint) != null;
	}

	/**
	 * File `run`, the `-v` (`verbose`) or plain compile of `oracle`, when it produced a status and its input hashed to
	 * `before` both before (`before`) and after (`after`) the compile: a tree that moved meanwhile produced a run about
	 * neither state. A cancelled run, or one that never started, is no answer and is never filed.
	 */
	public function file(oracle: OracleConfig, verbose: Bool, before: Null<String>, after: Null<String>, run: HaxeRun): Void {
		if (before == null || before != after || run.failure != '' || run.status == null || run.cancelled == true) return;
		if (verbose) judgeReads(oracle, run);
		_runs[key(oracle, verbose, before)] = run;
	}

	/**
	 * The fingerprint of each configuration of `oracles`, in order — null for one that is unavailable or cannot be
	 * fingerprinted, which the memo then neither answers nor files. It is `OracleCache.scanned`'s, joined with a hash of
	 * every path this run may write read NOW: the scan may reuse a library directory's hashes from earlier in the process,
	 * and a project whose sources arrive through `-lib` would then hash an edited file at its old content. A source every
	 * configuration reads is read once.
	 */
	public function fingerprints(oracles: Array<OracleConfig>): Array<Null<String>> {
		final contents: Map<String, String> = [];
		final walks: Map<String, Map<String, String>> = [];
		var written: Null<String> = null;
		return [
			for (oracle in oracles) {
				final scan: Null<{ fingerprint: String, roots: Array<String> }> = oracle.unavailable == null
					? OracleCache.scanned(oracle.hxml, oracle.dir, oracle.defines, contents, walks)
					: null;
				if (scan == null)
					null
				else {
					_roots[OracleDeclaration.oracleKey(oracle)] = scan.roots;
					written = written ?? writtenDigest(_written());
					OracleCache.md5('${scan.fingerprint}\n$written');
				}
			}
		];
	}

	/**
	 * Record what the successful `-v` compile `run` of `oracle` read: every `Parsed` file inside a directory its fingerprint
	 * walked makes the configuration answerable, one outside makes it blind for the rest of the run.
	 */
	private function judgeReads(oracle: OracleConfig, run: HaxeRun): Void {
		final config: String = OracleDeclaration.oracleKey(oracle);
		if (run.status != 0 || _blind.contains(config)) return;
		final base: String = oracle.dir ?? Sys.getCwd();
		final roots: Array<String> = [
			for (dir in _roots[config] ?? []) directoryPrefix(OracleCoverage.canonical(base, dir))
		];
		final read: Array<String> = OracleCoverage.parsedPaths(run.out);
		final inside: Bool = read.length > 0 && read.foreach(path -> {
			final file: String = OracleCoverage.canonical(base, path);
			roots.exists(dir -> file.startsWith(dir));
		});
		if (inside) {
			if (!_seen.contains(config)) _seen.push(config);
		} else
			_blind.push(config);
	}

	/** The memo the configurations of `oracles` carry, or null when none does — every configuration outside a lint run. */
	public static function of(oracles: Array<OracleConfig>): Null<OracleRunMemo> {
		for (oracle in oracles) {
			final memo: Null<OracleRunMemo> = oracle.runs;
			if (memo != null) return memo;
		}
		return null;
	}

	/** `oracles` carrying `memo`, every other field as it was — the configurations one run compiles with. */
	public static function attach(oracles: Array<OracleConfig>, memo: OracleRunMemo): Array<OracleConfig> {
		return [
			for (oracle in oracles) {
				// a copy of every field, so one added to `OracleConfig` later is carried without a line here
				final carried: OracleConfig = Reflect.copy(oracle) ?? throw 'a configuration could not be copied';
				carried.runs = memo;
				carried;
			}
		];
	}

	private static function key(oracle: OracleConfig, verbose: Bool, fingerprint: String): String {
		return '${verbose ? 'v' : 'p'}\n${OracleDeclaration.oracleKey(oracle)}\n$fingerprint';
	}

	/** `dir` with exactly one trailing separator, so a prefix test cannot match a sibling that merely shares its name's start. */
	private static function directoryPrefix(dir: String): String {
		return dir.endsWith('/') ? dir : '$dir/';
	}

	/** One hash over every path of `paths` and its content now — `absent` for one that does not exist. */
	private static function writtenDigest(paths: Array<String>): String {
		final sorted: Array<String> = paths.copy();
		sorted.sort(Reflect.compare);
		final lines: Array<String> = [
			for (path in sorted) {
				final text: Null<String> = try sys.io.File.getContent(path) catch (exception: haxe.Exception) null;
				'$path ${text == null ? 'absent' : OracleCache.md5(text)}';
			}
		];
		return OracleCache.md5(lines.join('\n'));
	}

}
