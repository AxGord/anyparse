package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.CanonicalEdit;
import anyparse.query.GrammarPlugin;
import anyparse.query.ModuleScan;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * The `using`-declaration helpers the static-extension checks share — `dead-binder-counter-loop`,
 * `prefer-exists`, `prefer-foreach`, `prefer-find`, `prefer-lpad` and `prefer-static-extension` each rewrite a
 * call into an extension method, so each has to ask the same four questions of a file's header: is
 * the module already brought in with `using`, where would the insert go, does some OTHER `using`
 * already bind the method name (which would make the rewrite resolve elsewhere), and — where a
 * receiver MEMBER shadows the extension and the rule falls back to the QUALIFIED `Module.m(recv, …)`
 * spelling — does the bare module name still mean that module here (`qualifiedCallReaches`).
 *
 * The header is not always the file's TOP LEVEL: a module whose whole body sits inside one `#if … #end` region carries its imports
 * there too, and `headerOf` reads that region as the header — `ModuleScan.guardedBodyRegion` holds the gates that decide when a region
 * qualifies. Every OTHER guarded `using` — one under a region that guards an import run but not the code using it — is in scope for
 * that region alone, which is why the presence question has a site-scoped form (`usingScopeAt`) whose third answer is a refusal.
 *
 * Split out of `CheckScan`, on the same contract: PURE static helpers over the tree a check
 * already holds, no shared mutable state and no cache — the memo a caller wants is its own
 * `Map` passed in, not state kept here.
 */
@:nullSafety(Strict)
final class UsingScan {

	/** The grammar's `using` declaration kind, spelled literally (see `hasUsingModule`). */
	public static inline final USING_DECL_KIND: String = 'UsingDecl';

	/**
	 * How `appendUsingInsert` names its subject in `guardedUsingDecline` — the rules that decide one
	 * insert for the whole file cannot point at a single call, so they say what is true of the set.
	 * `prefer-static-extension`, which decides per site, passes its own subject instead.
	 */
	public static inline final FILE_WIDE_SUBJECT: String = 'a rewritten call';

	/** The wildcard import kind — the one form that binds names it does not spell out (`headerRebindsName`). */
	private static inline final WILDCARD_IMPORT_KIND: String = 'ImportWildDecl';

	/** The top-level declaration kinds a `using` insert anchors after — the file's package / import / using header. */
	private static final USING_ANCHOR_KINDS: Array<String> = [
		'PackageDecl',
		'PackageEmpty',
		'ImportDecl',
		'ImportAliasDecl',
		'ImportAliasInDecl',
		'ImportWildDecl',
		USING_DECL_KIND
	];

	/**
	 * The `using` header of `tree`: its top level, paired with the `#if … #end` region that guards the
	 * module's WHOLE body when the file has one.
	 *
	 * A debug- or platform-only module wraps everything below `package` in a single conditional, so its
	 * import run — and every call a rewrite touches — sits INSIDE that region while the top level holds
	 * nothing but `package` and the region itself. Read one level down, the insert joins that import run
	 * and a `using` already declared there counts as present; read at the top level only, the insert
	 * lands on an island above the `#if` and the guarded `using` is invisible, so a second one is
	 * spliced in.
	 *
	 * Build it ONCE per file and pass it to the three readers: `guardOf` scans the file's directives,
	 * which a per-site rebuild would repeat for every candidate.
	 */
	public static function headerOf(tree: QueryNode, source: String, plugin: GrammarPlugin): UsingHeader {
		return {
			root: tree,
			guard: ModuleScan.guardedBodyRegion(tree, source, plugin),
			guardedUsings: [
				for (g in ModuleScan.guardedImportScopes(tree, source, plugin)) if (g.decl.kind == USING_DECL_KIND) g
			]
		};
	}

