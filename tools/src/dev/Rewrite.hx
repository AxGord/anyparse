package dev;

/** One turn that rebuilt its whole context in the cache, the idle gap before it, and what the rebuild cost over a cache read. */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef Rewrite = {
	var agent: String;
	@:optional var slice: Null<String>;
	var model: String;
	var tokens: Int;
	var context: Int;
	var gapSeconds: Float;
	var extraCost: Float;
}
