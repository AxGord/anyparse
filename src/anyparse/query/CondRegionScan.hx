package anyparse.query;

using StringTools;
using Lambda;

import anyparse.query.CondBranchProjection.CondBranchRun;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;

/**
 * Conditional-compilation regions, as far as an ANALYSIS can see them. A `#if` region is the
 * one construct whose contents the projected tree may not carry: an unparsed splice is raw
 * bytes, and a declaration that exists only under one set of build flags is invisible to any
 * scan of the other arm.
 *
 * So the module answers two questions. Fail-closed: does an opaque region MENTION the name a
 * mutating op is about to rewrite (`opaqueCondRegionMentioning` and the diagnostics over it) —
 * if it might, the op refuses rather than rewriting half the arms. And structurally: which
 * declarations of a name does a region carry, one per arm (`condArmDeclarations`,
 * `exclusiveBranchRedeclaration`), so a duplicate-declaration verdict does not fire on two
 * arms of the same `#if`.
 */
@:nullSafety(Strict)
final class CondRegionScan {

	/**
	 * Whether a projected node kind denotes a `#if...#end` region — a block
	 * `Conditional`, an expression `ConditionalExpr`, or any `CondSplice*`
	 * mid-expression / statement splice. An unrecognised conditional kind
	 * degrades to `ActiveCode`, which still blocks — fail-closed.
	 */
	public static inline function isConditionalKind(kind: String): Bool {
		return kind == 'Conditional' || kind == 'ConditionalExpr' || kind.startsWith('CondSplice');
	}

	/**
	 * The span of an UNPARSED conditional-compilation region inside `scope` whose raw bytes
	 * spell `name` as a standalone identifier, or null when no region there could hold one.
	 *
	 * `RefShape.opaqueCondRegionKinds` names the ctors a grammar falls back to when a
	 * `#if … #end` region is not a balanced subtree. Such a node keeps its CONTINUATION as a
	 * child (the tail operand, the shared body, the statement after `#end`) and drops the
	 * region itself: nothing in it projects. So the unmodelled bytes are exactly the parts of
	 * the node's own span that no child covers, which is what this returns — the region text
	 * a diagnostic quotes back, not the whole node.
	 *
	 * Asked by TEXT because there is no tree to ask. That makes the test conservative in the
	 * one direction that is safe: a mention bound to some OTHER binding of the same name, or
	 * one sitting in a comment or a string literal inside the region, refuses a rename that
	 * would have been fine. Being wrong the other way is a silent miscompile in whichever
	 * build defines the condition, and no scan of a region with no nodes can do better.
	 * Standalone-identifier matching rather than a bare substring: a real reference is a
	 * token, so `tagName` does not count as a mention of `tag`, and an interpolated `$tag`
	 * still does (a `$` is not an identifier character).
	 *
	 * CONSUMED BY BOTH SUBSYSTEMS, which is why the mutating ops and `lint --fix` are not in
	 * fact asymmetric over an unparsed region: the name-driven ops ask through
	 * `opaqueCondRegionInAny`, and the one CHECK whose fix is itself a rename (`naming`) asks
	 * this directly. No other check needs it — their fixes are span-local rewrites of
	 * constructs the tree DID project, a region with no interior nodes yields no edit, and the
	 * writer re-emits it byte-verbatim.
	 */
	public static function opaqueCondRegionMentioning(scope: QueryNode, source: String, name: String, shape: RefShape): Null<Span> {
		final kinds: Array<String> = shape.opaqueCondRegionKinds ?? [];
		if (kinds.length == 0 || name.length == 0) return null;
		function walk(node: QueryNode): Null<Span> {
			final span: Null<Span> = node.span;
			if (span != null && kinds.contains(node.kind))
				for (gap in unmodelledGaps(node, span))
					if (SourceText.mentionsIdent(source, gap, name)) return gap;
			for (c in node.children) {
				final found: Null<Span> = walk(c);
				if (found != null) return found;
			}
			return null;
		}
		return walk(scope);
	}

