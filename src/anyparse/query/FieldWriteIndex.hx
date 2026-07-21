package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportKind;

/**
 * One resolved field write: `owner`.`field` written at `(file, span)`. The owner
 * is the SIMPLE type name the receiver resolves to — `this`, a typed local /
 * param / field receiver, a field-access / index-access chain resolved step by
 * step through the symbol index, or a static access rooted at a type name — the
 * same simple-name keying `SymbolIndex` uses, so an ambiguous simple name
 * conservatively merges writes across same-named types (over-attribution only
 * ever KEEPS a field mutable).
 */
typedef FieldWrite = {
	var owner: String;
	var field: String;
	var file: String;
	var span: Span;
}

/**
 * One write whose receiver could NOT be attributed to a type: the written field
 * NAME plus `rhsType` — the builtin type of the right-hand side when the write is
 * a plain assignment of a literal whose type is statically certain (`String` /
 * `Int` / `Float` / `Bool`), or null for a compound / opaque / non-literal write.
 * `rhsType` lets `hasUnresolvedWriteTargeting` prove the write cannot target a
 * candidate whose declared type no builtin value can convert into.
 */
typedef UnresolvedWrite = {
	var field: String;
	var rhsType: Null<String>;
}
/** A parsed nominal type source: the simple `name` plus the raw text between its type-parameter brackets, if any. */
private typedef NominalParts = {
	var name: String;
	var params: Null<String>;
}
/**
 * The current type-body context threaded down the walk: the enclosing type's
 * simple name, its decl-node KIND (an `underlyingThisTypeKinds` container makes
 * `this` the underlying value, not an instance — unresolvable), plus the
 * binding-span starts of its directly-declared members, so a bare-identifier
 * write (`field = …`) can be told apart from a local/param write — it is a field
 * write only when its binding resolves to one of these.
 */
typedef WriteTypeCtx = {
	var name: String;
	var kind: String;
	var memberFroms: Array<Int>;
}

/**
 * Run-scoped invariants for the per-file write scan, bundled so the recursive
 * `scan` / `classify` need not thread a dozen scalars. `index` is the cross-file
 * symbol index the receiver-chain resolution walks; `typeSources` maps each
 * binding-span start to the VERBATIM `:Type` annotation text of its declaration.
 * `typeParams` accumulates each visited type's header type-parameter names
 * ACROSS files (it feeds the built instance); `patternNames` lazily caches the
 * names bound or mentioned by THIS file's case-patterns.
 */
