package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.MemberLookup.HostedMembers;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.query.TypingService.Resolution;
import anyparse.runtime.Span;

using Lambda;

/**
 * Whether an access chain reads storage nothing rebinds while code runs: the one answer to "is this a local or parameter
 * no call writes (`UnchangedLocal`), or a member declared final with no getter, followed by such members only".
 *
 * A member counts when every declaration of it a build may compile (`BuildBranches.declarations`) is a data field outside
 * `RefShape.mutableFieldDeclKinds` with no getter, on a plain class (`classDeclKinds`): an interface or a structure field
 * may be implemented by a property that computes it. A link's type is the typing service's (`MemberLookup.memberRead`,
 * `TypingService.resolve`); a link it cannot name ends the chain. A write of the chain itself (a constructor assigning
 * the final) stays the caller's question (`WriteSites`). Instance state of one file's scan, never shared.
 */
@:nullSafety(Strict)
final class StableChain {

	private final _tree: QueryNode;
	private final _shape: RefShape;
	private final _locals: UnchangedLocal;
	private final _typeSources: () -> Map<Int, String>;
	private final _index: () -> Null<SymbolIndex>;
	private final _file: String;

	/**
	 * `typeSources`: each declaration's written type by binding offset (`TypeInfoProvider.declaredTypeSources`); `index`:
	 * the run's declarations, asked only when a chain reaches past a local.
	 */
	public function new(
		tree: QueryNode, shape: RefShape, locals: UnchangedLocal, typeSources: () -> Map<Int, String>, index: () -> Null<SymbolIndex>,
		file: String
	) {
		_tree = tree;
		_shape = shape;
		_locals = locals;
		_typeSources = typeSources;
		_index = index;
		_file = file;
	}

	/**
	 * The chain `node` reads when it is stable, keyed like a `WriteSites` path whose member roots are under any binding
	 * (`x` and `this.x` alike `x@*`); null otherwise.
	 */
	public function read(node: QueryNode): Null<StableRead> {
		final found: Null<Link> = link(node);
		return found == null ? null : { key: found.key, binding: found.binding };
	}

	private function link(node: QueryNode): Null<Link> {
		final name: Null<String> = node.name;
		final span: Null<Span> = node.span;
		if (name == null || span == null) return null;
		if (node.kind == _shape.identKind) {
			if (name == _shape.selfReferenceText) return null;
			final binding: Null<Int> = Refs.bindingAt(name, span.from, _tree, _shape);
			if (binding == null) return null;
			if (_locals.survivesCalls(node)) return { key: '$name@$binding', binding: binding, type: _typeSources()[binding] };
			return _locals.isLocal(binding) ? null : memberLink(enclosing(span.from), name, null);
		}
		if (node.kind != _shape.fieldAccessKind || node.children.length != 1) return null;
		final inner: QueryNode = node.children[0];
		if (inner.kind == _shape.identKind && inner.name == _shape.selfReferenceText) return memberLink(enclosing(span.from), name, null);
		final below: Null<Link> = link(inner);
		return below == null ? null : memberLink(resolved(below.type, span.from), name, below);
	}

	/** The link reading `name` off `host` below `below` (a root when null), when every live declaration of it is a final field. */
	private function memberLink(host: Null<ResolvedType>, name: String, below: Null<Link>): Null<Link> {
		final index: Null<SymbolIndex> = _index();
		if (host == null || index == null) return null;
		final hit: Null<HostedMembers> = index.typing.members.declaringMember(host, name);
		if (hit == null || !(_shape.classDeclKinds ?? []).contains(hit.host.type.kind)) return null;
		final live: Array<MemberInfo> = index.typing.builds.declarations(hit.host, name);
		if (live.length == 0 || !live.foreach(isFinalField)) return null;
		final reader: Null<FileInfo> = index.fileInfo(_file);
		if (reader == null) return null;
		final type: Null<String> = index.typing.members.memberRead(host, name, [], reader)?.text;
		return below == null
			? { key: '$name@*', binding: -1, type: type }
			: { key: '${below.key}.$name', binding: below.binding, type: type };
	}

	private function isFinalField(m: MemberInfo): Bool {
		return (_shape.fieldDeclKinds ?? []).contains(m.kind)
			&& !(_shape.mutableFieldDeclKinds ?? []).contains(m.kind)
			&& !m.hasGetter
			&& !m.isDynamic;
	}

	/** The type declaration of this file holding offset `at`. */
	private function enclosing(at: Int): Null<ResolvedType> {
		final file: Null<FileInfo> = _index()?.fileInfo(_file);
		if (file == null) return null;
		final type: Null<TypeDeclInfo> = file.types.find(t -> t.span.from <= at && at < t.span.to);
		return type == null ? null : { file: file, type: type };
	}

	/** The one declaration the type `spelling`, written in this file at `at`, denotes; null when none is proven. */
	private function resolved(spelling: Null<String>, at: Int): Null<ResolvedType> {
		final index: Null<SymbolIndex> = _index();
		final file: Null<FileInfo> = index?.fileInfo(_file);
		if (spelling == null || index == null || file == null) return null;
		return switch index.typing.resolve(file, spelling, at) {
			case Declared(decl): decl;
			case Unknown: null;
		};
	}

}

/** A stable chain: its key, and the binding offset of its root when that is a local (-1 for a member). */
typedef StableRead = {
	final key: String;
	final binding: Int;
}

/** One link of a chain being read: its key, root binding and the type it reads in the file's spelling, when written. */
private typedef Link = {
	final key: String;
	final binding: Int;
	final type: Null<String>;
}
