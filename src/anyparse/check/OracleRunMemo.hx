package anyparse.check;

import anyparse.check.HaxeSpawn.HaxeRun;
import anyparse.check.LintConfig.OracleConfig;

/**
 * What the compiler already answered in THIS run, so a compile of a tree the run has already compiled is not paid twice.
 *
 * One run asks the same question of the same tree more than once: every `--fix` phase measures its own baseline, a
 * phase's coverage probe compiles the tree its baseline just compiled, and a revert returns the tree to a state an
 * earlier compile already judged. A finished spawn is filed under its configuration, under whether it was the `-v`
 * compile (`OracleCoverage.probeArgs` — the typecheck plus a print flag, so its status IS the typecheck's) or the plain
 * one (`CompilerOracle.oracleArgs`, whose streams a rejection quotes), and under the CONTENT fingerprint of everything
 * that compile reads (`OracleCache.fingerprint`). It is filed only when that input hashed the same before and after the
 * compile, and it never outlives the run: the memo hangs off the configurations the lint command prepared for one run
 * (`OracleConfig.runs`), since a verdict kept across runs is not sound for `--fix` (`docs/decisions.md`).
 */
@:nullSafety(Strict)
final class OracleRunMemo {

	/**
	 * Whether this run answers a baseline from the persisted report-mode cache when it can (`OracleCache`), so a
	 * configuration that cache already answers is not compiled ahead of time.
	 */
	public final persisted: Bool;

	private final _runs: Map<String, HaxeRun> = [];

	public function new(persisted: Bool) {
		this.persisted = persisted;
	}

	/** The run filed for `oracle`'s `-v` (`verbose`) or plain compile of the input `fingerprint` names, or null. */
	public function run(oracle: OracleConfig, verbose: Bool, fingerprint: Null<String>): Null<HaxeRun> {
		return fingerprint == null ? null : _runs[key(oracle, verbose, fingerprint)];
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
		_runs[key(oracle, verbose, before)] = run;
	}

	/** The memo the configurations of `oracles` carry, or null when none does — every configuration outside a lint run. */
	public static function of(oracles: Array<OracleConfig>): Null<OracleRunMemo> {
		for (oracle in oracles) {
			final memo: Null<OracleRunMemo> = oracle.runs;
			if (memo != null) return memo;
		}
		return null;
	}

	/**
	 * The content fingerprint of each configuration of `oracles`, in order — null for one that is unavailable or cannot
	 * be fingerprinted, which the memo then neither answers nor files. A source every configuration reads is read once.
	 */
	public static function fingerprints(oracles: Array<OracleConfig>): Array<Null<String>> {
		final contents: Map<String, String> = [];
		return [
			for (oracle in oracles) oracle.unavailable == null
				? OracleCache.fingerprint(oracle.hxml, oracle.dir, oracle.defines, contents)
				: null
		];
	}

	/** `oracles` carrying `memo`, every other field as it was — the configurations one run compiles with. */
	public static function attach(oracles: Array<OracleConfig>, memo: OracleRunMemo): Array<OracleConfig> {
		return [
			for (oracle in oracles) {
				final carried: OracleConfig = {
					hxml: oracle.hxml,
					dir: oracle.dir,
					defines: oracle.defines,
					runs: memo
				};
				if (oracle.generate != null) carried.generate = oracle.generate;
				if (oracle.unavailable != null) carried.unavailable = oracle.unavailable;
				if (oracle.raced != null) carried.raced = oracle.raced;
				carried;
			}
		];
	}

	private static function key(oracle: OracleConfig, verbose: Bool, fingerprint: String): String {
		return '${verbose ? 'v' : 'p'}\n${LintConfig.oracleKey(oracle)}\n$fingerprint';
	}

}
