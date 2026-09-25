package anyparse.query;

using Lambda;

/**
 * The abstract types one question's walk may meet as a STATIC type — `ReachGraph.visibleAbstracts`, kept as a
 * closure that only grows: the words the entered code spells (`add`), the members it reads (`read`), and, settled on
 * demand (`settle`), the signatures those reach and the declarations of the types found.
 */
@:nullSafety(Strict)
final class AbstractReach {

	/** Every word found: a type name among them is visible. */
	public final found: Map<String, Bool> = [];

	private final _types: Array<String> = [];
	private final _members: Map<String, Bool> = [];
	private final _memberQueue: Array<String> = [];

	/** The supertypes of every type found: a read through a value of a found type may reach their declarations. */
	private final _supers: Map<String, Bool> = [];

	/** The reads of an unknown receiver waiting for a type declaring their name to be found. */
	private final _pending: Array<MemberRead> = [];

	/** The reads taken (`read`), by name and receiver types. */
	private final _reads: Map<String, Bool> = [];

	private final _sig: SignatureWords;
	private final _graphTypes: CallGraphTypes;
	private final _literals: Array<String>;
	private final _everything: () -> Array<String>;
	private final _built: String -> Bool;
	private final _inferred: InferredRef -> Null<{ words: Array<String>, reads: Array<MemberRead> }>;

	private var _ti: Int = 0;
	private var _mi: Int = 0;

	/** Set when a type was found since the pending reads were last asked again. */
	private var _grown: Bool = false;

	/** Set by a name no indexed type declares, read off a receiver whose type is not known. */
	private var _undeclared: Bool = false;

	public function new(
		sig: SignatureWords, graphTypes: CallGraphTypes, literals: Array<String>, everything: () -> Array<String>, built: String -> Bool,
		inferred: InferredRef -> Null<{ words: Array<String>, reads: Array<MemberRead> }>
	) {
		_sig = sig;
		_graphTypes = graphTypes;
		_literals = literals;
		_everything = everything;
		_built = built;
		_inferred = inferred;
	}

	/** Record the word `word` as found; true when it is new. */
	public function add(word: String): Bool {
		if (found.exists(word)) return false;
		found[word] = true;
		_types.push(word);
		_grown = true;
		final queue: Array<String> = [word];
		var qi: Int = 0;
		while (qi < queue.length) for (s in _graphTypes.supertypesOf(queue[qi++])) if (!_supers.exists(s)) {
			_supers[s] = true;
			queue.push(s);
		}
		return true;
	}

	/**
	 * Take the read `read`; true when it is new. It resolves to the declarations of its name on the types it may
	 * reach: its receiver's, when known, and otherwise those of a type found so far — a receiver's static type comes
	 * from the same declarations. A receiver none of whose chain declares the name reads a static extension, or a
	 * member a build macro generated, which nothing indexed describes: every abstract.
	 */
	public function read(read: MemberRead): Bool {
		final owners: Null<Array<String>> = read.owners;
		final key: String = owners == null ? read.name : '${read.name}@${owners.join(',')}';
		if (_reads.exists(key)) return false;
		_reads[key] = true;
		final declaring: Array<String> = _sig.owners[read.name] ?? [];
		final receiver: Null<Array<String>> = read.owners;
		final r: MemberRead = if (receiver != null && !declaring.exists(o -> receiver.contains(o))) {
			if (receiver.exists(_built)) for (t in _everything()) add(t);
			{ name: read.name, owners: null };
		} else
			read;
		resolve(r, declaring);
		return true;
	}

	/** Run the closure to its fixpoint. */
	public function settle(): Void {
		while (true) {
			if (_ti >= _types.length && _mi >= _memberQueue.length) {
				// a member a build macro generated on a type in reach is described by nothing indexed: every abstract
				if (_undeclared && !_grown && [for (t in found.keys()) t].exists(t -> _graphTypes.declarationCount(t) > 0 && _built(t))) {
					_undeclared = false;
					for (t in _everything()) add(t);
				}
				// the found types grew: a read of an unknown receiver may reach more declarations now
				if (!_grown) break;
				_grown = false;
				final again: Array<MemberRead> = _pending.copy();
				_pending.resize(0);
				for (r in again) resolve(r, _sig.owners[r.name] ?? []);
				continue;
			}
			while (_mi < _memberQueue.length) {
				final name: String = _memberQueue[_mi++];
				for (w in _sig.byMember[name] ?? []) add(w);
				inferred(_sig.inferredMember[name]);
			}
			while (_ti < _types.length) {
				final t: String = _types[_ti++];
				for (w in _sig.byType[t] ?? []) add(w);
				inferred(_sig.inferredType[t]);
			}
		}
	}

	/** Queue the declarations of `r`'s name among `declaring` that it reaches; park it while it may reach more. */
	private function resolve(r: MemberRead, declaring: Array<String>): Void {
		if (declaring.length == 0 && r.owners == null) _undeclared = true;
		var open: Bool = false;
		for (owner in declaring) {
			final reach: Bool = r.owners == null ? found.exists(owner) || _supers.exists(owner) : r.owners.contains(owner);
			if (!reach) {
				open = open || r.owners == null;
				continue;
			}
			final key: String = '${r.name}@$owner';
			if (_members.exists(key)) continue;
			_members[key] = true;
			_memberQueue.push(key);
		}
		if (open) _pending.push(r);
	}

	/** A member whose type is inferred has the type of its own code: what that code spells, reads and builds. */
	private function inferred(refs: Null<Array<InferredRef>>): Void {
		for (r in refs ?? []) {
			final code: Null<{ words: Array<String>, reads: Array<MemberRead> }> = _inferred(r);
			if (code == null) {
				for (t in _literals.concat(_everything())) add(t);
				continue;
			}
			for (w in code.words) add(w);
			for (m in code.reads) read(m);
		}
	}

}

/** A member whose type its declaration leaves to inference: where it is declared. */
typedef InferredRef = {
	var file: String;
	var type: String;
	var member: String;
}

/** A member read by name, and the types whose declaration of it the read may reach (null: any). */
typedef MemberRead = {
	var name: String;
	var owners: Null<Array<String>>;
}

/** The words of the index's declared signatures: by member name, and by type name (see `ReachGraph.signatureWords`). */
typedef SignatureWords = {
	/** `name@Type` -> the words of that member's declared signature. */
	var byMember: Map<String, Array<String>>;

	/** Member name -> the types declaring a member so named (the constructor and implicitly-called members aside). */
	var owners: Map<String, Array<String>>;
	var byType: Map<String, Array<String>>;

	/** Where the members whose type the declaration leaves to inference are declared, by name / by type. */
	var inferredMember: Map<String, Array<InferredRef>>;
	var inferredType: Map<String, Array<InferredRef>>;
}
