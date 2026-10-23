package anyparse.query;

import anyparse.query.CallSelection.CallCandidate;
import anyparse.query.SymbolIndex.FileInfo;

/**
 * What an inference asks of the language (`docs/typing-service.md`, T7a): which type parameters of a call are its
 * variables, how a written type reads as a term, and the arcs along which a unification reads a given type as one of a
 * head it is not. `Monomorphs` binds; the policy reads. Haxe's is `HaxeInferencePolicy`.
 */
interface InferencePolicy {

	/** The cells a call binding the candidate `k` spawns in `monos`, by the name of the type parameter each stands for. */
	function callCells(k: CallCandidate, monos: Monomorphs): Map<String, Int>;

	/** The term the type `text`, written in `file` at `at`, reads as there, each name `cells` maps a `Mono` of that cell. */
	function termOf(text: String, file: FileInfo, at: Int, cells: Map<String, Int>): TypeTerm;

	/**
	 * `given` read as a type of the head `wanted` applies, its type arguments in `wanted`'s order (`Monomorphs.unify`);
	 * null where the language reads it as none.
	 */
	function reread(wanted: TypeTerm, given: TypeTerm): Null<TypeTerm>;

}
