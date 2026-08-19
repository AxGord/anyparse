package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;

/**
 * The NO-NULL-VALUE proof `redundant-map-exists` must clear before it will rewrite
 * `m.exists(k) ? m[k] : d` into `m[k] ?? d`.
 *
 * ## Why a proof is needed at all
 *
 * The two forms diverge on exactly one input: a key PRESENT in the map whose stored VALUE
 * is null. The `exists` ternary answers that key's stored `null`; `??` answers the default.
 * So the rewrite is licensed only where no null value can ever be in the map.
 *
 * ## The proof is an OCCURRENCE census, not a write scan
 *
 * `prefer-final-field` asks "is this field written anywhere else". Here the question is
 * "can a null VALUE reach this map", and a map's contents can also change through a
 * reference that ESCAPED — `g(m)` hands the callee the same object, which may then store a
 * null through it. So the census is a POSITIVE whitelist over EVERY occurrence of the name,
 * never a negative list of write shapes: an occurrence is safe only in one of the six slots
 * below, and everything else — an argument position, a return, a second binding, a field of
 * another object, a name the grammar gives to some other node — fails the proof. Enumerating
 * what the rewrite BUYS rather than what it must avoid is what keeps a shape nobody has
 * thought of from leaking through.
 *
 * The six safe slots:
 *
 * 1. The DECLARATION itself, with no initializer or with one that is a proven map expression.
 * 2. Receiver of an index READ — `m[k]` that is not the left side of an assignment.
 * 3. Receiver of an index WRITE `m[k] = v` whose value is proven non-null.
 * 4. Receiver of a Map member call: one of the members that can only read or REMOVE (`get`,
 *    `exists`, `keys`, `iterator`, `keyValueIterator`, `remove`, `clear`, `toString`,
 *    `copy` — none of them stores a value), or `set(k, v)` with a proven non-null value.
 * 5. The iterable slot of a `for` loop.
 * 6. The left side of a whole-map assignment whose right side is a proven map expression.
 *
 * A VALUE is proven non-null only when it is a literal that cannot be null — a string /
 * numeric / bool literal, an array / object literal, or a construction. An identifier, a
 * call result, a ternary and a `??` are all left unproven, and the proof fails closed.
 * A map EXPRESSION is proven only as an argument-less construction (`new Map()`) or as a
 * map literal every one of whose entries carries a proven non-null value; an empty `[]`
 * qualifies trivially.
 *
 * ## Scope
 *
 * The census runs over the RESOLUTION scope, falling back to the report scope — the same
 * contract `prefer-final-field` documents: run over a narrower set than the whole project
 * and a writer outside it is invisible. A file that mentions the name and fails to parse,
 * or that carries a `@:build` / `@:autoBuild` macro able to synthesize an unseen write,
 * fails the proof rather than being skipped. A file whose text does not mention the name at
 * all is skipped without parsing, which is what keeps the census cheap.
 */
@:nullSafety(Strict)
final class MapValueScan {

	/**
	 * The Map members that can only READ or REMOVE — none of them stores a value, so a
	 * receiver occurrence under any of them cannot introduce a null.
	 */
	private static final READ_ONLY_METHODS: Array<String> = [
		'get',
		'exists',
		'keys',
		'iterator',
		'keyValueIterator',
		'remove',
		'clear',
		'toString',
		'copy'
	];

	/** The one Map member that STORES a value — `m.set(k, v)`, whose value needs the non-null proof. */
	private static inline final SET_METHOD: String = 'set';

	/** `set(key, value)` plus the callee child: the exact child count of a storing call. */
	private static inline final SET_CALL_CHILDREN: Int = 3;

	/** A binary assignment has [target, value]. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	/** A map-literal entry has [key, value]. */
	private static inline final ENTRY_CHILD_COUNT: Int = 2;

	/** The build-macro metadata whose generated members no source scan can see. */
	private static final BUILD_MACRO_METAS: Array<String> = ['@:build', '@:autoBuild'];

