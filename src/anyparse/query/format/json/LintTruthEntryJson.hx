package anyparse.query.format.json;

/**
 * One labelled finding of a `LintTruthJson`: the key a report's finding matches it by — `family`, `function` (the
 * `member`; a Haxe keyword, so declared with `@:key`) and `subject`, as the finding's `data` spells them — its
 * `verdict` (`real-long`, `real-short`, `rare`, `false`, `dup-of`, `unknown`; `LintScore.VERDICTS`), the key of the
 * finding it duplicates (`dupOf`, for `dup-of` only), whether losing it must fail a scoring run (`recall`), the
 * evidence behind the verdict and a free note.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef LintTruthEntryJson = {

	var family: String;

	@:key('function') var member: String;

	var subject: String;

	var verdict: String;

	@:optional var dupOf: Null<String>;

	@:optional var recall: Null<Bool>;

	@:optional var evidence: Null<LintTruthEvidenceJson>;

	@:optional var note: Null<String>;
};
