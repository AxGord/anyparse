package anyparse.query.format.json;

/**
 * Declarative schema for `bin/.last-sweep.json` / `.prev-sweep.json`,
 * written by `HxFormatterCorpusTest.printSweepDelta` and read by
 * `Cli.loadSweepJson` / `Cli.loadSweepFixtureStatus`. Parsed by the
 * macro-generated `SweepSnapshotParser` (ByName struct lowering).
 *
 * The writer always emits all seven keys below in one `haxe.Json.stringify`
 * call, but the two readers each need only part of the shape:
 * `loadSweepJson` reads the six int totals and ignores `fixtures`;
 * `loadSweepFixtureStatus` reads only `fixtures` and ignores the totals.
 * Every field is `@:optional` so either reader can parse the same root
 * regardless of which half it needs — an absent key degrades to null per
 * field rather than failing the whole parse. `loadSweepJson` additionally
 * requires `pass`/`fail`/`skipParse` to be present (its historical "trio"
 * contract, checked post-parse); the other three ints default to 0 when
 * absent, matching the pre-schema Reflect-based reader.
 */
@:peg @:schema(anyparse.format.text.JsonFormat) @:ws
typedef SweepSnapshot = {

	@:optional var pass: Int;

	@:optional var fail: Int;

	@:optional var skipParse: Int;

	@:optional var skipWrite: Int;

	@:optional var skipConfig: Int;

	@:optional var skipMalformed: Int;

	@:optional var fixtures: Array<SweepFixture>;
};