typedef ScanCtx = {
	var file: String;
	var source: String;
	var tree: QueryNode;
	var shape: RefShape;
	var typeSources: Map<Int, String>;
	var index: SymbolIndex;
	var writes: Array<FieldWrite>;
	var unresolved: Array<UnresolvedWrite>;
	var writeKinds: Array<String>;
	var containerKinds: Array<String>;
	var faKind: Null<String>;
	var identKind: String;
	var selfText: Null<String>;
	var opaque: Array<String>;
	var untypedKinds: Array<String>;
	var assignKind: Null<String>;
	var indexKind: Null<String>;
	var literalTypes: Map<String, String>;
	var elementTypeParams: Map<String, Int>;
	var builtinNames: Array<String>;
	var unwrapNames: Array<String>;
	var rejectNames: Array<String>;
	var casePatternKind: Null<String>;
	var binderKinds: Array<String>;
	var aliasKinds: Array<String>;
	var abstractThisKinds: Array<String>;
	var typeParams: Map<String, Array<String>>;
	var patternNames: Null<Array<String>>;
}
/**
 * A cross-file index of field WRITES keyed by the receiver's resolved type. Built
 * once over a whole file set, it answers — for a `(typeName, field)` pair — whether
 * the field is written anywhere, written outside its declaring type, and whether any
 * write to that field NAME could not be attributed to a type (the soundness bail).
 *
 * The foundation the public-field immutability checks (`prefer-final-public-field`,
 * `prefer-read-only-field`) stand on: proving a public field is never reassigned, or
 * only reassigned internally, requires seeing every cross-file write to it — which
 * the simplified `QueryNode` field name alone cannot provide, since field names
 * collide across types.
 *
 * ## Receiver resolution
 *
 * A write target's receiver resolves to its STATIC declared type — sound under
 * nominal typing: a write through a receiver declared `:Y` targets Y's field
 * (inheritance is the CONSUMER's job, gated by `hasSubtype` /
 * `supertypeDeclaresMember`). Four receiver shapes resolve; each step that fails
 * falls back to the unresolved bail:
 *
 *  - `this` — the enclosing type, unless the container is an
 *    `underlyingThisTypeKinds` abstract (there `this` is the untyped underlying
 *    value).
 *  - A bound identifier — its verbatim `:Type` annotation
 *    (`TypeInfoProvider.declaredTypeSources`), `Null<T>` unwrapped;
 *    `Dynamic` / `Any` / a non-nominal annotation never resolve.
 *  - An UNBOUND identifier (a receiver, or a bare write target) — an inherited
 *    field, resolved through the enclosing type's supertype chain
 *    (`SymbolIndex.memberTypeSourceOf` per step), or a capitalized name declaring
 *    an indexed type (a static access).
 *  - A field-access / index-access chain — resolved recursively: member steps
 *    through `SymbolIndex.memberTypeSourceOf` (supertype closure, unanimous),
 *    index steps through the container's element type parameter
 *    (`RefShape.indexedElementTypeParams`: `Map<K, V>` → V, `Array<T>` → T).
 *
 * Every identifier arm except `this` bails when any case-pattern in the file binds
 * or mentions the name (`patternShadows` — pattern variables, including
 * `casePatternBinderKinds` captures, are invisible to the scope resolver and can
 * shadow a typed binding, an inherited field, or a type name). The final owner
 * passes the OWNER GATE (`allowedOwner`): a name the index does not declare (an
 * external type, or an unprojected TYPE PARAMETER like `s:T`) or one declared with
 * aliasing semantics (`RefShape.aliasingDeclKinds` — a typedef alias, an abstract
 * whose `@:forward` reaches the underlying type) never absorbs a write; it falls
 * back to the unresolved bail instead of silently filing the write away from the
 * type it mutates.
 *
 * ## Soundness — over-count toward "written"
 *
 * A false negative (a missed write) is the dangerous direction: it would let a check
 * rewrite a field that IS reassigned, a compile error. So every write whose receiver
 * the index cannot resolve to a concrete type is recorded as an UNRESOLVED write of
 * that field NAME (`hasUnresolvedWrite`), never silently dropped — a consumer must
 * bail on any candidate whose name has an unresolved write. A macro reification
 * (`opaqueKinds`) subtree is descended into, not skipped: its generated code can
 * write a REAL runtime field (`ctx.pos++` in an emitted parser), so every write
 * target there is marked an unresolved write of that field name (the emitted
 * receiver cannot be typed) — bailing the field rather than missing the write. An
 * `untyped` subtree (`RefShape.untypedKinds`) is treated the same way — with the
 * type system off, neither its receivers nor its RHS literals can be trusted.
 *
 * The unresolved entry additionally carries the RHS literal type of a plain `=`
 * write when it is statically certain (`UnresolvedWrite.rhsType`).
 * `hasUnresolvedWriteTargeting` uses it for a NARROWER bail: an unresolved write
 * whose RHS is provably a builtin value cannot target a field whose declared type
 * is a plain project class (no implicit conversion accepts a builtin), so such a
 * candidate is freed while every other consumer of `hasUnresolvedWrite` still sees
 * the name as poisoned. That freeing carries its own guards — the candidate's type
 * must not name its owner's type parameter, must resolve to exactly one indexed
 * plain class, and must not be import-shadowed in the candidate's file (see the
 * method doc).
 */
@:nullSafety(Strict)
final class FieldWriteIndex {

	private final _writes: Array<FieldWrite>;
	private final _unresolved: Array<UnresolvedWrite>;
	private final _index: SymbolIndex;
	private final _classKinds: Array<String>;
	private final _builtinNames: Array<String>;
	private final _unwrapNames: Array<String>;
	private final _rejectNames: Array<String>;
	private final _typeParams: Map<String, Array<String>>;

	private function new(
		writes: Array<FieldWrite>, unresolved: Array<UnresolvedWrite>, index: SymbolIndex, classKinds: Array<String>,
		builtinNames: Array<String>, unwrapNames: Array<String>, rejectNames: Array<String>, typeParams: Map<String, Array<String>>
	) {
		_writes = writes;
		_unresolved = unresolved;
		_index = index;
		_classKinds = classKinds;
		_builtinNames = builtinNames;
		_unwrapNames = unwrapNames;
		_rejectNames = rejectNames;
		_typeParams = typeParams;
	}

	/** Whether any resolved write targets `type`.`field` anywhere in the file set. */
	public function writtenAnywhere(type: String, field: String): Bool {
		for (w in _writes) if (w.owner == type && w.field == field) return true;
		return false;
	}

	/**
	 * How many resolved writes target `type`.`field` across the file set — the
	 * exactly-one-write proof `field-init-at-declaration` needs (a movable constructor
	 * init is the field's SOLE write). `writtenAnywhere` only answers presence; a mover
	 * must additionally rule out a second write elsewhere.
	 */
	public function writeCount(type: String, field: String): Int {
		var n: Int = 0;
		for (w in _writes) if (w.owner == type && w.field == field) n++;
		return n;
	}

