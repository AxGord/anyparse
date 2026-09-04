package anyparse.query;

import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ResolvedType;

/**
 * Type-level TRAITS that only a declaration-chain walk can decide: whether `@:rtti` or a build /
 * autoBuild macro reaches a type from anywhere in its supertype closure, and whether an abstract
 * rebinds `this` through its underlying chain. Each is a property of the TYPE rather than of any
 * member of it, and none is visible from the declaration alone — the evidence sits one or more hops
 * up.
 *
 * Split out of `SymbolIndex`. All three fail CLOSED in the same direction: an unresolved link ends
 * that branch and answers "no evidence", never "no", so a wider resolution scope can only ever add
 * findings.
 */
@:nullSafety(Strict)
final class TypeTraits {

	/** Every indexed file's `FileInfo`, handed over by the owning index. */
	private final _files: Array<FileInfo>;

	/** Per-file source text, handed over by the owning index. */
	private final _sources: Map<String, String>;

	/** The name -> declaration layer this one resolves every written supertype and underlying reference through. */
	private final _refs: TypeRefIndex;

	/** Built once by the owning `SymbolIndex`, which hands over the shared, immutable index data. */
	public function new(files: Array<FileInfo>, sources: Map<String, String>, refs: TypeRefIndex) {
		_files = files;
		_sources = sources;
		_refs = refs;
	}

	/**
	 * Whether the abstract named `typeName` may REBIND its underlying `this` through a method call on
	 * a binding of it — the precise `final`-conversion gate, tri-state like the other name-keyed
	 * queries: `null` when NO indexed type declares the name (external / unknown), `false` when the name
	 * resolves only to declarations that provably cannot rebind (a non-abstract class, or an abstract
	 * whose only `this`-writes are in its constructor and whose `@:forward` — if any — reaches a
	 * non-rebinding underlying), `true` when a matching abstract may rebind. Conservative under a
	 * simple-name collision (a rebinding match wins). Resolution is by SIMPLE name (the index
	 * models no packages).
	 *
	 * An UNRESOLVED `@:forward` underlying yields `null`, not `true`. The underlying is stored as
	 * the abstract's own source spelling, which is an import ALIAS whenever its file wrote
	 * `import pkg.T as U` (lime's `@:forward abstract Bytes(HaxeBytes)` is the live case), and a
	 * simple-name index can never resolve an alias — so "underlying not found" carries no evidence
	 * either way. Answering `true` there made ADDING a library to the resolution scope turn a
	 * previously-flagged binding silent: with no library the name was unknown and the caller's own
	 * unknown policy (`RefactorSupport.abstractMethodMayMutate`'s stdlib whitelist) called it safe,
	 * while with the library it resolved to an abstract with an unresolvable underlying and was
	 * hard-vetoed. `null` hands the decision back to that one policy, so more resolution scope can
	 * only ever add information.
	 */
	public function abstractRebindsThis(typeName: String, abstractKinds: Array<String>): Null<Bool> {
		return abstractRebindsWalk(typeName, abstractKinds, []);
	}

	/**
	 * Whether `typeName` OR any type in its transitive supertype closure carries
	 * `@:rtti` (resolved via the index). True marks a serialization-sensitive
	 * hierarchy - a class reflected on its field NAMES at runtime (a drill Node) -
	 * whose fields a naming autofix must not rename. An unresolved / ambiguous
	 * supertype simply ends that branch (a safe miss, matching `isSubtype`); the
	 * direct-`@:rtti` case is caught by the projection's `renameUnsafe` regardless.
	 */
	public function transitivelyCarriesRtti(typeName: String): Bool {
		final seen: Array<String> = [typeName];
		var i: Int = 0;
		while (i < seen.length) {
			final name: String = seen[i];
			i++;
			for (f in _files) for (t in f.types) if (t.name == name) {
				if (t.hasRtti) return true;
				for (s in t.supertypes) if (!seen.contains(s)) seen.push(s);
			}
		}
		return false;
	}

