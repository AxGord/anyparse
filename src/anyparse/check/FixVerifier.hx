package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.CompilerOracle.OracleOutcome;
import anyparse.query.GrammarPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Outcome of a risky-fix verification pass. `baseline` is the typecheck of the
 * trusted (safe-only) state BEFORE any risky edit — verification proceeds only
 * when it is `Confirmed`, so a compile failure is always attributable to the
 * risky edit rather than to pre-existing breakage. `applied` lists the files
 * whose risky edit survived the compile; `reverted` lists the files whose risky
 * edit broke it (or could not be verified) and was rolled back to report-only.
 */
typedef FixVerifyResult = {
	var baseline: OracleOutcome;
	var applied: Array<String>;
	var reverted: Array<String>;
}

/**
 * Fix-verification for `RiskyFix` checks: the machinery behind the `compilerOracle`
 * key's promise that a rewrite/deletion is applied ONLY if it still compiles. It
 * assumes the safe (non-risky) fixes are already applied on disk, then for each
 * risky check and each file it applies that check's edits speculatively, writes the
 * candidate, runs the compiler oracle, and KEEPS it on `Confirmed` or REVERTS it
 * (restoring the pre-edit bytes on disk) otherwise — the report-only fallback.
 *
 * Rollback granularity is per-file × per-risky-check: one file's edits from one
 * check are the smallest speculatively-applied unit, and one compile verifies them.
 * Cost is O(riskyChecks × changedFiles) compiles, acceptable because risky checks
 * are opt-in and rare; finer bisection WITHIN a single (check, file) edit set is a
 * documented future refinement. Cross-file risky checks are out of scope — the
 * intended consumers (avoid-dynamic and other targeted rewrites) are single-file.
 *
 * Stateless and free of global mutable state (the invariant): all state is the
 * caller's `files`/disk plus locals; `write` is the caller's own file sink so the
 * verifier does no IO of its own beyond the oracle spawn.
 */
@:nullSafety(Strict)
final class FixVerifier {

	public static function verify(
		files: Array<{ file: String, source: String }>, riskyChecks: Array<Check>, plugin: GrammarPlugin, oracleHxml: String,
		oracleDir: Null<String>, write: (String, String) -> Void, ?optsByFile: Map<String, Null<String>>
	): FixVerifyResult {
		final applied: Array<String> = [];
		final reverted: Array<String> = [];
		final baseline: OracleOutcome = CompilerOracle.typecheck(oracleHxml, oracleDir);
		switch baseline {
			case Confirmed:
			case Rejected(_) | Unavailable(_):
				return { baseline: baseline, applied: applied, reverted: reverted };
		}
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		for (check in riskyChecks) for (entry in files) {
			final own: Array<Violation> = check.run([{ file: entry.file, source: entry.source }], plugin).filter(v -> v.rule == check.id());
			if (own.length == 0) continue;
			final edits: Array<{ span: Span, text: String }> = check.fix(entry.source, own, plugin, index);
			if (edits.length == 0) continue;
			final opts: Null<String> = optsByFile == null ? null : optsByFile[entry.file];
			switch RefactorSupport.canonicalize(entry.source, edits, false, plugin, opts) {
				case Ok(text) if (text != entry.source):
					final before: String = entry.source;
					entry.source = text;
					write(entry.file, text);
					switch CompilerOracle.typecheck(oracleHxml, oracleDir) {
						case Confirmed:
							applied.push(entry.file);
						case Rejected(_) | Unavailable(_):
							entry.source = before;
							write(entry.file, before);
							reverted.push(entry.file);
					}
				case _:
			}
		}
		return { baseline: baseline, applied: applied, reverted: reverted };
	}

}
