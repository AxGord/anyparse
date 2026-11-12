package anyparse.check.scan;

import anyparse.query.IndexScope;
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
 * A read the index cannot prove plain may be a getter and is impure: a receiver whose type does not
 * resolve, a member the index cannot place. A loop binder and a lambda parameter written with no type
 * resolve to the type the typer binds them to. An index read on an abstract declaring an index
 * overload is impure, its access may select code.
 *
 * Grammar-agnostic: `contextOf` resolves every kind through `RefShape` and returns null when
 * the grammar leaves the field-access or call kind unset, which makes a caller a no-op rather
 * than a guess.
 */
@:nullSafety(Strict)
final class PurityScan {

	/**
	 * Whether every node in `node`'s subtree is side-effect-free, an access `accessRunsCode` clears counting as one. An
	 * access the index cannot prove plain — its receiver type unresolved, its member unplaced — may be a getter, so it
	 * counts as impure.
	 */
	public static function isPure(node: QueryNode, ctx: PurityCtx): Bool {
		final kind: String = node.kind;
		if (kind == ctx.identKind) return !readsGetterUnqualified(node, ctx);
		function childrenPure() return node.children.foreach(c -> isPure(c, ctx));
		if (ctx.safeKinds.contains(kind)) return childrenPure();
		if (kind == ctx.fieldAccessKind || (ctx.indexAccessKind != null && kind == ctx.indexAccessKind))
			return !accessRunsCode(node, ctx) && childrenPure();
		if (kind != ctx.callKind || !isPureCall(node, ctx)) return false;
		// the callee is a transparent function `StdlibPurity` placed, not a property read: only its receiver is asked
		final callee: Null<QueryNode> = node.children[0];
		final calleeRead: Bool = callee != null && callee.kind == ctx.fieldAccessKind;
		return node.children.foreach(c -> calleeRead && c == callee ? c.children.foreach(r -> isPure(r, ctx)) : isPure(c, ctx));
	}

	/**
	 * The per-file context `isPure` threads through its walk, or null when the grammar leaves the
	 * field-access or call kind unset. `report` supplies the property-getter map, read through the run's resolution scope
	 * when it has one, since whether a member runs code is what the name MEANS (`IndexScope`, a std `length` included), and
	 * `declaredTypes` the receiver types; a plugin that is no `TypeInfoProvider` yields an empty
	 * map, which leaves every non-`this` receiver unresolved. `file` is the file `source` is read from:
	 * a lambda parameter takes its type only from a function type read in that file.
	 */
	public static function contextOf(
		plugin: GrammarPlugin, source: String, root: QueryNode, report: SymbolIndex, file: String
	): Null<PurityCtx> {
		final index: SymbolIndex = IndexScope.resolutionIndexOf(plugin) ?? report;
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
			boundReceiverType: CheckScan.typeNominalResolver(source, plugin, root, file, index, true, false),
			wrappers: wrappers,
			index: index,
			report: report,
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
		return StdlibPurity.isTransparentCallee(call, ctx.root, ctx.shape, ctx.declaredTypes, ctx.report, r -> readsStringField(r, ctx));
	}

	/**
	 * Whether `recv` is a field read whose member the index declares plainly typed `String` — the receiver of a `String`
	 * method `StdlibPurity` takes on this scan's word, since `isPure` asks the receiver read itself next.
	 */
	private static function readsStringField(recv: QueryNode, ctx: PurityCtx): Bool {
		final host: Null<QueryNode> = recv.kind == ctx.fieldAccessKind ? recv.children[0] : null;
		final member: Null<String> = recv.name;
		final hostType: Null<String> = host == null ? null : receiverTypeName(host, ctx);
		return member != null
			&& hostType != null
			&& ctx.index.typing.members.memberTypeSourceOf(ctx.index.refs.aliasedName(hostType), member) == 'String';
	}

	/**
	 * Whether a field or index read may run code: the receiver type does not resolve, an index read's type declares an
	 * index overload or has no declaration, or a field read's member is a property getter or is not proven plain
	 * (`MemberLookup.memberGetter`). Every question follows a typedef alias (`TypeRefIndex.aliasedName`). A field-read
	 * interceptor (`@:op(a.b)`, `@:resolve`) runs only for a name the type does not declare, which is unplaced already.
	 */
	private static function accessRunsCode(access: QueryNode, ctx: PurityCtx): Bool {
		final recv: Null<QueryNode> = access.children[0];
		final typeName: Null<String> = recv == null ? null : receiverTypeName(recv, ctx);
		if (typeName == null) return true;
		final typing: TypingService = ctx.index.typing;
		if (access.kind != ctx.fieldAccessKind) return typing.accessOverloaded(typeName, false) || !typing.typeDeclared(typeName);
		final field: Null<String> = access.name;
		return field == null || typing.members.memberGetter(ctx.index.refs.aliasedName(typeName), field, true) != false;
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

	/**
	 * The type name a receiver read denotes: a value's declared type, a member of the enclosing type read with no self
	 * reference (inherited ones too), the type a path spells, or the type a binding written with none is bound to (a loop
	 * binder's element, a lambda parameter's expected type: `boundReceiverType`), `String` for a transparent stdlib call that
	 * answers one; null when none is known.
	 */
	private static function receiverTypeName(recv: QueryNode, ctx: PurityCtx): Null<String> {
		if (recv.kind == ctx.callKind)
			return StdlibPurity.answersString(recv, ctx.root, ctx.shape, ctx.declaredTypes, ctx.report, r -> readsStringField(r, ctx))
				? 'String'
				: null;
		final path: Null<Array<String>> = NominalTypes.pathOf(recv, ctx.identKind, ctx.fieldAccessKind);
		if (path == null) return null;
		final rootType: Null<String> = NominalTypes.pathRootTypeName(recv, ctx.root, ctx.receiverTypes, ctx.shape);
		final bound: (QueryNode) -> Null<String> = ctx.boundReceiverType ?? (_ -> null);
		if (rootType == null && TypeResolver.receiverRootIsUnboundType(recv, ctx.root, ctx.shape)) {
			var rootIdent: QueryNode = recv;
			while (rootIdent.kind == ctx.fieldAccessKind) rootIdent = rootIdent.children[0];
			// a name the enclosing type declares or inherits is read through an implicit self reference, ahead of a type name
			final member: Null<String> = bound(rootIdent);
			if (member != null) return pathEndType(path, member, ctx) ?? bound(recv);
			for (i => segment in path) if (SourceText.isUpperInitial(segment)) return pathEndType(path.slice(i), segment, ctx);
			return null;
		}
		final written: Null<String> = rootType == null ? null : pathEndType(path, rootType, ctx);
		return written ?? bound(recv);
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

	/**
	 * The member-lookup type of a receiver whose binding writes none (`CheckScan.typeNominalResolver`): the typer binds a loop
	 * binder and a lambda parameter as the program does. Null when the grammar carries no type information.
	 */
	final boundReceiverType: Null<(QueryNode) -> Null<String>>;
	final wrappers: Array<String>;
	final index: SymbolIndex;

	/** The caller's report-scoped index: a stdlib static is transparent only while no type of the REPORT shadows its name. */
	final report: SymbolIndex;
	final root: QueryNode;

};