	/**
	 * Whether `typeName` OR anything in its transitive supertype / interface closure is built by a
	 * macro (`@:build` / `@:autoBuild` / `@:genericBuild`), resolved through the index.
	 *
	 * A build macro may rewrite a member arbitrarily, so no rule that changes a field's MUTABILITY or
	 * PLACEMENT can reason about the declaration it can see. The motivating shape: an `@:autoBuild`
	 * interface whose builder strips the initializer off every non-inline `var` field and moves the
	 * assignment into the constructor — after which `var` -> `final` is `Static final variable must be
	 * initialized`, and a field moved to `static` is `Cannot access static field from a class instance`
	 * raised by the builder itself. The class carries no metadata of its own; the grant is inherited
	 * through `implements`, which is why the closure and not the declaring file alone.
	 *
	 * `fromFile` is the file of the container the caller is looking at, and naming it is what keeps the
	 * answer about THAT type. Hop zero is not a written type reference at all — the consumer holds the
	 * declaration — so resolving it by simple name across the whole index conflated every homonym:
	 * measured on `~/dev/haxelib` (16182 files, ~100 libraries in ONE index, the eight consumer rules,
	 * `--all`), the gate removed 16339 findings, of which 14426 were same-simple-name collisions and
	 * 1913 genuine. ONE `private typedef GL = js.html.webgl.GL2` in heaps' `h3d/impl/GlDriver.hx` — a
	 * file carrying a `@:build` of its own — silenced every `GL` in lime, hlsdl, hashlink/sdl and
	 * hashlink/mesa, 9800 findings from one line. Every consumer passes its file; a caller that has
	 * none keeps the whole-index answer it always got.
	 *
	 * Every hop ABOVE zero IS a written reference, and a Haxe supertype is a simple name most of the
	 * time, so those resolve through the referring file's own import scope (`buildMacroSupertypes`) and
	 * widen back to the union whenever that settles nothing. The widening is what is left of the
	 * conservatism, and it is cheap: of the 1913 the gate still removes, 205 are a token in the type's
	 * own file, 1375 a grant reached through a fully resolved chain, and 333 reached ONLY through a
	 * widened hop — a qualified path naming a type outside the scope, `haxe.io.Output` being the whole
	 * of that class. Deciding those would need the compiler's own std path in the resolution scope;
	 * nothing the index holds settles them, so do not narrow the widening without adding it.
	 *
	 * The narrowing can only ever turn a "yes" into a "no", so the consumers that pay for a wrong one
	 * are the DELETING ones (`trivial-getter`, `inline-constant`, `static-constant`), not only the
	 * rewriting ones. It is applied to all eight anyway because it is not a heuristic tightening: a
	 * `@:build` on a type in another package is not a fact about this type. What stays heuristic — the
	 * file-scoped text scan below, the widening above — stays conservative for all of them.
	 *
	 * `@:autoBuild` reaches subtypes and implementors, so the walk follows `supertypes`, which carries
	 * `implements` targets as well as `extends`. The per-file test is textual
	 * (`MemberWriteScan.carriesBuildMacro`), so an unrelated `@:build` elsewhere in the same file counts
	 * too — the conservative direction, which only ever keeps a field as it is (`ansi`'s `ANSI.hx`,
	 * whose second type carries the tag, is 6 of the 205). An unretained source ends the same way, as in
	 * `transitivelyCarriesRtti`.
	 */
	public function transitivelyCarriesBuildMacro(typeName: String, ?fromFile: String): Bool {
		final queue: Array<ResolvedType> = buildMacroRoots(typeName, fromFile);
		final seen: Array<String> = [];
		var i: Int = 0;
		while (i < queue.length) {
			final cur: ResolvedType = queue[i];
			i++;
			if (!_refs.markSeen(cur, seen)) continue;
			final source: Null<String> = _sources[cur.file.file];
			if (source == null || MemberWriteScan.carriesBuildMacro(source)) return true;
			for (hop in buildMacroSupertypes(cur)) queue.push(hop);
		}
		return false;
	}