	/**
	 * Whether a `using <module>;` the header already binds is in scope — then the module's
	 * extension methods resolve without inserting one. `module` may be QUALIFIED
	 * (`pkg.Lambda`), in which case only an exact match counts; a SIMPLE `module`
	 * (`Lambda`) also matches a qualified declaration ending in it (`pkg.Lambda`),
	 * since both bring the same module into scope. This is the FILE-wide half of `usingScopeAt`, which every rule now
	 * asks instead: a `using` under an accepted whole-body guard counts here, one under any other `#if` region does not.
	 *
	 * CAVEAT on that simple-name match: the index models no packages, so a `using
	 * other.pkg.Lambda` of an UNRELATED project-local module sharing the simple name reads
	 * as present and suppresses the insert. It errs toward not inserting — a loud compile
	 * error rather than a silent behaviour change — and a stdlib module (the configured
	 * default) has no same-named sibling to collide with.
	 *
	 * The declaration kind is spelled literally (`USING_DECL_KIND`): `RefShape` exposes no
	 * using-declaration seam, so a grammar naming it differently reads as having no
	 * `using` at all — which only ever causes a redundant insert, never a wrong one.
	 */
	public static function hasUsingModule(header: UsingHeader, module: String): Bool {
		return headerDecls(header).exists(child -> child.kind == USING_DECL_KIND && bindsModule(child.name, module));
	}

	/**
	 * Whether `using <module>;` is in scope at every one of `offsets` — the three-valued question
	 * `hasUsingModule` answers only for the file as a whole, and the one an INSERT has to ask.
	 *
	 * A `using` a `#if … #end` region guards is in scope for the bytes of that region and for no
	 * other, so presence alone decides nothing: read as present it leaves a rewritten call
	 * unresolved in the builds the region is compiled out of, read as absent it splices a SECOND,
	 * unguarded declaration next to the guarded one — which duplicates it, and changes what the
	 * guarded arms themselves resolve, since Haxe picks the LAST `using` of a name. That is the
	 * shape `prefer-static-extension --fix` shipped: a file whose import run sits under
	 * `#if (sys || nodejs)` while its class does not gained a top-level `using StringTools;` with
	 * one already three lines below, and no check reports the pair.
	 *
	 * `Guarded` is therefore a REFUSAL, not a "insert one anyway": neither spelling is safe, and
	 * the caller keeps its report-only finding. It is also the answer for
	 * a region whose span the grammar did not record and for a MULTI-BRANCH
	 * one, both of which cover nothing: the grammar gives every branch of a region one span, so without
	 * that gate a `using` in the `#if` arm read as covering a call in the `#else` arm
	 * (`ModuleScan.guardedImportScopes` holds the measurement).
	 *
	 * An empty `offsets` is a REFUSAL too — but only HERE, once a guarded region is in play. An
	 * unguarded `using` answers `InScope` on the first line whatever the offsets say, and a module
	 * the file declares nowhere answers `Absent` two lines down, so the empty case reaches the
	 * coverage loop only in the one shape that can be wrong. There it is decisive: no offset is no
	 * EVIDENCE of coverage, and the loop would read it as proof — a caller that decided the insert
	 * before it had collected its edits was told the guarded `using` covered sites it had not shown,
	 * kept its rewrites, and wrote an extension call that binds nothing in the builds the region is
	 * compiled out of, with no diagnostic, because `InScope` is the one answer that declines
	 * nothing. That makes `offsets` a contract rather than a hint: it must be every site the caller
	 * still intends to emit. A caller that genuinely has no site to rewrite loses nothing to the
	 * refusal: its edit set is empty either way, and the refusal names no finding. The containment
	 * test is SPAN coverage, not condition equivalence, so a call under its
	 * own `#if (sys || nodejs)` and a `using` under a SEPARATE region spelling the same condition read as uncovered
	 * and refuse. Answering that pair would mean deciding whether one condition implies another, chain of enclosing
	 * regions included; span coverage is the relation a tree can state on its own, and it errs toward the refusal.
	 */
	public static function usingScopeAt(header: UsingHeader, module: String, offsets: Array<Int>): UsingScope {
		if (hasUsingModule(header, module)) return UsingScope.InScope;
		// The element nullability is LOAD-BEARING and must not be "cleaned up" by filtering the
		// nulls out: an unlocatable region would then leave `regions` empty and the verdict would
		// flip from `Guarded` to `Absent` — from refusing to splicing a second `using`.
		final regions: Array<Null<Span>> = [for (g in header.guardedUsings) if (bindsModule(g.decl.name, module)) g.region];
		if (regions.length == 0) return UsingScope.Absent;
		// Ask BEFORE the loop, which passes vacuously on an empty array and would answer `InScope`.
		if (offsets.length == 0) return UsingScope.Guarded;
		for (offset in offsets) if (!regions.exists(r -> r != null && offset >= r.from && offset < r.to)) return UsingScope.Guarded;
		return UsingScope.InScope;
	}

