package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using Lambda;

/**
 * Whether an expression subtree can be evaluated once — or DROPPED — without changing what the
 * program does. Two checks ask this of the same shapes: `extract-repeated-expression` before
 * hoisting an expression into a `final` local, and `unnecessary-switch` before deleting a
 * degenerate switch's subject outright.
 *
 * ## Why `RefactorSupport.isSideEffectFree` is not this
 *
 * That predicate answers the same question from the SYNTAX alone — its whitelist holds
 * literals, bare identifiers, parens and the pure operators — and it is shared by the
 * inline-substitution and `unused-local` deletion gates. A FIELD ACCESS is deliberately absent
 * from it: `a.b` may be a property whose getter runs code, and nothing in the tree says which.
 * Refusing it is the safe answer for a predicate with no index behind it, and it must stay that
 * way — loosening it moves both of its callers at once. This scan asks the same question with
 * the symbol index in hand, so it can ADMIT the field read it proves is a plain one and refuse
 * only the getter it resolves.
 *
 * ## What passes
 *
 * A safe skeleton kind (`RefactorSupport.isSafeKind` — the syntactic core, reused rather than
 * restated), a field or index READ whose resolvable first hop is not a property getter, and a
 * provably-pure stdlib call (a `Math` / `Std` / `StringTools` static, minus the
 * non-deterministic members). Everything else — an instance call, a local-function call, a
 * complex-receiver call — is unproven and therefore impure.
 *
 * A BARE identifier is a safe skeleton kind with one exception: unqualified inside its own type
 * it may be a property read, which is a `get_p()` call. That one is asked of the SYMBOL INDEX and
 * of the RESOLVER together — the enclosing type must declare a getter of the name, AND the
 * identifier must not bind to a value declaration that shadows it (`readsGetterUnqualified`).
 *
 * An UNRESOLVED receiver reads as a plain field rather than as a getter: the receiver's type is
 * only resolvable when it is a bare identifier with a declared type, or `this`. That is the
 * assumption `extract-repeated-expression` has always made, kept here unchanged; it is the one
 * place this scan is optimistic, and it is why a caller that DELETES rather than hoists should
 * carry its own structural gates on top.
 *
 * Grammar-agnostic: `contextOf` resolves every kind through `RefShape` and returns null when
 * the grammar leaves the field-access or call kind unset, which makes a caller a no-op rather
 * than a guess.
 */
@:nullSafety(Strict)
final class PurityScan {

	/**
	 * Simple receiver names whose static methods are pure (referentially transparent) stdlib
	 * operations, so a call on one may be computed once — or dropped.
	 */
	private static final PURE_CALL_RECEIVERS: Array<String> = ['Math', 'Std', 'StringTools'];

	/** Members on a `PURE_CALL_RECEIVERS` receiver that are NOT pure (non-deterministic). */
	private static final IMPURE_MEMBERS: Array<String> = ['random'];

	/**
	 * The per-file context `isPure` threads through its walk, or null when the grammar leaves the
	 * field-access or call kind unset. `index` supplies the property-getter map and
	 * `declaredTypes` the receiver types; a plugin that is no `TypeInfoProvider` yields an empty
	 * map, which leaves every non-`this` receiver unresolved.
	 */
	public static function contextOf(plugin: GrammarPlugin, source: String, root: QueryNode, index: SymbolIndex): Null<PurityCtx> {
		final shape: RefShape = plugin.refShape();
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final callKind: Null<String> = shape.callKind;
		if (fieldAccessKind == null || callKind == null) return null;
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		final declaredTypes: Map<Int, String> = provider != null ? provider.declaredTypes(source) : [];
		return {
			shape: shape,
			identKind: shape.identKind,
			fieldAccessKind: fieldAccessKind,
			callKind: callKind,
			indexAccessKind: shape.indexAccessKind,
			selfReferenceText: shape.selfReferenceText,
			declaredTypes: declaredTypes,
			index: index,
			root: root
		};
	}

	/**
	 * Whether every node in `node`'s subtree is side-effect-free: a safe skeleton kind, a field /
	 * index READ, or a provably-pure stdlib call. A field read whose resolvable first hop is a
	 * property getter, and any non-whitelisted call, make it impure.
	 */
	public static function isPure(node: QueryNode, ctx: PurityCtx): Bool {
		final kind: String = node.kind;
		if (kind == ctx.identKind) return !readsGetterUnqualified(node, ctx);
		function childrenPure() return node.children.foreach(c -> isPure(c, ctx));
		if (MemberKinds.isSafeKind(kind)) return childrenPure();
		if (kind != ctx.fieldAccessKind) return if (ctx.indexAccessKind != null && kind == ctx.indexAccessKind)
			childrenPure()
		else if (kind == ctx.callKind)
			isPureCall(node, ctx) && childrenPure()
		else
			false;
		return !isSideEffectingGetter(node, ctx) && childrenPure();
	}