	/**
	 * The declarations `transitivelyCarriesBuildMacro` starts its closure walk from: the ONE
	 * `typeName` declares in `fromFile` when the caller named the file it is linting, else every
	 * same-simple-name declaration in the index.
	 *
	 * The starting type is not a written type REFERENCE — it is the container the consumer is
	 * looking at, whose declaring file it already holds — so `fromFile` makes hop zero exact
	 * rather than a guess. Falling back to the whole-index union keeps the answer a caller with no
	 * file (or a name the named file does not declare) used to get.
	 */
	private function buildMacroRoots(typeName: String, fromFile: Null<String>): Array<ResolvedType> {
		if (fromFile != null) {
			final own: Null<ResolvedType> = _refs.findDeclaredType(fromFile, typeName);
			if (own != null) return [own];
		}
		return _refs.resolvedDeclsNamed(typeName);
	}

	/**
	 * `cur`'s direct supertypes and interfaces as RESOLVED declarations — the hop
	 * `transitivelyCarriesBuildMacro` takes upward.
	 *
	 * Unlike hop zero these ARE written type references, and a Haxe one is a simple name most of
	 * the time, so they are resolved against the REFERRING file's import scope (`supertypesRaw`
	 * keeps the verbatim path a simple-name reduction throws away). When that settles nothing — an
	 * alias import, a qualified path naming a type outside the scope (`haxe.io.Output`), a scope
	 * form the index does not model — the hop widens back to the same-simple-name union the walk
	 * always used, so a failure to resolve can only ever keep the conservative answer.
	 * `interfaces` is a subset of `supertypes` (`collectImplementsRaw` reads the `ImplementsClause`
	 * that `collectSupertypesRaw` also reads), so walking `supertypes` alone reaches every
	 * `@:autoBuild` grant the old two-list walk did.
	 */
	private function buildMacroSupertypes(cur: ResolvedType): Array<ResolvedType> {
		final out: Array<ResolvedType> = [];
		final raws: Array<String> = cur.type.supertypesRaw;
		final simples: Array<String> = cur.type.supertypes;
		for (i in 0...simples.length) {
			final resolved: Array<ResolvedType> = _refs.resolveTypeRefAll(i < raws.length ? raws[i] : simples[i], cur.file);
			final hops: Array<ResolvedType> = resolved.length > 0 ? resolved : _refs.resolvedDeclsNamed(simples[i]);
			for (r in hops) out.push(r);
		}
		return out;
	}

	/**
	 * `abstractRebindsThis`'s recursion, cycle-guarded by `seen` (a cycle is treated as
	 * possibly-rebinding — conservative). A non-abstract match contributes "found" without rebinding; an
	 * abstract with `abstractSelfRebind` rebinds; a `@:forward` abstract defers to its underlying (an
	 * unresolved or rebinding underlying rebinds, a non-rebinding one contributes "found"); any other
	 * abstract contributes "found". `null` when nothing named `typeName` is indexed, else `false`.
	 */
	private function abstractRebindsWalk(typeName: String, abstractKinds: Array<String>, seen: Array<String>): Null<Bool> {
		if (seen.contains(typeName)) return true;
		seen.push(typeName);
		var found: Bool = false;
		var unknown: Bool = false;
		for (fi in _files) for (t in fi.types) if (t.name == typeName) {
			if (!abstractKinds.contains(t.kind)) {
				found = true;
				continue;
			}
			if (t.abstractSelfRebind) return true;
			final underlying: Null<String> = t.abstractForwardUnderlying;
			if (underlying == null) {
				found = true;
				continue;
			}
			final rec: Null<Bool> = abstractRebindsWalk(underlying, abstractKinds, seen);
			if (rec == true) return true;
			if (rec == null)
				unknown = true;
			else
				found = true;
		}
		return found && !unknown ? false : null;
	}

}
