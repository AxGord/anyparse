package anyparse.query;

import anyparse.query.SymbolIndex.ResolvedType;

/**
 * Walks UP a type's supertype closure with every written link resolved where it is written (`TypeRefIndex.resolveTypeRefAll`),
 * never by the simple name alone: two packages' types of one name are two types. Two readings of the same walk, one per
 * kind of consumer. `verdict` answers "is this a subtype of THAT declaration" in three values, so an autofix acting on
 * "yes" and a veto acting on "maybe" each read the side that is safe for it. `closureAny` asks a predicate of every
 * declaration above a type for a veto, widening a link nothing resolves to every declaration of its name.
 */
@:nullSafety(Strict)
final class SupertypeWalk {

	/**
	 * Whether what `sub` denotes is a transitive proper subtype of what `sup` denotes: `true` when a chain of links, each
	 * resolved to exactly one declaration, reaches it; `null` when a link MAY reach it and nothing proves it — `sup` or `sub`
	 * pins no single declaration, or a link that could name it resolves to nothing or to several; `false` otherwise, a `sub`
	 * whose name no declaration carries included. Each side is resolved as written in its file (`supFile` at `supAt`, `subFile`
	 * at `subAt`) when given — an alias, a std type or another package's namesake then means what that file says — else it
	 * must be the name of exactly one declaration.
	 */
	public static function verdict(
		refs: TypeRefIndex, sub: String, sup: String, ?supFile: String, ?supAt: Int, ?subFile: String, ?subAt: Int
	): Null<Bool> {
		// A start whose name no declaration carries is outside the index, `false`; one that names an indexed type the file or the
		// name cannot pin to one declaration may be any of them, or the unindexed type the file means.
		final start: Null<ResolvedType> = refs.resolveStartType(sub, subFile, subAt);
		if (start == null) return refs.resolvedDeclsNamed(SourceText.lastSegment(sub)).length == 0 ? false : null;
		final target: Null<ResolvedType> = refs.resolveStartType(sup, supFile, supAt);
		return closureReaches(refs, start, target, target == null ? SourceText.lastSegment(sup) : target.type.name, true, []);
	}

	/** `typeName`'s declaration in `fromFile` when that file declares it, else every declaration of the name. */
	public static function declarationsOf(refs: TypeRefIndex, typeName: String, fromFile: Null<String>): Array<ResolvedType> {
		if (fromFile != null) {
			final own: Null<ResolvedType> = refs.findDeclaredType(fromFile, typeName);
			if (own != null) return [own];
		}
		return refs.resolvedDeclsNamed(typeName);
	}

	/**
	 * The declarations `cur`'s written supertypes denote, each resolved in `cur`'s file and widened to every declaration of
	 * its simple name when that resolves nothing — a veto's direction, where an unresolved link may only add declarations.
	 */
	public static function hops(refs: TypeRefIndex, cur: ResolvedType): Array<ResolvedType> {
		final out: Array<ResolvedType> = [];
		final raws: Array<String> = cur.type.supertypesRaw;
		final simples: Array<String> = cur.type.supertypes;
		for (i in 0...simples.length) {
			final resolved: Array<ResolvedType> = refs.resolveTypeRefAll(
				i < raws.length ? raws[i] : simples[i], cur.file, cur.type.span.from
			);
			final denoted: Array<ResolvedType> = resolved.length > 0 ? resolved : refs.resolvedDeclsNamed(simples[i]);
			for (r in denoted) out.push(r);
		}
		return out;
	}

	/**
	 * Whether `hit` holds for a declaration of the closure above `roots` along `hops` — for the roots themselves too only
	 * with `withRoots`. Cycle-safe.
	 */
	public static function closureAny(refs: TypeRefIndex, roots: Array<ResolvedType>, withRoots: Bool, hit: ResolvedType -> Bool): Bool {
		final queue: Array<ResolvedType> = roots.copy();
		final seen: Array<String> = [];
		var i: Int = 0;
		while (i < queue.length) {
			final cur: ResolvedType = queue[i];
			final asked: Bool = withRoots || i >= roots.length;
			i++;
			if (!refs.markSeen(cur, seen)) continue;
			if (asked && hit(cur)) return true;
			for (up in hops(refs, cur)) queue.push(up);
		}
		return false;
	}

