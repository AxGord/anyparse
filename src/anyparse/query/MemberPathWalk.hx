package anyparse.query;

import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.TypeSyntax.TypeSyntaxReader;

using Lambda;

/**
 * The multi-hop counterpart of a single member lookup: given a path root and `a.b.c`, resolve
 * each hop's member on the SPECIFIC type in the previous hop's declaring-file scope, and answer the
 * final member's verbatim declared type source. Package-safe by construction — a same-simple-named
 * type in another package never contributes a member, which is the flaw of the package-blind
 * simple-name walk it replaces — and it fails CLOSED at every hop.
 *
 * Split out of `SymbolIndex`. Each hop's member comes from `MemberLookup` and each hop's type from
 * the index's own reference resolution; the type-argument substitution is the member layer's (`MemberLookup.memberReadType`).
 */
@:nullSafety(Strict)
final class MemberPathWalk {

	/** Every indexed file's `FileInfo`, handed over by the owning index. */
	private final _files: Array<FileInfo>;

	/** The name -> declaration layer this one resolves each hop's type through. */
	private final _refs: TypeRefIndex;

	/** The member layer that answers each individual hop. */
	private final _members: MemberLookup;

	/** `GrammarPlugin.typeSyntax` of the grammar that built the owning index. */
	private final _typeSyntax: TypeSyntaxReader;

	/** Built once by the owning `SymbolIndex`, which hands over the shared, immutable index data. */
	public function new(files: Array<FileInfo>, refs: TypeRefIndex, members: MemberLookup, typeSyntax: TypeSyntaxReader) {
		_files = files;
		_refs = refs;
		_members = members;
		_typeSyntax = typeSyntax;
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
	 * Each hop is a READ of the member (`MemberLookup.memberReadType`): the declaring type's parameters are bound through the
	 * receiver's arguments or, for an INHERITED member, through what the extends chain passes up
	 * (`AncestorTable.argumentsTo`), and an optional structure field reads as its optional-value type; a hop whose type still
	 * names a parameter nothing binds aborts THIS walk. Null on every unresolved / ambiguous link, exactly like the plain walk.
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
	 * follows a chain of generic containers (`Array<Box<Item>>` → `Box<Item>` → `Item`). The fail-closed
	 * rule that ends the walk when a parameter name survives substitution (`memberReadType` answers null) is
	 * what keeps that sound: without it an unsubstituted `T` would travel forward as if it were a concrete
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
			final startArgs: Null<Array<String>> = NominalTypes.typeArgumentSourcesOf(startSource, _typeSyntax);
			if (startArgs != null) {
				final head: Null<String> = NominalTypes.outerNominalOf(startSource, _typeSyntax);
				if (head == null) return null;
				args = startArgs;
				startName = head;
			}
		}
		var current: Null<ResolvedType> = _refs.resolveTypeRef(startName, origin);
		for (i in 0...memberPath.length - 1) {
			if (current == null) return null;
			final cur: ResolvedType = current;
			final effective: Null<String> = substitute
				? _members.memberReadType(cur, memberPath[i], args)
				: _members.memberTypeSource(cur, memberPath[i]);
			if (effective == null) return null;
			// An INTERMEDIATE link is a receiver for the next segment, so a member-transparent
			// wrapper on it is peeled (`res: Null<Res>` in `box.res.count`). The FINAL member's
			// source, returned below, is never peeled — a read of `Null<T>` IS `Null<T>`.
			final carried: String = NominalTypes.memberLookupReceiverSource(effective, transparentWrappers, _typeSyntax);
			if (substitute) args = NominalTypes.typeArgumentSourcesOf(carried, _typeSyntax) ?? [];
			final nominal: Null<String> = switch _typeSyntax(carried)?.shape {
				case Nominal(path, _): path;
				case _: null;
			};
			current = nominal == null ? null : _refs.resolveTypeRef(nominal, cur.file, cur.type.span.from);
		}
		if (current == null) return null;
		final last: ResolvedType = current;
		final member: String = memberPath[memberPath.length - 1];
		return substitute ? _members.memberReadType(last, member, args) : _members.memberTypeSource(last, member);
	}

}