	/**
	 * The seams the census reads, or null when the grammar leaves a required one unset — in
	 * which case no proof is available and the check reports without fixing.
	 */
	public static function seamsOf(shape: RefShape): Null<ValueSeams> {
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (fieldAccessKind == null) return null;
		final callKind: Null<String> = shape.callKind;
		if (callKind == null) return null;
		final indexAccessKind: Null<String> = shape.indexAccessKind;
		if (indexAccessKind == null) return null;
		final assignKind: Null<String> = shape.assignKind;
		if (assignKind == null) return null;
		final arrayLiteralKind: Null<String> = shape.arrayLiteralKind;
		if (arrayLiteralKind == null) return null;
		final nonNullLiteralKinds: Array<String> = (shape.stringLiteralKinds ?? []).concat(shape.numericLiteralKinds ?? []);
		for (k in [(shape.boolLitKind: Null<String>), shape.objectLiteralKind, shape.newExprKind]) if (k != null)
			nonNullLiteralKinds.push(k);
		nonNullLiteralKinds.push(arrayLiteralKind);
		return {
			identKind: shape.identKind,
			fieldAccessKind: fieldAccessKind,
			callKind: callKind,
			indexAccessKind: indexAccessKind,
			assignKind: assignKind,
			arrayLiteralKind: arrayLiteralKind,
			parenKind: shape.parenKind,
			newExprKind: shape.newExprKind,
			mapLiteralEntryKind: shape.mapLiteralEntryKind,
			declKinds: (shape.fieldDeclKinds ?? []).concat(shape.localDeclKinds ?? []),
			paramKinds: shape.paramKinds ?? [],
			iterationKinds: shape.iterationBindingKinds ?? [],
			writeParentKinds: shape.writeParentKinds,
			typeAnnotationKinds: shape.typeAnnotationKinds ?? [],
			nonNullLiteralKinds: nonNullLiteralKinds
		};
	}