	/**
	 * Whether any resolved write to `type`.`field` occurs OUTSIDE the declaring type's
	 * own source range `(declFile, declSpan)` — an external write that forbids making
	 * the field externally read-only.
	 */
	public function writtenExternally(type: String, field: String, declFile: String, declSpan: Span): Bool {
		for (w in _writes) if (w.owner == type && w.field == field) {
			final internal: Bool = w.file == declFile && declSpan.from <= w.span.from && w.span.to <= declSpan.to;
			if (!internal) return true;
		}
		return false;
	}

	/**
	 * Whether any write to a field named `field` could not be attributed to a concrete
	 * receiver type — the soundness bail: such a write might be a hidden write to the
	 * candidate, so a consumer must not rewrite a field whose name appears here.
	 */
	public function hasUnresolvedWrite(field: String): Bool {
		for (u in _unresolved) if (u.field == field) return true;
		return false;
	}

	/**
	 * The targeting-aware refinement of `hasUnresolvedWrite` for a SPECIFIC
	 * candidate: the field named `field` declared by type `owner` in `ownerFile`.
	 * True (poisoned) unless EVERY unresolved write to `field` carries a known
	 * builtin RHS type (`UnresolvedWrite.rhsType`) that provably cannot be assigned
	 * to the candidate's declared type. "Provably cannot" requires that type —
	 * `Null<T>` unwrapped — to be a non-builtin nominal that (1) does not name one
	 * of the OWNER's type parameters (there it denotes the instantiation argument,
	 * not the same-named project type), (2) resolves to EXACTLY ONE indexed decl of
	 * a plain-class kind (`RefShape.classDeclKinds` — no implicit conversions, so
	 * no builtin value can flow in; an abstract's `@:from`, an interface, a
	 * typedef, an enum, a builtin, or an unresolved name keeps the poison), and
	 * (3) is not shadowed in the candidate's own file by an import of a
	 * same-simple-named module from elsewhere (`importShadowed` — the annotation
	 * would denote the imported type, not the indexed class).
	 */
	public function hasUnresolvedWriteTargeting(field: String, owner: String, ownerFile: String): Bool {
		var any: Bool = false;
		var allTyped: Bool = true;
		for (u in _unresolved) if (u.field == field) {
			any = true;
			if (u.rhsType == null) allTyped = false;
		}
		if (!any) return false;
		if (!allTyped) return true;
		final candidateTypeSource: Null<String> = _index.memberTypeSourceOf(owner, field);
		if (candidateTypeSource == null) return true;
		final cand: Null<String> = nominalSimpleName(candidateTypeSource, _unwrapNames, _rejectNames);
		if (cand == null || _builtinNames.contains(cand)) return true;
		final ownerParams: Null<Array<String>> = _typeParams[owner];
		if (ownerParams != null && ownerParams.contains(cand)) return true;
		if (!uniquePlainClass(cand)) return true;
		return importShadowed(cand, ownerFile);
	}

	/**
	 * Whether `name` resolves in the symbol index to EXACTLY ONE type declaration
	 * whose kind is a plain class (`RefShape.classDeclKinds`) — the no-implicit-
	 * conversion proof `hasUnresolvedWriteTargeting` stands on. Zero decls (a
	 * builtin / external type), several (ambiguous), or a non-class kind all fail.
	 */
	private function uniquePlainClass(name: String): Bool {
		final decls: Array<TypeDeclInfo> = declsNamedIn(_index, name);
		return decls.length == 1 && _classKinds.contains(decls[0].kind);
	}

	/**
	 * Whether the simple type name `name`, as written in `file`, is SHADOWED by an
	 * import: the file imports (or aliases to `name`, or `using`s) a module whose
	 * last segment is `name` but which is NOT the indexed declaring module — the
	 * annotation then denotes the imported out-of-scope type, so nothing can be
	 * proven about it. Wildcard imports are not compared (their package content is
	 * unknowable); an unindexed file or an ambiguous declaring module poisons.
	 */
	private function importShadowed(name: String, file: String): Bool {
		final fi: Null<FileInfo> = _index.fileInfo(file);
		if (fi == null) return true;
		final declaredPath: Null<String> = _index.importPathOf(name);
		if (declaredPath == null) return true;
		for (imp in fi.imports) if (imp.kind != ImportKind.Wild) {
			if (imp.kind == ImportKind.Alias) {
				if (imp.raw == name) return true;
			} else if (lastSegment(imp.raw) == name && imp.raw != declaredPath)
				return true;
		}
		return false;
	}

