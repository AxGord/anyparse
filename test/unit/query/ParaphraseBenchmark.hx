package unit.query;

/** A benchmark file under `test/probes`: its questions, how far down an owner may rank, and how many must find one. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef ParaphraseBenchmark = {
	var top: Int;
	var atLeast: Int;
	var questions: Array<ParaphrasedQuestion>;
};
