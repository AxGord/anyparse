package anyparse.core;

#if macro
import haxe.macro.Expr;

/**
 * Runtime contribution declared by a strategy: extra fields on the
 * generated `Parser` context, helper methods injected into the parser
 * class, and expressions contributing to the packrat cache key.
 *
 * Any strategy that needs per-parse state (the `Indent` strategy's
 * indent stack, the `Capture` strategy's named slots) declares it
 * here. The macro merges contributions from all registered strategies
 * into the final generated parser class.
 */
typedef RuntimeContrib = {
	ctxFields:Array<Field>,
	helpers:Array<Field>,
	cacheKeyContributors:Array<Expr>,
};
#end
