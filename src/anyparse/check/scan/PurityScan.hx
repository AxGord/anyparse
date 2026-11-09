package anyparse.check.scan;

import anyparse.query.MemberKinds;
import anyparse.query.NominalTypes;
import anyparse.query.SourceText;
import anyparse.query.StdlibPurity;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.query.TypingService;

/**
 * Whether an expression subtree can be evaluated once — or DROPPED — without changing what the
 * program does: the one answer to "can this expression be hoisted or deleted without changing
 * behaviour". Two checks ask this of the same shapes: `extract-repeated-expression` before
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
 * restated), a field or index READ whose receiver type resolves and proves no code runs, and a
 * call whose callee is a referentially transparent stdlib function (`StdlibPurity`). Everything
 * else — an instance call, a local-function call, a complex-receiver call — is impure.
 *
 * A BARE identifier is a safe skeleton kind with one exception: unqualified inside its own type
 * it may be a property read, which is a `get_p()` call. That one is asked of the SYMBOL INDEX and
 * of the RESOLVER together — the enclosing type must declare a getter of the name, AND the
 * identifier must not bind to a value declaration that shadows it (`readsGetterUnqualified`).
 *
 * A read whose receiver type does not resolve may be a getter: `isProvenPure` reads it as impure,
 * `isPure` as plain, because receivers the rules type on their own (a loop binder, a lambda
 * parameter) do not resolve here. A read on an abstract declaring an operator or index overload
 * is impure for both, its access may select code.
 *
 * Grammar-agnostic: `contextOf` resolves every kind through `RefShape` and returns null when
 * the grammar leaves the field-access or call kind unset, which makes a caller a no-op rather
 * than a guess.
 */
@:nullSafety(Strict)
final class PurityScan {

	/**
	 * Whether every node in `node`'s subtree is side-effect-free, an access `accessRunsCode` clears counting as one. An
	 * access whose receiver type does not resolve is assumed a plain read here; the caller that reorders an expression
	 * against effects it cannot see asks `isProvenPure`.
	 */
	public static inline function isPure(node: QueryNode, ctx: PurityCtx): Bool {
		return pure(node, ctx, false);
	}

