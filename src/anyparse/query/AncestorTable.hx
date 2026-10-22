package anyparse.query;

import anyparse.query.SymbolIndex.FileInfo;
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

	/**
	 * The one type a reference may name with its type parameters left out and no default for them (Haxe `Dynamic`,
	 * `RefShape.rawDynamicTypeName`): every other one is a compile error (4.3.7: `Not enough type parameters`).
	 */
	private final _bareType: Null<String>;

	/**
	 * Built once by the owning `TypingService` over the index's name resolution and the service's cache; `bareType` is the
	 * grammar's dynamic type name.
	 */
	public function new(refs: TypeRefIndex, cache: QueryCache, typeSyntax: TypeSyntaxReader, bareType: Null<String>) {
		_refs = refs;
		_cache = cache;
		_typeSyntax = typeSyntax;
		_bareType = bareType;
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
	 * The type `written`, written in the declaration `host` at `at` by a member declaring the type parameters `own`, as a value
	 * read off a receiver of the declaration `start` written with the type arguments `args` carries it: completed where it is
	 * written (a reference leaving arguments out names their defaults, `completed`), `host`'s type parameters bound to what
	 * `start`'s chain passes them (`argumentsTo`, `start`'s own bound to `args`). Null where a parameter of `host` it names is
	 * not bound. What a member read (`MemberLookup.memberRead`) and a call's return (`CallSelection.returnType`) carry.
	 */
	public function boundType(
		start: ResolvedType, host: ResolvedType, args: Array<String>, written: String, at: Int, own: Array<String>
	): Null<String> {
		final params: Array<String> = host.type.typeParamNames;
		// the type as the compiler reads it where it is written: a reference leaving arguments out names their defaults
		final complete: Null<String> = completed(written, host.file, at, params.concat(own));
		if (complete == null) return null;
		final passed: Null<Array<String>> = params.length == 0 ? [] : boundArguments(start, host, args);
		return if (passed != null && passed.length >= params.length)
			CallGraphNames.substituteTypeParams(complete, params, passed, _typeSyntax)
		else if (CallGraphNames.mentionsTypeName(complete, params, _typeSyntax))
			null
		else
			complete;
	}

	/**
	 * `args`, the type arguments a reference to `decl` writes, with each trailing parameter it leaves out bound to the
	 * default the declaration writes for it (`TypeDeclInfo.typeParamDefaults`; 4.3.7: `Box` names `Box<Int>` for
	 * `class Box<T = Int>`, inside `Box` as well): `args` itself when it binds every parameter, null when a parameter it
	 * leaves out has no default. A default is in `decl`'s file's terms, and cannot name a parameter of `decl` (4.3.7:
	 * `Type not found`).
	 */
	public function withDefaults(decl: ResolvedType, args: Array<String>): Null<Array<String>> {
		final arity: Int = decl.type.typeParamNames.length;
		if (args.length >= arity) return args;
		final out: Array<String> = args.copy();
		for (i in args.length ... arity) {
			final value: Null<String> = decl.type.typeParamDefaults[i];
			if (value == null) return null;
			out.push(value);
		}
		return out;
	}

	/**
	 * The written type `source`, as the file `from` writes it at `at`, with the arguments each named type in it leaves out
	 * written in (`withDefaults`): `Array<Box>` is `Array<Box<Int>>` for `class Box<T = Int>`, `Pair<Int>` is
	 * `Pair<Int, String>` for `class Pair<A, B = String>`, and a default that leaves arguments out is completed in its own
	 * file in turn. The dynamic type, a name that resolves to no single declaration and a reference that writes every
	 * argument are left as written.
	 *
	 * Null when the answer would not be the compiler's: a reference leaves out a parameter that has no default (not a type
	 * the compiler accepts), its name is one of `scope` — the names a type parameter may hold where `source` is written, so
	 * it may name that parameter instead — a default names a type `from` does not resolve to the declaration the default's
	 * own file does (written into `source` it would name another one), a default reaches its own declaration again, or the
	 * reference is not spelled as its plain path (a parenthesised one).
	 */
	public function completed(source: String, from: FileInfo, at: Null<Int>, scope: Array<String>): Null<String> {
		return completedIn(source, from, at, scope, []);
	}

	/**
	 * Whether `r` or an ancestor its links reach carries a build macro (`@:build`, `@:autoBuild`) — one that may give the
	 * declaration members, statics among them, no declaration shows. A link that does not resolve adds none.
	 */
	public function builtAtOrAbove(r: ResolvedType): Bool {
		return builtFrom(r, []);
	}

	/**
	 * What `start`'s chain passes `host`'s type parameters (`argumentsTo`), in the terms of `args`, the type arguments a
	 * receiver of `start` is written with; null where a parameter of `start` it names is not bound by `args`.
	 */
	private function boundArguments(start: ResolvedType, host: ResolvedType, args: Array<String>): Null<Array<String>> {
		final via: Null<Array<String>> = argumentsTo(start, host);
		final own: Array<String> = start.type.typeParamNames;
		return if (via == null || own.length == 0)
			via
		else if (args.length >= own.length)
			[for (a in via) CallGraphNames.substituteTypeParams(a, own, args, _typeSyntax)]
		else if (via.exists(a -> CallGraphNames.mentionsTypeName(a, own, _typeSyntax)))
			null
		else
			via;
	}

	/** `completed`, `seen` the declarations whose defaults are being completed around it. */
	private function completedIn(source: String, from: FileInfo, at: Null<Int>, scope: Array<String>, seen: Array<String>): Null<String> {
		final t: Null<TypeSyntax> = _typeSyntax(source);
		if (t == null) return source;
		final inserts: Array<{ at: Int, order: Int, text: String }> = [];
		final all: Array<TypeSyntax> = t.descendants();
		for (order in 0...all.length) switch all[order].shape {
			case Nominal(path, args):
				final d: TypeSyntax = all[order];
				final decl: Null<ResolvedType> = _refs.resolveTypeRef(path, from, at);
				if (decl == null || args.length >= decl.type.typeParamNames.length || decl.type.name == _bareType) continue;
				final filled: Null<Array<String>> = withDefaults(decl, [for (a in args) a.text]);
				final key: String = _refs.seenKey(decl);
				final unspellable: Bool = !d.text.startsWith(path) || (args.length > 0 && !d.text.endsWith('>'));
				// a name a type parameter may hold there is that parameter or this type: which one is not read here
				if (filled == null || seen.contains(key) || scope.contains(path) || unspellable) return null;
				final added: Array<String> = [];
				for (value in filled.slice(args.length)) {
					final spelled: Null<String> = defaultFor(value, decl, from, at, seen.concat([key]));
					if (spelled == null) return null;
					added.push(spelled);
				}
				inserts.push(
					args.length == 0
						? { at: d.span.from + path.length, order: order, text: '<${added.join(', ')}>' }
						: { at: d.span.to - 1, order: order, text: ', ${added.join(', ')}' }
				);
			case _:
		}
		// an inner reference ending where its outer one's argument list closes is written in first
		inserts.sort((a, b) -> a.at == b.at ? b.order - a.order : a.at - b.at);
		final out: StringBuf = new StringBuf();
		var copied: Int = 0;
		for (i in inserts) {
			out.add(source.substring(copied, i.at));
			out.add(i.text);
			copied = i.at;
		}
		out.add(source.substring(copied));
		return out.toString();
	}

	/**
	 * The default `value` of a parameter of `decl`, completed in `decl`'s file, as `from` (at `at`) may write it: null when
	 * a type it names resolves from `from` to no declaration, or to another one than from `decl`'s file.
	 */
	private function defaultFor(value: String, decl: ResolvedType, from: FileInfo, at: Null<Int>, seen: Array<String>): Null<String> {
		final spelled: Null<String> = completedIn(value, decl.file, decl.type.span.from, [], seen);
		final t: Null<TypeSyntax> = spelled == null ? null : _typeSyntax(spelled);
		if (spelled == null || t == null) return null;
		for (d in t.descendants()) switch d.shape {
			case Nominal(path, _):
				final there: Null<ResolvedType> = _refs.resolveTypeRef(path, decl.file, decl.type.span.from);
				final here: Null<ResolvedType> = _refs.resolveTypeRef(path, from, at);
				if (there == null || here == null) return null;
				if (!same(there, here)) return null;
			case _:
		}
		return spelled;
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
		final decl: Null<ResolvedType> = matches.length == 1 ? matches[0] : null;
		// a link leaving trailing arguments out passes the defaults of the type it names (`extends Box` is `Box<Int>`)
		final args: Null<Array<String>> = written.length != 1
			? null
			: decl == null ? written[0] : withDefaults(decl, written[0]) ?? written[0];
		return {
			raw: raw,
			matches: matches,
			decl: decl,
			args: args
		};
	}

	/** Whether `a` and `b` are one declaration: one file, one offset (`DeclarationKey.ofType`). */
	public static inline function same(a: ResolvedType, b: ResolvedType): Bool {
		return a.file.file == b.file.file && a.type.span.from == b.type.span.from;
	}

	/**
	 * Whether a supertype reference is `Dynamic`. `implements Dynamic<T>` marks dynamic FIELD
	 * ACCESS and declares no NAMED member, so it can never be the inherited `_x` a rename would
	 * redefine — it must be SKIPPED rather than counted as an unresolvable dead end, which would
	 * wrongly block every `openfl` display subclass (`DisplayObject` carries such a clause under
	 * `#if`). Matched on the last path segment, so a qualified spelling is skipped too.
	 */
	public static inline function dynamicSupertypeRef(raw: String): Bool {
		return SourceText.lastSegment(raw) == 'Dynamic';
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
