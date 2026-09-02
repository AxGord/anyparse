package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.CondBranchProjection;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags a class / abstract member declared without an explicit `public` or
 * `private` modifier. Haxe defaults an unmodified member to `private`, so the
 * omission is not a bug — but leaving visibility implicit hides intent, and stating
 * it on every member is a documented project rule. `--fix` inserts the default
 * visibility keyword (`private` — the Haxe default, so a behaviour-preserving
 * change) at the canonical position.
 *
 * ## The autofix resolves an `override` through the SymbolIndex
 *
 * An unmodified `override` inherits its visibility from the supertype, NOT the
 * class default — forcing `private` on an override of a public method lowers
 * visibility below the superclass, a compile error. The autofix instead asks the
 * `SymbolIndex` for the overridden member's declared keyword
 * (`memberVisibilityOf`, which walks the supertype closure and defers through
 * unmarked mid-chain overrides) and inserts THAT keyword. When the index cannot
 * prove one — no index, an unindexed supertype, a simple-name collision that
 * disagrees, or an unmarked non-override base (whose default depends on a
 * public-default container the index does not model) — the member stays
 * report-only (it is still flagged — explicit visibility is the rule — but the
 * keyword is the author's to choose).
 *
 * ## An extern container is skipped OUTRIGHT, a `@:publicFields` one only by the fix
 *
 * Both default their unmodified members to `public`, not `private` — so inserting
 * `private` is not behaviour-preserving there, it lowers visibility (probed: a bare
 * `function foo()` on an `extern class` is callable from outside, and writing
 * `private` on it turns the same call into "Cannot access private field").
 *
 * An extern class is therefore not scanned at all (`externModifierKind` on the
 * container's modifier run). It declares an API owned outside the project: the member
 * set mirrors a foreign signature, so neither remedy is an improvement — `private`
 * breaks every caller, `public` is noise on a declaration that has no body to hide.
 * Reporting it means a finding that can only be "fixed" wrongly, which is how it ends
 * up sitting forever on an otherwise clean tree.
 *
 * A `@:publicFields` class is an ORDINARY class the project wrote, where `private` on
 * one member is a real, meaningful opt-out — so stating visibility stays actionable and
 * detection keeps reporting it. Only the fix skips it, leaving the keyword to the
 * author. The fix ALSO re-checks extern, so a caller passing a hand-built violation
 * list cannot route around the detection skip.
 *
 * ## Members inside a conditional-compilation region
 *
 * A `#if … #else … #end` written in MEMBER position is one node
 * (`RefShape.conditionalMemberKind`) holding every branch's members flattened as
 * siblings — a container's direct children do not include them, so a scan of those
 * children alone silently exempts every guarded member. The check descends into the
 * region and recovers the branch boundaries from the directive text between child spans
 * (`CondBranchProjection.conditionalBranchRuns`, the same recovery `member-order` uses),
 * scanning each branch as its own modifier run.
 *
 * Per-branch matters in one direction that a flat scan gets wrong: a region holding
 * NOTHING but a visibility keyword (`#if cpp public #else private #end function f()`)
 * is a modifier for the member AFTER `#end`, so a branch ending on a visibility keyword
 * carries that keyword out of the region. Conversely a keyword written BEFORE the `#if`
 * reaches into every branch, since whichever branch compiles is the one it modifies —
 * and an `insertAt` slot claimed before the `#if` does NOT, because one shared offset
 * cannot take one keyword per branch; each branch's keyword goes at its own member.
 *
 * A carried-out keyword is exempting, not proving: `#if cpp public #end function f()`
 * leaves `f` unmarked in a `!cpp` build, and the check no longer reports it. The carry
 * therefore RAISES the visibility the fix would assume rather than lowering it (an
 * `override` carried the same way resolves through the supertype, which can be `public`)
 * — the direction that costs a finding, never a compile error.
 *
 * Only the `conditionalMemberKind` shape is covered. A `#if` that splits a member's own
 * SIGNATURE rather than listing whole members (`#if cpp function f():Int #else function
 * f():Float #end return 1;`) parses as a straddling `CondSplice*` form carrying no
 * recoverable member run, and its members stay unreported — as they were before.
 *
 * ## Grammar-agnostic
 *
 * `RefShape.visibilityContainerKinds` lists the declaration kinds whose members
 * require visibility (a class / abstract — NOT an interface, whose members are
 * implicitly public, nor an enum abstract, whose values are). A member-host kind
 * comes from `RefShape.memberDeclKinds`, the visibility keywords from
 * `RefShape.visibilityModifierKinds`. Any unset → no-op. The autofix additionally
 * needs `RefShape.defaultVisibilityModifierText` (the keyword to insert),
 * `RefShape.modifierOrderKinds` (to place it after `override` / `@:meta` and before
 * `static` / `inline`), `RefShape.overrideModifierKind` (to route overrides through
 * the index resolution above), and `RefShape.publicDefaultMetaNames` (to exempt a
 * `@:publicFields` container); a grammar leaving the keyword unset is report-only.
 * `RefShape.externModifierKind` drives the outright skip and
 * `RefShape.conditionalMemberKind` / `conditionalElseKeywords` /
 * `conditionalIfKeyword` the branch descent — a grammar setting none of them keeps
 * the plain direct-children scan.
 */
@:nullSafety(Strict)
final class MissingVisibility implements Check {

	public function new() {}

	public function id(): String {
		return 'missing-visibility';
	}

	public function description(): String {
		return 'a class / abstract member without an explicit public or private modifier';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final resolved: Null<Seams> = resolveSeams(plugin);
		if (resolved == null) return [];
		// Re-bound to a non-null local: strict null-safety narrowing does not reach into an
		// anonymous struct literal.
		final seams: Seams = resolved;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk({
				out: violations,
				file: entry.file,
				seams: seams,
				source: entry.source,
				comments: commentTokens(entry.source, seams, plugin.lexicalRegions.bind(entry.source)),
				guarded: EnumAbstractForms.valueStarts(plugin, tree)
			}, tree, false);
		}
		return violations;
	}

	/**
	 * Insert the visibility keyword on each flagged member of a private-default
	 * container. Re-parses `source`, re-walks the containers, and for a member whose
	 * host-span `from` matches a violation inserts the keyword at the canonical
	 * visibility slot: after any `override` / `@:meta`, before the first `static` /
	 * `inline` (a run sibling ranked above visibility in `modifierOrderKinds`), else
	 * immediately before the member host. A non-override gets
	 * `defaultVisibilityModifierText` — behaviour-preserving in a plain class /
	 * abstract (Haxe treats an unmodified member there as `private`). An
	 * `overrideModifierKind`-bearing member gets the SUPERTYPE's keyword resolved
	 * through `index.memberVisibilityOf`, or stays report-only when unprovable. A
	 * container whose members are implicitly public — an extern class
	 * (`externModifierKind`) or one carrying a public-default meta
	 * (`publicDefaultMetaNames`, e.g. `@:publicFields`) — is skipped: it stays
	 * report-only rather than being lowered to `private`. Detection already skips the
	 * extern half outright, so that arm only matters for a caller passing a hand-built
	 * violation list. No default keyword set → report-only.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final resolved: Null<Seams> = resolveSeams(plugin);
		if (resolved == null) return [];
		// Re-bound to non-null locals: strict null-safety narrowing does not reach into an
		// anonymous struct literal.
		final seams: Seams = resolved;
		final resolvedKeyword: Null<String> = seams.keyword;
		if (resolvedKeyword == null) return [];
		final keyword: String = resolvedKeyword;
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		var visRank: Int = -1;
		for (v in seams.visibility) {
			final r: Int = seams.order.indexOf(v);
			if (r > visRank) visRank = r;
		}
		final flagged: Array<Int> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push(span.from);
		}
		final edits: Array<{ span: Span, text: String }> = [];
		insertWalk({
			edits: edits,
			seams: seams,
			source: source,
			comments: commentTokens(source, seams, plugin.lexicalRegions.bind(source)),
			visRank: visRank,
			keyword: keyword,
			flagged: flagged,
			index: index,
			guarded: EnumAbstractForms.valueStarts(plugin, tree)
		}, tree, false);
		return edits;
	}

	/**
	 * The file's comment tokens, needed only to mask a `#else` written inside a comment out of a
	 * conditional region's branch-boundary scan — so a grammar with no conditional seams, or a file
	 * with no `#if` in it at all, pays nothing.
	 */
	private static function commentTokens(
		source: String, seams: Seams, regions: () -> Array<LexRegion>
	): Array<{ from: Int, to: Int, isLine: Bool }> {
		return seams.condKind != null && source.indexOf(seams.ifKeyword) >= 0 ? RefactorSupport.collectCommentTokens(regions()) : [];
	}

	/**
	 * Walk `node`; for every visibility-requiring container NOT preceded by an extern modifier,
	 * flag each member lacking a visibility modifier. `incomingExtern` carries that skip into the
	 * declaration the modifier belongs to, including a wrapper decl node (Haxe `final class`
	 * projects the class as a `ClassForm` nested in a `FinalDecl`).
	 *
	 * The run ends at the first child that is not itself a modifier (`Seams.modifierRunKinds`) —
	 * that child IS the declaration the run modified. Ending it on the CONTAINER kind instead
	 * leaks the flag past any declaration this check does not scan: `extern interface I {}` then
	 * `class C {}` exempted every member of `C`.
	 */
	private static function walk(ctx: ScanCtx, node: QueryNode, incomingExtern: Bool): Void {
		final externKind: Null<String> = ctx.seams.externKind;
		var isExtern: Bool = incomingExtern;
		for (child in node.children) {
			if (externKind != null && child.kind == externKind) isExtern = true;
			if (ctx.seams.modifierRunKinds.contains(child.kind)) continue;
			if (ctx.seams.containers.contains(child.kind)) {
				if (!isExtern) scanRun(ctx, child.children, false);
				walk(ctx, child, false);
			} else
				walk(ctx, child, isExtern);
			isExtern = false;
		}
	}

	/**
	 * Scan one member run in source order, flagging each member whose preceding modifier run
	 * carries no visibility keyword. Modifier siblings precede the member they attach to, so a
	 * running `sawVisibility` flag — set by a visibility node, read and reset at each member —
	 * tells whether the member that just appeared had one. A conditional-compilation region is
	 * descended into per branch by `scanConditional`. Returns the flag's value at the end of the
	 * run: a run ending on a visibility keyword modifies whatever member follows it.
	 */
	private static function scanRun(ctx: ScanCtx, kids: Array<QueryNode>, incoming: Bool): Bool {
		var sawVisibility: Bool = incoming;
		for (child in kids) {
			if (ctx.seams.condKind != null && child.kind == ctx.seams.condKind)
				sawVisibility = scanConditional(ctx, child, sawVisibility);
			else if (ctx.seams.visibility.contains(child.kind))
				sawVisibility = true;
			else if (ctx.seams.members.contains(child.kind)) {
				final span: Null<Span> = child.span;
				if (
					!sawVisibility && !statesOwnVisibility(child, ctx.seams) && span != null
					&& !EnumAbstractForms.isValue(span, ctx.guarded)
				) ctx.out.push({
					file: ctx.file,
					span: span,
					rule: 'missing-visibility',
					severity: Severity.Warning,
					message: 'member declared without an explicit public or private modifier'
				});
				sawVisibility = false;
			}
		}
		return sawVisibility;
	}

	/**
	 * Scan a member-position conditional region branch by branch, returning the visibility-run
	 * state it leaves behind. Each branch starts from the state that reached the `#if` (a keyword
	 * written before the region modifies whichever branch compiles), and a branch ENDING on a
	 * visibility keyword carries it out — a region holding nothing but `public` / `private` is a
	 * modifier for the member after `#end`, not a region of members of its own. Any branch carrying
	 * out is enough — a spurious carry only exempts a member, never reports one.
	 *
	 * A shape the splitter refuses — or a region with no children at all — falls back to ONE flat
	 * run: losing the branch boundaries costs the straddling case above, losing the region costs
	 * every member in it. The fallback drops `incoming` though, and with a keyword already in
	 * flight it skips the region outright: flattened, that keyword is consumed by the FIRST member
	 * and every later one is reported, but each is in a mutually exclusive branch the keyword also
	 * modifies — a false positive whose fix writes a second keyword onto the same member.
	 */
	private static function scanConditional(ctx: ScanCtx, region: QueryNode, incoming: Bool): Bool {
		final runs: Null<Array<CondBranchRun>> = CondBranchProjection.conditionalBranchRuns(
			region, ctx.source, ctx.seams.elseKeywords, ctx.comments
		);
		if (runs == null || runs.length == 0) return incoming || scanRun(ctx, region.children, false);
		var carry: Bool = false;
		// Not `runs.exists(...)`: every branch must be scanned for its own violations, and `exists`
		// stops at the first branch that carries out.
		for (run in runs) if (scanRun(ctx, run.nodes, incoming)) carry = true;
		// `|| incoming`, for the branch NO directive writes: a `#if A … #end` contributes nothing when
		// A is false, so a keyword written before the `#if` reaches the member after `#end` untouched
		// in that build. Dropping it reported a member that IS marked there — and the fix then wrote a
		// second keyword in front of the first, which does not compile.
		return carry || incoming;
	}

	/**
	 * Walk `node`; insert the keyword on each flagged member of a container. A container
	 * preceded by an extern modifier or a public-default meta (`@:publicFields`) is skipped
	 * — its members are implicitly public, so inserting `private` would change visibility.
	 * `incomingPublicDefault` carries that skip into the declaration the modifier belongs to,
	 * including a wrapper decl node (Haxe `final class` projects the class as a `ClassForm` nested
	 * in a `FinalDecl`). The run ends at the first non-modifier child — that child IS the
	 * declaration it modified. Ending it on the CONTAINER kind instead leaked the flag past a
	 * declaration this walk does not visit: `@:publicFields interface I {}` then `class C {}` left
	 * `C`'s members report-only forever.
	 */
	private static function insertWalk(ctx: FixCtx, node: QueryNode, incomingPublicDefault: Bool): Void {
		final externKind: Null<String> = ctx.seams.externKind;
		var publicDefault: Bool = incomingPublicDefault;
		for (child in node.children) {
			final metaName: Null<String> = child.name;
			if (externKind != null && child.kind == externKind || metaName != null && ctx.seams.publicMetaNames.contains(metaName))
				publicDefault = true;
			if (ctx.seams.modifierRunKinds.contains(child.kind)) continue;
			if (ctx.seams.containers.contains(child.kind)) {
				if (!publicDefault) insertRun(ctx, child.children, child.name, { insertAt: -1, sawOverride: false });
				insertWalk(ctx, child, false);
			} else
				insertWalk(ctx, child, publicDefault);
			publicDefault = false;
		}
	}

	/**
	 * Emit the keyword for each flagged member of one member run and return the modifier-run state
	 * the run ends on. `insertAt` tracks the start of the first preceding-run sibling ranked above
	 * visibility (`static` / `inline`), `sawOverride` whether the run carries an override; both
	 * reset at each member. A conditional-compilation region is descended into per branch by
	 * `insertConditional`, so the keyword lands at the member's own declaration INSIDE its branch.
	 */
	private static function insertRun(ctx: FixCtx, kids: Array<QueryNode>, typeName: Null<String>, incoming: RunState): RunState {
		var insertAt: Int = incoming.insertAt;
		var sawOverride: Bool = incoming.sawOverride;
		for (child in kids) {
			if (ctx.seams.condKind != null && child.kind == ctx.seams.condKind) {
				final after: RunState = insertConditional(ctx, child, typeName, { insertAt: insertAt, sawOverride: sawOverride });
				insertAt = after.insertAt;
				sawOverride = after.sawOverride;
			} else if (ctx.seams.members.contains(child.kind)) {
				insertMember(ctx, child, typeName, { insertAt: insertAt, sawOverride: sawOverride });
				insertAt = -1;
				sawOverride = false;
			} else {
				if (ctx.seams.overrideKind != null && child.kind == ctx.seams.overrideKind) sawOverride = true;
				if (insertAt < 0 && ctx.visRank >= 0 && ctx.seams.order.indexOf(child.kind) > ctx.visRank) {
					final span: Null<Span> = child.span;
					if (span != null) insertAt = span.from;
				}
			}
		}
		return { insertAt: insertAt, sawOverride: sawOverride };
	}

	/**
	 * The fix-side mirror of `scanConditional`: every branch is walked as its own modifier run, so a
	 * flagged member gets its keyword at its own declaration inside the branch rather than before
	 * the region.
	 *
	 * `insertAt` does NOT cross the `#if` in either direction. Inwards, a slot claimed by a modifier
	 * BEFORE the region is one offset that cannot receive one keyword per branch — passing it in
	 * emitted N identical zero-width inserts at it (`private private static`). Outwards, a slot
	 * claimed INSIDE a branch must not place the keyword of a member after `#end`. Both ends reset
	 * to -1, putting each keyword immediately before its own member — a valid slot under any
	 * preceding modifier, even if not the canonical one.
	 *
	 * `sawOverride` does cross, from any branch: a member after `#end` that is an override in even
	 * one build resolves through the index rather than being forced to `private`.
	 */
	private static function insertConditional(ctx: FixCtx, region: QueryNode, typeName: Null<String>, incoming: RunState): RunState {
		final entry: RunState = { insertAt: -1, sawOverride: incoming.sawOverride };
		final runs: Null<Array<CondBranchRun>> = CondBranchProjection.conditionalBranchRuns(
			region, ctx.source, ctx.seams.elseKeywords, ctx.comments
		);
		if (runs == null || runs.length == 0)
			return { insertAt: -1, sawOverride: insertRun(ctx, region.children, typeName, entry).sawOverride };
		var sawOverride: Bool = false;
		// Not `runs.exists(...)`: every branch must emit its own edits, and `exists` stops at the
		// first branch that carries an override out.
		for (run in runs) if (insertRun(ctx, run.nodes, typeName, entry).sawOverride) sawOverride = true;
		// `|| incoming.sawOverride`, for the branch no directive writes — the region contributes
		// nothing when its condition is false, so what reached the `#if` reaches the member after
		// `#end`. Mirrors the detection side.
		return { insertAt: -1, sawOverride: sawOverride || incoming.sawOverride };
	}

	/**
	 * Emit a zero-width insert at `member`'s canonical visibility slot when it is flagged —
	 * `keyword` for a plain member, the index-resolved supertype keyword for an override (none
	 * provable → no edit). The keyword lands at `insertAt`, else immediately before the member host
	 * — after any `override` / `@:meta`, which rank at or below visibility.
	 */
	private static function insertMember(ctx: FixCtx, member: QueryNode, typeName: Null<String>, state: RunState): Void {
		final span: Null<Span> = member.span;
		// `statesOwnVisibility` is re-asked here, exactly as the extern check is: `fix` is handed the
		// CALLER's violation list, so a hand-built one naming a member that already carries its
		// visibility would otherwise get a second keyword prepended — the invalid `private final
		// private function f()` this whole guard exists to stop.
		if (
			span == null || !ctx.flagged.contains(span.from) || EnumAbstractForms.isValue(span, ctx.guarded)
			|| statesOwnVisibility(member, ctx.seams)
		)
			return;
		final memberName: Null<String> = member.name;
		final index: Null<SymbolIndex> = ctx.index;
		final insert: Null<String> = if (!state.sawOverride)
			ctx.keyword;
		else if (index != null && typeName != null && memberName != null)
			index.memberVisibilityOf(typeName, memberName);
		else
			null;
		if (insert == null) return;
		final pos: Int = state.insertAt >= 0 ? state.insertAt : span.from;
		ctx.edits.push({ span: new Span(pos, pos), text: '$insert ' });
	}

	/** Resolve the container / member / visibility seam kinds plus the fix-only autofix seams, or null when any required kind is unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final containers: Array<String> = shape.visibilityContainerKinds ?? [];
		if (containers.length == 0) return null;
		final members: Array<String> = shape.memberDeclKinds ?? [];
		if (members.length == 0) return null;
		final visibility: Array<String> = shape.visibilityModifierKinds ?? [];
		if (visibility.length == 0) return null;
		final order: Array<String> = shape.modifierOrderKinds ?? [];
		final elseKeywords: Null<Array<String>> = shape.conditionalElseKeywords;
		return {
			containers: containers,
			members: members,
			visibility: visibility,
			order: order,
			modifierRunKinds: modifierRunKinds(shape, plugin.metaShape()),
			keyword: shape.defaultVisibilityModifierText,
			overrideKind: shape.overrideModifierKind,
			externKind: shape.externModifierKind,
			publicMetaNames: shape.publicDefaultMetaNames ?? [],
			condKind: shape.conditionalMemberKind,
			elseKeywords: elseKeywords ?? [],
			ifKeyword: shape.conditionalIfKeyword ?? '#if'
		};
	}

	/**
	 * The kinds that may PRECEDE a declaration without ending its modifier run — every modifier
	 * and every annotation kind. Deliberately a positive criterion: anything else a walk meets
	 * IS the declaration the run modified, so the run ends there whether or not this check
	 * scans it.
	 *
	 * The modifier half is ASKED (`CheckScan.modifierKinds`), not re-derived. It used to
	 * assemble its own narrower union — `modifierOrderKinds` plus the visibility pair plus
	 * `externModifierKind` — which ended a run at `dynamic`, `macro`, `abstract` and
	 * `overload`, four keywords the shared answer covers. One question, one answer.
	 */
	private static function modifierRunKinds(shape: RefShape, meta: MetaShape): Array<String> {
		final out: Array<String> = CheckScan.modifierKinds(shape);
		for (k in meta.metaKinds) if (!out.contains(k)) out.push(k);
		return out;
	}

	/**
	 * Whether `member` CARRIES its own visibility modifier rather than following one in the
	 * container's modifier run.
	 *
	 * A member is normally PRECEDED by its modifiers as siblings, which is what `scanRun`
	 * accumulates. But when `final` leads the run the parser projects one node that swallows the
	 * rest: `final private function f()` is `(FinalModifiedMember f (Private) …)` while `private
	 * final function f()` is `(Private) (FinalModifiedMember f …)`. Reading only the siblings
	 * therefore saw no visibility on the first spelling and reported a member that states it — and
	 * the fix then PREPENDED a second keyword, writing `private final private function f()`, which
	 * anyparse re-parses and Haxe rejects. Pre-existing and reachable with no writer refusal
	 * anywhere: `--fix --rule missing-visibility` on a one-member file wrote exactly that, and no
	 * gate in the pipeline objected. `static private` was never affected — only `final` swallows.
	 *
	 * DIRECT children only: a visibility node deeper inside belongs to a nested declaration, and
	 * counting it would exempt the enclosing member for its neighbour's modifier.
	 */
	private static function statesOwnVisibility(member: QueryNode, seams: Seams): Bool {
		return member.children.exists(kid -> seams.visibility.contains(kid.kind));
	}

}

/** The resolved seams `MissingVisibility` reads in both `run` and `fix`. */
private typedef Seams = {
	final containers: Array<String>;
	final members: Array<String>;
	final visibility: Array<String>;
	final order: Array<String>;

	/** The kinds a declaration's preceding modifier run may hold; any other kind ENDS the run. */
	final modifierRunKinds: Array<String>;

	final keyword: Null<String>;
	final overrideKind: Null<String>;
	final externKind: Null<String>;
	final publicMetaNames: Array<String>;

	/** The member-position conditional-compilation region kind; null keeps the plain direct-children scan. */
	final condKind: Null<String>;

	/** The branch-opening directives (`#else` / `#elseif`); empty makes a region one flat run. */
	final elseKeywords: Array<String>;

	/** The region-opening directive, used only as the cheap "does this file hold any `#if`" pre-scan. */
	final ifKeyword: String;
};

/** What `MissingVisibility.run`'s walk threads through every frame — resolved once per file. */
private typedef ScanCtx = {
	final out: Array<Violation>;
	final file: String;
	final seams: Seams;
	final source: String;
	final comments: Array<{ from: Int, to: Int, isLine: Bool }>;

	/**
	 * The span starts of the values of an enum abstract the grammar does not project as one
	 * (`EnumAbstractForms.valueStarts`). They arrive as members of a plain abstract, and an
	 * enum-abstract value is implicitly public — writing `private` on one turns every read of it
	 * into `Cannot access private field`.
	 */
	final guarded: Array<Int>;
};

/** What `MissingVisibility.fix`'s walk threads through every frame — resolved once per call. */
private typedef FixCtx = {
	final edits: Array<{ span: Span, text: String }>;
	final seams: Seams;
	final source: String;
	final comments: Array<{ from: Int, to: Int, isLine: Bool }>;
	final visRank: Int;
	final keyword: String;
	final flagged: Array<Int>;
	final index: Null<SymbolIndex>;

	/** The same unprojected enum-abstract values `ScanCtx.guarded` holds, re-derived here. */
	final guarded: Array<Int>;
};

/**
 * The modifier-run state carried between siblings of one member run: the insert position claimed by
 * a preceding sibling ranked above visibility (`-1` = none, insert at the member itself), and
 * whether the run carries an `override`.
 */
private typedef RunState = {
	final insertAt: Int;
	final sawOverride: Bool;
};