	/**
	 * The fail-closed diagnostic every MUTATING op shares for an unparsed conditional-compilation
	 * region that mentions `name`, or null when `scope` holds none.
	 *
	 * One builder rather than a message per op: the refusal is the same fact everywhere (the model
	 * dropped these bytes, so no rewrite can be complete over them), and a reader who has met it
	 * once should recognise it from any op. `what` is the op's own subject, spelled as its other
	 * diagnostics spell it (`rename of "x"`, `inline of "f"`); `file` is included only when the op
	 * works over more than one, where a bare line:col would not locate the region.
	 */
	public static function opaqueCondRegionDiagnostic(
		source: String, scope: QueryNode, name: String, shape: RefShape, what: String
	): Null<String> {
		final region: Null<Span> = opaqueCondRegionMentioning(scope, source, name, shape);
		if (region == null) return null;
		final at: Position = region.lineCol(source);
		return '$what is unsafe: the unparsed conditional-compilation region at ${at.line}:${at.col} spells "$name" in bytes'
			+ ' the parser captured raw (${SourceText.regionExcerpt(source, region)}), so no scan can see that occurrence and the'
			+ ' rewrite would leave it on the old name - restructure the region into a balanced #if first';
	}

	/**
	 * The first `opaqueCondRegionDiagnostic` any of `files` yields for `name`, prefixed with the
	 * file it came from, or null when none does.
	 *
	 * The multi-file arm every CROSS-file mutating op needs, as one pre-pass rather than a check
	 * threaded through each op's own rewrite loop: the refusal is atomic — a region anywhere in the
	 * scope defeats the whole edit set — so deciding it before the first edit is both cheaper and
	 * the only order that cannot half-apply. The file prefix is load-bearing here where the
	 * single-file arm's bare line:col is not: one coordinate names no file.
	 */
	public static function opaqueCondRegionInAny(
		files: Array<{ final file: String; final source: String; final tree: QueryNode; }>, name: String, shape: RefShape, what: String
	): Null<String> {
		for (f in files) {
			final opaque: Null<String> = opaqueCondRegionDiagnostic(f.source, f.tree, name, shape, what);
			if (opaque != null) return '${f.file}: $opaque';
		}
		return null;
	}