	/**
	 * Append the `using <module>;` insert `edits` need — nothing when the module is already in
	 * scope at every edit — and answer whether the file can carry the rewrite at all.
	 *
	 * `false` is a REFUSAL and the caller must DROP its whole edit set: either `usingScopeAt` answered
	 * `Guarded`, so the rewrites resolve through a `using` only some builds declare, or the insert byte
	 * is already covered by an accepted rewrite and the declaration cannot be spliced at all. Whichever
	 * it was, the answer NEVER means "inserted" — the only way `true` comes back is with the insert in
	 * `edits` or the module already in scope.
	 * `violations` are the findings that set is built from — ONLY those, and the contract is load-bearing rather than
	 * descriptive: the refusal is written on every one of them, unconditionally on the `Guarded` branch and on every one
	 * carrying no reason yet on the covered branch, so a caller handing over its whole `run` output makes this gate
	 * answer for findings it never decided. A site the caller skipped for its OWN cause (an unproven range, a candidate
	 * key that missed) also gets no edit, which is true and is not this gate's doing; naming it here is the
	 * mis-attribution `noteDeclineWhereUnset` avoids in the other direction. A `fix` that
	 * returns nothing and says nothing reads to the ledger as a rule that withheld an edit without a reason. The rules that
	 * insert one `using` per file share this seam rather than each spelling the same branches; `prefer-static-extension`
	 * decides per SITE instead (one file can hold a covered call and an uncovered one) and calls `usingScopeAt` directly.
	 *
	 * The offsets are every edit's start, INCLUDING rewrites that would not have needed the module
	 * — a caller that mixes qualified and extension forms is refused a little more often than it
	 * strictly must be, which is the direction that cannot emit a call binding nothing.
	 */
	public static function appendUsingInsert(
		header: UsingHeader, module: String, edits: Array<{ span: Span, text: String }>, violations: Array<Violation>
	): Bool {
		final scope: UsingScope = usingScopeAt(header, module, [for (e in edits) e.span.from]);
		if (scope == UsingScope.Guarded) {
			for (violation in violations) violation.declineReason = guardedUsingDecline(module, FILE_WIDE_SUBJECT);
			return false;
		}
		if (scope == UsingScope.Absent) {
			final insert: Null<{ span: Span, text: String }> = insertUnlessCovered(header, module, edits, violations);
			if (insert == null) return false;
			edits.push(insert);
		}
		return true;
	}

	/**
	 * Why a rewrite is refused when the file's only `using <module>;` sits inside a `#if` region that
	 * leaves one of its call sites out — one sentence, in one place, so every rule sharing the gate
	 * reports the same fact and a reader who has met it once recognises it from any of them.
	 */
	public static function guardedUsingDecline(module: String, subject: String): String {
		return 'the file declares `using $module` only inside a `#if` region $subject sits outside of, so the extension call'
			+ ' would not resolve in the builds that region is compiled out of, and a second unguarded `using` would change'
			+ ' what the region\'s own calls resolve to';
	}