	/** `verdict`'s walk from `cur`; `trusted` while every link from the start resolved to exactly one declaration. */
	private static function closureReaches(
		refs: TypeRefIndex, cur: ResolvedType, target: Null<ResolvedType>, name: String, trusted: Bool, seen: Array<String>
	): Null<Bool> {
		// Keyed by trust too: a declaration first reached through an unpinned link must not block the pinned visit that proves.
		final key: String = refs.seenKey(cur) + (trusted ? '' : '?');
		if (seen.contains(key)) return false;
		seen.push(key);
		var maybe: Bool = false;
		for (raw in writtenSupertypesOf(cur)) {
			final resolved: Array<ResolvedType> = refs.resolveTypeRefAll(raw, cur.file, cur.type.span.from);
			// The written name may BE the target whenever nothing pins the link or the target to one declaration.
			if (SourceText.lastSegment(raw) == name && (target == null || resolved.length != 1)) maybe = true;
			final reached: Null<Bool> = resolved.length == 0
				? (unresolvedLinkMayReach(refs, cur, raw, target, name, seen) ? null : false)
				: hopsReach(refs, resolved, target, name, trusted && resolved.length == 1, seen);
			if (reached == true) return true;
			if (reached == null) maybe = true;
		}
		return maybe ? null : false;
	}

	/** `closureReaches` over the declarations one link resolved to; only a `pinned` link turns a hit on `target` into a proof. */
	private static function hopsReach(
		refs: TypeRefIndex, resolved: Array<ResolvedType>, target: Null<ResolvedType>, name: String, pinned: Bool, seen: Array<String>
	): Null<Bool> {
		var maybe: Bool = false;
		for (up in resolved) {
			if (target != null && refs.seenKey(up) == refs.seenKey(target)) {
				if (pinned) return true;
				maybe = true;
				continue;
			}
			if (target == null && up.type.name == name) maybe = true;
			final above: Null<Bool> = closureReaches(refs, up, target, name, pinned, seen);
			if (above == true) return true;
			if (above == null) maybe = true;
		}
		return maybe ? null : false;
	}

	/**
	 * Whether a link `raw` of `cur` that resolves to nothing may still reach the target: walked the way the simple-name graph
	 * walks it — the name and every alias `cur`'s file binds to it, each through its one declaration — and never proving more
	 * than a maybe.
	 */
	private static function unresolvedLinkMayReach(
		refs: TypeRefIndex, cur: ResolvedType, raw: String, target: Null<ResolvedType>, name: String, seen: Array<String>
	): Bool {
		final simple: String = SourceText.lastSegment(raw);
		for (n in [simple].concat(TypeRefIndex.importAliasEdges(cur.file, false)[simple] ?? [])) {
			if (n == name) return true;
			final decls: Array<ResolvedType> = refs.resolvedDeclsNamed(n);
			if (decls.length == 1 && closureReaches(refs, decls[0], target, name, false, seen) != false) return true;
		}
		return false;
	}

	/**
	 * The supertype references `cur` writes, and for a `typedef U = Base;` the target it aliases, which is named where the
	 * typedef is written. A guarded typedef has no `aliasTargetNominal` and adds nothing: that is where the alias kinds agree
	 * to fail closed.
	 */
	private static function writtenSupertypesOf(cur: ResolvedType): Array<String> {
		final written: Array<String> = cur.type.supertypesRaw.copy();
		final hop: Null<String> = cur.type.aliasTargetNominal;
		final aliasRaw: Null<String> = cur.type.aliasTargetRaw;
		if (hop != null && hop != cur.type.name && aliasRaw != null && !cur.type.isAnonStruct) written.push(aliasRaw);
		return written;
	}

}
