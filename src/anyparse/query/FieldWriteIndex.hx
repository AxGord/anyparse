package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * One resolved field write: `owner`.`field` written at `(file, span)`. The owner
 * is the SIMPLE type name the receiver resolves to (`this`, or a typed
 * local / param / field receiver) — the same simple-name keying `SymbolIndex`
 * uses, so an ambiguous simple name conservatively merges writes across
 * same-named types (over-attribution only ever KEEPS a field mutable).
 */
typedef FieldWrite = {
	var owner: String;
	var field: String;
	var file: String;
	var span: Span;
}

/**
 * The current type-body context threaded down the walk: the enclosing type's
 * simple name plus the binding-span starts of its directly-declared members, so a
 * bare-identifier write (`field = …`) can be told apart from a local/param write —
 * it is a field write only when its binding resolves to one of these.
 */
typedef WriteTypeCtx = {
	var name: String;
	var memberFroms: Array<Int>;
}

/**
 * Run-scoped invariants for the per-file write scan, bundled so the recursive
 * `scan` / `classify` need not thread a dozen scalars.
 */
typedef ScanCtx = {
	var file: String;
	var tree: QueryNode;
	var shape: RefShape;
	var declaredTypes: Map<Int, String>;
	var writes: Array<FieldWrite>;
	var unresolved: Array<String>;
	var writeKinds: Array<String>;
	var containerKinds: Array<String>;
	var faKind: Null<String>;
	var identKind: String;
	var selfText: Null<String>;
	var opaque: Array<String>;
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
 * collide across types. Receiver types are recovered via `TypeInfoProvider`'s
 * declared-type map and the scope resolver, exactly as `TypeResolver` does for read
 * purity.
 *
 * ## Soundness — over-count toward "written"
 *
 * A false negative (a missed write) is the dangerous direction: it would let a check
 * rewrite a field that IS reassigned, a compile error. So every write whose receiver
 * the index cannot resolve to a concrete type is recorded as an UNRESOLVED write of
 * that field NAME (`hasUnresolvedWrite`), never silently dropped — a consumer must
 * bail on any candidate whose name has an unresolved write. A macro reification (`opaqueKinds`) subtree is descended into, not skipped: its generated code can write a REAL runtime field (`ctx.pos++` in an emitted parser), so every write target there is marked an unresolved write of that field name (the emitted receiver cannot be typed) — bailing the field rather than missing the write.
 */
@:nullSafety(Strict)
final class FieldWriteIndex {

	private final _writes: Array<FieldWrite>;
	private final _unresolved: Array<String>;

	private function new(writes: Array<FieldWrite>, unresolved: Array<String>) {
		_writes = writes;
		_unresolved = unresolved;
	}

	/** Whether any resolved write targets `type`.`field` anywhere in the file set. */
	public function writtenAnywhere(type: String, field: String): Bool {
		for (w in _writes) if (w.owner == type && w.field == field) return true;
		return false;
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
		return _unresolved.contains(field);
	}

	/**
	 * Parse every `(file, source)` entry (skip-parse tolerant, never throws) and walk
	 * each for write sites, resolving each write's receiver type via the plugin's
	 * `TypeInfoProvider` declared-type map and the scope resolver. A plugin without the
	 * capability yields no declared types, so every receiver is unresolved — every
	 * candidate then bails, which is sound.
	 */
	public static function build(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): FieldWriteIndex {
		final shape: RefShape = plugin.refShape();
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final writes: Array<FieldWrite> = [];
		final unresolved: Array<String> = [];
		for (entry in files) {
			final parsed: Null<QueryNode> = try plugin.parseFile(entry.source) catch (_: Exception) null;
			if (parsed == null) continue;
			final tree: QueryNode = parsed;
			final declaredTypes: Map<Int, String> = provider != null ? provider.declaredTypes(entry.source) : [];
			final ctx: ScanCtx = {
				file: entry.file,
				tree: tree,
				shape: shape,
				declaredTypes: declaredTypes,
				writes: writes,
				unresolved: unresolved,
				writeKinds: shape.writeParentKinds,
				containerKinds: shape.visibilityContainerKinds ?? [],
				faKind: shape.fieldAccessKind,
				identKind: shape.identKind,
				selfText: shape.selfReferenceText,
				opaque: shape.opaqueKinds ?? []
			};
			scan(tree, null, false, ctx);
		}
		return new FieldWriteIndex(writes, unresolved);
	}

	/**
	 * Walk `node`, threading the enclosing type context; on a write-parent node,
	 * classify its child-0 target. A macro-reification subtree is not descended.
	 */
	private static function scan(node: QueryNode, typeCtx: Null<WriteTypeCtx>, inOpaque: Bool, c: ScanCtx): Void {
		// A macro-reification subtree is NOT skipped: the generated code there can
		// write a REAL runtime field (`ctx.pos++` / `ctx.pos = …`), so dropping it
		// would miss those writes and wrongly flag the field. Instead every write
		// target inside it is marked unresolved (the receiver is an emitted runtime
		// variable the resolver cannot type), which conservatively bails the field.
		final opaque: Bool = inOpaque || c.opaque.contains(node.kind);
		var ctx: Null<WriteTypeCtx> = typeCtx;
		if (c.containerKinds.contains(node.kind)) {
			final nm: Null<String> = node.name;
			if (nm != null) ctx = { name: nm, memberFroms: directMemberFroms(node) };
		}
		if (c.writeKinds.contains(node.kind) && node.children.length > 0) classify(node.children[0], ctx, opaque, c);
		for (child in node.children) scan(child, ctx, opaque, c);
	}

	/**
	 * Record a write for `target` (a write node's child-0): a `recv.field` field-access
	 * resolves the receiver's type (`this` → the enclosing type; a typed identifier →
	 * its declared type; anything else → unresolved field name), and a bare identifier
	 * is a field write only when its binding is one of the enclosing type's members.
	 */
	private static function classify(target: QueryNode, typeCtx: Null<WriteTypeCtx>, inOpaque: Bool, c: ScanCtx): Void {
		final tspan: Null<Span> = target.span;
		if (tspan == null) return;
		final span: Span = tspan;
		if (c.faKind != null && target.kind == c.faKind) {
			final field: Null<String> = target.name;
			if (field == null) return;
			final fieldName: String = field;
			if (inOpaque) {
				markUnresolved(c.unresolved, fieldName);
				return;
			}
			final recv: Null<QueryNode> = target.children.length > 0 ? target.children[0] : null;
			if (recv == null) {
				markUnresolved(c.unresolved, fieldName);
				return;
			}
			if (recv.kind == c.identKind && c.selfText != null && recv.name == c.selfText) {
				final t: Null<WriteTypeCtx> = typeCtx;
				if (t != null)
					record(c, t.name, fieldName, span);
				else
					markUnresolved(c.unresolved, fieldName);
				return;
			}
			final recvName: Null<String> = recv.name;
			final recvSpan: Null<Span> = recv.span;
			if (recv.kind == c.identKind && recvName != null && recvSpan != null) {
				final bf: Null<Int> = TypeResolver.resolveBindingFrom(recvName, recvSpan, c.tree, c.shape);
				final ty: Null<String> = bf == null ? null : c.declaredTypes[bf];
				if (ty != null)
					record(c, ty, fieldName, span);
				else
					markUnresolved(c.unresolved, fieldName);
				return;
			}
			markUnresolved(c.unresolved, fieldName);
			return;
		}
		if (target.kind == c.identKind) {
			final id: Null<String> = target.name;
			if (id == null) return;
			final idName: String = id;
			if (inOpaque) {
				markUnresolved(c.unresolved, idName);
				return;
			}
			final bf: Null<Int> = TypeResolver.resolveBindingFrom(idName, span, c.tree, c.shape);
			if (bf == null) {
				markUnresolved(c.unresolved, idName);
				return;
			}
			final t: Null<WriteTypeCtx> = typeCtx;
			if (t != null && t.memberFroms.contains(bf)) record(c, t.name, idName, span);
			// else binds to a local / parameter — not a field write, ignored.
		}
		// IndexAccess / call / other targets are not field writes.
	}

	/** Append a resolved write of `owner`.`field` at `span` in the current file. */
	private static inline function record(c: ScanCtx, owner: String, field: String, span: Span): Void {
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

	/** Add `name` to the unresolved-field-name set if not already present. */
	private static inline function markUnresolved(list: Array<String>, name: String): Void {
		if (!list.contains(name)) list.push(name);
	}

}
