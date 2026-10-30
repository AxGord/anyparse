package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.query.TypingService.Resolution;
import anyparse.runtime.Span;

using Lambda;

/**
 * What the receiver `R` of a qualified call `R.name(...)` names, relative to ONE member declaration of `name`: the type
 * declaring it, another type's same-named member, or nothing provable. Read through `TypingService.resolveAt`, which first
 * proves the receiver binds no value, over the edited file's resolution index; the index is built on the first receiver
 * asked about, so a file whose calls are all bare or `this.`-qualified pays nothing.
 */
@:nullSafety(Strict)
final class QualifiedReceiver {

	private final _file: String;
	private final _plugin: GrammarPlugin;
	private final _identKind: String;

	/** Offset of the member declaration the receivers are read against. */
	private final _declFrom: Int;

	/** The file's resolution index, built on the first receiver asked about. */
	private final _index: () -> Null<SymbolIndex>;

	/** `file` is the edited file's path as the run's index keys it, `source` its current text. */
	public function new(file: String, source: String, plugin: GrammarPlugin, shape: RefShape, declFrom: Int) {
		_file = file;
		_plugin = plugin;
		_index = IndexScope.lazySymbolIndex([{ file: file, source: source }], plugin);
		_identKind = shape.identKind;
		_declFrom = declFrom;
	}

	/**
	 * What the receiver node `recv` of `recv.name(...)` names. `OtherType` only for a type that is not an alias and declares
	 * a member `name` itself, so the call provably reaches that member and not the declaration read against.
	 */
	public function read(recv: QueryNode, name: String): ReceiverTarget {
		final span: Null<Span> = recv.span;
		if (recv.kind != _identKind || span == null) return Unproven;
		final index: Null<SymbolIndex> = _index();
		if (index == null) return Unproven;
		return switch TypingService.resolveAt(index, _plugin, _file, span.from) {
			case Declared(decl): classify(decl, name);
			case Unknown: Unproven;
		};
	}

	private function classify(decl: ResolvedType, name: String): ReceiverTarget {
		final type: TypeDeclInfo = decl.type;
		if (decl.file.file == _file && type.span.from <= _declFrom && _declFrom < type.span.to) return DeclaringType;
		if (type.aliasTargetRaw != null || !type.members.exists(m -> m.name == name)) return Unproven;
		return OtherType;
	}

}

/** `QualifiedReceiver.read`'s answer. */
enum ReceiverTarget {

	/** The receiver names the type declaring the member: the call targets it. */
	DeclaringType;

	/** The receiver names another type declaring its own member of the name: the call does not target this one. */
	OtherType;

	/** Nothing proves either reading — a value receiver, a dotted path, a type outside the index, an alias. */
	Unproven;

}