	/**
	 * Why a rewrite is refused when another `using` in the same file could also supply `method` — the THIRD way this seam says
	 * no, and the one that used to say nothing at all. The refusal it explains is FILE-WIDE: a caller that mixes extension-form
	 * and qualified rewrites drops both, and the sentence says so rather than implying every dropped rewrite needed the module
	 * in scope. Narrowing it to the extension-form sites is T829 - the back-link exists (`PreferFind.rewrote`,
	 * `BoolLoopScan.extensionForm`), so it is a behaviour change with its own measurement, not a wording fix.
	 *
	 * `conflictingUsing` answers a Bool, so the conflicting module is not nameable here; what the
	 * reader needs is the rule, which is the same in every file it fires on. Written in one place for
	 * the same reason `guardedUsingDecline` is: three rules take this branch and a hand-spelled copy
	 * in each would drift.
	 */
	public static function conflictingUsingDecline(module: String, method: String): String {
		return 'another `using` in this file could also supply `$method`, and Haxe resolves static extensions in REVERSE'
			+ ' declaration order, so a rewritten extension call could bind there instead of `$module.$method` — the refusal is'
			+ ' WHOLESALE, so a rewrite that would have named the module outright and needed no `using` goes down with it';
	}

	/**
	 * Write `reason` on every finding that carries none yet — the annotation half of a WHOLESALE
	 * refusal, where one gate closes on an edit set several findings share.
	 *
	 * A finding that already names its own gate keeps that sentence: it is the more specific of the
	 * two, and overwriting it would replace "this call is shadowed" with the file-wide answer. The
	 * WhereUnset half of the name is load-bearing: `ImportBlockOrder.noteDecline` is the same idea with
	 * the opposite policy (it targets a known set and overwrites), and the two must not be read as one.
	 */
	public static function noteDeclineWhereUnset(violations: Array<Violation>, reason: String): Void {
		for (violation in violations) if (violation.declineReason == null) violation.declineReason = reason;
	}

	/**
	 * The zero-width `using <module>;` edit for `header`, or null when an already-accepted edit covers
	 * the byte it would be spliced at — in which case the refusal is ALREADY written on `violations`.
	 *
	 * This is the decision `appendUsingInsert` and `BoolLoopScan.withUsingInsert` share; they differ
	 * only in what a refusal looks like to their own caller (`false` against an empty grouped set).
	 * Returning the edit rather than pushing it is what makes "did not insert" unrepresentable as
	 * "inserted": there is no success value to hand back when nothing was produced.
	 */
	public static function insertUnlessCovered(
		header: UsingHeader, module: String, edits: Array<{ span: Span, text: String }>, violations: Array<Violation>
	): Null<{ span: Span, text: String }> {
		final insert: { span: Span, text: String } = usingInsertEdit(header, module);
		if (!CanonicalEdit.editsOverlapAny([insert], edits)) return insert;
		noteDeclineWhereUnset(violations, coveredUsingDecline([module]));
		return null;
	}

	/**
	 * Why a rewrite is refused when the byte the `using <module>;` insert would go at is already
	 * covered by an accepted rewrite — the second, rarer way the declaration cannot be made, and the
	 * one that used to be answered by inserting nothing and reporting success.
	 *
	 * The subject is spelled as the caller would have written it, so the per-file rules name one module
	 * and `prefer-static-extension`, which can owe several, names them all in one declaration run.
	 */
	public static function coveredUsingDecline(modules: Array<String>): String {
		final declarations: String = 'using ' + modules.join('; using ') + ';';
		return 'an accepted rewrite already covers the byte where `$declarations` would be spliced, so the declaration cannot'
			+ ' be inserted without corrupting that edit — and a rewritten extension call whose `using` never landed does not'
			+ ' compile, so the whole edit set goes rather than ship one that cannot build';
	}