	/**
	 * Parse every `(file, source)` entry (skip-parse tolerant, never throws) and walk
	 * each for write sites, resolving each write's receiver type via the plugin's
	 * `TypeInfoProvider` verbatim type-source map, the scope resolver, and the
	 * cross-file symbol `index` (built internally when the caller has none to
	 * share). A plugin without the capability yields no declared types, so every
	 * receiver is unresolved — every candidate then bails, which is sound.
	 */
	public static function build(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, ?index: SymbolIndex
	): FieldWriteIndex {
		final shape: RefShape = plugin.refShape();
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final symbols: SymbolIndex = index ?? SymbolIndex.build(files, plugin);
		final literalTypes: Map<String, String> = shape.literalTypeNames ?? [];
		final builtinNames: Array<String> = [];
		for (v in literalTypes) if (!builtinNames.contains(v)) builtinNames.push(v);
		final unwrapNames: Array<String> = shape.nullableReturnMarkerTypes ?? [];
		final rejectNames: Array<String> = shape.nullableWrapperTypeNames ?? [];
		final typeParams: Map<String, Array<String>> = [];
		final writes: Array<FieldWrite> = [];
		final unresolved: Array<UnresolvedWrite> = [];
		for (entry in files) {
			final parsed: Null<QueryNode> = try plugin.parseFile(entry.source) catch (_: Exception) null;
			if (parsed == null) continue;
			final tree: QueryNode = parsed;
			final ctx: ScanCtx = {
				file: entry.file,
				source: entry.source,
				tree: tree,
				shape: shape,
				typeSources: provider != null ? provider.declaredTypeSources(entry.source) : [],
				index: symbols,
				writes: writes,
				unresolved: unresolved,
				writeKinds: shape.writeParentKinds,
				containerKinds: shape.visibilityContainerKinds ?? [],
				faKind: shape.fieldAccessKind,
				identKind: shape.identKind,
				selfText: shape.selfReferenceText,
				opaque: shape.opaqueKinds ?? [],
				untypedKinds: shape.untypedKinds ?? [],
				assignKind: shape.assignKind,
				indexKind: shape.indexAccessKind,
				literalTypes: literalTypes,
				elementTypeParams: shape.indexedElementTypeParams ?? [],
				builtinNames: builtinNames,
				unwrapNames: unwrapNames,
				rejectNames: rejectNames,
				casePatternKind: shape.plainCasePatternKind,
				binderKinds: shape.casePatternBinderKinds ?? [],
				aliasKinds: shape.aliasingDeclKinds ?? [],
				abstractThisKinds: shape.underlyingThisTypeKinds ?? [],
				typeParams: typeParams,
				patternNames: null
			};
			scan(tree, null, false, ctx);
		}
		return new FieldWriteIndex(
			writes, unresolved, symbols, shape.classDeclKinds ?? [], builtinNames, unwrapNames, rejectNames, typeParams
		);
	}

	/**
	 * Walk `node`, threading the enclosing type context and collecting each type
	 * header's type-parameter names; on a write-parent node, classify its target. A
	 * macro-reification or `untyped` subtree is descended with `inOpaque` set,
	 * marking every write target there unresolved with an unknown RHS.
	 */
	private static function scan(node: QueryNode, typeCtx: Null<WriteTypeCtx>, inOpaque: Bool, c: ScanCtx): Void {
		final opaque: Bool = inOpaque || c.opaque.contains(node.kind) || c.untypedKinds.contains(node.kind);
		var ctx: Null<WriteTypeCtx> = typeCtx;
		if (c.containerKinds.contains(node.kind)) {
			final nm: Null<String> = node.name;
			if (nm != null) {
				ctx = {
					name: nm,
					kind: node.kind,
					memberFroms: directMemberFroms(node)
				};
				final sp: Null<Span> = node.span;
				if (sp != null) mergeTypeParams(c.typeParams, nm, headerTypeParams(c.source, nm, sp.from));
			}
		}
		if (c.writeKinds.contains(node.kind)) classify(node, ctx, opaque, c);
		for (child in node.children) scan(child, ctx, opaque, c);
	}

