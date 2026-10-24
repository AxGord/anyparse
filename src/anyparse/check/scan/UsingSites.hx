package anyparse.check.scan;

import anyparse.query.ArgumentSlots.ArgumentFit;
import anyparse.query.IndexScope;
import anyparse.query.NominalTypes;
import anyparse.query.OccurrenceScan;
import anyparse.query.ShapeVocab;
import anyparse.query.StdTypes;
import anyparse.query.SymbolIndex;
import anyparse.query.ValueDoors;
import haxe.Exception;

/**
 * Whether a `using` takes part in the accesses `recv.name` one source writes — the one answer `unused-import`,
 * `redundant-import`, `hoist-common-import` and the move carry ask, so none of them builds its own. Each access is read
 * once: no `using` takes part (a member of the receiver's type binds first, or a static of the type a type expression
 * names), the receiver's declaration — and then the typing service decides (`StaticExtensions.mayBindThrough`,
 * `offers`) — or not known: an access the parser does not project, a receiver the typer leaves untyped or no declaration
 * resolves. Not known counts as the `using` taking part, the direction a fix deleting or moving the statement must err
 * in. The source is parsed and typed on the first offset asked, once.
 */
@:nullSafety(Strict)
final class UsingSites {

	/** The once-built door, empty until the first offset is asked. */
	private final _door: Array<AccessDoor> = [];

	/** The source whose offsets are asked. */
	private final _source: String;

	/** The grammar that parses and types it. */
	private final _plugin: GrammarPlugin;

	/** The file the source is, which its `using` statements and every type name resolve from. */
	private final _file: String;

	/** The index the caller holds, read where the plugin carries no resolution scope. */
	private final _index: Null<SymbolIndex>;

	public function new(source: String, plugin: GrammarPlugin, file: String, index: Null<SymbolIndex>) {
		_source = source;
		_plugin = plugin;
		_file = file;
		_index = index;
	}

	/**
	 * Whether one of `methods` is spelled as an access `.method` in `[from, to)` of the source that `using <raw>` may bind:
	 * the use test of the statement (`OccurrenceScan.usingExtensionCalled`) with every access this door proves the
	 * statement takes no part in left out.
	 */
	public function calledThrough(raw: String, methods: Array<String>, from: Int = 0, ?to: Int): Bool {
		final text: String = _source.substring(from, to ?? _source.length);
		return OccurrenceScan.usingExtensionCalled(text, raw, methods, at -> !mayBindThrough(from + at, raw));
	}

	/**
	 * Whether `using <path>` and `using <other>` may both offer one access of the source — the access whose winner moving
	 * either statement past the other could change. Only a name both may extend with is weighed (`methodsOf` lists a
	 * module's, null when it cannot); one `path` cannot list contests every access.
	 */
	public function contested(path: String, other: String, methodsOf: (String) -> Null<Array<String>>): Bool {
		final mine: Null<Array<String>> = methodsOf(path);
		if (mine == null) return true;
		final theirs: Null<Array<String>> = methodsOf(other);
		final shared: Array<String> = theirs == null ? mine : mine.filter(m -> theirs.contains(m));
		return shared.exists(m -> OccurrenceScan.methodCalledInSource(_source, m, '', at -> !contestedAt(at, path, other)));
	}

	/** Whether the access whose name the source spells at `at` may bind through `using <path>`. */
	public function mayBindThrough(at: Int, path: String): Bool {
		return switch siteAt(at) {
			case NoUsing: false;
			case Unknown: true;
			case Receiver(fi, receiver, name, index): index.typing.extensions.mayBindThrough(fi, receiver, name, path);
		};
	}

	/** Whether `using <path>` and `using <other>` may both offer the access at `at`. */
	private function contestedAt(at: Int, path: String, other: String): Bool {
		return switch siteAt(at) {
			case NoUsing: false;
			case Unknown: true;
			case Receiver(_, receiver, name, index):
				index.typing.extensions.offers(path, receiver, name) != Misfits
					&& index.typing.extensions.offers(other, receiver, name) != Misfits;
		};
	}

