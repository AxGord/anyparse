package dev;

/**
 * The document a worker or reviewer leaves in a slice's logs dir:
 * `{"lessons": [<LessonRecordJson>, …]}`. Read by `LessonRecordsJsonParser`.
 */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef LessonRecordsJson = { var lessons: Array<LessonRecordJson>; };
