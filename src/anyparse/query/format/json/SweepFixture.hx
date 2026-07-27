package anyparse.query.format.json;

/**
 * One entry of a `SweepSnapshot.fixtures` array — the per-fixture status
 * `HxFormatterCorpusTest.printSweepDelta` records for `apq recon
 * --regression-probe` / `apq sweep --diff` to diff between two sweeps:
 *
 *   {"path": "whitespace/issue_195_macro_do_while.hxtest", "status": "PASS"}
 *
 * `path` is rooted at the fork (`test/testcases/<subdir>/<name>`);
 * `Cli.loadSweepFixtureStatus` strips the `test/testcases/` prefix before
 * keying its map. `status` is one of PASS / FAIL / SKIP_PARSE / SKIP_WRITE /
 * SKIP_CONFIG / MALFORMED, matching `runCategory`'s six outcomes.
 *
 * Both fields are `@:optional`: the writer always emits both, but the
 * consumer treats an entry missing either as "skip this entry" (its
 * pre-schema behaviour). A field present with the WRONG type (e.g. a
 * numeric `path`) is a schema violation the ByName parser cannot coerce
 * past — it throws, failing the WHOLE `fixtures` array parse rather than
 * skipping just that entry; both `Cli` callers catch that and fail soft
 * (null / empty map), which reads as "no baseline" — a stricter but still
 * non-crashing degradation than before.
 */
@:peg typedef SweepFixture = {

	@:optional var path: String;

	@:optional var status: String;
};
