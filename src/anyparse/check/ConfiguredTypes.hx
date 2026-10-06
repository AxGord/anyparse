package anyparse.check;

import anyparse.query.NominalTypes;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeSyntax.TypeSyntaxReader;

using Lambda;

/**
 * Resolution helpers for a rule whose SUBJECT TYPES the project names in its `apqlint.json` by qualified path —
 * `prefer-api-idiom`'s idiom types, `typed-event-constant`'s event base and type abstract.
 *
 * Which framework a name belongs to is the project's declaration, never this tool's knowledge: every answer here is a
 * walk over the resolution index, keyed by the IDENTITY of a resolved declaration (its file plus its name), never by a
 * simple name two packages may share. Every walk fails CLOSED in the direction its callers act on — an unresolved link
 * answers null, "not proven", which no caller reads as permission.
 */
@:nullSafety(Strict)
@:access(anyparse.check.LintConfig)
final class ConfiguredTypes {

	/** Whether `a` and `b` are the same resolved declaration. */
	public static inline function same(index: SymbolIndex, a: ResolvedType, b: ResolvedType): Bool {
		return index.refs.seenKey(a) == index.refs.seenKey(b);
	}

	/** The ONE declaration `qualified` names in `index` (`openfl.geom.Point`), or null when none or several do. */
	public static function resolve(index: SymbolIndex, qualified: String): Null<ResolvedType> {
		final all: Array<ResolvedType> = index.refs.resolveQualifiedRefAll(qualified);
		return all.length == 1 ? all[0] : null;
	}

	/**
	 * The declaration a WRITTEN type denotes when read in `from`'s scope: its head path after peeling every `wrappers`
	 * application (`Null<Point>` reads as `Point`), resolved import-aware. Null for a type that is not a plain nominal,
	 * and for one that resolves to no declaration or to several.
	 */
	public static function resolveWritten(
		index: SymbolIndex, source: String, from: FileInfo, wrappers: Array<String>, typeSyntax: TypeSyntaxReader
	): Null<ResolvedType> {
		final peeled: String = NominalTypes.memberLookupReceiverSource(source, wrappers, typeSyntax);
		final path: Null<String> = switch typeSyntax(peeled)?.shape {
			case Nominal(head, _): head;
			case _: null;
		};
		return path == null ? null : index.refs.resolveTypeRef(path, from);
	}

	/**
	 * `member` as `cur` declares or INHERITS it: the first declaration met walking `cur` and then its supertypes, each
	 * resolved import-aware from the file that writes it, paired with the type declaring it. Null when no resolvable type
	 * of the closure declares it. Haxe forbids redeclaring an inherited field, so for a field the first declaration is the
	 * one an access binds to; for a method it is the nearest override, which is the body a call runs.
	 */
	public static function memberOf(index: SymbolIndex, cur: ResolvedType, member: String): Null<OwnedMember> {
		return memberWalk(index, cur, member, []);
	}

	/**
	 * Whether `sub` is `sup` or reaches it through its supertypes: true on a proof; false when every supertype link of the
	 * closure resolved and none of them is `sup`; null when a link did not resolve — an external or ambiguous supertype,
	 * which proves neither answer.
	 */
	public static function inherits(index: SymbolIndex, sub: ResolvedType, sup: ResolvedType): Null<Bool> {
		return inheritsWalk(index, sub, index.refs.seenKey(sup), []);
	}

	/**
	 * Print `line` about `rule`'s configuration once per process, through `LintConfig`'s own ledger — a config problem
	 * is a property of the document, and a run re-reads the document once per linted directory.
	 */
	public static function warn(rule: String, line: String): Void {
		LintConfig.warnOnce('$rule:$line', 'apq lint: $rule: $line\n');
	}

	/** `memberOf`'s recursion; `seen` cycle-guards on the resolved identity. */
	private static function memberWalk(index: SymbolIndex, cur: ResolvedType, member: String, seen: Array<String>): Null<OwnedMember> {
		if (!index.refs.markSeen(cur, seen)) return null;
		final direct: Null<MemberInfo> = cur.type.members.find(m -> m.name == member);
		if (direct != null) return { owner: cur, member: direct };
		for (raw in cur.type.supertypesRaw) {
			final ancestor: Null<ResolvedType> = index.refs.resolveTypeRef(raw, cur.file);
			if (ancestor == null) continue;
			final found: Null<OwnedMember> = memberWalk(index, ancestor, member, seen);
			if (found != null) return found;
		}
		return null;
	}

	/** `inherits`' recursion: `target` is the sought declaration's identity, `seen` the cycle guard. */
	private static function inheritsWalk(index: SymbolIndex, cur: ResolvedType, target: String, seen: Array<String>): Null<Bool> {
		if (index.refs.seenKey(cur) == target) return true;
		if (!index.refs.markSeen(cur, seen)) return false;
		var complete: Bool = true;
		for (raw in cur.type.supertypesRaw) {
			final ancestor: Null<ResolvedType> = index.refs.resolveTypeRef(raw, cur.file);
			if (ancestor == null) {
				complete = false;
				continue;
			}
			switch inheritsWalk(index, ancestor, target, seen) {
				case true:
					return true;
				case null:
					complete = false;
				case false:
			}
		}
		return complete ? false : null;
	}

}

/** A member together with the resolved type that declares it — see `ConfiguredTypes.memberOf`. */
typedef OwnedMember = {
	final owner: ResolvedType;
	final member: MemberInfo;
}
