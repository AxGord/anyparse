package anyparse.grammar.haxe;

/**
 * What `HaxeFormatConfigDiagnostics.diagnose` found in one
 * `hxformat.json`: the settings hxq will not act on, split by what
 * ignoring them costs.
 *
 * The two groups are reported separately because their consequences
 * differ. An unimplemented KEY simply does nothing — the config states
 * a preference and the writer never reads it. An unimplemented wrap
 * VALUE is worse: `HaxeFormatConfigLoader.wrapRuleFromConfig` drops the
 * whole rule that names it, so the cascade falls through to a different
 * rule and the construct lays out by a policy nobody wrote down.
 *
 * Both arrays are already formatted for display and carry no positions
 * of their own — a key phrase embeds its own `(l.N)` and a wrap phrase
 * embeds the offending string, which is what an author greps for.
 */
typedef HaxeFormatConfigIssues = {

	/** Keys with no schema field, in document order: `name (l.N)`, plus `did you mean` when one is close. */
	keys: Array<String>,

	/** Wrap-cascade strings with no runtime mapping, deduplicated and quoted. */
	wrapValues: Array<String>
};
