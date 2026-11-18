package dev;

/** The mapping `wf-queue --add` takes for a filed lesson: `status` is set for a backlog line, `difficulty` for a pending one. */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef LessonRowJson = {

	var id: String;

	@:optional
	var status: String;

	@:optional
	var difficulty: Int;
	var kind: String;
	var priority: String;
	var touches: Array<String>;
	var text: String;

};
