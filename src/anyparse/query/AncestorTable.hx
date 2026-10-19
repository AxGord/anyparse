package anyparse.query;

import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.TypeSyntax.TypeSyntaxReader;

using Lambda;

/**
 * The ancestor table of the typing service (`docs/typing-service.md`, step T2): every type declaration's direct supertype
 * links, each resolved ONCE where the declaration writes it and carrying the type arguments it passes; the declaration a
 * plain alias re-points at; and what a declaration's supertype chain passes to an ancestor's type parameters, in its own
 * terms (`tUnification.ml`: `loop cs (List.map (apply_params c.cl_params tl) tls)`). Each answer is a function of the
 * declarations it is about and the immutable index, remembered in the service's `QueryCache` by `DeclarationKey`: the
 * closure walks of `MemberLookup`, the member types it substitutes and the unification of plain types (`Unification`) read
 * it instead of resolving each link again.
 */
@:nullSafety(Strict)
final class AncestorTable {

	/** The name -> declaration layer each written link is resolved through. */
	private final _refs: TypeRefIndex;

	/** The owning service's remembered answers. */
	private final _cache: QueryCache;

	/** `GrammarPlugin.typeSyntax` — how a written supertype's head and arguments are read. */
	private final _typeSyntax: TypeSyntaxReader;

	/** Built once by the owning `TypingService` over the index's name resolution and the service's cache. */
	public function new(refs: TypeRefIndex, cache: QueryCache, typeSyntax: TypeSyntaxReader) {
		_refs = refs;
		_cache = cache;
		_typeSyntax = typeSyntax;
	}

	/**
	 * The direct supertype links of `r`, in the order its `extends` / `implements` clauses write them (`supertypesRaw`):
	 * each with every declaration the written reference names from `r`'s file (`TypeRefIndex.resolveTypeRefAll`), the one
	 * it resolves to when that is a single declaration, and the type arguments it passes.
	 */
	public function links(r: ResolvedType): Array<AncestorLink> {
		return _cache.ancestorLinks.answer(DeclarationKey.ofType(r), () -> [for (raw in r.type.supertypesRaw) linkOf(r, raw)]);
	}

	/**
	 * The declaration `r`'s written alias target (`typedef A = C`, `aliasTargetRaw`) names, resolved where `r` writes it; null
	 * for a declaration that re-points at nothing and for a target that resolves to no single declaration.
	 */
	public function aliasTarget(r: ResolvedType): Null<ResolvedType> {
		return _cache.aliasTargets.answer(DeclarationKey.ofType(r), () -> {
			final target: Null<String> = r.type.aliasTargetRaw;
			target == null ? null : _refs.resolveTypeRef(target, r.file, r.type.span.from);
		});
	}

	/**
	 * The type arguments `start`'s supertype chain passes to the type parameters of its ancestor `host`, in `start`'s own
	 * terms (`class D extends B<W>` passes `W`, `class M<X> extends B<Array<X>>` passes `Array<X>`, `class E extends M<Y>`
	 * passes `Array<Y>` through `M`), and `start`'s own parameters when `host` is `start`. The first link of each type that
	 * reaches `host`, in written order, answers — the compiler's `loop` — and null when none does, or when the link it goes
	 * through passes fewer arguments than the parameters it fills, or writes different ones in two `#if` branches: what those
	 * parameters bind to is then not written anywhere this reads.
	 */
	public function argumentsTo(start: ResolvedType, host: ResolvedType): Null<Array<String>> {
		return same(start, host)
			? start.type.typeParamNames.copy()
			: _cache.ancestorArguments.answer(DeclarationKey.ofPair(start, host), () -> chainTo(start, host, []));
	}

	/**
	 * Whether `r` or an ancestor its links reach carries a build macro (`@:build`, `@:autoBuild`) — one that may give the
	 * declaration members, statics among them, no declaration shows. A link that does not resolve adds none.
	 */
	public function builtAtOrAbove(r: ResolvedType): Bool {
		return builtFrom(r, []);
	}

	/** `builtAtOrAbove` from `cur` up, `seen` the declarations already walked. */
	private function builtFrom(cur: ResolvedType, seen: Array<String>): Bool {
		if (!_refs.markSeen(cur, seen)) return false;
		if (cur.type.hasBuild || cur.type.hasAutoBuild) return true;
		for (link in links(cur)) {
			final up: Null<ResolvedType> = link.decl;
			if (up != null && builtFrom(up, seen)) return true;
		}
		return false;
	}

	/** `argumentsTo` from `cur` up, `seen` the declarations already walked. */
	private function chainTo(cur: ResolvedType, host: ResolvedType, seen: Array<String>): Null<Array<String>> {
		if (!_refs.markSeen(cur, seen)) return null;
		for (link in links(cur)) {
			final up: Null<ResolvedType> = link.decl;
			if (up == null) continue;
			final ancestor: ResolvedType = up;
			final above: Null<Array<String>> = same(ancestor, host) ? ancestor.type.typeParamNames : chainTo(ancestor, host, seen);
			if (above == null) continue;
			final params: Array<String> = ancestor.type.typeParamNames;
			final args: Null<Array<String>> = link.args;
			return args == null || args.length < params.length ? null : [
				for (a in above) CallGraphNames.substituteTypeParams(a, params, args, _typeSyntax)
			];
		}
		return null;
	}

	/** The link `r` writes as `raw`: its resolution from `r`'s file, and the arguments every branch writing it passes. */
	private function linkOf(r: ResolvedType, raw: String): AncestorLink {
		final matches: Array<ResolvedType> = _refs.resolveTypeRefAll(raw, r.file, r.type.span.from);
		final written: Array<Array<String>> = [];
		for (w in r.type.supertypesWritten) if (NominalTypes.outerPathOf(w, [], _typeSyntax) == raw) {
			final args: Array<String> = NominalTypes.typeArgumentSourcesOf(w, _typeSyntax) ?? [];
			if (!written.exists(a -> a.join(',') == args.join(','))) written.push(args);
		}
		return {
			raw: raw,
			matches: matches,
			decl: matches.length == 1 ? matches[0] : null,
			args: written.length == 1 ? written[0] : null
		};
	}

	/** Whether `a` and `b` are one declaration: one file, one offset (`DeclarationKey.ofType`). */
	public static inline function same(a: ResolvedType, b: ResolvedType): Bool {
		return a.file.file == b.file.file && a.type.span.from == b.type.span.from;
	}

}

/** One `extends` / `implements` link of a type declaration (`AncestorTable.links`). */
typedef AncestorLink = {

	/** The supertype as written, its path without type arguments (`TypeDeclInfo.supertypesRaw`). */
	final raw: String;

	/** Every declaration `raw` names from the declaring file (`TypeRefIndex.resolveTypeRefAll`): several when it is ambiguous. */
	final matches: Array<ResolvedType>;

	/** The declaration `raw` resolves to, or null when it names none or several (`TypeRefIndex.resolveTypeRef`). */
	final decl: Null<ResolvedType>;

	/** The type arguments the link passes, as the declaring file writes them; null when two `#if` branches write different ones. */
	final args: Null<Array<String>>;

}
