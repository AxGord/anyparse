package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;

using Lambda;

/**
 * Every WRITE in a tree — each `RefShape.writeParentKinds` node: an assignment in every operator spelling, an
 * increment, a decrement — with the storage it writes named the way `Refs` binds a name, so a consumer asks "can this
 * write change the value that expression reads" by comparing two PATHS (`mayOverlap`).
 *
 * A path is a root key and the steps below it, joined by `.`: `<name>@<binding>` for the root identifier, binding
 * being `Refs.bindingAt`'s answer for it — the offset of the declaration it binds, a member declared in the file
 * included, or -1 for a name that binds nothing in the file (an inherited member, a type, an import) — then one step
 * per member access (its name) and per index access (`[]`, any element). `a.b[k].c` is `a@12.b.[].c`. A path rooted
 * at the self reference (`this.x`) is rooted at its first member under ANY binding (`x@*`): which declaration that
 * member is, the binder does not say. Parentheses and casts are transparent, so `(i) += 1`, `a.b = …`, `arr[k] = …`
 * and `cast(a, B).x = …` write `i`, `a.b`, `arr.[]` and `a.x` — where `Refs` classifies as `Write` only an identifier
 * sitting DIRECTLY at child 0 of a write node. A write inside a macro reification is code emitted, not run: none.
 *
 * POSITIVE: a target whose root is anything else (`f().x = …`, a cast) or a name the binder answers nothing for has a
 * NULL path, and a read whose operand the binder cannot name makes `readPaths` null. A consumer takes a null path as a
 * write of every operand and a null read list as an operand no write can be proven not to reach.
 */
@:nullSafety(Strict)
final class WriteSites {

	/** The binding half of a member root reached through the self reference: whichever declaration the member is. */
	private static inline final ANY_BINDING: String = '*';

	/** The step an index access adds: any element. */
	private static inline final ANY_ELEMENT: String = '[]';

	/**
	 * The path of the access chain `node` is — the storage a write target names, or the chain an expression reads;
	 * null when `node` is no access chain or its root cannot be named.
	 */
	public static inline function accessPath(node: QueryNode, tree: QueryNode, shape: RefShape): Null<String> {
		return pathOf(node, tree, shape, null);
	}

	/** Every write in `tree`, in pre-order. */
	public static function of(tree: QueryNode, shape: RefShape): Array<WriteSite> {
		final out: Array<WriteSite> = [];
		collect(tree, tree, shape, false, out);
		return out;
	}

	/**
	 * The paths of every value `expr` reads, in pre-order: each access chain rooted at an identifier (a braceless
	 * `$name` too) or at the self reference, at its longest. Null when the binder answers nothing for a root.
	 */
	public static function readPaths(expr: QueryNode, tree: QueryNode, shape: RefShape): Null<Array<String>> {
		final out: Array<String> = [];
		return collectReads(expr, tree, shape, out) ? out : null;
	}

	/**
	 * The binding half of a path's root: the offset of the declaration it binds; -1 for a name that binds nothing in
	 * the file and for a member reached through the self reference.
	 */
	public static function rootBinding(path: String): Int {
		final root: String = path.split('.')[0];
		return Std.parseInt(root.substr(root.lastIndexOf('@') + 1)) ?? -1;
	}

	/**
	 * Whether writing the storage at path `written` can change the value at path `read`: the two roots name the same
	 * storage — equal, or one a self-reference member (`x@*`) and the other the same name under any binding — and one
	 * path continues the other step for step, `[]` matching any step. A write BELOW what is read changes it (`a.b.c =`
	 * under a read of `a.b` passed whole), and so does one ABOVE it (`a.b =` under `a.b.c`); siblings (`a.x =` under
	 * `a.y`) do not. A local of the member's name read under `this.x`'s root is a collision this accepts: the direction
	 * that keeps a write.
	 *
	 * `reference`: the read takes the storage itself as its value — an expression that IS the chain — so a write below
	 * it changes what the value refers to, never the value: `a.b.c.d = …` leaves `a.b.c` the same reference.
	 */
	public static function mayOverlap(written: String, read: String, reference: Bool): Bool {
		final w: Array<String> = written.split('.');
		final r: Array<String> = read.split('.');
		if (!sameRoot(w[0], r[0]) || (reference && w.length > r.length)) return false;
		for (i in 1...(w.length < r.length ? w.length : r.length)) if (w[i] != r[i] && w[i] != ANY_ELEMENT && r[i] != ANY_ELEMENT)
			return false;
		return true;
	}

	/** Whether `node` is a root a path can start at: an identifier, the self reference alone included, or a braceless `$name`. */
	private static inline function isRoot(node: QueryNode, shape: RefShape): Bool {
		return node.kind == shape.identKind || node.kind == shape.stringInterpIdentKind;
	}

