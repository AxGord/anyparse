package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.MemberWriteScan;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

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

	/** The one Map member that STORES a value — `m.set(k, v)`, whose value needs the non-null proof. */
	private static inline final SET_METHOD: String = 'set';

	/** `set(key, value)` plus the callee child: the exact child count of a storing call. */
	private static inline final SET_CALL_CHILDREN: Int = 3;

	/** A binary assignment has [target, value]. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	/** A map-literal entry has [key, value]. */
	private static inline final ENTRY_CHILD_COUNT: Int = 2;

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
			containerKinds: shape.visibilityContainerKinds ?? [],
			memberDeclKinds: shape.memberDeclKinds ?? [],
			publicModifierKind: shape.publicModifierKind,
			paramKinds: shape.paramKinds ?? [],
			iterationKinds: shape.iterationBindingKinds ?? [],
			writeParentKinds: shape.writeParentKinds,
			typeAnnotationKinds: shape.typeAnnotationKinds ?? [],
			nonNullLiteralKinds: nonNullLiteralKinds
		};
	}

	/**
	 * Whether the map named `name` and declared at offset `bindingFrom` of `source` can be
	 * proven never to hold a null VALUE.
	 *
	 * The census is OWNER-scoped, not name-scoped, and that distinction is load-bearing: a
	 * walk over every file that merely MENTIONS the name reads a same-named binding in an
	 * unrelated type — or in the standard library, which the resolution scope always carries
	 * — as evidence against this map. Measured over ten realistic map field names, the
	 * name-scoped form refused five of them (`cache`, `values`, `index`, `map`, `data`) on
	 * nothing but a std-library collision, while reporting a message about a stored null
	 * value. So the reachable set is derived instead: a LOCAL is visible only in its own
	 * file, and a non-public member only in its declaring file, its subtypes and an
	 * `@:access` grantee — the same three doors `prefer-final-field` closes.
	 */
	public static function proven(
		name: String, bindingFrom: Int, source: String, root: QueryNode, index: Null<SymbolIndex>, plugin: GrammarPlugin, seams: ValueSeams
	): Bool {
		if (MemberWriteScan.carriesBuildMacro(source)) return false;
		final decl: Null<Decl> = locate(root, null, -1, null, bindingFrom, seams);
		if (decl == null) return false;
		if (!subtreeSafe(root, null, -1, null, -1, name, 0, source.length, seams)) return false;
		final owner: Null<String> = decl.owner;
		// A local is unreachable outside the file just censused; a member needs the three
		// cross-file doors closed.
		if (owner == null) return true;
		if (decl.exported || index == null) return false;
		final report: SymbolIndex = index;
		if (!RefactorSupport.privateMemberScanIsSound(source, report, name)) return false;
		final scope: SymbolIndex = RefactorSupport.resolutionIndexOf(plugin) ?? report;
		return !scope.hasAccessGrant(owner) && !scope.subtypeDeclMatches(owner, name, (subtype, src, span, redeclares) -> {
			if (redeclares || MemberWriteScan.carriesBuildMacro(src)) return true;
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, src);
			return tree == null || !subtreeSafe(tree, null, -1, null, -1, name, span.from, span.to, seams);
		});
	}

	/**
	 * The declaration at offset `at` — its owning type when it is a MEMBER of one, and
	 * whether that member is public. A local, a parameter and a declaration nested inside a
	 * function body all answer with a null owner, since the parent of a member is the
	 * visibility container itself.
	 */
	private static function locate(
		node: QueryNode, parent: Null<QueryNode>, slot: Int, container: Null<QueryNode>, at: Int, seams: ValueSeams
	): Null<Decl> {
		final span: Null<Span> = node.span;
		if (span != null && span.from == at && seams.declKinds.contains(node.kind)) {
			final host: Null<QueryNode> = parent != null && parent == container ? container : null;
			return host == null ? { owner: null, exported: false } : {
				owner: CheckScan.typeDeclName(host, seams.containerKinds),
				exported: precededByPublic(host, slot, seams)
			};
		}
		final host: Null<QueryNode> = seams.containerKinds.contains(node.kind) ? node : container;
		for (i in 0...node.children.length) {
			final found: Null<Decl> = locate(node.children[i], node, i, host, at, seams);
			if (found != null) return found;
		}
		return null;
	}

	/** Whether the member at `slot` of `host` carries a `public` modifier — its modifiers are the siblings just before it. */
	private static function precededByPublic(host: QueryNode, slot: Int, seams: ValueSeams): Bool {
		var i: Int = slot - 1;
		while (i >= 0) {
			final kind: String = host.children[i].kind;
			if (kind == seams.publicModifierKind) return true;
			if (seams.memberDeclKinds.contains(kind)) return false;
			i--;
		}
		return false;
	}

	/**
	 * Whether every occurrence of `name` in `node`'s subtree that STARTS within `[from, to)`
	 * sits in a safe slot — the range being how a subtype's own declaration slice is censused
	 * without the rest of its file. `parent` / `parentSlot` and `grand` / `grandSlot` carry
	 * the two ancestor levels the classification needs: a receiver's meaning is decided by its
	 * parent AND by what that parent is used for (`m.set` is a field access under a call;
	 * `m[k]` is an index access that may be an assignment target).
	 */
	private static function subtreeSafe(
		node: QueryNode, parent: Null<QueryNode>, parentSlot: Int, grand: Null<QueryNode>, grandSlot: Int, name: String, from: Int,
		to: Int, seams: ValueSeams
	): Bool {
		final span: Null<Span> = node.span;
		final inRange: Bool = span == null || (span.from >= from && span.from < to);
		if (node.name == name && inRange && !occurrenceSafe(node, parent, parentSlot, grand, grandSlot, seams)) return false;
		for (i in 0...node.children.length) if (!subtreeSafe(node.children[i], node, i, parent, parentSlot, name, from, to, seams))
			return false;
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
		// Slot 4 — a member call.
		// Slot 5 — the iterable of a `for`. It is the child right before the body, since a
		// key-value binder occupies a slot of its own that a plain binder does not.
		// Slot 6 — a whole-map assignment.
		return if (p.kind == seams.indexAccessKind && parentSlot == 0)
			indexSlotSafe(grand, grandSlot, seams)
		else if (p.kind == seams.fieldAccessKind && parentSlot == 0 && grand != null && grand.kind == seams.callKind && grandSlot == 0)
			memberCallSlotSafe(p.name, grand, seams)
		else if (seams.iterationKinds.contains(p.kind))
			parentSlot == p.children.length - 2
		else
			p.kind == seams.assignKind && parentSlot == 0 && p.children.length == ASSIGN_CHILD_COUNT && provenMapExpr(p.children[1], seams);
	}

	/**
	 * Whether an index access over the map is a safe slot: a plain READ always is, an
	 * assignment to it only with a proven non-null value. A compound assignment or an
	 * increment READS the stored value and writes back a derived one, which no literal gate
	 * can prove non-null.
	 */
	private static function indexSlotSafe(grand: Null<QueryNode>, grandSlot: Int, seams: ValueSeams): Bool {
		if (grand == null) return true;
		final g: QueryNode = grand;
		return g.kind == seams.assignKind && grandSlot == 0
			? g.children.length == ASSIGN_CHILD_COUNT && provenNonNullValue(g.children[1], seams)
			: !seams.writeParentKinds.contains(g.kind);
	}

	/**
	 * Whether a call of the map's member `method` is a safe slot: one of the members that can
	 * only read or REMOVE always is, `set(k, v)` only with a proven non-null value, and any
	 * other name — a static extension, a foreign member — fails closed.
	 */
	private static function memberCallSlotSafe(method: Null<String>, call: QueryNode, seams: ValueSeams): Bool {
		return method != null
			&& (READ_ONLY_METHODS.contains(method)
				|| (method == SET_METHOD && call.children.length == SET_CALL_CHILDREN && provenNonNullValue(call.children[2], seams)));
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
			return node.children.foreach(c -> seams.typeAnnotationKinds.contains(c.kind));
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

/**
 * Where a map binding was declared: its owning type when it is a member of one, and whether
 * that member is public.
 */
typedef Decl = {
	final owner: Null<String>;
	final exported: Bool;
}
/**
 * The grammar seams the no-null-value census reads.
 */
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
	final containerKinds: Array<String>;
	final memberDeclKinds: Array<String>;
	final publicModifierKind: Null<String>;
	final paramKinds: Array<String>;
	final iterationKinds: Array<String>;
	final writeParentKinds: Array<String>;
	final typeAnnotationKinds: Array<String>;
	final nonNullLiteralKinds: Array<String>;
};
