package anyparse.check.scan;

import anyparse.query.MemberLookup.HostedMembers;
import anyparse.query.NominalTypes;
import anyparse.query.Refs.RefHit;
import anyparse.query.ShapeVocab;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.query.ValueNameBinding.ImportedStatics;

/**
 * The one answer to "which member declarations does this call's callee name": `m` as the enclosing type's member
 * (inherited included) unless a local shadows it, else what an `import` names; `recv.m` off the receiver's one resolved
 * type, else a `using` extension. Null where unproven — an ambiguous receiver, a library the index does not read.
 */
@:nullSafety(Strict)
final class CalleeResolver {

	private final _binder: OperandBinder;
	private final _file: String;
	private final _tree: QueryNode;
	private final _shape: RefShape;
	private final _index: SymbolIndex;
	private final _identKinds: Array<String>;

	public function new(binder: OperandBinder, file: String, tree: QueryNode, shape: RefShape, index: SymbolIndex) {
		_binder = binder;
		_file = file;
		_tree = tree;
		_shape = shape;
		_index = index;
		_identKinds = [
			for (kind in [shape.identKind, shape.stringInterpIdentKind]) if (kind != null) kind
		];
	}

	/** The members `callee` names (`resolve`), or null. */
	public function calleeMembers(callee: QueryNode): Null<Array<MemberInfo>> {
		return resolve(callee)?.members;
	}

	/**
	 * The declarations `callee` names and how the call reaches them. An `extension` callee is a static extension: its
	 * receiver is the declaration's FIRST argument, so every written argument sits one parameter later.
	 */
	public function resolve(callee: QueryNode): Null<ResolvedCallee> {
		final name: Null<String> = callee.name;
		final span: Null<Span> = callee.span;
		if (name == null || span == null) return null;
		if (_identKinds.contains(callee.kind)) return bare(name, span);
		if (callee.kind != _shape.fieldAccessKind || callee.children.length != 1) return null;
		final owners: Null<Array<ResolvedType>> = ownersOfReceiver(callee.children[0]);
		if (owners == null || owners.length == 0) return usingExtension(name);
		if (owners.length != 1) return null;
		final own: Null<HostedMembers> = _binder.declarationOf(owners[0], name);
		if (own != null) return { members: own.members, host: own.host, extension: false };
		final fi: Null<FileInfo> = _index.fileInfo(_file);
		final bound: Null<HostedMembers> = fi == null ? null : _index.typing.extensions.binding(fi, owners[0], name);
		return bound == null ? usingExtension(name) : { members: bound.members, host: bound.host, extension: true };
	}

	/** A bare `m(…)`: the enclosing type's member unless this file binds the name, else the static an import brings. */
	private function bare(name: String, span: Span): Null<ResolvedCallee> {
		// Only a local, parameter or local function shadows the bare name: a binding to a MEMBER of the enclosing type is
		// exactly what the call names.
		final hit: Null<RefHit> = TypeResolver.resolveBindingHit(name, span, _tree, _shape);
		final bound: Null<QueryNode> = hit?.bindingNode;
		final shadowed: Bool = bound == null
			? OperandBinder.bindsHere(hit)
			: ShapeVocab.localOrParamKinds(_shape).contains(bound.kind) || (_shape.localFunctionKinds ?? []).contains(bound.kind);
		if (shadowed) return null;
		final enclosing: Null<ResolvedType> = _binder.enclosingDeclaration(span);
		final own: Null<HostedMembers> = enclosing == null ? null : _binder.declarationOf(enclosing, name);
		if (own != null) return { members: own.members, host: own.host, extension: false };
		// A member the closure may hold unseen outranks every import, so the import is read only past a proven absence.
		if (bound != null || (enclosing != null && !_index.typing.members.declarationFreeOfExtensionTypes(enclosing))) return null;
		return importedStatic(name, span.from);
	}

	/** The one static a static import of this file brings in under `name`, as its owner declares it. */
	private function importedStatic(name: String, at: Int): Null<ResolvedCallee> {
		final fi: Null<FileInfo> = _index.fileInfo(_file);
		if (fi == null) return null;
		final found: ImportedStatics = _index.values.importedStatics(fi, name, at);
		if (found.unknown || found.statics.length != 1 || found.statics[0].decls.length != 1) return null;
		final declared: Null<HostedMembers> = _binder.declarationOf(found.statics[0].decls[0], found.statics[0].member);
		final statics: Array<MemberInfo> = declared == null ? [] : declared.members.filter(m -> m.isStatic);
		return declared == null || statics.length == 0 ? null : { members: statics, host: declared.host, extension: false };
	}

	/**
	 * `recv.name(…)` on a receiver no declaration types, or whose one type proves no member `name` and no typed extension
	 * binding of it: the static extension the file's `using`s bind to `name`, when
	 * exactly one of the module's types declares it. The receiver's own type may declare `name` unseen, so a reader
	 * that WRITES on this answer refuses an `extension` callee.
	 */
	private function usingExtension(name: String): Null<ResolvedCallee> {
		final fi: Null<FileInfo> = _index.fileInfo(_file);
		final binding: Null<{ path: String, hosts: Null<Array<ResolvedType>> }> = fi == null
			? null
			: _index.typing.extensions.bindingUsing(fi, name);
		final hosts: Array<ResolvedType> = (binding?.hosts ?? []).filter(h -> h.type.members.exists(m -> m.name == name && m.isStatic));
		return hosts.length != 1
			? null
			: { members: hosts[0].type.members.filter(m -> m.name == name && m.isStatic), host: hosts[0], extension: true };
	}

	/** The declarations a receiver resolves to: its typed binding or type name, else a dotted type path. */
	private function ownersOfReceiver(receiver: QueryNode): Null<Array<ResolvedType>> {
		final named: Null<Array<ResolvedType>> = _binder.receiverDecls(receiver);
		if (named != null) return named;
		final fieldKind: Null<String> = _shape.fieldAccessKind;
		final path: Null<Array<String>> = fieldKind == null ? null : NominalTypes.pathOf(receiver, _shape.identKind, fieldKind);
		final fi: Null<FileInfo> = _index.fileInfo(_file);
		var root: QueryNode = receiver;
		while (root.kind != _shape.identKind && root.children.length == 1) root = root.children[0];
		final rootSpan: Null<Span> = root.span;
		final rootName: Null<String> = root.name;
		if (path == null || path.length < 2 || fi == null || rootSpan == null || rootName == null) return null;
		if (OperandBinder.bindsHere(TypeResolver.resolveBindingHit(rootName, rootSpan, _tree, _shape))) return null;
		return switch _index.refs.names.dottedTierOf(path.join('.'), fi, false, rootSpan.from) {
			case Bound(decls): decls;
			case _: null;
		};
	}

}

/** A callee's declarations, their host, and whether a static extension reaches them. */
typedef ResolvedCallee = { final members: Array<MemberInfo>; final host: ResolvedType; final extension: Bool; }