	/**
	 * Record the write of `write`'s child-0 target: a `recv.field` field-access
	 * resolves the receiver's static type through `resolveReceiverTypeSource`
	 * (identifier, `this`, chain, index-access, or static root), and a bare
	 * identifier is a field write when its binding is one of the enclosing type's
	 * members — or, unbound, when a supertype declares it (an implicit-`this` write
	 * to the inherited field, attributed to its declarers via `inheritedOwnersOf`).
	 * Every unresolvable receiver marks the field name unresolved, carrying the RHS
	 * literal type of a plain `=` write (`rhsTypeOf`).
	 */
	private static function classify(write: QueryNode, typeCtx: Null<WriteTypeCtx>, inOpaque: Bool, c: ScanCtx): Void {
		if (write.children.length == 0) return;
		final target: QueryNode = write.children[0];
		final tspan: Null<Span> = target.span;
		if (tspan == null) return;
		final span: Span = tspan;
		if (c.faKind != null && target.kind == c.faKind) {
			final field: Null<String> = target.name;
			if (field == null) return;
			final fieldName: String = field;
			if (inOpaque) {
				markUnresolved(c, fieldName, null);
				return;
			}
			final recv: Null<QueryNode> = target.children.length > 0 ? target.children[0] : null;
			if (recv == null) {
				markUnresolved(c, fieldName, rhsTypeOf(write, c));
				return;
			}
			final ts: Null<String> = resolveReceiverTypeSource(recv, typeCtx, c);
			final owner: Null<String> = ts == null ? null : nominalSimpleName(ts, c.unwrapNames, c.rejectNames);
			final rhs: Null<String> = rhsTypeOf(write, c);
			if (owner != null)
				record(c, owner, fieldName, span, rhs);
			else
				markUnresolved(c, fieldName, rhs);
			return;
		}
		if (target.kind == c.identKind) {
			final id: Null<String> = target.name;
			if (id == null) return;
			final idName: String = id;
			if (inOpaque) {
				markUnresolved(c, idName, null);
				return;
			}
			final bf: Null<Int> = TypeResolver.resolveBindingFrom(idName, span, c.tree, c.shape);
			final rhs: Null<String> = rhsTypeOf(write, c);
			if (bf == null) {
				final owners: Array<String> = inheritedOwnersOf(idName, typeCtx, c);
				if (owners.length > 0)
					for (o in owners) record(c, o, idName, span, rhs);
				else
					markUnresolved(c, idName, rhs);
				return;
			}
			final t: Null<WriteTypeCtx> = typeCtx;
			if (t != null && t.memberFroms.contains(bf)) record(c, t.name, idName, span, rhs);
			// else binds to a local / parameter — not a field write, ignored.
		}
		// Other target shapes (a call result, a bare index access) are not field writes.
	}

	/**
	 * Append a resolved write of `owner`.`field` at `span` — after the OWNER GATE:
	 * a name the write can soundly be filed under is a builtin value type or a name
	 * the symbol index declares with no aliasing decl (`allowedOwner`). Any other
	 * name — an external type, or an unprojected TYPE PARAMETER (`s:T`) — must not
	 * absorb the write: filing it under a nonexistent owner would silently drop it,
	 * so it falls back to the unresolved bail with the caller's RHS type.
	 */
	private static function record(c: ScanCtx, owner: String, field: String, span: Span, rhsType: Null<String>): Void {
		if (!allowedOwner(owner, c)) {
			markUnresolved(c, field, rhsType);
			return;
		}
		c.writes.push({
			owner: owner,
			field: field,
			file: c.file,
			span: span
		});
	}

	/** Binding-span starts of the directly-declared field members of a type-body node. */
	private static function directMemberFroms(node: QueryNode): Array<Int> {
		final out: Array<Int> = [];
		for (child in node.children) if (RefactorSupport.FIELD_MEMBER_KINDS.contains(child.kind)) {
			final sp: Null<Span> = child.span;
			if (sp != null) out.push(sp.from);
		}
		return out;
	}

	/** Add an unresolved write of `field` with RHS type `rhsType` (null = unknown), deduplicated by the pair. */
	private static function markUnresolved(c: ScanCtx, field: String, rhsType: Null<String>): Void {
		for (u in c.unresolved) if (u.field == field && u.rhsType == rhsType) return;
		c.unresolved.push({ field: field, rhsType: rhsType });
	}

	/**
	 * The RHS builtin literal type of a plain `=` write — `String` / `Int` /
	 * `Float` / `Bool` per the grammar's `literalTypeNames` — or null for a
	 * compound write, an increment, or a non-literal RHS.
	 */
	private static function rhsTypeOf(write: QueryNode, c: ScanCtx): Null<String> {
		return c.assignKind == null || write.kind != c.assignKind || write.children.length < 2
			? null
			: c.literalTypes[write.children[1].kind];
	}

	/**
	 * Resolve the STATIC declared type SOURCE of a receiver expression: an
	 * identifier (`resolveIdentTypeSource`), a field-access chain (each member step
	 * through the symbol index's supertype-closure member lookup), or an
	 * index-access (the container's element type parameter). Any other shape — a
	 * call result, a cast, a safe access — yields null: unresolvable.
	 */
	private static function resolveReceiverTypeSource(node: QueryNode, typeCtx: Null<WriteTypeCtx>, c: ScanCtx): Null<String> {
		if (node.kind == c.identKind) return resolveIdentTypeSource(node, typeCtx, c);
		if (c.faKind != null && node.kind == c.faKind) {
			final member: Null<String> = node.name;
			if (member == null || node.children.length == 0) return null;
			final recvTs: Null<String> = resolveReceiverTypeSource(node.children[0], typeCtx, c);
			if (recvTs == null) return null;
			final recvName: Null<String> = nominalSimpleName(recvTs, c.unwrapNames, c.rejectNames);
			return recvName == null ? null : memberTypeSourceInChain(c.index, recvName, member, []);
		}
		if (c.indexKind != null && node.kind == c.indexKind) {
			if (node.children.length == 0) return null;
			final containerTs: Null<String> = resolveReceiverTypeSource(node.children[0], typeCtx, c);
			return containerTs == null ? null : elementTypeSource(containerTs, c);
		}
		return null;
	}