	/**
	 * A ZERO-WIDTH edit inserting `using <module>;` into the header. The insert companion of
	 * `hasUsingModule`; the caller applies it only after deciding at least one rewrite needs
	 * the module in scope.
	 *
	 * The position is a CORRECTNESS choice, not cosmetics: Haxe resolves static extensions in
	 * REVERSE declaration order, so the LAST `using` wins. Inserting after an existing `using`
	 * run would give the new module top priority and silently re-target every same-named
	 * extension call the file already makes through an earlier `using`. So the insert goes
	 * ABOVE the FIRST existing `using` — lowest priority, no existing call disturbed — and
	 * falls back to after the last package / import declaration, or the file head with a
	 * trailing blank line, only when the file declares no `using` at all.
	 *
	 * An UNGUARDED `using` decides the position on its own: it is in scope for the whole file, so an
	 * insert below it — inside the guard included — would outrank it. Only when the file has none does
	 * the guard's own header take over, which is where the rewrites and their imports live.
	 */
	public static function usingInsertEdit(header: UsingHeader, module: String): { span: Span, text: String } {
		final unguarded: Null<Span> = firstUsing(header.root);
		if (unguarded != null) return { span: new Span(unguarded.from, unguarded.from), text: 'using $module;\n' };
		final guard: Null<QueryNode> = header.guard;
		if (guard != null) {
			final guarded: Null<Span> = firstUsing(guard);
			if (guarded != null) return { span: new Span(guarded.from, guarded.from), text: 'using $module;\n' };
			final inner: Null<Span> = lastAnchor(guard);
			if (inner != null) return { span: new Span(inner.to, inner.to), text: '\nusing $module;' };
		}
		final at: Null<Span> = lastAnchor(header.root);
		return at == null ? { span: new Span(0, 0), text: 'using $module;\n\n' } : {
			span: new Span(at.to, at.to),
			text: '\nusing $module;'
		};
	}

	/**
	 * Whether a `using` OTHER than `module` in the same file could also supply `method` — the
	 * gate every extension-method rewrite needs before it emits a `<recv>.<method>(…)` call.
	 *
	 * Haxe resolves static extensions in REVERSE declaration order, so a second module declaring
	 * the same name decides where the rewritten call lands. Two rules depend on that: writing an
	 * explicit `Module.m(x)` in such a file may be deliberate disambiguation the rewrite would
	 * undo, and a `using` INSERTED below an existing run (see `usingInsertEdit`) loses to it. A
	 * module naming the same type as `module` is skipped; for the rest a known extension table
	 * decides, and without one `symbols` must PROVE the module declares no such member. Every
	 * doubt — an unknown module with no index, or one the index cannot resolve — counts as a
	 * conflict, so the caller refuses rather than emits a silently retargeted call.
	 *
	 * The verdict depends only on the `(module, method)` pair while a file repeats it across
	 * every site, and each miss costs a whole-index member-closure query, so `memo` carries it
	 * for the caller's run. Pass a fresh map per file — a `using` set is per-file state.
	 */
	public static function conflictingUsing(
		usings: Array<String>, module: String, method: String, plugin: GrammarPlugin, symbols: () -> Null<SymbolIndex>,
		memo: Map<String, Bool>
	): Bool {
		final key: String = '$module:$method';
		final cached: Null<Bool> = memo[key];
		if (cached != null) return cached;
		final verdict: Bool = conflictScan(usings, module, method, plugin, symbols);
		memo[key] = verdict;
		return verdict;
	}