	/**
	 * The span of a declaration of `name` under `scope` whose EXISTENCE depends on build flags while
	 * another declaration of the same name is already in effect where it sits, or null when no
	 * conditional-compilation region there creates that ambiguity.
	 *
	 * A conditional-compilation branch is NOT a scope — a name declared inside `#if` stays visible past
	 * the `#end` — while the arms are mutually exclusive, so the tree carries declarations of which only
	 * some exist in any one build. Every reference past the `#end` resolves to exactly one of them, which
	 * makes a rename or an escape analysis correct for that configuration and wrong for the other. Two
	 * shapes create it, and both are reported:
	 *
	 * - the name declared on TWO OR MORE arms of one region;
	 * - the name declared on ONE arm while a declaration ALREADY IN EFFECT there also carries it — a
	 *   sibling declaration BEFORE the region, a parameter of the enclosing function, or either of
	 *   those in an ENCLOSING statement list. In the configuration the arm is compiled out of, the
	 *   reference falls through to that declaration instead.
	 *
	 * An arm's declaration may sit inside a NESTED region: the inner `#end` does not end the outer arm,
	 * so the scan recurses and attributes it to the arm that holds it.
	 *
	 * A declaration AFTER the region is not this shape: it is in effect in every configuration from its
	 * own position on, which is where the references that could differ live. Neither is a SEQUENTIAL
	 * re-declaration in one block or in one arm — `ScopeFrame` resolves those by position, so a
	 * reference past the second declaration answers the second, and `rename` / `extract-method` both
	 * produce correct output. Measured on a loop body, a try/catch, a case branch, a second binding
	 * shadowing a parameter, a closure declared between the two, a self-reading `var x = x + 1` and two
	 * declarations inside ONE arm, each compiled under two `#if` configurations after the edit.
	 *
	 * One conservative edge: the arm test is `topLevelDeclaredName`, which descends a single-child
	 * wrapper, so an arm whose only statement is a BLOCK declaring the name counts as declaring it even
	 * though a block-scoped declaration cannot be read past the `#end`. That direction refuses, which is
	 * the safe one; the same descent is what lets a lone-statement NESTED region be seen at all.
	 */
	public static function exclusiveBranchRedeclaration(
		scope: QueryNode, source: String, name: String, plugin: GrammarPlugin, shape: RefShape
	): Null<Span> {
		final kind: Null<String> = shape.conditionalMemberKind;
		final keywords: Null<Array<String>> = shape.conditionalElseKeywords;
		if (kind == null || keywords == null) return null;
		// Re-bound to non-null locals: strict null-safety narrowing does not reach into an
		// anonymous-structure literal.
		final condKind: String = kind;
		final elseKeywords: Array<String> = keywords;
		// No `#if` in the file means no region to read, and the walk below is per node — so the
		// overwhelmingly common file skips it on one string scan, as the branch projection does.
		if (source.indexOf(shape.conditionalIfKeyword ?? '#if') == -1) return null;
		final scan: ArmScan = {
			source: source,
			name: name,
			condKind: condKind,
			declKinds: TypeResolver.blockScopedValueDeclarationKinds(shape),
			metaKinds: plugin.metaShape().metaKinds,
			elseKeywords: elseKeywords,
			comments: SourceComments.collectCommentTokens(plugin.lexicalRegions(source))
		};
		// A PARAMETER is in effect for the whole body, so it is an "already in effect" declaration
		// for every region under it - the same standing a sibling declaration before the region has.
		final params: Array<String> = shape.paramKinds ?? [];
		final shadowsParam: Bool = scope.children.exists(c -> params.contains(c.kind) && c.name == name);
		// A reference past the `#end` binds to a declaration whose EXISTENCE depends on build flags
		// in two shapes, and `inEffect` is what separates them from the safe rest: the name on two
		// arms of one region, and the name on ONE arm while a declaration ALREADY IN EFFECT there
		// also carries it - in the configuration the arm is compiled out of, the reference falls
		// through to that one instead. Already in effect means a sibling declaration BEFORE the
		// region, a parameter, or either of those in an ENCLOSING statement list, which is what the
		// `inherited` argument carries down: a local declared in an outer block is visible in the
		// inner one and a rename of the arm's own declaration breaks the same way there.
		// A sibling declaration AFTER the region is safe: it is in effect in every configuration
		// from its own position on, which is where the references that could differ live.
		function walk(node: QueryNode, inherited: Bool): Null<Span> {
			var inEffect: Bool = inherited;
			for (c in node.children) {
				if (c.kind == scan.condKind) {
					final decls: Array<QueryNode> = condArmDeclarations(c, scan);
					if (decls.length > 1) return decls[1].span;
					if (decls.length == 1) {
						if (inEffect) return decls[0].span;
						inEffect = true;
					}
				} else if (BinderScan.topLevelDeclaredName(c, scan.declKinds, scan.metaKinds) == scan.name)
					inEffect = true;
				final found: Null<Span> = walk(c, inEffect);
				if (found != null) return found;
			}
			return null;
		}
		return walk(scope, shadowsParam);
	}

	/**
	 * Whether `node` is a `#if ... #end` region that declares NOTHING and guards
	 * only modifiers / metadata - `#if !flash inline #end` or
	 * `#if (haxe_ver >= 4.2) extern #else @:extern #end` sitting in front of the
	 * member they qualify. The grammar projects such a region as an ordinary
	 * `Conditional` SIBLING of the decl, exactly like the plain `(Public)(Static)`
	 * modifier siblings around it, so without this test `declGroupSpan` stopped its
	 * walk-back at the region and the decl group began AFTER it.
	 *
	 * That truncation is silent and it changes MEANING: a reorder (`member-order
	 * --fix`) moved the declaration out from under its own guard and left the guard
	 * in place for whichever member slid up into that slot - measured on
	 * `Pony/pony/TypedPool.hx`, where `#if (!flash && !debug) inline #end` stayed
	 * put and the `public inline function get_isDestroy` that moved under it became
	 * `inline inline` (`Duplicate access modifier inline`), and on
	 * `Pony/pony/events/Listener0.hx`, where four `@:from #if ... extern #else
	 * @:extern #end` prefixes were left behind and re-attached to unrelated
	 * properties (`@:from cast functions must be static`).
	 *
	 * A region that declares a MEMBER is a different construct entirely - it owns that
	 * member rather than qualifying the next one - so a region with a child that is
	 * neither a modifier / annotation nor one of the bare declaration-STARTING keywords
	 * (`COND_DECL_PREFIX_KEYWORD_KINDS`) is deliberately not folded here. Those keywords
	 * had to be added: `#if (haxe_ver >= 4.2) enum #else @:enum #end` carries a bare
	 * `EnumKw` in its true branch, so a modifier-and-annotation-only test read the region
	 * as a declaration of its own and `move` cut the abstract out from under it, leaving
	 * `enum` standing in front of the next declaration (`Unexpected @` on
	 * `Pony/pony/text/TextTools.hx` after moving `AnsiForeground` out).
	 */
	public static function isConditionalModifierRegion(node: QueryNode): Bool {
		return node.kind == MemberKinds.CONDITIONAL_REGION_KIND && node.children.length > 0
			&& node.children.foreach(
				c -> MemberKinds.MODIFIER_META_KINDS.contains(c.kind) || MemberKinds.COND_DECL_PREFIX_KEYWORD_KINDS.contains(c.kind)
			);
	}