	/**
	 * Resolve an identifier receiver's declared type source: `this` → the enclosing
	 * type (unless the container is an `underlyingThisTypeKinds` abstract, where
	 * `this` is the untyped underlying value); a BOUND identifier → its verbatim
	 * `:Type` annotation; an UNBOUND identifier — an inherited field resolved
	 * through the enclosing type's supertype chain, or a capitalized name declaring
	 * an indexed type (a static access). EVERY non-`this` arm — bound included —
	 * bails when a case-pattern in the file binds the name: a pattern variable is
	 * invisible to the scope resolver, so a "bound" identifier may in fact be the
	 * shadowing pattern variable (`case Leaf(outer):` over a typed param `outer`).
	 */
	private static function resolveIdentTypeSource(node: QueryNode, typeCtx: Null<WriteTypeCtx>, c: ScanCtx): Null<String> {
		final name: Null<String> = node.name;
		final sp: Null<Span> = node.span;
		if (name == null || sp == null) return null;
		if (c.selfText != null && name == c.selfText) {
			final t: Null<WriteTypeCtx> = typeCtx;
			return t == null || c.abstractThisKinds.contains(t.kind) ? null : t.name;
		}
		if (patternShadows(name, c)) return null;
		final bf: Null<Int> = TypeResolver.resolveBindingFrom(name, sp, c.tree, c.shape);
		if (bf != null) return c.typeSources[bf];
		final t: Null<WriteTypeCtx> = typeCtx;
		if (t != null) {
			final inherited: Null<String> = memberTypeSourceInChain(c.index, t.name, name, []);
			if (inherited != null) return inherited;
		}
		return RefactorSupport.isUpperInitial(name) && declaresType(c.index, name) ? name : null;
	}

	/**
	 * The unanimous member type source of `typeName`.`member`, resolved through the
	 * supertype closure: a direct member first (`SymbolIndex.memberTypeSourceOf` —
	 * sound alone, Haxe forbids redeclaring an inherited field), then each
	 * supertype recursively. A simple-name collision on the walk origin, a
	 * disagreement between supertype branches, or a cycle yields null.
	 */
	private static function memberTypeSourceInChain(
		index: SymbolIndex, typeName: String, member: String, seen: Array<String>
	): Null<String> {
		if (seen.contains(typeName)) return null;
		seen.push(typeName);
		final direct: Null<String> = index.memberTypeSourceOf(typeName, member);
		if (direct != null) return direct;
		final decls: Array<TypeDeclInfo> = declsNamedIn(index, typeName);
		if (decls.length != 1) return null;
		var found: Null<String> = null;
		for (sup in decls[0].supertypes) {
			final ts: Null<String> = memberTypeSourceInChain(index, sup, member, seen);
			if (ts != null) {
				if (found != null && found != ts) return null;
				found = ts;
			}
		}
		return found;
	}

	/** Every indexed type declaration named `name`, across all files. */
	private static function declsNamedIn(index: SymbolIndex, name: String): Array<TypeDeclInfo> {
		return [for (fi in index.allFiles()) for (t in fi.types) if (t.name == name) t];
	}

	/** Whether the symbol index has a type declaration named `name`. */
	private static function declaresType(index: SymbolIndex, name: String): Bool {
		return index.declaringFiles(name).length > 0;
	}

	/**
	 * Whether any case-pattern in the file binds (or mentions) `name`. A pattern
	 * variable is not a scope-resolver binding — it can SHADOW a typed local, an
	 * inherited field, or a type name, so a same-named identifier resolution
	 * anywhere in the file is unsound. Two binder shapes are collected: every name
	 * inside a `plainCasePatternKind` subtree, and each `casePatternBinderKinds`
	 * node's own name (`case var x:` — no identifier child). Conservative: a
	 * grammar exposing neither kind disables identifier resolution entirely.
	 */
	private static function patternShadows(name: String, c: ScanCtx): Bool {
		if (c.casePatternKind == null && c.binderKinds.length == 0) return true;
		var names: Null<Array<String>> = c.patternNames;
		if (names == null) {
			names = [];
			collectPatternNames(c.tree, false, names, c);
			c.patternNames = names;
		}
		return names.contains(name);
	}

