package anyparse.check.oracle;

/**
 * What one `haxe` spawn produced: its exit `status` (null when the process gave none),
 * its `out` and `err` streams, and — the fields that keep a non-verdict apart from a
 * verdict — `failure`, non-empty only when no exit status could be obtained at all, and
 * `overflowed`, which says the process RAN and out-wrote its buffer rather than never
 * having started.
 *
 * Folding the last two into a null status would make "no `haxe` on PATH" and "the
 * compiler out-wrote the output buffer" one sentence, and those send a reader to
 * opposite places. `out` / `err` are the PARTIAL streams in the overflow case, which is
 * what lets a caller still quote a failing build's errors.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef HaxeRun = {

	var ?status: Null<Int>;
	var out: String;
	var err: String;
	var failure: String;
	var overflowed: Bool;

	/** `runAll` under `stopAfterFailure` ended this job because an earlier one failed: no verdict, by design. */
	var ?cancelled: Bool;

	/** A cancelled job that never started — no process was spawned for it. */
	var ?unstarted: Bool;

}
