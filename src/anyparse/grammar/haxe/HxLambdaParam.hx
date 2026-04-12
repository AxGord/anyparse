package anyparse.grammar.haxe;

/**
 * A single parameter in a lambda expression (`=>`).
 *
 * Shape: `name` or `name : Type`.
 *
 * Unlike `HxParam` (function declaration parameters), the type
 * annotation is optional — lambda parameters rely on type inference
 * when the annotation is omitted.  Default values are deferred.
 */
@:peg
typedef HxLambdaParam = {
	var name:HxIdentLit;
	@:optional @:lead(':') var type:Null<HxTypeRef>;
}