	/**
	 * The index-free half of `isPureCall`, for a caller that has a grammar but no symbol index:
	 * whether `call`'s callee is a `Recv.method` field access where `Recv` is a bare identifier in
	 * `PURE_CALL_RECEIVERS` and `method` is not an `IMPURE_MEMBERS` name. It answers for the CALL
	 * NODE ONLY — the arguments are the caller's business, so a caller that walks a subtree must
	 * recurse into them itself (`Std.int(Math.random())` has a pure callee and an impure argument).
	 */
	public static function isPureStdlibCall(call: QueryNode, fieldAccessKind: String, identKind: String): Bool {
		if (call.children.length < 1) return false;
		final callee: QueryNode = call.children[0];
		if (callee.kind != fieldAccessKind || callee.children.length != 1) return false;
		final method: Null<String> = callee.name;
		if (method == null || IMPURE_MEMBERS.contains(method)) return false;
		final recv: QueryNode = callee.children[0];
		return recv.kind == identKind && recv.name != null && PURE_CALL_RECEIVERS.contains(recv.name);
	}

	/**
	 * Whether a `callKind` node is a provably-pure stdlib call — its callee is a `Recv.method`
	 * field access where `Recv` is a bare identifier in `PURE_CALL_RECEIVERS` and `method` is not
	 * an `IMPURE_MEMBERS` name. Any other callee (an instance method, a local function, a complex
	 * receiver) is unproven and therefore impure.
	 */
	private static inline function isPureCall(call: QueryNode, ctx: PurityCtx): Bool {
		return isPureStdlibCall(call, ctx.fieldAccessKind, ctx.identKind);
	}

	/**
	 * Whether a `fieldAccessKind` node reads a member proven to be a property GETTER — resolvable
	 * only when the receiver is a bare identifier (its declared type) or `this` (the enclosing
	 * type); a deeper receiver is left unresolved and assumed a plain read. Reuses
	 * `MemberLookup.memberGetter` (the getter-property map).
	 */
	private static function isSideEffectingGetter(fa: QueryNode, ctx: PurityCtx): Bool {
		final field: Null<String> = fa.name;
		if (field == null || fa.children.length != 1) return false;
		final recv: QueryNode = fa.children[0];
		if (recv.kind != ctx.identKind) return false;
		final recvName: Null<String> = recv.name;
		if (recvName == null) return false;
		final typeName: Null<String> = if (recvName == ctx.selfReferenceText) {
			final span: Null<Span> = fa.span;
			span == null ? null : TypeResolver.enclosingTypeName(ctx.root, span);
		} else {
			TypeResolver.identTypeName(recv, ctx.root, ctx.shape, ctx.declaredTypes);
		}
		return typeName != null && ctx.index.members.memberGetter(typeName, field) == true;
	}

	/**
	 * Whether a BARE identifier reads a property of the enclosing type whose getter runs code. The
	 * qualified spellings (`this.p`, `o.p`) arrive as a field access and are answered by
	 * `isSideEffectingGetter`; unqualified inside its own type, the same read is an `identKind` leaf
	 * that `RefactorSupport.isSafeKind` would wave through — `switch prop { case _: … }` would then
	 * look droppable while dropping a `get_prop()` call.
	 *
	 * The enclosing type having a getter of that NAME is only half the question: a parameter or a
	 * local of the same name SHADOWS it, and then the identifier reads that binding, not the
	 * property. So the name is asked of the resolver, and a read it positively places in a value
	 * declaration — `TypeResolver.bindsToValueDeclaration`, whose three conditions are stated there
	 * — is not a property read at all. Anything the resolver cannot place that way stays refused,
	 * including a name it fails to resolve: over-refusing costs a finding, under-refusing costs a
	 * behaviour, and every consumer of this scan reads a pure verdict as permission to drop or
	 * hoist the expression.
	 *
	 * The getter lookup runs FIRST because it is the cheap half — the resolver walk is reached only
	 * for an identifier that names a getter of its own type, which is rare.
	 */
	private static function readsGetterUnqualified(ident: QueryNode, ctx: PurityCtx): Bool {
		final name: Null<String> = ident.name;
		final span: Null<Span> = ident.span;
		if (name == null || span == null) return false;
		final owner: Null<String> = TypeResolver.enclosingTypeName(ctx.root, span);
		if (owner == null || ctx.index.members.memberGetter(owner, name) != true) return false;
		return !TypeResolver.bindsToValueDeclaration(name, span, ctx.root, ctx.shape);
	}

}

/** Per-file resolved constants threaded through `PurityScan`'s recursive walk. */
typedef PurityCtx = {
	final shape: RefShape;
	final identKind: String;
	final fieldAccessKind: String;
	final callKind: String;
	final indexAccessKind: Null<String>;
	final selfReferenceText: Null<String>;
	final declaredTypes: Map<Int, String>;
	final index: SymbolIndex;
	final root: QueryNode;
};
