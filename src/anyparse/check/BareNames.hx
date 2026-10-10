package anyparse.check;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;

/**
 * Which declaration a bare name read in a function body means, as far as the body's own text decides it. A positive
 * whitelist: a name means a declaration of the body only where nothing else in the body declares it, and a parameter
 * keeps the value a call hands it only where no other node of the body binds its name (a local, a loop binder, a
 * `catch` variable, a nested function's parameter, a case capture) and nothing writes it. Any other shape answers "not
 * known", never a guess at which binding wins.
 */
@:nullSafety(Strict)
final class BareNames {

	/**
	 * The nodes of `node`'s subtree carrying `name` that are no plain read of it: every declaration-like node, an access
	 * of a field so named, an object literal's field so named and a name a string interpolates (`$name`) excepted.
	 */
	public static function collectNamed(node: QueryNode, name: String, shape: RefShape, into: Array<QueryNode>): Void {
		// a bare name in a case pattern captures: it declares a new binding
		if (node.kind == shape.caseBranchKind && node.children.length > 0 && readsName(node.children[0], name, shape)) into.push(node);
		for (k in node.children) {
			if (
				k.name == name && k.kind != shape.identKind && k.kind != shape.stringInterpIdentKind && k.kind != shape.objectFieldKind
				&& !isAccess(k.kind, shape)
			)
				into.push(k);
			collectNamed(k, name, shape, into);
		}
	}

	/**
	 * Whether the parameter `param` of the function node `fn` keeps the value a call hands it throughout the body: no
	 * other node of the body declares its name and no write targets it.
	 */
	public static function stable(fn: QueryNode, param: QueryNode, shape: RefShape): Bool {
		final name: Null<String> = param.name;
		if (name == null) return false;
		final named: Array<QueryNode> = [];
		collectNamed(fn, name, shape, named);
		return named.length == 1 && named[0] == param && !writes(fn, name, shape);
	}

	/** Whether nothing in the function node `fn` declares `name`: a bare read of it there means no binding of the body. */
	public static function bindsNothing(fn: QueryNode, name: String, shape: RefShape): Bool {
		final named: Array<QueryNode> = [];
		collectNamed(fn, name, shape, named);
		return named.length == 0;
	}

	/**
	 * The local declaration the bare read `read` in the function node `fn` means: the one node of the body declaring its
	 * name, a statement of a block (`sequenceKinds`) on the way from `fn` down to `read` that ends before `read` starts.
	 * Null for any other shape: several declarations, one in a block the read is outside of (a nested function's, an
	 * inner block's), one after the read.
	 */
	public static function localOf(fn: QueryNode, read: QueryNode, shape: RefShape, sequenceKinds: Array<String>): Null<QueryNode> {
		final name: Null<String> = read.name;
		final at: Null<Span> = read.span;
		if (read.kind != shape.identKind || name == null || at == null) return null;
		final named: Array<QueryNode> = [];
		collectNamed(fn, name, shape, named);
		if (named.length != 1) return null;
		final decl: QueryNode = named[0];
		final declSpan: Null<Span> = decl.span;
		var node: Null<QueryNode> = fn;
		while (node != null) {
			if (sequenceKinds.contains(node.kind) && node.children.contains(decl))
				return declSpan != null && declSpan.to <= at.from ? decl : null;
			node = node.children.find(c -> c.span != null && c.span.from <= at.from && c.span.to >= at.to);
		}
		return null;
	}

	/** Whether something in `node`'s subtree writes the identifier `name`: an assignment to it, an increment. */
	public static function writes(node: QueryNode, name: String, shape: RefShape): Bool {
		final kids: Array<QueryNode> = node.children;
		return shape.writeParentKinds.contains(node.kind) && kids.length > 0 && kids[0].kind == shape.identKind && kids[0].name == name
			|| kids.exists(k -> writes(k, name, shape));
	}

	private static inline function isAccess(kind: String, shape: RefShape): Bool {
		return kind == shape.fieldAccessKind || kind == shape.nullSafeAccessKind || kind == shape.forceFieldAccessKind;
	}

	/** Whether `node`'s subtree holds the identifier `name`. */
	private static function readsName(node: QueryNode, name: String, shape: RefShape): Bool {
		return node.kind == shape.identKind && node.name == name || node.children.exists(k -> readsName(k, name, shape));
	}

}