	/**
	 * Whether every occurrence of `name` across `index`'s files proves the map it binds can
	 * never hold a null VALUE. A source the index cannot produce, one that mentions the name
	 * and does not parse, and one carrying a build macro all answer false.
	 */
	public static function provenNonNullValues(name: String, index: SymbolIndex, plugin: GrammarPlugin, seams: ValueSeams): Bool {
		for (info in index.allFiles()) {
			final source: Null<String> = index.sourceOf(info.file);
			if (source == null) return false;
			final src: String = source;
			if (src.indexOf(name) < 0) continue;
			for (meta in BUILD_MACRO_METAS) if (src.indexOf(meta) >= 0) return false;
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, src);
			if (tree == null) return false;
			if (!subtreeSafe(tree, null, -1, null, -1, name, seams)) return false;
		}
		return true;
	}

	/**
	 * Whether every occurrence of `name` in `node`'s subtree sits in a safe slot. `parent` /
	 * `parentSlot` and `grand` / `grandSlot` carry the two ancestor levels the classification
	 * needs — a receiver's meaning is decided by its parent AND by what that parent is used
	 * for (`m.set` is a field access under a call; `m[k]` is an index access that may be an
	 * assignment target).
	 */
	private static function subtreeSafe(
		node: QueryNode, parent: Null<QueryNode>, parentSlot: Int, grand: Null<QueryNode>, grandSlot: Int, name: String, seams: ValueSeams
	): Bool {
		if (node.name == name && !occurrenceSafe(node, parent, parentSlot, grand, grandSlot, seams)) return false;
		for (i in 0...node.children.length) if (!subtreeSafe(node.children[i], node, i, parent, parentSlot, name, seams)) return false;
		return true;
	}

	/** Whether the single occurrence `node` sits in one of the six safe slots. */
	private static function occurrenceSafe(
		node: QueryNode, parent: Null<QueryNode>, parentSlot: Int, grand: Null<QueryNode>, grandSlot: Int, seams: ValueSeams
	): Bool {
		// Slot 1 — the declaration. A parameter is deliberately NOT one: the map then comes
		// from a caller the census cannot see.
		if (seams.declKinds.contains(node.kind))
			return node.children.length == 0 || (node.children.length == 1 && provenMapExpr(node.children[0], seams));
		if (seams.paramKinds.contains(node.kind)) return false;
		// Any OTHER node the grammar happens to name the same — a method, a loop binder, a
		// type — is a shadow or an unrelated declaration, and fails closed.
		if (node.kind != seams.identKind && node.kind != seams.fieldAccessKind) return false;
		if (parent == null) return false;
		final p: QueryNode = parent;
		// Slots 2 and 3 — index read, index write.
		if (p.kind == seams.indexAccessKind && parentSlot == 0) {
			if (grand == null) return true;
			final g: QueryNode = grand;
			if (g.kind == seams.assignKind && grandSlot == 0)
				return g.children.length == ASSIGN_CHILD_COUNT && provenNonNullValue(g.children[1], seams);
			// A compound assignment or an increment READS the stored value and writes back a
			// derived one, which no literal gate can prove non-null.
			return !seams.writeParentKinds.contains(g.kind);
		}
		// Slot 4 — a member call.
		if (p.kind == seams.fieldAccessKind && parentSlot == 0 && grand != null && grand.kind == seams.callKind && grandSlot == 0) {
			final method: Null<String> = p.name;
			if (method == null) return false;
			if (READ_ONLY_METHODS.contains(method)) return true;
			final g: QueryNode = grand;
			return method == SET_METHOD && g.children.length == SET_CALL_CHILDREN && provenNonNullValue(g.children[2], seams);
		}
		// Slot 5 — the iterable of a `for`. It is the child right before the body, since a
		// key-value binder occupies a slot of its own that a plain binder does not.
		if (seams.iterationKinds.contains(p.kind)) return parentSlot == p.children.length - 2;
		// Slot 6 — a whole-map assignment.
		if (p.kind == seams.assignKind && parentSlot == 0)
			return p.children.length == ASSIGN_CHILD_COUNT && provenMapExpr(p.children[1], seams);
		return false;
	}

	/**
	 * Whether `expr` builds a map that provably holds no null value — an argument-less
	 * construction, or a map literal every entry of which carries a proven non-null value.
	 * An empty literal qualifies trivially; a construction taking VALUE arguments does not,
	 * since those could carry an existing map's contents.
	 */
	private static function provenMapExpr(expr: QueryNode, seams: ValueSeams): Bool {
		final node: QueryNode = RefactorSupport.unwrapParens(expr, seams.parenKind);
		if (node.kind == seams.newExprKind) {
			for (c in node.children) if (!seams.typeAnnotationKinds.contains(c.kind)) return false;
			return true;
		}
		if (node.kind != seams.arrayLiteralKind) return false;
		final entryKind: Null<String> = seams.mapLiteralEntryKind;
		for (c in node.children) {
			if (entryKind == null || c.kind != entryKind || c.children.length != ENTRY_CHILD_COUNT) return false;
			if (!provenNonNullValue(c.children[1], seams)) return false;
		}
		return true;
	}

	/** Whether `expr` is a literal form that cannot evaluate to null. */
	private static function provenNonNullValue(expr: QueryNode, seams: ValueSeams): Bool {
		return seams.nonNullLiteralKinds.contains(RefactorSupport.unwrapParens(expr, seams.parenKind).kind);
	}

}

/** The grammar seams the no-null-value census reads. */
typedef ValueSeams = {
	final identKind: String;
	final fieldAccessKind: String;
	final callKind: String;
	final indexAccessKind: String;
	final assignKind: String;
	final arrayLiteralKind: String;
	final parenKind: Null<String>;
	final newExprKind: Null<String>;
	final mapLiteralEntryKind: Null<String>;
	final declKinds: Array<String>;
	final paramKinds: Array<String>;
	final iterationKinds: Array<String>;
	final writeParentKinds: Array<String>;
	final typeAnnotationKinds: Array<String>;
	final nonNullLiteralKinds: Array<String>;
};
