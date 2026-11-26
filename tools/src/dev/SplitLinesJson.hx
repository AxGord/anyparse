package dev;

/** The document the queue CLI's batch add reads, `{"tasks": [<SplitLineJson>, …]}`: a delivered list is wrapped in it to be read. */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef SplitLinesJson = { var tasks: Array<SplitLineJson>; };