	/**
	 * Whether the QUALIFIED spelling `<module>.<method>(receiver, …)` provably reaches `module`'s
	 * own static from THIS file — the FALLBACK every `Lambda`-targeting rule emits at a site whose
	 * receiver type declares a member of the same name.
	 *
	 * A real member beats a `using` static extension, so `m.exists(x -> …)` on a receiver whose type
	 * declares `exists` binds to THAT member and does not compile. The fold itself is untouched by
	 * that: `Lambda.exists(m, x -> …)` names the module outright and never consults the receiver's
	 * members. What the qualified call DOES depend on is the one thing the extension form did not —
	 * that the bare name `module` means the module here — and this is that question.
	 *
	 * Three ways it can fail, each a REFUSAL (the rule keeps the report-only finding it had before):
	 *
	 * - the file's own module declares a type named `module`. A same-module type wins the simple
	 *   name outright;
	 * - the header REBINDS the simple name — `import p.Lambda;`, `import p.X as Lambda;`,
	 *   `using p.Lambda;` — or carries a WILDCARD `import p.*;`, which binds main types it does not
	 *   spell out and which no scan of the statement can enumerate without the package's contents;
	 * - the run's index holds a type named `module` that does not declare `method` as a STATIC. That
	 *   is the live case: a project may ship its own root-package `Lambda.hx`, which displaces the
	 *   std one for every file that compiles against it.
	 *
	 * The index arm is VACUOUSLY true when nothing by that name is indexed, which is the same
	 * fail-open posture `memberShadowsExtension` itself takes: no evidence of a shadow is not
	 * evidence of one, and a resolution scope that models neither the std nor the project would
	 * otherwise turn the whole fallback off.
	 */
	public static function qualifiedCallReaches(
		header: UsingHeader, module: String, method: String, symbols: () -> Null<SymbolIndex>
	): Bool {
		if (headerDeclaresType(header, module) || headerRebindsName(header, module)) return false;
		final index: Null<SymbolIndex> = symbols();
		if (index == null) return true;
		for (fi in index.refs.declaringFiles(module))
			for (t in fi.types)
				if (t.name == module && !t.members.exists(m -> m.name == method && m.isStatic)) return false;
		return true;
	}

	/** The module paths of every `using` declaration the header binds — the read side of `hasUsingModule`. */
	public static function usingModules(header: UsingHeader): Array<String> {
		final out: Array<String> = [];
		for (child in headerDecls(header)) if (child.kind == USING_DECL_KIND) {
			final name: Null<String> = child.name;
			if (name != null) out.push(name);
		}
		return out;
	}

	/**
	 * Whether a `using` declaration spelling `name` brings `module` into scope: an exact match, or —
	 * for a SIMPLE `module` — a qualified path ending in it, since both reach the same module. The
	 * one place that comparison is made, so the presence test and the scope test cannot drift apart
	 * on which declaration counts.
	 */
	private static function bindsModule(name: Null<String>, module: String): Bool {
		return name != null && (name == module || (module.indexOf('.') == -1 && name.endsWith('.$module')));
	}

	/** The unmemoised body of `conflictingUsing` — one pass over the file's other `using` declarations. */
	private static function conflictScan(
		usings: Array<String>, module: String, method: String, plugin: GrammarPlugin, symbols: () -> Null<SymbolIndex>
	): Bool {
		final simple: String = CheckScan.simpleModuleName(module);
		for (path in usings) if (path != module && CheckScan.simpleModuleName(path) != simple) {
			final known: Null<Array<String>> = plugin.knownExtensionMethods(path);
			if (known != null) {
				if (known.contains(method)) return true;
				continue;
			}
			final index: Null<SymbolIndex> = symbols();
			// The FULL module path, not its last segment: `typeProvablyLacksMember` resolves a
			// dotted name by import path, so a module whose simple name another package reuses
			// no longer reads as ambiguous-and-therefore-conflicting.
			// The FULL module path, not its last segment: `typeProvablyLacksMember` resolves a
			// dotted name by import path, so a module whose simple name another package reuses
			// no longer reads as ambiguous-and-therefore-conflicting.
			if (index == null || !index.members.typeProvablyLacksMember(path, method)) return true;
		}
		return false;
	}