	/** Collect into `out` every name inside a case-pattern subtree and every pattern-binder node's name. */
	private static function collectPatternNames(node: QueryNode, inPattern: Bool, out: Array<String>, c: ScanCtx): Void {
		final within: Bool = inPattern || (c.casePatternKind != null && node.kind == c.casePatternKind);
		final nm: Null<String> = node.name;
		if (nm != null && (within || c.binderKinds.contains(node.kind)) && !out.contains(nm)) out.push(nm);
		for (child in node.children) collectPatternNames(child, within, out, c);
	}

	/**
	 * The nominal SIMPLE name a verbatim type source denotes: `Null<…>` wrappers
	 * unwrapped, a package path reduced to its last segment, type parameters
	 * dropped. Null when the source is not a plain dotted nominal (a function or
	 * anonymous-struct type) or names an untypable wrapper (`Dynamic` / `Any`).
	 */
	private static function nominalSimpleName(source: String, unwrapNames: Array<String>, rejectNames: Array<String>): Null<String> {
		final parsed: Null<NominalParts> = nominalParse(source, unwrapNames);
		return parsed == null || rejectNames.contains(parsed.name) ? null : parsed.name;
	}

	/**
	 * Parse a verbatim type source into its nominal simple name and raw
	 * type-parameter text: `Null<…>` wrappers (`unwrapNames`) unwrapped first, then
	 * the head validated as a dotted identifier path. Null for any other shape.
	 */
	private static function nominalParse(source: String, unwrapNames: Array<String>): Null<NominalParts> {
		var t: String = StringTools.trim(source);
		var unwrapped: Bool = true;
		while (unwrapped) {
			unwrapped = false;
			for (w in unwrapNames) if (StringTools.startsWith(t, w)) {
				final rest: String = StringTools.trim(t.substring(w.length));
				if (StringTools.startsWith(rest, '<') && StringTools.endsWith(rest, '>')) {
					t = StringTools.trim(rest.substring(1, rest.length - 1));
					unwrapped = true;
					break;
				}
			}
		}
		final lt: Int = t.indexOf('<');
		if (lt < 0) return isDottedIdentPath(t) ? { name: lastSegment(t), params: null } : null;
		if (!StringTools.endsWith(t, '>')) return null;
		final head: String = StringTools.trim(t.substring(0, lt));
		return isDottedIdentPath(head) ? { name: lastSegment(head), params: t.substring(lt + 1, t.length - 1) } : null;
	}

	/**
	 * The ELEMENT type source an index access `container[key]` yields, per the
	 * container's `RefShape.indexedElementTypeParams` entry — `Map<K, V>` → `V`,
	 * `Array<T>` → `T`. Null when the container is not such a type, carries no
	 * parameters, or the listed parameter is missing.
	 */
	private static function elementTypeSource(containerSource: String, c: ScanCtx): Null<String> {
		final parsed: Null<NominalParts> = nominalParse(containerSource, c.unwrapNames);
		if (parsed == null) return null;
		final params: Null<String> = parsed.params;
		final at: Null<Int> = c.elementTypeParams[parsed.name];
		if (params == null || at == null) return null;
		final split: Array<String> = splitTypeParams(params);
		return at < split.length ? split[at] : null;
	}

	/**
	 * Split a type-parameter list on its TOP-LEVEL commas, respecting nested
	 * `<…>` / `(…)` groups (`Map<String, (Int, Int) -> Void>` splits into two) and
	 * the `->` arrow whose `>` is not a bracket closer.
	 */
	private static function splitTypeParams(text: String): Array<String> {
		final out: Array<String> = [];
		var depth: Int = 0;
		var start: Int = 0;
		var prev: Int = 0;
		for (i in 0...text.length) {
			final ch: Int = StringTools.fastCodeAt(text, i);
			if (ch == '<'.code || ch == '('.code)
				depth++;
			else if (ch == ')'.code)
				depth--;
			else if (ch == '>'.code && prev != '-'.code)
				depth--;
			else if (ch == ','.code && depth == 0) {
				out.push(StringTools.trim(text.substring(start, i)));
				start = i + 1;
			}
			prev = ch;
		}
		out.push(StringTools.trim(text.substring(start)));
		return out;
	}

	/** Whether `s` is a plain dotted identifier path (`pkg.sub.Name`), with no other characters. */
	private static function isDottedIdentPath(s: String): Bool {
		if (s.length == 0) return false;
		var expectStart: Bool = true;
		for (i in 0...s.length) {
			final ch: Int = StringTools.fastCodeAt(s, i);
			if (expectStart) {
				if (!RefactorSupport.isIdentStartChar(ch)) return false;
				expectStart = false;
			} else if (ch == '.'.code)
				expectStart = true;
			else if (!RefactorSupport.isIdentChar(ch))
				return false;
		}
		return !expectStart;
	}