	/**
	 * What the access whose name the source spells at `at` is. A type expression receiver binds a static the type itself
	 * declares; a value receiver a member of its type, proved on one declaration (`MemberLookup.instanceMemberBinds`) or —
	 * for a type no index holds — by the std listing unless a project type takes the name.
	 */
	private function siteAt(at: Int): AccessSite {
		final door: AccessDoor = doorOf();
		final access: Null<QueryNode> = door.accesses[at];
		final typeOf: Null<(QueryNode) -> Null<String>> = door.typeOf;
		final tree: Null<QueryNode> = door.tree;
		final name: Null<String> = access?.name;
		if (access == null || typeOf == null || tree == null || name == null || access.children.length == 0) return Unknown;
		final index: Null<SymbolIndex> = door.index;
		final recv: QueryNode = access.children[0];
		final typeName: Null<String> = index == null ? null : NominalTypes.staticReceiverName(recv, tree, _plugin.refShape(), index);
		if (index != null && typeName != null) return staticSite(index, recv, tree, typeName, name, at);
		final nominal: Null<String> = try typeOf(recv) catch (exception: Exception) null;
		if (nominal == null) return Unknown;
		final indexed: Null<Bool> = index?.typing.members.instanceMemberBinds(nominal, name, _file, at);
		final member: Bool = indexed ?? (
			!NominalTypes.shadowedByNonStdType(index, nominal) && StdTypes.declaresInstanceMember(_plugin, nominal, name)
		);
		if (member) return NoUsing;
		final fi: Null<FileInfo> = index?.fileInfo(_file);
		final start: Null<ResolvedType> = index?.refs.resolveStartType(nominal, _file, at);
		return index == null || fi == null || start == null ? Unknown : Receiver(fi, start, name, index);
	}

	/**
	 * `Type.name` on a type expression: the type's own static of the name binds, and no `using` takes part — unless the
	 * identifier may name a value first (`ValueDoors.bindsNoValue`: a field of the enclosing type, a module-level field, a
	 * static or constructor an import brings), the type or the static is under `#if`, or it declares none, where an extension
	 * taking the class may.
	 */
	private function staticSite(index: SymbolIndex, recv: QueryNode, tree: QueryNode, typeName: String, name: String, at: Int): AccessSite {
		final fi: Null<FileInfo> = index.fileInfo(_file);
		final span: Null<Span> = recv.span;
		if (fi == null || span == null) return Unknown;
		if (!ValueDoors.bindsNoValue(recv, typeName, span, fi, tree, _plugin.refShape(), _file, index)) return Unknown;
		final start: Null<ResolvedType> = index.refs.resolveStartType(typeName, _file, at);
		if (start == null || start.type.guarded) return Unknown;
		final statics: Array<MemberInfo> = start.type.members.filter(m -> m.name == name && m.isStatic);
		return statics.length > 0 && statics.foreach(m -> !m.guarded) ? NoUsing : Unknown;
	}

	/** The door, built on the first offset asked. */
	private function doorOf(): AccessDoor {
		if (_door.length == 0) _door.push(buildDoor());
		return _door[0];
	}

	/** The member accesses of the source by the offset of their name, the receiver typer, the tree and the index. */
	private function buildDoor(): AccessDoor {
		final accesses: Map<Int, QueryNode> = [];
		final tree: Null<QueryNode> = try _plugin.parseFile(_source) catch (exception: Exception) null;
		if (tree == null) return {
			accesses: accesses,
			typeOf: null,
			tree: null,
			index: null
		};
		collectNamedAccesses(tree, _source, ShapeVocab.memberAccessKinds(_plugin.refShape()), accesses);
		return {
			accesses: accesses,
			typeOf: CheckScan.typeNominalResolver(_source, _plugin, tree, _file, _index, true),
			tree: tree,
			index: IndexScope.resolutionIndexOf(_plugin) ?? _index
		};
	}

	/**
	 * The member names a `using` of each module may extend with, by module: the union over every top-level type the module
	 * declares in `index`, main and sub-module alike — a static extension is contributed by every type of the module.
	 */
	public static function membersByModule(index: SymbolIndex): Map<String, Array<String>> {
		final map: Map<String, Array<String>> = [];
		for (info in index.allFiles()) map[info.module] = [for (t in info.types) for (m in t.members) m.name];
		return map;
	}

	/** Every member access under `node` with a name, by the offset of that name in `source`. */
	private static function collectNamedAccesses(node: QueryNode, source: String, kinds: Array<String>, out: Map<Int, QueryNode>): Void {
		final span: Null<Span> = node.span;
		final name: Null<String> = node.name;
		if (span != null && name != null && kinds.contains(node.kind) && span.to >= name.length) {
			final at: Int = span.to - name.length;
			if (source.substr(at, name.length) == name) out[at] = node;
		}
		for (c in node.children) collectNamedAccesses(c, source, kinds, out);
	}

}

/** What one access `recv.name` is to a `using` (`UsingSites`). */
private enum AccessSite {

	/** A member or a static of the receiver's own type binds it, before any static extension. */
	NoUsing;

	/** A value receiver of the declaration `receiver`, in the file `fi` of `index`: the typing service decides. */
	Receiver(fi: FileInfo, receiver: ResolvedType, name: String, index: SymbolIndex);

	/** Not known: counts as the `using` taking part. */
	Unknown;

}

/** The once-built state behind `UsingSites`. */
private typedef AccessDoor = {
	final accesses: Map<Int, QueryNode>;
	final typeOf: Null<(QueryNode) -> Null<String>>;
	final tree: Null<QueryNode>;
	final index: Null<SymbolIndex>;
};
