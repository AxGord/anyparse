package anyparse.query;

import anyparse.runtime.TokenLog;

/**
 * The handle a `ParsedRootProvider` hands out for one parse: the grammar's root value and the literals that parse
 * matched and kept. They travel together because a run holds roots for many files at once (`CachingGrammarPlugin`), so a
 * log kept anywhere but beside its own root would answer for the wrong file.
 */
@:nullSafety(Strict)
final class ParsedRoot<T> {

	/** The grammar's root value, opaque to everyone but the plugin that parsed it. */
	public final value: T;

	/** The literals the parse matched (`NodeTokens.attach`); null for a parse that recorded none. */
	public final tokens: Null<TokenLog>;

	public function new(value: T, tokens: Null<TokenLog>) {
		this.value = value;
		this.tokens = tokens;
	}

}