	/** Whether `node` is a cast in either spelling — the same object under another type. */
	private static inline function isCast(node: QueryNode, shape: RefShape): Bool {
		return node.kind == shape.uncheckedCastKind || (shape.typedCastKinds ?? []).contains(node.kind);
	}

	private static inline function joined(step: String, below: Null<String>): String {
		return below == null ? step : '$step.$below';
	}

	private static function sameRoot(a: String, b: String): Bool {
		if (a == b) return true;
		final at: Int = a.lastIndexOf('@');
		final bt: Int = b.lastIndexOf('@');
		return a.substr(0, at) == b.substr(0, bt) && (a.substr(at + 1) == ANY_BINDING || b.substr(bt + 1) == ANY_BINDING);
	}

	/**
	 * `of`'s walk. `emitted`: `node` sits in a macro reification (`RefShape.opaqueKinds`), which emits code rather than
	 * running it — a write there writes nothing here — until an interpolation (`interpolationKinds`) re-opens real code,
	 * the context `Refs` resolves in.
	 */
	private static function collect(node: QueryNode, tree: QueryNode, shape: RefShape, emitted: Bool, out: Array<WriteSite>): Void {
		final span: Null<Span> = node.span;
		if (!emitted && span != null && node.children.length > 0 && shape.writeParentKinds.contains(node.kind))
			out.push({ node: node, effect: span.to, path: accessPath(node.children[0], tree, shape) });
		final childEmitted: Bool = (shape.opaqueKinds ?? []).contains(node.kind)
			|| (emitted && !(shape.interpolationKinds ?? []).contains(node.kind));
		for (c in node.children) collect(c, tree, shape, childEmitted, out);
	}

	/** `readPaths`' walk: false as soon as one root has no key. An index access's own operands are reads of their own. */
	private static function collectReads(node: QueryNode, tree: QueryNode, shape: RefShape, out: Array<String>): Bool {
		final path: Null<String> = isChainHead(node, shape) ? pathOf(node, tree, shape, null) : null;
		if (path == null) return !isRoot(node, shape) && node.children.foreach(c -> collectReads(c, tree, shape, out));
		out.push(path);
		return indexOperandReads(node, tree, shape, out);
	}

	/** The reads of every index operand along the access chain `node` heads. */
	private static function indexOperandReads(node: QueryNode, tree: QueryNode, shape: RefShape, out: Array<String>): Bool {
		if (isRoot(node, shape) || node.children.length == 0) return true;
		if (node.kind == shape.indexAccessKind)
			for (i in 1...node.children.length)
				if (!collectReads(node.children[i], tree, shape, out)) return false;
		return indexOperandReads(node.children[0], tree, shape, out);
	}

	/**
	 * The path of the access chain `node` heads, `below` being the steps already taken above it; null when its root
	 * is no identifier or one the binder names nothing for.
	 */
	private static function pathOf(node: QueryNode, tree: QueryNode, shape: RefShape, below: Null<String>): Null<String> {
		if (isRoot(node, shape)) {
			final name: Null<String> = node.name;
			final span: Null<Span> = node.span;
			if (name == null || span == null) return null;
			// The self reference alone: nothing writes it.
			if (name == shape.selfReferenceText) return joined('$name@-1', below);
			final binding: Null<Int> = Refs.bindingAt(name, span.from, tree, shape);
			return binding == null ? null : joined('$name@$binding', below);
		}
		if (!isChainHead(node, shape) || node.children.length == 0) return null;
		// Parentheses and a cast are the value they hold — the operand is the last child (`TypedCastExpr` leads with its type).
		if (node.kind == shape.parenKind || isCast(node, shape)) return pathOf(node.children[node.children.length - 1], tree, shape, below);
		final inner: QueryNode = node.children[0];
		final memberName: Null<String> = node.name;
		return if (node.kind == shape.indexAccessKind)
			pathOf(inner, tree, shape, joined(ANY_ELEMENT, below))
		else if (memberName == null)
			null
		else if (inner.kind == shape.identKind && inner.name == shape.selfReferenceText)
			joined('$memberName@$ANY_BINDING', below)
		else
			pathOf(inner, tree, shape, joined(memberName, below));
	}

	/** Whether `node` can head an access chain: a root, a member or index access, parentheses. */
	private static function isChainHead(node: QueryNode, shape: RefShape): Bool {
		return isRoot(node, shape)
			|| node.kind == shape.indexAccessKind
			|| node.kind == shape.parenKind
			|| isCast(node, shape)
			|| ShapeVocab.memberAccessKinds(shape).contains(node.kind);
	}

}

/** One write: its node, where it takes effect, and the key of what it writes. */
typedef WriteSite = {

	/** The `RefShape.writeParentKinds` node. */
	final node: QueryNode;

	/** Where the write takes effect: the END of its node, since the right-hand side is read before the target is written. */
	final effect: Int;

	/** `WriteSites.targetPath` of its target — null when no path can name it, which a consumer reads as writing every operand. */
	final path: Null<String>;
};
