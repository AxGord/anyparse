package anyparse.query;

/**
 * Optional capability a `GrammarPlugin` may ALSO implement to answer what a type
 * annotation's SOURCE TEXT says about the function it denotes. The simplified
 * `QueryNode` projection carries no parameter types at all, and
 * `TypeInfoProvider.declaredTypeSources` hands the annotation back verbatim, so a
 * consumer that needs the SHAPE of a function type has nothing but that text — and
 * reading it is grammar knowledge, which belongs to the plugin rather than to a
 * check. A grammar that does not implement this leaves every function type unread,
 * so consumers `Std.downcast` to it and refuse for want of evidence when it is
 * absent — never required of a plugin.
 *
 * A capability is only as reachable as its FORWARDING. Every check the CLI runs is handed
 * `CachingGrammarPlugin`, not the grammar itself, so a capability that wrapper does not implement
 * reads as absent to every consumer while a direct unit-test call sees it fine — the failure is a
 * silent refusal, not an error. Adding one here means adding it there too.
 */
@:nullSafety(Strict)
interface FunctionTypeProvider {

	/**
	 * How many parameters the function type spelled by `typeSource` takes, or null
	 * when the question has no safe answer: the annotation is not a function type,
	 * or it is one whose parameter list a VALUE of that type cannot reproduce
	 * positionally.
	 *
	 * The null on an optional / rest parameter is the contract's point rather than
	 * caution. Haxe refuses `(?Int) -> Void` where `() -> Void` is expected, and
	 * `(Int, ?Int) -> Void` where `(Int) -> Void` is (both measured on 4.3), so a
	 * consumer that reduced a wrapper lambda to such a value would emit code the
	 * compiler rejects. An arity comes back only for a parameter list that is
	 * positionally exact, and every other shape answers null.
	 */
	public function functionTypeArity(typeSource: String): Null<Int>;

}
