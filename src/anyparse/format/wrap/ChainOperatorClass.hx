package anyparse.format.wrap;

/**
 * The operator class of a binary-op chain's TOP-LEVEL separators, as `WrapList.topLevelOperatorClass` reads it off
 * the chain's rendered `Doc`: the one answer to "which operator family does this chain Doc join its operands with?".
 */
enum ChainOperatorClass {

	/** `+` / `-` (opAddSub). */
	OpAddSub;

	/** `||` / `&&` (opBool). */
	OpBool;

	/** A ternary's `?` / `:`. */
	OpTernary;

}
