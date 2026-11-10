package dev;

/** A tree no slice may write, and the digest of its `git diff` at the baseline. */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef FrozenTree = {
	var dir: String;
	var digest: String;
}