	/** The last `.`-separated segment of `path` (its simple name). */
	private static function lastSegment(path: String): String {
		final dot: Int = path.lastIndexOf('.');
		return dot < 0 ? path : path.substring(dot + 1);
	}

	/**
	 * The declaring owners of an UNBOUND bare-identifier write target: every type in
	 * the enclosing type's supertype closure (itself included) that directly
	 * declares a member named `name` — the write is then an implicit-`this` write to
	 * that inherited field. Empty when there is no enclosing type, no declarer, or a
	 * case-pattern in the file binds the name (a pattern variable would shadow the
	 * field). A simple-name collision merges declarers conservatively —
	 * over-attribution only ever keeps a field mutable.
	 */
	private static function inheritedOwnersOf(name: String, typeCtx: Null<WriteTypeCtx>, c: ScanCtx): Array<String> {
		final t: Null<WriteTypeCtx> = typeCtx;
		if (t == null || patternShadows(name, c)) return [];
		final out: Array<String> = [];
		collectDeclaringSupertypes(c.index, t.name, name, [], out);
		return out;
	}

	/** Collect into `out` every type in `typeName`'s supertype closure (`typeName` included) directly declaring a member named `member`. */
	private static function collectDeclaringSupertypes(
		index: SymbolIndex, typeName: String, member: String, seen: Array<String>, out: Array<String>
	): Void {
		if (seen.contains(typeName)) return;
		seen.push(typeName);
		for (d in declsNamedIn(index, typeName)) {
			for (m in d.members) if (m.name == member) {
				if (!out.contains(typeName)) out.push(typeName);
				break;
			}
			for (sup in d.supertypes) collectDeclaringSupertypes(index, sup, member, seen, out);
		}
	}

	/**
	 * Whether `owner` may carry a resolved write: a builtin value type, or a name
	 * the symbol index declares whose decls are all free of aliasing semantics —
	 * not a typedef (the write actually targets the aliased type) and not an
	 * abstract (a `@:forward` field access writes the UNDERLYING type's field).
	 */
	private static function allowedOwner(owner: String, c: ScanCtx): Bool {
		if (c.builtinNames.contains(owner)) return true;
		final decls: Array<TypeDeclInfo> = declsNamedIn(c.index, owner);
		if (decls.length == 0) return false;
		for (d in decls) if (c.aliasKinds.contains(d.kind)) return false;
		return true;
	}

	/**
	 * The type-parameter names of a type-declaration header (`class Cell<Data,
	 * K:B>` → `Data`, `K`), extracted TEXTUALLY from the decl's source slice — the
	 * `QueryNode` projection drops type parameters, so the header text is the only
	 * carrier. Empty when the header carries none or the shape is unrecognisable
	 * (a miss only loses a poison guard elsewhere is compensating for, never a
	 * write).
	 */
	private static function headerTypeParams(source: String, name: String, from: Int): Array<String> {
		final bodyAt: Int = source.indexOf('{', from);
		final nameAt: Int = source.indexOf(name, from);
		if (nameAt < 0 || (bodyAt >= 0 && nameAt > bodyAt)) return [];
		var i: Int = nameAt + name.length;
		while (i < source.length && RefactorSupport.isSpace(StringTools.fastCodeAt(source, i))) i++;
		if (i >= source.length || StringTools.fastCodeAt(source, i) != '<'.code) return [];
		var depth: Int = 1;
		final start: Int = i + 1;
		var j: Int = start;
		var prev: Int = 0;
		while (j < source.length && depth > 0) {
			final ch: Int = StringTools.fastCodeAt(source, j);
			if (ch == '<'.code)
				depth++;
			else if (ch == '>'.code && prev != '-'.code)
				depth--;
			prev = ch;
			j++;
		}
		if (depth != 0) return [];
		final out: Array<String> = [];
		for (p in splitTypeParams(source.substring(start, j - 1))) {
			final colon: Int = p.indexOf(':');
			final nm: String = StringTools.trim(colon < 0 ? p : p.substring(0, colon));
			if (isDottedIdentPath(nm) && !out.contains(nm)) out.push(nm);
		}
		return out;
	}

	/** Union `params` into `map[owner]` — a simple-name collision merges conservatively (more names → more poisons). */
	private static function mergeTypeParams(map: Map<String, Array<String>>, owner: String, params: Array<String>): Void {
		if (params.length == 0) return;
		final cur: Null<Array<String>> = map[owner];
		if (cur == null)
			map[owner] = params;
		else
			for (p in params) if (!cur.contains(p)) cur.push(p);
	}

}
