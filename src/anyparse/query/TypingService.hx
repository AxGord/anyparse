package anyparse.query;

import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.TypeSyntax.TypeSyntaxReader;

/**
 * The typing service of one run scope: the ONE place a typing question is asked, over the declarations the
 * `SymbolIndex` read. Its questions split the way a compiler's typer splits them. SIGNATURE questions are answered from
 * the declarations alone, no body read (`members`: what a named type declares or inherits; `structural`: what it unifies
 * with). BODY questions walk an expression. Every answer the service remembers lives in `cache`, keyed by the
 * declaration the question is about (`DeclarationKey`), never by a name a second declaration may share.
 *
 * A declaration's key is its position in its file, so one declaration is one key whichever `#if` configuration reads it:
 * the index reads every branch, and the thirteen compiler configurations of a project ask one service and share its
 * answers. Built once by the `SymbolIndex` it types and dropped with it, so nothing a run learns outlives the run.
 * The design, the cache keys and where the later typer steps plug in: `docs/typing-service.md`.
 */
@:nullSafety(Strict)
final class TypingService {

	/** Every remembered answer of the service's declaration-keyed questions. */
	public final cache: QueryCache = new QueryCache();

	/** SIGNATURE: what a named type declares or inherits, and with what declared type, return type and visibility. */
	public final members: MemberLookup;

	/** SIGNATURE: unification with an anonymous structure, and membership of a builtin structural type. */
	public final structural: StructuralTypes;

	/** Built by the owning `SymbolIndex` over its immutable declaration tables. */
	public function new(files: Array<FileInfo>, refs: TypeRefIndex, subtypes: SubtypeGraph, typeSyntax: TypeSyntaxReader) {
		members = new MemberLookup(refs, cache);
		structural = new StructuralTypes(files, refs, subtypes, members, typeSyntax);
	}

}
