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

}
