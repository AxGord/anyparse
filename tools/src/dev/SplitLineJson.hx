package dev;

/**
 * One queue line a split delivers, in the task shape the queue CLI's batch add takes. `difficulty` is optional here so a
 * missing one is `SplitApply`'s refusal with the line named, not a parse error of the whole list.
 */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef SplitLineJson = {

	var id: String;

	@:optional
	var difficulty: Int;

	@:optional
	var kind: String;

	@:optional
	var priority: String;
	var touches: Array<String>;

	@:optional
	var owner: String;

	@:optional
	var after: Array<String>;
	var text: String;

};
