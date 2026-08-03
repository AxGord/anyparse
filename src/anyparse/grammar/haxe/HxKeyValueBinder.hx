package anyparse.grammar.haxe;

/**
 * The VALUE binder of a key-value iteration — the `v` in
 * `for (k => v in m)` — shared by `HxForStmt.valueName` and
 * `HxForExpr.valueName`.
 *
 * A one-field wrapper around the identifier terminal, existing solely so
 * `@:spanned('KeyValueBinder')` can make the binder an ADDRESSABLE
 * `QueryNode` carrying its own name and span. The bare
 * `Null<HxIdentLit>` slot it replaces parsed fine but projected NOTHING:
 * `for (k => v in m)` surfaced as `(ForStmt k (IdentExpr m) …)`, so `v`
 * existed nowhere in the tree — `refs` could not resolve its uses,
 * `rename` could not address it, and every declaration-walking check was
 * blind to it. Exactly the `HxVarMore` lift, one construct over.
 *
 * The `=>` literal stays on the PARENT field
 * (`@:optional @:lead('=>')`) instead of moving in here: the
 * optional-single-Ref commit peek reads the parent's lead, and leaving
 * it there makes this node's span the bare identifier — which is what a
 * decl hit and a rename edit want to address.
 *
 * The field is called `name` so `QueryWalkerLowering.NAME_STRING_SLOTS`
 * lifts it with no new slot. The loop's own `varName` keeps naming the
 * KEY binder, so `node.name` on `ForStmt` / `ForExpr` is unchanged for
 * every existing consumer; the value binder arrives as an extra FIRST
 * child, ahead of the iterable (`RefShape.iterationValueBinderKinds`
 * publishes the kind so a consumer can skip past it).
 */
@:peg
@:spanned('KeyValueBinder')
typedef HxKeyValueBinder = {
	var name: HxIdentLit;
};
