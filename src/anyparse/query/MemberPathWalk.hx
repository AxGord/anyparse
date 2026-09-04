package anyparse.query;

import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ResolvedType;

using StringTools;
using Lambda;

/**
 * The multi-hop counterpart of a single member lookup: given a path root and `a.b.c`, resolve
 * each hop's member on the SPECIFIC type in the previous hop's declaring-file scope, and answer the
 * final member's verbatim declared type source. Package-safe by construction — a same-simple-named
 * type in another package never contributes a member, which is the flaw of the package-blind
 * simple-name walk it replaces — and it fails CLOSED at every hop.
 *
 * Split out of `SymbolIndex`. Each hop's member comes from `MemberLookup` and each hop's type from
 * the index's own reference resolution; the type-argument substitution is this layer's own.
 */
@:nullSafety(Strict)
final class MemberPathWalk {

	/** Every indexed file's `FileInfo`, handed over by the owning index. */
	private final _files: Array<FileInfo>;

	/** The name -> declaration layer this one resolves each hop's type through. */
	private final _refs: TypeRefIndex;

	/** The member layer that answers each individual hop. */
	private final _members: MemberLookup;

	/** Built once by the owning `SymbolIndex`, which hands over the shared, immutable index data. */
	public function new(files: Array<FileInfo>, refs: TypeRefIndex, members: MemberLookup) {
		_files = files;
		_refs = refs;
		_members = members;
	}

	/**
	 * The verbatim declared type SOURCE of a receiver path's FINAL member, resolved IMPORT- and
	 * INHERITANCE-aware from `fromFile`'s scope. `startTypeName` is the path root's type name (a
	 * value's declared type, `this`'s enclosing type, or a static TYPE-name root); it resolves via
	 * `resolveTypeRef` to the SPECIFIC type in scope, then each `memberPath[i]` is looked up on
	 * that exact type + its supertype closure and its nominal resolved import-aware to the next
	 * type in ITS declaring file's scope. Package-safe by construction: a same-simple-named type in
	 * ANOTHER package never contributes a member (the flaw of the package-blind simple-name walk).
	 * Null when the root, any intermediate type, or any member is unresolved / ambiguous (fails
	 * closed). Feeds `RefactorSupport.staticRootPathTypeSource` and the value-root gate.
	 */
	public inline function resolvePathFinalMemberTypeSource(
		fromFile: String, startTypeName: String, memberPath: Array<String>
	): Null<String> {
		return pathFinalMemberWalk(fromFile, startTypeName, memberPath, false, []);
	}

	/**
	 * `resolvePathFinalMemberTypeSource` with TYPE-ARGUMENT SUBSTITUTION: `startTypeSource` is the
	 * root's WRITTEN type (`Box<Item>`, arguments included), and a member declared as one of its
	 * type's parameters answers the matching argument instead of the parameter name. Resolves
	 * `Box<Item>.payload : T` to `Item`, which is what makes a generic container's element member
	 * reachable at all — the verbatim `T` resolves to no type.
	 *
	 * Strictly more conservative than the plain walk wherever it is unsure: substitution applies
	 * ONLY to a member declared DIRECTLY on the current type (an INHERITED member's `T` names the
	 * SUPERTYPE's parameter, and the extends-clause argument mapping is not modelled), and any
	 * effective source that STILL mentions a parameter name of the type it came from aborts THIS
	 * walk. Null on every unresolved / ambiguous link, exactly like the plain walk.
	 *
	 * "Aborts this walk" is the honest scope: the caller
	 * (`NominalTypes.pathReceiverMemberTypeSource`) treats a null the same way it treats one from
	 * the plain walk and drops to its package-blind fallback, which may still answer the verbatim
	 * parameter source. That keeps the deep answer a superset of the shallow one, and a bare
	 * parameter name is not a type any consumer of this chain acts on.
	 */
	public inline function resolveGenericPathFinalMemberTypeSource(
		fromFile: String, startTypeSource: String, memberPath: Array<String>, ?transparentWrappers: Array<String>
	): Null<String> {
		return pathFinalMemberWalk(fromFile, startTypeSource, memberPath, true, transparentWrappers ?? []);
	}

