package anyparse.query;

import anyparse.query.SymbolIndex.ResolvedType;

/**
 * Which declaration a question is about: the declaring file and the declaration's offset there. Two declarations of one
 * name — namesakes in two packages, the two branches of an `#if` in one file — are two keys; one declaration is one key
 * in every configuration that reads it.
 */
abstract DeclarationKey(String) to String {

	private inline function new(key: String) {
		this = key;
	}

	/** The key of the type declaration `r`. */
	public static inline function ofType(r: ResolvedType): DeclarationKey {
		return new DeclarationKey('${r.file.file}@${r.type.span.from}');
	}

	/** The key of the question about `r`'s member named `member`. */
	public static inline function ofMember(r: ResolvedType, member: String): DeclarationKey {
		return new DeclarationKey('${r.file.file}@${r.type.span.from}.$member');
	}

	/**
	 * The key of a question asked in the file `file` about `r`'s member named `member` — what `recv.member` binds there on
	 * a receiver of `r`, which the file's `using` statements take part in (`StaticExtensions.binding`).
	 */
	public static inline function ofUse(file: String, r: ResolvedType, member: String): DeclarationKey {
		return new DeclarationKey('$file:${r.file.file}@${r.type.span.from}.$member');
	}

	/** The key of a question about the two declarations `a` and `b`, in that order (`a` unifies with `b`, `a` reaches `b`). */
	public static inline function ofPair(a: ResolvedType, b: ResolvedType): DeclarationKey {
		return new DeclarationKey('${a.file.file}@${a.type.span.from}>${b.file.file}@${b.type.span.from}');
	}

	/**
	 * The key of a question about the expression at offset `site` of the file `file`, written in the declaration starting at
	 * `declaration` there, as the text `written` (of a file `length` characters long) spells it: a BODY question (what a call
	 * site's arguments are typed), dropped with that declaration's body. The text is part of the key because a run that
	 * rewrites a file (`lint --fix`) asks again of an index built before the rewrite.
	 */
	public static inline function ofSite(file: String, declaration: Int, site: Int, length: Int, written: String): DeclarationKey {
		return new DeclarationKey('$file@$declaration#$site/$length:$written');
	}

}
