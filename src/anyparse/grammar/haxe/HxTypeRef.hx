package anyparse.grammar.haxe;

/**
 * Type reference in the Haxe grammar skeleton.
 *
 * Phase 3 slice carries a single identifier — enough to cover `Int`,
 * `Void`, `String`, `Bool`, `Float`, and user-defined class names.
 * Type parameters (`Array<T>`), module paths (`pkg.Type`), function
 * types (`Int -> Void`), and anonymous structure types are deferred to
 * later Phase 3 milestones.
 */
@:peg
typedef HxTypeRef = {
	var name:HxIdentLit;
}
