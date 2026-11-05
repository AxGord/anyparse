package anyparse.query.cli;

/** The generated parser of `BatchAnswers` — what `apq --batch` answers. Throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(anyparse.query.cli.BatchAnswers))
@:nullSafety(Strict)
class BatchAnswersParser {}