	/** `isPure` with unknown read as impure: an access through a receiver whose type does not resolve may be a getter. */
	public static inline function isProvenPure(node: QueryNode, ctx: PurityCtx): Bool {
		return pure(node, ctx, true);
	}

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
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		final declaredTypes: Map<Int, String> = provider != null ? provider.declaredTypes(source) : [];
		final wrappers: Array<String> = shape.memberTransparentWrapperTypeNames ?? [];
		final receiverTypes: Map<Int, String> = [];
		if (provider != null) for (from => written in provider.declaredTypeSources(source)) {
			final nominal: Null<String> = NominalTypes.outerNominalOf(
				NominalTypes.memberLookupReceiverSource(written, wrappers, index.typeSyntax), index.typeSyntax
			);
			if (nominal != null) receiverTypes[from] = nominal;
		}
		return {
			shape: shape,
			safeKinds: MemberKinds.sideEffectFreeExprKinds(shape),
			identKind: shape.identKind,
			fieldAccessKind: fieldAccessKind,
			callKind: callKind,
			indexAccessKind: shape.indexAccessKind,
			selfReferenceText: shape.selfReferenceText,
			declaredTypes: declaredTypes,
			receiverTypes: receiverTypes,
			wrappers: wrappers,
			index: index,
			root: root
		};
	}

	/**
	 * Whether `node` is pure AND built from the safe skeleton alone — literals, identifiers,
	 * grouping and the pure operators: no field or index read, no call, however transparent. A
	 * caller that DROPS the expression asks this rather than `isPure`, because even a plain read
	 * then disappears from the program.
	 * A bare identifier is still asked of `readsGetterUnqualified`.
	 */
	public static function isPlainValue(node: QueryNode, ctx: PurityCtx): Bool {
		return node.kind == ctx.identKind
			? !readsGetterUnqualified(node, ctx)
			: ctx.safeKinds.contains(node.kind) && node.children.foreach(c -> isPlainValue(c, ctx));
	}

	/**
	 * Whether a `callKind` node's callee is a referentially transparent stdlib function — the one
	 * table `StdlibPurity` holds, so this scan and the deletion predicates
	 * (`TypeResolver.isDeletionPure`) can never disagree about which `Math` / `Std` / `StringTools` /
	 * `Path` statics and `String` methods are pure. Any other callee (an instance method, a local
	 * function, a complex receiver) is unproven and therefore impure.
	 */
	private static inline function isPureCall(call: QueryNode, ctx: PurityCtx): Bool {
		return StdlibPurity.isTransparentCallee(call, ctx.root, ctx.shape, ctx.declaredTypes, ctx.index);
	}

	private static function pure(node: QueryNode, ctx: PurityCtx, unknownRuns: Bool): Bool {
		final kind: String = node.kind;
		if (kind == ctx.identKind) return !readsGetterUnqualified(node, ctx);
		function childrenPure() return node.children.foreach(c -> pure(c, ctx, unknownRuns));
		if (ctx.safeKinds.contains(kind)) return childrenPure();
		if (kind == ctx.fieldAccessKind || (ctx.indexAccessKind != null && kind == ctx.indexAccessKind))
			return !accessRunsCode(node, ctx, unknownRuns) && childrenPure();
		return kind == ctx.callKind && isPureCall(node, ctx) && childrenPure();
	}

	/**
	 * Whether a field or index read may run code: the type is an abstract whose access may select an overload, the field
	 * is a property getter (`MemberLookup.memberGetter`), or, with `unknownRuns` set, the receiver type does not resolve, an
	 * index read's type has no declaration, or a field read's member is not proven plain. The overload and declaration
	 * questions follow a typedef alias; the getter question does not, so a field read through an alias is unknown.
	 */
	private static function accessRunsCode(access: QueryNode, ctx: PurityCtx, unknownRuns: Bool): Bool {
		final recv: Null<QueryNode> = access.children[0];
		final typeName: Null<String> = recv == null ? null : receiverTypeName(recv, ctx);
		if (typeName == null) return unknownRuns;
		final typing: TypingService = ctx.index.typing;
		if (typing.accessOverloaded(typeName)) return true;
		if (access.kind != ctx.fieldAccessKind) return unknownRuns && !typing.typeDeclared(typeName);
		final field: Null<String> = access.name;
		final getter: Null<Bool> = field == null ? null : typing.members.memberGetter(typeName, field);
		return getter == true || (unknownRuns && getter == null);
	}

	/**
	 * Whether a BARE identifier reads a property of the enclosing type whose getter runs code. The
	 * qualified spellings (`this.p`, `o.p`) arrive as a field access and are answered by
	 * `accessRunsCode`; unqualified inside its own type, the same read is an `identKind` leaf
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
		if (owner == null || ctx.index.typing.members.memberGetter(owner, name) != true) return false;
		return !TypeResolver.bindsToValueDeclaration(name, span, ctx.root, ctx.shape);
	}

	/** The type name a receiver read denotes: a value's declared type, or the type a path spells; null when neither is known. */
	private static function receiverTypeName(recv: QueryNode, ctx: PurityCtx): Null<String> {
		final path: Null<Array<String>> = NominalTypes.pathOf(recv, ctx.identKind, ctx.fieldAccessKind);
		if (path == null) return null;
		final rootType: Null<String> = NominalTypes.pathRootTypeName(recv, ctx.root, ctx.receiverTypes, ctx.shape);
		if (rootType != null) return pathEndType(path, rootType, ctx);
		if (!TypeResolver.receiverRootIsUnboundType(recv, ctx.root, ctx.shape)) return null;
		for (i => segment in path) if (SourceText.isUpperInitial(segment)) return pathEndType(path.slice(i), segment, ctx);
		return null;
	}

	private static function pathEndType(path: Array<String>, rootType: String, ctx: PurityCtx): Null<String> {
		if (path.length == 1) return rootType;
		final written: Null<String> = NominalTypes.pathFinalMemberTypeSource(path, rootType, ctx.index, ctx.wrappers);
		return written == null
			? null
			: NominalTypes.outerNominalOf(
				NominalTypes.memberLookupReceiverSource(written, ctx.wrappers, ctx.index.typeSyntax), ctx.index.typeSyntax
			);
	}

}

/** Per-file resolved constants threaded through `PurityScan`'s recursive walk. */
typedef PurityCtx = {

	final shape: RefShape;

	/**
	 * The grammar's side-effect-free expression vocabulary, derived ONCE per file rather than per
	 * node: `isPure` asks it at every node of every subtree it walks, and the vocabulary is a
	 * function of `shape` alone. Run-scoped like the rest of this context — nothing here outlives
	 * the file it was built for.
	 */
	final safeKinds: Array<String>;
	final identKind: String;
	final fieldAccessKind: String;
	final callKind: String;
	final indexAccessKind: Null<String>;
	final selfReferenceText: Null<String>;
	final declaredTypes: Map<Int, String>;

	/** Every binding's outer nominal, parametric and optional types included: a receiver's type is what this asks. */
	final receiverTypes: Map<Int, String>;
	final wrappers: Array<String>;
	final index: SymbolIndex;
	final root: QueryNode;

};