	/**
	 * The parts of `span` that none of `node`'s direct children cover — the bytes the model
	 * dropped. Children are taken in span order and a child with no span contributes nothing,
	 * which widens the gap rather than narrowing it: the safe direction for a fail-closed gate.
	 */
	private static function unmodelledGaps(node: QueryNode, span: Span): Array<Span> {
		final covered: Array<Span> = [for (c in node.children) if (c.span != null) (c.span: Span)];
		covered.sort((a, b) -> a.from - b.from);
		final out: Array<Span> = [];
		var at: Int = span.from;
		for (c in covered) {
			if (c.from > at) out.push(new Span(at, c.from < span.to ? c.from : span.to));
			if (c.to > at) at = c.to;
		}
		if (at < span.to) out.push(new Span(at, span.to));
		return out;
	}

	/**
	 * The declarations of `scan.name` this conditional region carries, ONE per arm that declares it,
	 * in arm order — the per-region half of `exclusiveBranchRedeclaration`.
	 *
	 * A run whose candidate is a NESTED region contributes that region's own declaration: the nested
	 * `#end` does not end the enclosing arm, so a declaration under it is still visible past the outer
	 * one. Two arms of a nested region already carry the name on mutually exclusive arms, and that
	 * verdict is returned as it stands, whatever the enclosing region does. A run contributes at most
	 * one declaration: a SEQUENTIAL re-declaration inside one arm resolves by position like any other
	 * and is not this shape.
	 *
	 * When the splitter refuses the region's shape it reports null runs and which arm a declaration
	 * belongs to is unknown; every top-level declaration among the flat children is then counted as its
	 * own arm's, which is the refusing direction. On that path alone the caller's message overstates
	 * what was established — two SEQUENTIAL declarations inside one arm would also reach it — but no
	 * constructed input makes `CondBranchProjection.monotonicChildSpans` refuse, so the message is left
	 * as the reachable paths need it rather than split for a path nothing can exercise.
	 */
	private static function condArmDeclarations(region: QueryNode, scan: ArmScan): Array<QueryNode> {
		final runs: Null<Array<CondBranchRun>> = CondBranchProjection.conditionalBranchRuns(
			region, scan.source, scan.elseKeywords, scan.comments
		);
		final out: Array<QueryNode> = [];
		if (runs == null) {
			for (c in region.children) if (BinderScan.topLevelDeclaredName(c, scan.declKinds, scan.metaKinds) == scan.name) out.push(c);
			return out;
		}
		for (run in runs) for (n in run.nodes) {
			if (n.kind == scan.condKind) {
				final nested: Array<QueryNode> = condArmDeclarations(n, scan);
				if (nested.length > 1) return nested;
				if (nested.length == 0) continue;
				out.push(nested[0]);
				break;
			}
			if (BinderScan.topLevelDeclaredName(n, scan.declKinds, scan.metaKinds) != scan.name) continue;
			out.push(n);
			break;
		}
		return out;
	}

}

/**
 * The seams `RefactorSupport.condArmDeclarations` reads while scanning one conditional region's
 * arms for a declaration of `name` — the grammar's conditional and declaration vocabularies plus
 * the file text the branch splitter needs, gathered once per `exclusiveBranchRedeclaration` call.
 */
private typedef ArmScan = {
	final source: String;
	final name: String;
	final condKind: String;
	final declKinds: Array<String>;
	final metaKinds: Array<String>;
	final elseKeywords: Array<String>;
	final comments: Array<{ from: Int, to: Int, isLine: Bool }>;
};