	/**
	 * Whether the file's own module declares a top-level type named `name` — the first way a
	 * qualified `<name>.<method>(…)` can mean something other than the module it spells.
	 */
	private static function headerDeclaresType(header: UsingHeader, name: String): Bool {
		for (child in headerDecls(header)) {
			final decl: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(child);
			if (decl != null && decl.name == name) return true;
		}
		return false;
	}

	/**
	 * Whether an `import` / `using` in the header binds the simple name `name` to something other
	 * than the module of that very name — an aliased import taking the name, a qualified path whose
	 * LAST segment is it, or any wildcard import (which binds main types it does not spell out).
	 *
	 * A bare `import Lambda;` / `using Lambda;` is the module itself and is NOT a rebind: those
	 * statements are exactly what a file writes to reach the std module the qualified call wants.
	 */
	private static function headerRebindsName(header: UsingHeader, name: String): Bool {
		for (child in headerDecls(header)) switch (child.kind) {
			case 'ImportAliasDecl', 'ImportAliasInDecl':
				if (child.name == name) return true;
			case WILDCARD_IMPORT_KIND:
				return true;
			case 'ImportDecl', USING_DECL_KIND:
				final path: Null<String> = child.name;
				if (path != null && path != name && path.endsWith('.$name')) return true;
			case _:
		}
		return false;
	}

	/** The declarations the header binds: the file's top level, followed by the whole-body guard's own when it has one. */
	private static function headerDecls(header: UsingHeader): Array<QueryNode> {
		final guard: Null<QueryNode> = header.guard;
		return guard == null ? header.root.children : header.root.children.concat(guard.children);
	}

	/** The span of the FIRST `using` declared directly under `node`, or null when it declares none. */
	private static function firstUsing(node: QueryNode): Null<Span> {
		for (child in node.children) if (child.kind == USING_DECL_KIND) {
			final span: Null<Span> = child.span;
			if (span != null) return span;
		}
		return null;
	}

	/** The span of the LAST package / import / using declared directly under `node` — the declaration an insert follows. */
	private static function lastAnchor(node: QueryNode): Null<Span> {
		var anchor: Null<Span> = null;
		for (child in node.children) if (USING_ANCHOR_KINDS.contains(child.kind)) {
			final span: Null<Span> = child.span;
			if (span != null) anchor = span;
		}
		return anchor;
	}

}

/**
 * A module's `using` header: the file's top level, plus the `#if … #end` region that guards its
 * WHOLE body when it has one — built by `UsingScan.headerOf`. `guard` is null for the ordinary
 * unguarded module and for every region the coverage gates refuse.
 */
typedef UsingHeader = {
	final root: QueryNode;
	final guard: Null<QueryNode>;

	/**
	 * Every `using` the module declares inside a conditional-compilation region, each paired with
	 * the span of the innermost region holding it — what `usingScopeAt` tests a rewrite site
	 * against. A `using` DIRECTLY under an accepted whole-body `guard` appears here too and decides nothing: that
	 * region covers every type the module declares, and `headerDecls` merges its children, so `hasUsingModule`
	 * has already answered. One nested a level deeper inside that guard is NOT in `headerDecls`, which reads one
	 * level only, so its entry here is what answers — correctly, since the inner region is where it binds.
	 */
	final guardedUsings: Array<GuardedImport>;
}

/**
 * Whether a module's `using` is in scope where a rewrite is about to spell an extension call —
 * `UsingScan.usingScopeAt`'s verdict, and the three answers an insert has to tell apart.
 */
enum abstract UsingScope(Int) {

	/** In scope at every site: an unguarded `using`, or a guarded one whose region covers them all. Nothing to insert. */
	final InScope = 0;

	/** Declared ONLY inside a `#if` region that leaves some site out — neither an insert nor the rewrite is safe. */
	final Guarded = 1;

	/** Not declared at all, so an insert is the whole job. */
	final Absent = 2;

}
