package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.query.SymbolIndex;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags a PUBLIC METHOD of a class whose NAME occurs NOWHERE in scope outside its own
 * declaration — dead weight that neither the compiler nor the formatter removes, and which
 * still reads like live behaviour. The public-facing sibling of `unused-private`, whose
 * confinement proof stops at the file boundary: a public member can be reached from anywhere,
 * so the only usable proof is that the name is not written anywhere at all. DEFAULT OFF
 * (`apqlint.json` `"rules": { "unused-public-member": { "enabled": true } }`, or an explicit
 * `--rule`).
 *
 * ## RUN IT WHOLE-PROJECT
 *
 * Report scope bounds every scan here — the token map, the occurrence confirm, and the
 * chain / subtype queries all see the file set the lint was given (widened to the resolution
 * scope where one is configured). A subdirectory run is a PREVIEW, not a verdict: a call site
 * in an unlinted file reads as absent, so the report over-reports and `--fix` would delete a
 * method the rest of the project calls. That is also why the rule is registered in the
 * `--fix` loop's full-scope set.
 *
 * ## The reference test — two complementary text mechanisms
 *
 * 1. A GLOBAL identifier-token count map, built ONCE per run over every source in report
 *    UNION resolution scope. It is the cost-bounded pre-filter: a per-candidate scan of a
 *    scope that carries the configured libraries (lime / openfl / … — thousands of files)
 *    would be quadratic. The member is a candidate only when the map's count for its name
 *    EQUALS the count of the same tokens inside the member's OWN exclusion region — i.e.
 *    every occurrence in the whole scope is its own declaration.
 * 2. The authoritative confirm, on the REPORT index only:
 *    `SymbolIndex.nameOccursOutside`, whose `RefactorSupport.referencedInRange` also sees the
 *    `\x24name` interpolation ESCAPE the plain tokenizer reads as one long token. That closes
 *    the tokenizer's single unsafe blind spot exactly where it matters — the project's own
 *    files.
 *
 * Both are raw-text scans, which makes the rule conservative in the SAFE direction: a name
 * that merely OCCURS — in a comment, in a string literal, in a library, in a `#if` branch, or
 * as an unrelated same-named member of another type — suppresses the finding. A common name
 * (`update`, `run`, `dispose`) is therefore almost never reported; what survives is a name
 * unique to its own declaration, which is exactly the shape a genuinely dead public method
 * has.
 *
 * The exclusion region is NOT the bare member span: it is
 * `docExtendedSpan(declGroupSpan(...))`, so the member's own doc comment and its modifier /
 * metadata run are excluded too — a doc comment naming the member must not read as a
 * reference to it.
 *
 * ## Gates — any of these and the member is never reported
 *
 * The modifier / metadata run preceding a member is walked as `OrphanAccessor` walks it, and
 * RESETS at every member: a `public` or a `@:keep` written on a preceding FIELD belongs to
 * that field, and reading it as the next method's would both invent and hide findings.
 *
 * - Not a method (`FnMember` / `FinalModifiedMember`).
 * - No explicit `public` modifier. A Haxe member with no visibility keyword is PRIVATE, and
 *   `unused-private` owns it.
 * - An `override` — reached polymorphically through the supertype's own call.
 * - ANY `@:meta` in the run (`RefactorSupport.META_KINDS`). Metadata makes a member
 *   implicitly reachable — this is the Haxe grammar's own `isImplicitlyReachable` rule;
 *   `@:keep` is the motivating case, but the whole class of metadata is treated the same
 *   rather than enumerating a whitelist that would leak by category.
 * - A name reached without ever being written: `new` (a constructor), `main` (an entry
 *   point), `toString` (implicit string coercion), and a dunder `__x__` (module init /
 *   target hook). A `get_` / `set_` prefix is `orphan-accessor`'s territory — skipped
 *   outright so the two rules can never claim the same method.
 * - An enclosing class the index says is out of reach: `@:keep` or `@:build` on the class
 *   (a build macro may generate the call), an `extern class` (its members are declarations
 *   over a foreign object), or `SymbolIndex.transitivelyCarriesRtti` (the hierarchy is
 *   reflected on field NAMES at runtime).
 * - An ancestor carrying `@:autoBuild` — that macro generates into DESCENDANTS, so it is
 *   read while walking the chain UPWARD, never off the class in hand.
 * - A supertype link that FAILS to resolve. Unresolvable anything means the chain cannot be
 *   read, and this rule has no report-only third arm the way `orphan-accessor` does: a
 *   doubtful chain yields NOTHING. (`OrphanAccessor`'s speculative unique-simple-name
 *   fallback is deliberately not reused — it exists to let a resolved slot SILENCE a finding
 *   while keeping the link marked unresolved, and here an unresolved link already silences.)
 * - A supertype declaring a member of the same name (`supertypeDeclaresMember` — an unmarked
 *   abstract-method implementation carries no `override`), an implemented interface declaring
 *   it (`implementsInterfaceDeclaringMember`, which is also true for an interface it cannot
 *   resolve), or a SUBTYPE declaring it (`subtypeDeclaresMember` — deleting the base breaks
 *   the subtype's `override`).
 * - ANY report file that skip-parses. The parser could not read it, so it may hold the only
 *   call; the whole run then reports nothing.
 *
 * ## Autofix
 *
 * The deletion adds ONE gate on top of every report gate: no static `Literal` FRAGMENT of an
 * INTERPOLATED string in report scope may be CONTAINED IN the member name — `'do$suffix'`
 * may name it at runtime, and `literalOf` answers null for an interpolated string by
 * contract, so its fragments are what carry the intent. Fragments shorter than
 * `MIN_FRAGMENT_LENGTH` carry no intent and would block every deletion in scope.
 *
 * A WHOLE (non-interpolated) reflection literal needs no separate gate: a string literal's
 * content is raw text in the source, so the token map and the occurrence confirm already see
 * the name inside it and the member is never even REPORTED. That is a strictly stronger
 * outcome than `orphan-accessor`'s, where the same literal only blocks the fix.
 *
 * `fix` deletes the method with its modifier / metadata run and its leading doc comment,
 * whole-line, so nothing orphaned is left behind. The verdict itself is computed in `run`,
 * where the whole file set is in hand, and read back by span (`_deletable`) — `fix` sees one
 * file, and a `fix` with no preceding `run` edits nothing (fail-closed).
 *
 * Scope is class bodies (`CheckScan.classBodies`: `class` / `final class` / `abstract
 * class`). An `interface` declares a contract, an `abstract`'s members reach the underlying
 * type by rules the index does not model, and an `enum` / `typedef` declares no methods.
 */
@:nullSafety(Strict)
final class UnusedPublicMember implements Check implements DefaultOff {

	/** This check's stable id — named once so the literal is not itself a repeated string. */
	private static inline final RULE_ID: String = 'unused-public-member';

	/** The class-body member kinds a method declaration projects as — a plain method and a `final` one. */
	private static final METHOD_KINDS: Array<String> = ['FnMember', 'FinalModifiedMember'];

	/** Method names the runtime or the compiler reaches without any written call. */
	private static final IMPLICIT_NAMES: Array<String> = ['new', 'main', 'toString'];

	/** The read-accessor prefix — `orphan-accessor`'s territory, never claimed here. */
	private static inline final GET_PREFIX: String = 'get_';

	/** The write-accessor prefix — `orphan-accessor`'s territory, never claimed here. */
	private static inline final SET_PREFIX: String = 'set_';

	/** The wrapper of a dunder name (`__init__`) — a compiler hook, not a call target. */
	private static inline final DUNDER: String = '__';

	/** The modifier sibling an explicit `public` projects as. */
	private static inline final PUBLIC_MODIFIER: String = 'Public';

	/** The modifier sibling `override` projects as. */
	private static inline final OVERRIDE_MODIFIER: String = 'Override';

	/** The node kinds a string expression projects as — the hosts whose `Literal` children are interpolation fragments. */
	private static final STRING_EXPR_KINDS: Array<String> = ['SingleStringExpr', 'DoubleStringExpr'];

	/** The static-text child kind inside an interpolated string expression. */
	private static inline final STRING_FRAGMENT_KIND: String = 'Literal';

	/**
	 * Shortest interpolation FRAGMENT that can block a deletion. Same rationale as
	 * `orphan-accessor`'s accessor-prefix length: a one- or two-character fragment (`'_'`,
	 * `'$a-$b'`) carries no naming intent and is contained in almost every identifier, so
	 * admitting it would veto every deletion in scope.
	 */
	private static inline final MIN_FRAGMENT_LENGTH: Int = 4;

	/**
	 * `<file>#<from>:<to>` of every flagged method whose deletion `run` PROVED safe. Every gate
	 * is whole-project (the token map, the occurrence confirm, the chain and subtype queries,
	 * skip-parse completeness) and `fix` sees ONE file — so the verdict is computed once where
	 * the whole file set is in hand and read back by span. A finding with no entry here is
	 * report-only; `fix` called without a preceding `run` therefore edits nothing (fail-closed).
	 */
	private var _deletable: Array<String> = [];

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a public method whose name occurs nowhere in scope outside its own declaration — dead weight nothing can reach';
	}

	/**
	 * Report every provably unreferenced public method across `files`, and record the ones whose
	 * deletion is proven safe. A single skip-parsed report file aborts the whole run: the parser
	 * could not read it, so it may hold the only call to any candidate.
	 */
	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		_deletable = [];
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		if (index.skippedFiles().length != 0) return [];
		// Names resolve over report UNION resolution scope: a call from a configured library is a
		// real reference, and reading it as absent would report every method a library reaches.
		final wide: SymbolIndex = RefactorSupport.resolutionIndexOf(plugin) ?? index;
		final ctx: Ctx = { tokens: tokenCounts(wide), fragments: interpolationFragments(files, plugin) };
		final out: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			// The resolution index carries the report files too, but only when a scope reached the
			// run at all — fall back to the report index rather than skipping the file. A report
			// file absent from BOTH leaves its own tokens out of the map, which under-counts and so
			// only ever silences a finding.
			final scope: SymbolIndex = wide.fileInfo(entry.file) == null ? index : wide;
			final info: Null<FileInfo> = scope.fileInfo(entry.file);
			if (info == null) continue;
			for (cls in CheckScan.classBodies(tree)) considerClass(out, cls, entry.source, index, scope, info, ctx);
		}
		return out;
	}

	/**
	 * Delete each flagged method `run` proved deletable — the method with its modifier / metadata
	 * run (`declGroupSpan`) and its leading doc comment (`docExtendedSpan`), then the whole line
	 * (`lineExtendedSpan`), so no orphaned doc comment or blank modifier line is left behind. A
	 * finding absent from `_deletable` (an interpolation fragment naming it, or a bare `fix`)
	 * yields no edit.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final wanted: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null && _deletable.contains(key(v.file, span))) wanted.push('${span.from}:${span.to}');
		}
		if (wanted.length == 0) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final edits: Array<{ span: Span, text: String }> = [];
		for (cls in CheckScan.classBodies(tree)) for (child in cls.children) {
			final span: Null<Span> = child.span;
			if (span != null && METHOD_KINDS.contains(child.kind) && wanted.contains('${span.from}:${span.to}'))
				edits.push(deletionEdit(source, child, cls, span));
		}
		return edits;
	}

	/**
	 * Flag every unreferenced public method of `cls`, and record the ones whose deletion is proven
	 * safe. `host` is the class's own declaring file, `scope` the index the chain and member
	 * queries resolve through, `index` the REPORT index the authoritative occurrence confirm runs
	 * over.
	 *
	 * The cheap candidate scan runs FIRST and the index-resolved gates only after it yields
	 * something: each of those walks the whole scope, and on a real tree almost no member survives
	 * the reference test, so paying for them per class would dominate the run.
	 */
	private function considerClass(
		out: Array<Violation>, cls: QueryNode, source: String, index: SymbolIndex, scope: SymbolIndex, host: FileInfo, ctx: Ctx
	): Void {
		final owner: Null<String> = cls.name;
		if (owner == null) return;
		final declared: Null<TypeDeclInfo> = host.types.find(t -> t.name == owner);
		// A `@:build` macro can generate the call the scan cannot see; a `@:keep` class is reached
		// by machinery no scan models; an `extern class` declares members of a foreign object.
		if (declared == null || declared.hasKeep || declared.hasBuild || declared.isExtern) return;
		final candidates: Array<Candidate> = unreferencedCandidates(cls, source, host.file, index, ctx);
		if (candidates.length == 0) return;
		if (scope.transitivelyCarriesRtti(owner)) return;
		final chain: Chain = { unresolved: false, generated: false };
		walkChain(scope, host, declared, chain, []);
		if (chain.unresolved || chain.generated) return;
		for (candidate in candidates) {
			final name: String = candidate.name;
			if (
				scope.supertypeDeclaresMember(owner, name) || scope.implementsInterfaceDeclaringMember(owner, name)
				|| scope.subtypeDeclaresMember(owner, name)
			)
				continue;
			out.push({
				file: host.file,
				span: candidate.span,
				rule: RULE_ID,
				severity: Severity.Warning,
				message: 'unused public $name: no reference to it anywhere in scope'
			});
			if (deletable(ctx, name)) _deletable.push(key(host.file, candidate.span));
		}
	}

	/**
	 * The class's public methods that clear every CHEAP gate — the modifier / metadata run, the
	 * implicitly-reachable name list, and the two-mechanism reference test — each paired with the
	 * span its own declaration occupies.
	 */
	private static function unreferencedCandidates(
		cls: QueryNode, source: String, file: String, index: SymbolIndex, ctx: Ctx
	): Array<Candidate> {
		final out: Array<Candidate> = [];
		var mods: Array<String> = [];
		var annotations: Int = 0;
		for (child in cls.children) {
			final isMethod: Bool = METHOD_KINDS.contains(child.kind);
			// The run resets at EVERY member, not only at a method: a `public` or a `@:keep`
			// written on a preceding FIELD would otherwise carry onto the next method and answer
			// for it — inventing a finding in one direction and hiding one in the other.
			if (!isMethod && !RefactorSupport.isMemberDeclKind(child.kind)) {
				if (RefactorSupport.META_KINDS.contains(child.kind))
					annotations++;
				else
					mods.push(child.kind);
				continue;
			}
			final name: Null<String> = child.name;
			final span: Null<Span> = child.span;
			final isPublic: Bool = mods.contains(PUBLIC_MODIFIER);
			final isOverride: Bool = mods.contains(OVERRIDE_MODIFIER);
			final annotated: Bool = annotations > 0;
			mods = [];
			annotations = 0;
			if (!isMethod || name == null || span == null) continue;
			if (!isPublic || isOverride || annotated || !reportableName(name)) continue;
			// Re-bound: a null-safety narrowing does not reach inside an anonymous structure literal.
			final memberName: String = name;
			final memberSpan: Span = span;
			final region: Span = RefactorSupport.docExtendedSpan(source, RefactorSupport.declGroupSpan(child, cls, memberSpan));
			if (provablyUnreferenced(memberName, file, source, region, index, ctx)) out.push({ name: memberName, span: memberSpan });
		}
		return out;
	}

	/**
	 * Whether every occurrence of `name` in scope lies inside `region`, its own declaration. The
	 * cheap global token map decides it first (equal counts = nothing outside), then the
	 * authoritative report-scope confirm agrees — `nameOccursOutside` reads the `\x24name`
	 * interpolation escape the plain tokenizer cannot see.
	 */
	private static function provablyUnreferenced(
		name: String, file: String, source: String, region: Span, index: SymbolIndex, ctx: Ctx
	): Bool {
		final own: Map<String, Int> = [];
		countTokens(source, region.from, region.to, own);
		if (ctx.tokens[name] != own[name]) return false;
		return !index.nameOccursOutside(name, file, region);
	}

	/**
	 * Whether the member `name` may be DELETED: no static FRAGMENT of an interpolated string in
	 * report scope is CONTAINED IN it. `literalOf` answers null for an interpolated string by
	 * contract, so a fragment is only ever PART of a runtime name (`'do$suffix'`) and containment
	 * is asked the other way round. A WHOLE string literal naming the member needs no gate here —
	 * its content is raw text, so the reference test already refused to report the member at all.
	 */
	private static function deletable(ctx: Ctx, name: String): Bool {
		return !ctx.fragments.exists(f -> f.length >= MIN_FRAGMENT_LENGTH && name.indexOf(f) >= 0);
	}

	/**
	 * Whether `name` is a candidate at all: not one of the names reached with no written call
	 * (`new` / `main` / `toString`), not a dunder compiler hook, and not accessor-prefixed —
	 * a `get_` / `set_` method is `orphan-accessor`'s finding, and reporting it here would
	 * double-claim it.
	 */
	private static function reportableName(name: String): Bool {
		if (IMPLICIT_NAMES.contains(name) || StringTools.startsWith(name, GET_PREFIX) || StringTools.startsWith(name, SET_PREFIX))
			return false;
		return !StringTools.startsWith(name, DUNDER) || !StringTools.endsWith(name, DUNDER);
	}

	/**
	 * Accumulate into `chain` whether any ANCESTOR of `type` carries `@:autoBuild` (it generates
	 * members into this class, so its member set is unknowable) and whether any supertype
	 * reference resolved to no indexed declaration (the chain cannot be read at all). Either one
	 * takes the whole class out of scope.
	 */
	private static function walkChain(scope: SymbolIndex, host: FileInfo, type: TypeDeclInfo, chain: Chain, seen: Array<String>): Void {
		final visited: String = '${host.file}#${type.name}';
		if (seen.contains(visited)) return;
		seen.push(visited);
		for (raw in type.supertypesRaw) {
			final supers: Array<{ file: FileInfo, type: TypeDeclInfo }> = scope.resolveTypeRefsFrom(raw, host.file);
			if (supers.length == 0) {
				chain.unresolved = true;
				continue;
			}
			for (s in supers) {
				if (s.type.hasAutoBuild) chain.generated = true;
				walkChain(scope, s.file, s.type, chain, seen);
			}
		}
	}

	/** The identifier-token occurrence counts of every source `scope` indexes — the run's cost-bounded pre-filter. */
	private static function tokenCounts(scope: SymbolIndex): Map<String, Int> {
		final out: Map<String, Int> = [];
		for (fi in scope.allFiles()) {
			final src: Null<String> = scope.sourceOf(fi.file);
			if (src != null) countTokens(src, 0, src.length, out);
		}
		return out;
	}

	/**
	 * Accumulate into `out` the occurrence count of every identifier token in `source[from, to)`,
	 * word-boundary by construction. Raw text, so tokens inside comments, string literals and
	 * `#if` branches all count — the conservative direction (an extra occurrence only ever keeps
	 * a member). A token STRADDLING `to` is counted truncated, which likewise can only under-count
	 * the region and so silence a finding.
	 */
	private static function countTokens(source: String, from: Int, to: Int, out: Map<String, Int>): Void {
		final stop: Int = to <= source.length ? to : source.length;
		var i: Int = from;
		while (i < stop) {
			if (!RefactorSupport.isIdentStartChar(StringTools.fastCodeAt(source, i))) {
				i++;
				continue;
			}
			var end: Int = i + 1;
			while (end < stop && RefactorSupport.isIdentChar(StringTools.fastCodeAt(source, end))) end++;
			final token: String = source.substring(i, end);
			out[token] = (out[token] ?? 0) + 1;
			i = end;
		}
	}

	/**
	 * The static text FRAGMENTS of every INTERPOLATED string in report scope — a partially
	 * computed reflection name. Empty when the grammar exposes no string-fold support, which only
	 * loses the deletion gate.
	 */
	private static function interpolationFragments(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<String> {
		final out: Array<String> = [];
		final stringFold: Null<StringFoldSupport> = plugin.stringFoldSupport();
		if (stringFold == null) return out;
		final fold: StringFoldSupport = stringFold;
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) collectFragments(tree, entry.source, fold, out);
		}
		return out;
	}

	/** Collect into `out` the static `Literal` fragments of every interpolated string `node` and its descendants carry. */
	private static function collectFragments(node: QueryNode, source: String, fold: StringFoldSupport, out: Array<String>): Void {
		final literal: Null<StringLiteral> = fold.literalOf(node, source);
		if (literal == null && STRING_EXPR_KINDS.contains(node.kind)) for (child in node.children) {
			final fragment: Null<String> = child.name;
			if (child.kind == STRING_FRAGMENT_KIND && fragment != null && !out.contains(fragment)) out.push(fragment);
		}
		for (child in node.children) collectFragments(child, source, fold, out);
	}

	/** The whole-line deletion of `node` including its modifier / metadata run and its doc comment. */
	private static function deletionEdit(source: String, node: QueryNode, parent: QueryNode, span: Span): { span: Span, text: String } {
		final group: Span = RefactorSupport.declGroupSpan(node, parent, span);
		return { span: RefactorSupport.lineExtendedSpan(source, RefactorSupport.docExtendedSpan(source, group)), text: '' };
	}

	/** The `_deletable` key of one method declaration. */
	private static inline function key(file: String, span: Span): String {
		return '$file#${span.from}:${span.to}';
	}

}

/** One public method that cleared every cheap gate: its name and its own declaration span. */
private typedef Candidate = {

	/** The method's name — the token the reference test proved absent everywhere else. */
	final name: String;

	/** The method declaration's own span, which the finding reports and `fix` looks up. */
	final span: Span;

};

/** The accumulated verdict of one inheritance-chain walk. */
private typedef Chain = {

	/** Whether a supertype reference resolved to no indexed declaration, leaving the chain unreadable. */
	var unresolved: Bool;

	/** Whether an ancestor carries `@:autoBuild` — it generates members into the class the walk started from. */
	var generated: Bool;

};

/** The whole-run reference evidence, gathered once where the entire file set is in hand. */
private typedef Ctx = {

	/** Identifier-token occurrence counts over every source in report UNION resolution scope. */
	final tokens: Map<String, Int>;

	/** The static text FRAGMENTS of every interpolated string in report scope — the deletion gate. */
	final fragments: Array<String>;

};