	/**
	 * The shared body of the two path walks. With `substitute == false` it is the plain
	 * import-aware walk, byte for byte what `resolvePathFinalMemberTypeSource` always did; with
	 * `substitute == true` it additionally carries the receiver's written type ARGUMENTS alongside
	 * the current type and rewrites a parameter-typed member through them.
	 *
	 * `args` is re-seeded at every step from the effective member source, so the substitution
	 * follows a chain of generic containers (`Array<Box<Item>>` → `Box<Item>` → `Item`). The
	 * fail-closed rule that ends the walk when a parameter name survives substitution is what keeps
	 * that sound: without it an unsubstituted `T` would travel forward as if it were a concrete
	 * argument and could collide with the NEXT type's parameter of the same name, or with a project
	 * type literally called `T` / `K` / `V`.
	 */
	private function pathFinalMemberWalk(
		fromFile: String, startSource: String, memberPath: Array<String>, substitute: Bool, transparentWrappers: Array<String>
	): Null<String> {
		if (memberPath.length == 0) return null;
		final origin: Null<FileInfo> = _files.find(f -> f.file == fromFile);
		if (origin == null) return null;
		var args: Array<String> = [];
		var startName: String = startSource;
		if (substitute) {
			final startArgs: Null<Array<String>> = NominalTypes.typeArgumentSourcesOf(startSource);
			if (startArgs != null) {
				final head: Null<String> = NominalTypes.outerNominalOf(startSource);
				if (head == null) return null;
				args = startArgs;
				startName = head;
			}
		}
		var current: Null<ResolvedType> = _refs.resolveTypeRef(startName, origin);
		for (i in 0...memberPath.length - 1) {
			if (current == null) return null;
			final cur: ResolvedType = current;
			final memberSource: Null<String> = _members.memberTypeSourceWalk(cur, memberPath[i], []);
			if (memberSource == null) return null;
			final effective: Null<String> = substitute ? substitutedMemberSource(cur, memberPath[i], memberSource, args) : memberSource;
			if (effective == null) return null;
			// An INTERMEDIATE link is a receiver for the next segment, so a member-transparent
			// wrapper on it is peeled (`res: Null<Res>` in `box.res.count`). The FINAL member's
			// source, returned below, is never peeled — a read of `Null<T>` IS `Null<T>`.
			final carried: String = NominalTypes.memberLookupReceiverSource(effective, transparentWrappers);
			if (substitute) args = NominalTypes.typeArgumentSourcesOf(carried) ?? [];
			final nominal: String = StringTools.trim(carried.split('<')[0]);
			current = _refs.resolveTypeRef(nominal, cur.file);
		}
		if (current == null) return null;
		final last: ResolvedType = current;
		final member: String = memberPath[memberPath.length - 1];
		final finalSource: Null<String> = _members.memberTypeSourceWalk(last, member, []);
		return finalSource == null || !substitute ? finalSource : substitutedMemberSource(last, member, finalSource, args);
	}

	/**
	 * `memberSource` with `cur`'s type parameters resolved through `args`, or null when the result
	 * would still name one of them.
	 *
	 * Substitution fires only when ALL three hold: the member is declared DIRECTLY on `cur.type`
	 * (an inherited one's parameter name belongs to the supertype's header, a mapping this index
	 * does not model); its trimmed source is EXACTLY one parameter name (a source that merely
	 * CONTAINS one, `Array<T>`, would need a rewrite, not a lookup); and that name's position is
	 * covered by the arguments actually written on the receiver. Otherwise the verbatim source
	 * stands — and is then rejected by the parameter-mention gate if it names a parameter, so an
	 * unsubstitutable parameter can never leave this function as if it were a concrete type.
	 *
	 * The DIRECT-member gate is the one that stops a wrong CONCRETE type, not merely an
	 * unresolvable one: a subtype whose header parameter happens to share the supertype's name but
	 * passes something else up (`class Der<T:Item> extends Base<Str>`, `Base<T> { var u:T; }`)
	 * would otherwise substitute `Der`'s argument into `Base`'s parameter and resolve `u` to the
	 * wrong type entirely. `SimplifyNegatedCompoundCheckTest.testSupertypeParamNameCollisionKeepsWrap`
	 * is the fixture that fails if it is removed.
	 */
	private function substitutedMemberSource(cur: ResolvedType, member: String, memberSource: String, args: Array<String>): Null<String> {
		final params: Array<String> = cur.type.typeParamNames;
		final at: Int = params.indexOf(memberSource.trim());
		final declaredHere: Bool = cur.type.members.exists(m -> m.name == member);
		final effective: String = declaredHere && at >= 0 && at < args.length ? args[at] : memberSource;
		return mentionsTypeParam(effective, params) ? null : effective;
	}

	/** Whether `text` names any of `params` as a WHOLE identifier token — `Item` does not mention `T`, `Array<T>` does. */
	private static function mentionsTypeParam(text: String, params: Array<String>): Bool {
		if (params.length == 0) return false;
		var i: Int = 0;
		while (i < text.length) {
			if (!SourceText.isIdentStartChar(text.fastCodeAt(i))) {
				i++;
				continue;
			}
			var end: Int = i + 1;
			while (end < text.length && SourceText.isIdentChar(text.fastCodeAt(end))) end++;
			if (params.contains(text.substring(i, end))) return true;
			i = end;
		}
		return false;
	}

}
