package anyparse.check;

import anyparse.check.Check.CrossFileEdits;
import anyparse.check.Check.Violation;
import anyparse.check.ReflectionScan.ScopeFile;
import anyparse.query.AllowGrants;
import anyparse.query.CanonicalEdit;
import anyparse.query.CondRegionScan;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberBranchScan;
import anyparse.query.NamingPolicy.ImplicitReach;
import anyparse.query.NamingPolicy.NamedDecl;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.NamingPolicy.NamingPolicy;
import anyparse.query.NamingPolicy.NamingRule;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.OccurrenceScan;
import anyparse.query.ParseGate;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.Refs;
import anyparse.query.Rename;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.query.Uses;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;
using Lambda;

/**
 * The rename proofs behind the naming rules' autofixes: for a flagged declaration, the complete
 * set of spans that rename it — in its own file (`declaringFileRenameSpans`, `renameEditsFor`) or
 * across every file that can reach it (`crossFileRenameFor`) — or the reason no such set can be
 * proven (`RenameRefusal`).
 *
 * Its own module rather than more of `Naming` because two rules drive it: `naming` corrects a name
 * against the project's convention, `no-underscore-prefix` strips one prefix, and both need the same
 * answer to "is this occurrence set complete and does the new name collide" (`collidesInScope`). The
 * rule decides WHAT a name becomes (`Naming.correctedName`); this module proves the rewrite safe.
 */
@:nullSafety(Strict)
@:access(anyparse.check.Naming)
final class NamingRenames {

	/**
	 * A cheap PRE-gate on `decl`: is it even the KIND of declaration whose collision a `this.`
	 * qualification could repair? A non-`static` field or method is - a parameter capturing its
	 * references is the param idiom, repaired by naming the member through `this.`. A function-body
	 * binding (Local / Param / CatchVar) is one for the MIRROR direction, where the renamed binding
	 * itself proves nothing and it is the CAPTURED member reference that gets qualified. Everything
	 * else (a type, a `static` member, a Constant - static by construction) is refused outright.
	 * Placed ahead of the occurrence resolution so the ordinary refusal path costs nothing extra. It
	 * is NOT the proof: which arm applies, and whether the binding or the capture is truly reachable
	 * through `selfReferenceText`, is decided by `Rename.qualifyCaptured` inside
	 * `qualifyCapturedEdits`.
	 */
	private static inline function qualifiableBinding(decl: NamedDecl): Bool {
		return switch decl.category {
			case NamingCategory.Field, NamingCategory.Method: !decl.mods.contains('static');
			case NamingCategory.Local, NamingCategory.Param, NamingCategory.CatchVar: true;
			case _: false;
		}
	}

	/**
	 * Whether `category` is a binding scoped to one function BODY - a local, a parameter, a catch
	 * variable. The three categories the scope-aware collision proof governs, and the ones whose
	 * references can never precede their declaration.
	 */
	public static inline function isBodyScopedCategory(category: NamingCategory): Bool {
		return category == NamingCategory.Local || category == NamingCategory.Param || category == NamingCategory.CatchVar;
	}

	/**
	 * The rename edits for one projected declaration, or null when it must be skipped: not
	 * among the flagged spans, not rename-safe, no applicable rule with a derivable correction,
	 * already conformant, a collision the `this.`-qualification arm cannot repair, or an
	 * incomplete rename — the old name still occurs outside the resolved spans as active code,
	 * inside a `#if...#end` region, in a string literal, or on a `noqa` directive line. A plain
	 * comment mention does NOT block: its occurrence joins the returned edits and is renamed
	 * together with the code.
	 */
	public static function renameEditsFor(
		decl: NamedDecl, source: String, tree: QueryNode, policy: NamingPolicy, shape: RefShape, plugin: GrammarPlugin,
		flaggedFroms: Array<Int>, reflectionNames: Array<String>, confinedMemo: Map<String, Bool>, resolutionIndex: Null<SymbolIndex>,
		confinementIndex: Null<SymbolIndex>, file: String, flaggedAt: Map<Int, Violation>
	): Null<DeclRename> {
		final span: Null<Span> = decl.span;
		if (span == null || !flaggedFroms.contains(span.from)) return null;
		final declFrom: Int = span.from;
		final unsafe: Null<String> = RenameRefusal.of(
			decl, source, confinementIndex, reflectionNames, confinedMemo, memberGrants(tree, source, plugin, decl), file
		);
		if (unsafe != null) return RenameRefusal.rename(flaggedAt, declFrom, unsafe);
		final rule: Null<NamingRule> = Naming.applicableRule(decl, policy);
		if (rule == null) return RenameRefusal.rename(flaggedAt, declFrom, RenameRefusal.NO_RULE);
		final correction: Array<String> = [];
		final corrected: Null<String> = Naming.correctedName(decl.name, rule, reason -> correction.push(reason));
		if (corrected == null)
			return RenameRefusal.rename(flaggedAt, declFrom, correction.length == 0 ? RenameRefusal.NORMALIZER_DECLINED : correction[0]);
		final resolved: { name: String, collides: Bool, refusal: Null<String> } = resolvedRename(
			decl, corrected, rule, source, tree, shape, resolutionIndex, plugin, file
		);
		final refused: Null<String> = resolved.refusal;
		if (refused != null) return RenameRefusal.rename(flaggedAt, declFrom, refused);
		final newName: String = resolved.name;
		final collides: Bool = resolved.collides;
		// Completeness + comment-along: the SAME scope-correct occurrence resolution +
		// `classifyOccurrences` gate the cross-file path applies to its declaring file — a `#if` /
		// name-shaped string / `noqa` / resolver-missed active-code occurrence bails, a distinctive
		// comment mention renames along, and anything else non-code is IGNORED (see
		// `declaringFileRenameSpans`). A member declaration also passes its owner, so an access on a
		// receiver of a PROVABLY unrelated type stops counting as an uncovered occurrence.
		final bodyScoped: Bool = isBodyScopedCategory(decl.category);
		final ownerName: Null<String> = decl.enclosingType;
		// The owner half applies to members only; the index + file half applies to every declaration.
		final ctx: Null<RenameContext> = resolutionIndex == null ? null : {
			index: resolutionIndex,
			file: file,
			ownerName: bodyScoped ? null : ownerName
		};
		final renameSpans: Null<Array<Span>> = declaringFileRenameSpans(
			source, tree, span.from, decl.name, shape, plugin, isDistinctiveName(decl.name), bodyScoped, ctx
		);
		if (renameSpans == null) return RenameRefusal.rename(flaggedAt, declFrom, RenameRefusal.OCCURRENCE_UNRESOLVED);
		final spans: Array<Span> = renameSpans;
		final edits: Array<{ span: Span, text: String }> = [for (occ in spans) { span: occ, text: newName }];
		final scope: Span = claimScope(tree, shape, span.from, bodyScoped, source.length);
		if (!collides) return { newName: newName, edits: edits, scope: scope };
		final qualified: Null<Array<{ span: Span, text: String }>> = qualifyCapturedEdits(
			source, tree, span.from, spans, newName, shape, plugin, edits, resolutionIndex, file
		);
		return qualified == null
			? RenameRefusal.rename(flaggedAt, declFrom, RenameRefusal.qualifyFailed(newName))
			: { newName: newName, edits: qualified, scope: scope };
	}

	/**
	 * The region a rename's new name occupies for same-pass claim purposes, mirroring
	 * `collidesInScope`'s own scope notion: a local / param / catch var binds only through its
	 * innermost enclosing function, everything else (member, constant, enum value) file-wide. A
	 * body-scoped declaration with no resolvable enclosing function falls back to file-wide, the
	 * same defensive direction `collidesInScope` takes.
	 */
	private static function claimScope(tree: QueryNode, shape: RefShape, from: Int, bodyScoped: Bool, sourceLength: Int): Span {
		final whole: Span = new Span(0, sourceLength);
		if (!bodyScoped) return whole;
		final funcKinds: Array<String> = (shape.functionKinds ?? []).concat(shape.inlineFunctionKinds ?? []);
		return BindingScope.enclosingScopeSpan(tree, funcKinds, from, shape) ?? whole;
	}

	/**
	 * The rename edits with every param-captured occurrence qualified through `this.`, or null when
	 * the collision is not the param idiom this repair addresses. `__position = position` renamed to
	 * `_position` would become the self-assignment `position = position`; qualified it reads
	 * `this.position = position` - the same `--qualify-shadowed` strategy the standalone `Rename` op
	 * implements, with every boundary left where `Rename.qualifyCaptured` draws it (a capture by a
	 * LOCAL, or one inside a STATIC function, refuses there).
	 *
	 * An EMPTY capture mismatch means the rewrite re-bound nothing, so the collision `collidesInScope`
	 * saw belongs to some OTHER binding this repair does not address: the existing refusal stands
	 * rather than the veto-side gate being weakened.
	 *
	 * The qualification is folded into the occurrence's own replacement text instead of being emitted
	 * as a separate zero-width insertion, because `RefactorSupport.applyEdits` splices strictly by
	 * descending `from`: two edits sharing a `from` have no defined order there, and one clobbers the
	 * other. Every insertion must therefore land on a span this rename owns - one landing anywhere
	 * else would prefix a binding the rename does not own, so it refuses.
	 */
	@:access(anyparse.query.Rename)
	private static function qualifyCapturedEdits(
		source: String, tree: QueryNode, declFrom: Int, renameSpans: Array<Span>, newName: String, shape: RefShape, plugin: GrammarPlugin,
		edits: Array<{ span: Span, text: String }>, resolutionIndex: Null<SymbolIndex>, file: String
	): Null<Array<{ span: Span, text: String }>> {
		final self: Null<String> = shape.selfReferenceText;
		if (self == null) return null;
		// The resolver-only subset: `renameSpans` may additionally carry a comment-along mention.
		final resolved: Array<Span> = Rename.renameOccurrences(source, tree, declFrom, shape);
		if (resolved.length == 0) return null;
		final rewritten: String = CanonicalEdit.applyEdits(source, edits);
		final newTree: Null<QueryNode> = ParseGate.parseOrNull(plugin, rewritten);
		if (newTree == null) return null;
		final mismatch: Array<Capture> = Rename.captureMismatch(rewritten, newTree, renameSpans, resolved, newName, declFrom, shape);
		if (mismatch.length == 0) return null;
		final reachable: Bool = Rename.selfReachableBindingAt(source, tree, declFrom, shape);
		final qualification: Null<Qualification> = Rename.qualifyCaptured(
			rewritten, newTree, mismatch, newName, shape, reachable, resolutionIndex, file
		);
		if (qualification == null) return null;
		switch Rename.verifyQualified(qualification, renameSpans, resolved, newName, declFrom, plugin, shape) {
			case RenameResult.Ok(_):
			case RenameResult.Err(_):
				return null;
		}
		final sorted: Array<Span> = renameSpans.copy();
		sorted.sort((a, b) -> a.from - b.from);
		final delta: Int = newName.length - (sorted[0].to - sorted[0].from);
		final starts: Array<Int> = [for (s in sorted) s.from];
		final targets: Array<Int> = [];
		final captured: Array<{ span: Span, text: String }> = [];
		for (offset in qualification.insertions) {
			final orig: Int = preRewriteOffset(sorted, delta, offset);
			if (starts.contains(orig)) {
				targets.push(orig);
				continue;
			}
			// The MIRROR arm's insertion: a bare reference to a MEMBER the renamed local now shadows.
			// The rename owns no edit there, so the token is rewritten whole (`width` -> `this.width`)
			// rather than as a zero-width insertion - and it must genuinely spell `newName` and lie
			// clear of every rename span, else the offset arithmetic has drifted and the repair is off.
			final end: Int = orig + newName.length;
			if (source.substring(orig, end) != newName || sorted.exists(s -> orig < s.to && end > s.from)) return null;
			captured.push({ span: new Span(orig, end), text: '$self.$newName' });
		}
		return [
			for (e in edits) { span: e.span, text: targets.contains(e.span.from) ? '$self.$newName' : e.text }
		].concat(captured);
	}

	/**
	 * The offset in the ORIGINAL source of a position in the RENAME-REWRITTEN one: undo the length
	 * delta accumulated by every rename span that starts before it. `sorted` is the rename spans
	 * ascending by `from`, `delta` the per-span length change.
	 */
	private static function preRewriteOffset(sorted: Array<Span>, delta: Int, offset: Int): Int {
		var shift: Int = 0;
		for (s in sorted) {
			if (s.from + shift >= offset) break;
			shift += delta;
		}
		return offset - shift;
	}

	/**
	 * The resolved cross-file rename CANDIDATE for one flagged violation, or null when it must be
	 * skipped: not a member this path owns (see `crossCategoryRefusal`), something the single-file path
	 * already covers (a confined private member), an unenumerable hierarchy (a skip-parse file hiding a
	 * subtype, an `@:allow` grant, a non-unique owner), no derivable corrected name, or a blocked
	 * inherited-member / `@:rtti` guard. Carries the parsed declaring file, `isPublic` (which decides the
	 * affected-file set), plus the names the per-file span pass needs.
	 */
	private static function crossFileCandidate(
		v: Violation, sourceByFile: Map<String, String>, support: NamingSupport, plugin: GrammarPlugin, index: SymbolIndex,
		resolutionIndex: SymbolIndex
	): Null<CrossFileCandidate> {
		final declFile: String = v.file;
		final vspan: Null<Span> = v.span;
		if (vspan == null) return null;
		final declSource: Null<String> = sourceByFile[declFile];
		if (declSource == null) return null;
		final source: String = declSource;
		final declTree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		if (declTree == null) return null;
		final tree: QueryNode = declTree;
		final decl: Null<NamedDecl> = support.project(tree, Naming.propertyFacts(plugin, source))
			.find(d -> d.span != null && d.span.from == vspan.from);
		if (decl == null) return null;
		// Candidate: a NON-confined private field / constant the single-file `fix` skips, or ANY public
		// member - `RenameRefusal.of` refuses every public declaration, so this is a public member's only path.
		if (decl.renameUnsafe == true) return null;
		final isPublic: Bool = decl.mods.contains('public');
		// A silent decline here (`return null` on a category this path does not own) is not harmless:
		// the per-file path writes a sentence for the same findings afterwards, and for a PUBLIC method
		// it writes the WRONG one — `RenameRefusal.of` tests `public` BEFORE it tests `override`, so a
		// mute-refused override was reported as owned-and-declined by the cross-file path, which had
		// declined only because it does not own the declaration at all. So the category is refused
		// with its own sentence.
		// A local / parameter / catch variable is the single-file path's alone: its whole scope is one
		// function body, so there is nothing for this path to prove and nothing for it to SAY. Answering
		// `NOT_A_MEMBER` here wrote the first decline reason on the finding — first writer wins — and the
		// single-file path's own sentence (a collision, say) never reached the reader.
		if (isBodyScopedCategory(decl.category)) return null;
		final category: Null<String> = crossCategoryRefusal(decl);
		if (category != null) return RenameRefusal.candidate(v, category);
		final owner: Null<String> = decl.enclosingType;
		if (owner == null) return null;
		final ownerName: String = owner;
		// A METHOD a SUBTYPE overrides renames as a FAMILY: the override is not a candidate of its own
		// (`crossCategoryRefusal` turns one away), and renaming the base alone leaves `override function
		// __draw` overriding nothing - which the completeness gate catches across FILES, where the
		// subtype's declaration is an occurrence no receiver attributes, but not within ONE file. The
		// family carries every such declaration into the same edit set; `null` means one same-named
		// declaration's relation to the owner is unprovable, and a partial family is worse than none.
		// Asked of the RESOLUTION index, the superset - a family it reports too large only refuses more.
		final family: Null<Array<OverrideFamilyMember>> = decl.category == NamingCategory.Method
			? resolutionIndex.subtypes.overrideFamilyOf(ownerName, decl.name)
			: [];
		if (family == null) return null;
		final overrides: Array<OverrideFamilyMember> = family;
		// A confined PRIVATE member is the single-file path's job; only a non-confined one crosses files.
		// A PUBLIC member is never confined in that sense - any file holding a value of the owner's type
		// reaches it - so the proof does not apply and it always crosses.
		//
		// The REPORT index here, deliberately, where the single-file path's twin of this question
		// (`RenameRefusal.of`) takes the WIDEST one. The asymmetry is load-bearing and was measured
		// rather than reasoned: this gate only decides who OWNS the declaration, and everything after
		// it — `affectedFiles`, `publicAffectedFiles`, `sourceByFile` — enumerates the files to edit
		// from the REPORT scope. Widen the question without widening the enumeration and a member the
		// wide index calls unconfined is accepted here, its affected set comes back as the declaring
		// file alone, and the rename lands in that one file: on a two-file `@:access` probe under
		// `resolutionRoots`, a one-file `naming --fix` would rename the member in the declaring file
		// alone and leave the grantee's access bound to the old name — the same orphan the single-file
		// path is stopped from writing.
		//
		// Asking NARROW here is therefore not a hole. Confinement is monotone: widening the index can
		// only flip `confined` true -> false, so the wider `RenameRefusal.of` can only DECLINE where
		// this one accepts, never the reverse — the two paths can leave a member to nobody (reported,
		// with `NOT_CONFINED` as its decline reason) and can never both claim it. The gap is the safe
		// direction; the overlap, which is the one that writes twice, is structurally impossible.
		final grants: Null<Array<String>> = memberGrants(tree, source, plugin, decl);
		if (!isPublic && RefactorSupport.isPrivateMemberConfined(ownerName, decl.name, source, index, grants, declFile)) return null;
		// No reflection guard here, deliberately. `RenameRefusal.of`'s exists because the single-file path
		// never looks at another file; this path DOES - a public member's affected set is every scope file
		// mentioning the name (`publicAffectedFiles`), and `otherFileRenameSpans` already refuses on a
		// name-shaped string literal in any of them, in the declaring file and in another file alike.
		// A second mechanism answering the same question would only re-scan the resolution scope once
		// per candidate for an answer this path already holds.
		// Unresolvable hierarchy, and the two causes answer separately: one sentence for both sent a
		// reader looking for an `@:allow` that a duplicate type name had actually caused.
		//
		// The DUPLICATE is asked first, and that order is the point rather than a preference: it is
		// the cause the index knows EXACTLY, and the one a reader can act on. The grant half is
		// `RefactorSupport.carriesAllowGrant` — the single reader, comment- and literal-masked — so
		// the sentence is true when it is written; the order still stands on its own, since a
		// duplicate type name is the more actionable of two real causes.
		final declarers: Array<FileInfo> = index.refs.declaringFiles(ownerName);
		if (declarers.length != 1)
			return RenameRefusal.candidate(v, RenameRefusal.crossOwnerNotUnique(ownerName, declarers.map(f -> f.file)));
		// A PRIVATE member's `@:allow` grantees join its edit set: the grant is read off THIS member and
		// its type (`AllowGrants.reaching`), never off the file, so a grant on a neighbour opens nothing
		// here. Enumerated over the RESOLUTION index, the widest one; a grantee file outside this run's
		// sources is then refused by the per-file loop like any other file it cannot edit. A PUBLIC
		// member asks nothing of a grant - its affected set is already every file that spells it.
		final opened: Null<Array<String>> = isPublic ? [] : granteesOf(v, grants, resolutionIndex);
		if (opened == null) return null;
		final grantees: Array<String> = opened;
		// Every refusal from here down belongs to THIS path: the gates above either hand the
		// declaration to the single-file rename or are not about it at all, and speaking for those
		// would overwrite the more accurate sentence that path is about to write. The category gate is
		// the ONE exception and states why there: what it declines belongs to NEITHER path, so nothing
		// more accurate is coming and the sentence it writes is the same one `RenameRefusal.of` holds
		// for the same declaration.
		final correction: Array<String> = [];
		final corrected: Null<String> = correctedFieldName(
			decl, support.policyFor(declFile), ownerName, resolutionIndex, declFile, reason -> correction.push(reason)
		);
		if (corrected == null)
			return RenameRefusal.candidate(v, correction.length == 0 ? RenameRefusal.NORMALIZER_DECLINED : correction[0]);
		// Re-bound: a narrowed local does not stay narrowed inside an anonymous structure literal.
		final targetName: String = corrected;
		// The skip-parse arm of the same unresolvable-hierarchy question, and the last gate because it
		// needs `targetName` - the identifier the rename INTRODUCES, whose only unreadable hazard is a
		// file already declaring it under this owner. Asked as `skippedFiles().length > 0` this refused
		// EVERY cross-file rename in any scope holding one unparseable file, however unrelated; asked
		// per NAME it refuses the renames a skipped file could actually invalidate, and names it.
		//
		// Asked of the RESOLUTION index for the same reason the override family above is: it sees the
		// files the lint scope does not, and a project module outside that scope is exactly where an
		// unreadable reference this rename would break can hide. `declFile` is the per-owner narrowing
		// `RawSourceScan.admits` applies - a THIRD-PARTY skipped source cannot reference a member the
		// project declares, since the dependency points the other way - so widening the scan to the
		// library adds no refusal of its own. With no resolution scope injected the two indexes are the
		// same object and the third-party half is empty, which is the unnarrowed question this asked
		// before.
		final unreadable: Array<String> = resolutionIndex.text.skippedFilesMentioning([decl.name, ownerName, targetName], declFile);
		return unreadable.length > 0 ? RenameRefusal.candidate(v, RenameRefusal.crossSkipParse(unreadable)) : {
			declFile: declFile,
			source: source,
			tree: tree,
			declFrom: vspan.from,
			oldName: decl.name,
			targetName: targetName,
			ownerName: ownerName,
			distinctive: isDistinctiveName(decl.name),
			isPublic: isPublic,
			family: overrides,
			grantees: grantees
		};
	}

	/**
	 * The files a PRIVATE member's `grants` open it to (`AllowGrants.granteeFiles`), or null - with the refusal noted on
	 * `v` - when they cannot be enumerated: the grants themselves could not be read, or one names a grantee the index
	 * does not see.
	 */
	private static function granteesOf(v: Violation, grants: Null<Array<String>>, resolutionIndex: SymbolIndex): Null<Array<String>> {
		if (grants == null) {
			RenameRefusal.note(v, RenameRefusal.CROSS_ALLOW_GRANT);
			return null;
		}
		if (grants.length == 0) return [];
		final opened: Grantees = AllowGrants.granteeFiles(grants, resolutionIndex);
		final unmatched: Null<String> = opened.unmatched;
		if (unmatched == null) return opened.files;
		RenameRefusal.note(v, RenameRefusal.crossAllowUnenumerable(unmatched));
		return null;
	}

	/**
	 * The corrected name for `decl` under `policy`, or null when there is none / it must not apply:
	 * no derivable correction (see `correctedName`), a supertype that already declares the name
	 * (Haxe's "Redefinition of variable in subclass"), or a transitive `@:rtti` serialization
	 * hierarchy (renaming a reflected field name breaks saved files). `ownerName` / `resolutionIndex`
	 * drive the inheritance + rtti guards through the resolution scope.
	 */
	private static function correctedFieldName(
		decl: NamedDecl, policy: NamingPolicy, ownerName: String, resolutionIndex: SymbolIndex, declFile: String,
		?refusal: (String) -> Void
	): Null<String> {
		final say: Null<(String) -> Void> = refusal;
		function no(reason: String): Null<String> {
			// Re-bound inside the closure: strict null-safety does not narrow a CAPTURED local.
			final sink: Null<(String) -> Void> = say;
			if (sink != null) sink(reason);
			return null;
		}
		final rule: Null<NamingRule> = Naming.applicableRule(decl, policy);
		if (rule == null) return no(RenameRefusal.NO_RULE);
		final newName: Null<String> = Naming.correctedName(decl.name, rule, say);
		return if (newName == null)
			null
		else if (!resolutionIndex.members.typeProvablyLacksMember(ownerName, newName, declFile))
			no(RenameRefusal.INHERITED_COLLISION)
		else if (resolutionIndex.traits.transitivelyCarriesRtti(ownerName))
			no(RenameRefusal.RTTI_HIERARCHY)
		else
			newName;
	}

	/**
	 * The cross-file rename fixing one flagged NON-confined private, or public, field / constant / method,
	 * or null when it cannot be proven complete. Resolves the candidate (`crossFileCandidate`), then
	 * collects and gates each affected file's occurrence spans; a bail in ANY file makes the whole rename
	 * report-only. Returns the per-file `CrossFileEdits` slices.
	 */
	public static function crossFileRenameFor(
		v: Violation, sourceByFile: Map<String, String>, support: NamingSupport, shape: RefShape, plugin: GrammarPlugin,
		index: SymbolIndex, resolutionIndex: SymbolIndex
	): Null<CrossFileRename> {
		final candidate: Null<CrossFileCandidate> = crossFileCandidate(v, sourceByFile, support, plugin, index, resolutionIndex);
		if (candidate == null) return null;
		final c: CrossFileCandidate = candidate;
		final slices: Array<CrossFileEdits> = [];
		final hierarchy: Array<String> = affectedFiles(c.ownerName, c.declFile, index, c.grantees);
		final scanned: Array<String> = c.isPublic ? publicAffectedFiles(hierarchy, c.oldName, index, sourceByFile) : hierarchy;
		// An override the edit set cannot reach makes the base unrenameable: the family is resolved
		// against the RESOLUTION index, which sees files the lint scope does not, and half a family
		// leaves a declaration overriding nothing.
		for (fm in c.family) if (!scanned.contains(fm.file)) return RenameRefusal.crossRename(v, RenameRefusal.CROSS_FAMILY_UNREACHABLE);
		final outside: Null<String> = outsideScopeFile(c, sourceByFile, support, shape, plugin, resolutionIndex);
		if (outside != null) return RenameRefusal.crossRename(v, RenameRefusal.crossOutsideScope(outside));
		for (file in scanned) {
			final fileSource: Null<String> = sourceByFile[file];
			if (fileSource == null) return RenameRefusal.crossRename(v, RenameRefusal.CROSS_FILE_UNREADABLE);
			final fsrc: String = fileSource;
			final fileTree: Null<QueryNode> = file == c.declFile ? c.tree : ParseGate.parseOrNull(plugin, fsrc);
			if (fileTree == null) return RenameRefusal.crossRename(v, RenameRefusal.CROSS_FILE_UNREADABLE);
			final familySpans: Array<Span> = familyOccurrences(c.family, file, fsrc, fileTree, shape);
			final spans: Null<Array<Span>> = file == c.declFile
				? declaringFileRenameSpans(
					fsrc, c.tree, c.declFrom, c.oldName, shape, plugin, c.distinctive, false,
					{ index: resolutionIndex, file: c.declFile, ownerName: c.ownerName }, familySpans
				)
				: otherFileRenameSpans(
					fsrc, c.oldName, plugin, c.distinctive, c.ownerName, shape, resolutionIndex, file, support, familySpans
				);
			if (spans == null) return RenameRefusal.crossRename(v, RenameRefusal.OCCURRENCE_UNRESOLVED);
			// A file receiving NO edit and lying outside the owner's own hierarchy cannot collide: nothing
			// is rewritten there and no member of the owner is inherited there, so the scan below would
			// only refuse on an unrelated binding of the target name. Only a PUBLIC member's affected set
			// carries such a file (see `publicAffectedFiles`); for a private one the loop set IS the
			// hierarchy, so this never fires and the scan runs over exactly the files it always did.
			if (spans.length == 0 && !hierarchy.contains(file)) continue;
			// A `targetName` already bound where the rename lands would collide once it does - scanned
			// across the OWNER's own hierarchy in this file only, since a sibling hierarchy's same-named
			// member is not reachable from it (see `unrelatedTypeSpans`).
			final unrelated: Array<Span> = unrelatedTypeSpans(fileTree, c.ownerName, shape, resolutionIndex);
			final baseEdits: Array<{ span: Span, text: String }> = [for (s in spans) { span: s, text: c.targetName }];
			// The param idiom, reached one path over from where the single-file rename repairs it:
			// `__x = x` renamed to `x` is the self-assignment `x = x`, and qualified it reads
			// `this.x = x`. Only the DECLARING file can be repaired that way - `this.` names the enclosing
			// class's own member, which is precisely what the collision shadows there, while a collision
			// in any other file is a real one. `qualifyCapturedEdits` decides by RE-RESOLUTION, so an
			// empty capture mismatch means the collision belongs to some OTHER binding and the refusal
			// correctly stands.
			final edits: Null<Array<{ span: Span, text: String }>> = if (!OccurrenceScan.nameBoundInRange(
				fsrc, c.targetName, 0, fsrc.length, unrelated, plugin
			))
				baseEdits;
			else if (file != c.declFile)
				null;
			else
				qualifyCapturedEdits(fsrc, c.tree, c.declFrom, spans, c.targetName, shape, plugin, baseEdits, resolutionIndex, file);
			if (edits == null) return RenameRefusal.crossRename(v, RenameRefusal.CROSS_COLLISION);
			// Re-bound: a narrowed local does not stay narrowed inside an anonymous structure literal.
			final fileEdits: Array<{ span: Span, text: String }> = edits;
			if (spans.length > 0) slices.push({ file: file, edits: fileEdits });
		}
		return slices.length == 0 ? null : { slices: slices, owner: c.ownerName, newName: c.targetName };
	}

	/**
	 * The first PROJECT file outside this run's sources that the rename of `c` would have to reach, or null when none
	 * does: a file declaring a subtype of the owner or an `@:access` grant to it, or - for a PUBLIC member - a file whose
	 * occurrences of the name are not all accounted for (`otherFileRenameSpans` answers edits or cannot prove them).
	 *
	 * The edit set is enumerated from the REPORT index, so on a narrowed `--fix` (one file, a subdirectory) a reference in an
	 * unlinted project file read as absent and the narrow run renamed what the whole-project run refused - the
	 * lint-fix-scope incident in this rule's shape. The project half of the resolution scope (`resolutionRoots`) closes it: a
	 * narrow scope can now only refuse more than the project scope, never less. A library file is not asked - it cannot
	 * name a project type's member - and a run declaring no roots has no wider project to ask about.
	 */
	private static function outsideScopeFile(
		c: CrossFileCandidate, sourceByFile: Map<String, String>, support: NamingSupport, shape: RefShape, plugin: GrammarPlugin,
		resolutionIndex: SymbolIndex
	): Null<String> {
		final project: Null<Array<{ file: String, source: String }>> = RefactorSupport.resolutionProjectSourcesOf(plugin);
		if (project == null) return null;
		final projectFiles: Array<String> = [for (entry in project) entry.file];
		for (file in affectedFiles(c.ownerName, c.declFile, resolutionIndex)) if (!sourceByFile.exists(file) && projectFiles.contains(file))
			return file;
		if (!c.isPublic) return null;
		for (entry in project) if (!sourceByFile.exists(entry.file) && entry.source.indexOf(c.oldName) >= 0) {
			final spans: Null<Array<Span>> = otherFileRenameSpans(
				entry.source, c.oldName, plugin, c.distinctive, c.ownerName, shape, resolutionIndex, entry.file, support
			);
			if (spans == null || spans.length > 0) return entry.file;
		}
		return null;
	}

	/**
	 * Every occurrence, in `file`, of an override family member DECLARED there — its declaration name
	 * token plus the bare / `this.`-qualified reads its own type makes of it, resolved exactly as the
	 * base's own are. Empty when the file declares no family member. These are RENAME targets, not
	 * exclusions: an override left spelled the old way overrides nothing.
	 */
	private static function familyOccurrences(
		family: Array<OverrideFamilyMember>, file: String, source: String, tree: QueryNode, shape: RefShape
	): Array<Span> {
		final out: Array<Span> = [];
		for (fm in family)
			if (fm.file == file)
				for (occ in Rename.renameOccurrences(source, tree, fm.declFrom, shape))
					if (!out.exists(s -> s.from == occ.from)) out.push(occ);
		return out;
	}

	/**
	 * `extra` appended to a COPY of `base`, skipping any span that starts where one already there does.
	 * The two halves resolve DIFFERENT bindings — the member's own and each override's — and a resolver
	 * that attributes one bare read to both would otherwise leave `applyEdits` two edits over one span
	 * with no defined winner.
	 */
	private static function mergeUniqueSpans(base: Array<Span>, extra: Array<Span>): Array<Span> {
		final out: Array<Span> = base.copy();
		for (s in extra) if (!out.exists(o -> o.from == s.from)) out.push(s);
		return out;
	}

	/**
	 * The declaring file's rename spans for the binding at `declFrom`, or null when the rename cannot
	 * be proven complete there. The spans are the scope-correct resolved reference set (decl + reads /
	 * writes + `this.<name>`), gated for completeness. A resolved-outside occurrence that is
	 * `ActiveCode` (a reference the resolver missed), `ConditionalRaw`, a name-shaped `StringLiteral`
	 * or a `DirectiveComment` bails (null); a distinctive-name `CommentTrivia` mention renames along;
	 * a non-distinctive comment mention and a `StringWord` are ignored. Null on a parse failure when
	 * the fail-closed raw scan finds an uncovered mention.
	 *
	 * `bodyScoped` marks a binding visible only from its declaration on (a local, a parameter, a
	 * catch variable); an occurrence resolved BEFORE the declaration is then the resolver
	 * over-reaching past a shadowed member and the whole rename is refused. A MEMBER's references
	 * legitimately precede it, so the flag defaults off.
	 *
	 * `ctx` supplies the discounts that need the index (see `RenameContext`). With `ownerName` — a
	 * member declaration — every same-name access is attributed through its RECEIVER's declared type
	 * (`inheritedFieldRefSpans`, the attribution the cross-file path also runs): one on a provably
	 * unrelated type stops counting as an uncovered occurrence, and one on the owner or a subtype is
	 * RENAMED along, since `renameOccurrences` emits only bare and `this.`-qualified reads. With the
	 * index and file alone, an occurrence where the name denotes a TYPE rather than a value
	 * (`typeReferenceSpans`). A receiver whose type does not resolve is in neither set and still
	 * blocks. Module-path declarations are excluded unconditionally
	 * (`RefactorSupport.modulePathSpans`) — a dotted path references nothing in any language.
	 *
	 * A simple `$name` string-interpolation read needs no caller-side help: `Refs` indexes it as
	 * an ordinary read, so it is already in the resolved set and renames along instead of
	 * blocking the gate.
	 *
	 * A MEMBER redeclared in a MUTUALLY EXCLUSIVE conditional branch is one declaration in two
	 * builds, so its occurrences join the rename rather than being excluded as another binding's
	 * (`MemberBranchScan.exclusiveSpansAt`) — the same treatment, and for the same reason, that
	 * `familySpans` gives an override.
	 */
	public static function declaringFileRenameSpans(
		source: String, tree: QueryNode, declFrom: Int, name: String, shape: RefShape, plugin: GrammarPlugin, distinctive: Bool,
		bodyScoped: Bool = false, ?ctx: RenameContext, ?familySpans: Array<Span>
	): Null<Array<Span>> {
		// A subtype declared beside its base overrides the member in THIS file; its declaration and own
		// reads are rename targets, and excluded from the completeness scan for the same reason the
		// base's own occurrences are.
		final family: Array<Span> = familySpans ?? [];
		final covered: Array<Span> = Rename.renameOccurrences(source, tree, declFrom, shape);
		if (covered.length == 0) return null;
		if (strandsOccurrence(source, tree, declFrom, name, shape, covered, bodyScoped)) return null;
		// Attribute every OTHER same-name occurrence to its binding: one provably bound to a DIFFERENT
		// binding (a param / loop var / sibling local sharing the name) is neither a rename target nor a
		// blocker for THIS binding, so it joins the resolved set as an excluded span. An occurrence whose
		// binding is unresolved is left uncovered so the completeness gate below blocks (fail-closed).
		// A same-named member on ANOTHER type (`rect.bottom` beside a field `bottom`,
		// `event.bytesLoaded`) is not a reference to this declaration — but neither
		// `renameOccurrences` nor `otherBindingSpans` says so, and an uncovered occurrence blocks
		// the whole rename. The cross-file path already resolves such an access through the
		// RECEIVER's declared type (`inheritedFieldRefSpans`); a member declaration gets the same
		// treatment here. A receiver whose type does not RESOLVE stays out of both halves and keeps
		// blocking — fail-closed.
		final ownerName: Null<String> = ctx?.ownerName;
		final attributed: {
			bareBound: Array<Span>,
			typedBound: Array<Span>,
			ignore: Array<Span>
		} = ctx == null || ownerName == null
			? { bareBound: [], typedBound: [], ignore: [] }
			: inheritedFieldRefSpans(source, tree, name, ownerName, plugin, shape, ctx.index);
		final foreign: Array<Span> = attributed.ignore;
		// The `typedBound` half is a set of EDITS, not exclusions. `renameOccurrences` emits bare and
		// `this.`-qualified reads only, so an access through a RECEIVER typed to the owner or a subtype
		// (`printer.output`, reaching a sibling sub-module's private) is invisible to it — yet it is a
		// genuine reference, and renaming the declaration without it strands the access on a name that
		// no longer exists. The `bareBound` half is deliberately NOT merged: it is class-attributed, so
		// it also holds reads bound to a local of the same name (see `inheritedFieldRefSpans`), and here
		// `renameOccurrences` is the authority on which bare reads are references. Deduped by offset
		// against `covered` anyway — two edits over one span leave `applyEdits` no defined winner.
		final ownerBound: Array<Span> = [
			for (s in attributed.typedBound) if (!OccurrenceScan.offsetWithinAny(s.from, covered)) s
		];
		// A receiver that is a TYPE, not a value: `Event.ACTIVATE` beside a parameter named `Event`
		// projects the same `IdentExpr` as a read of that parameter, so the resolver leaves it
		// unattributed and the gate refuses. Discount it when BOTH hold — the identifier binds to no
		// value visible there, and the index resolves the name to a type in this file's scope.
		final typeRefs: Array<Span> = ctx == null ? [] : typeReferenceSpans(source, tree, name, shape, plugin, ctx);
		// A `package` / `import` path is a dotted module path, not a reference — a field named after
		// its own package (`package touches;` beside `var touches`) or after a package some import
		// traverses would otherwise leave an unattributable occurrence and veto the rename.
		// One class of "other binding" is not one at all: a same-named MEMBER declared in a conditional
		// branch that never compiles with this declaration's own is THIS member as another build writes
		// it, and `#if ios … #elseif android …` writes that pair by design. Excluded — which is what
		// `otherBindingSpans` does with it — the rename lands on one branch's declaration and leaves the
		// other spelled the old way, while the references it rewrote are shared: the build compiling the
		// untouched branch then reaches a name nothing declares, and a later `unused-private` pass
		// deletes the stranded declaration outright. So the twin's occurrences are RENAME targets, for
		// the same reason an override family's are. Body-scoped bindings are excluded: two locals in
		// exclusive branches are genuinely unrelated, sharing a name by coincidence, not by design.
		final others: Array<Span> = BindingScope.otherBindingSpans(source, tree, name, declFrom, shape);
		final exclusive: Array<Span> = bodyScoped
			? []
			: MemberBranchScan.exclusiveSpansAt(shape, source, tree, declFrom, plugin.lexicalRegions.bind(source));
		final twins: Array<Span> =
			exclusive.length == 0 ? [] : [for (s in others) if (OccurrenceScan.offsetWithinAny(s.from, exclusive)) s];
		final excluded: Array<Span> = covered.concat(others)
			.concat(ownerBound)
			.concat(foreign)
			.concat(typeRefs)
			.concat(family)
			.concat(OccurrenceScan.modulePathSpans(tree, shape));
		final classified: Null<Array<ClassifiedOccurrence>> = OccurrenceScan.classifyOccurrences(
			source, name, plugin, 0, source.length, excluded
		);
		final renamed: Array<Span> = mergeUniqueSpans(mergeUniqueSpans(covered.concat(ownerBound), twins), family);
		return if (classified != null)
			withMentions(renamed, classified, tree, declFrom, shape, distinctive)
		else if (OccurrenceScan.referencedInRange(source, name, 0, source.length, excluded))
			null
		else
			renamed;
	}

	/**
	 * Whether renaming the binding declared at `declFrom` would strand an occurrence of `name` that the rewrite of its
	 * `covered` occurrences cannot reach (`declaringFileRenameSpans`): a resolution reaching past a shadowed member, a
	 * `$name` read spelled by escapes, or a read inside an unparsed conditional region.
	 */
	private static function strandsOccurrence(
		source: String, tree: QueryNode, declFrom: Int, name: String, shape: RefShape, covered: Array<Span>, bodyScoped: Bool
	): Bool {
		// A body-scoped binding (local / param / catch variable) is visible from its DECLARATION on -
		// no language here hoists one - so an occurrence resolved BEFORE `declFrom` is the scope
		// resolver over-reaching: it binds a whole block to the declaration, while the compiler binds
		// the earlier read to whatever it shadows (a member, a static, an import). Rewriting that read
		// emits an unknown identifier, so the whole rename is refused. Never true for a MEMBER, whose
		// references legitimately precede its declaration - hence the caller-supplied flag. Asked
		// first of the two refusals: it walks `covered`, while the interpolation one below re-walks
		// the whole tree.
		if (bodyScoped) for (occ in covered) if (occ.from < declFrom) return true;
		// A `$name` read whose identifier token is not in the raw bytes — an escape-spelled `$`
		// or name — is DROPPED by `renameOccurrences`, not rewritten, so the rename would strand
		// it on a name the fix has removed. `rename` refuses the same shape; the completeness
		// scan below cannot see it, since the occurrence sits inside a string literal.
		if (OccurrenceScan.unrewrittenInterpRead(Refs.find(name, tree, shape), declFrom, covered) != null) return true;
		// An unparsed conditional-compilation region is the same drop one level lower: its interior
		// projects no nodes at all, so neither `renameOccurrences` nor the completeness scan below can
		// see a read of `name` written inside it, and the fix would strand it on the old spelling.
		return CondRegionScan.opaqueCondRegionMentioning(tree, source, name, shape) != null;
	}

	/**
	 * The spans `declaringFileRenameSpans` renames: `spans`, with each distinctive comment mention of the binding in its
	 * own lexical container among the `classified` occurrences nothing resolved. Null when one of those is a mention that
	 * refuses the rename.
	 */
	private static function withMentions(
		spans: Array<Span>, classified: Array<ClassifiedOccurrence>, tree: QueryNode, declFrom: Int, shape: RefShape, distinctive: Bool
	): Null<Array<Span>> {
		// A distinctive comment mention renames along, but only within the binding's own lexical container:
		// the same distinctive name can name an UNRELATED binding elsewhere in the file, and a comment about
		// THAT one must not be rewritten (nor block this rename). A field's container is its type, so its
		// comment-along still spans the whole class.
		final container: Null<Span> = BindingScope.enclosingScopeSpan(
			tree, shape.scopeKinds.concat(['CaseBranch', 'DefaultBranch']), declFrom, shape
		);
		for (occ in classified) switch occ.kind {
			case OccurrenceClass.CommentTrivia if (distinctive):
				if (container != null && occ.span.from >= container.from && occ.span.from < container.to) spans.push(occ.span);
			// Neither renamed nor a blocker. A word inside a longer literal (`t('Can edit')` beside a
			// field `edit`) is prose; a literal that NAMES the member stays `StringLiteral` and still
			// refuses (see `OccurrenceClass`). A NON-distinctive comment mention lands here too: a
			// comment does not execute, so no form of it can make a rename unsafe — the worst case is
			// a stale sentence, which is not worth refusing a correct rename over. The distinctive arm
			// above still rewrites the mention; `DirectiveComment` (a `noqa`) still refuses.
			case OccurrenceClass.StringWord, OccurrenceClass.CommentTrivia:
			case _:
				return null;
		}
		return spans;
	}

	/**
	 * The occurrence spans to rewrite in a SUBTYPE / `@:access`-grant file, by PER-OCCURRENCE owner
	 * attribution: each occurrence of the old name provably binding to `ownerName`'s inherited field
	 * (a bare reference / `this.` / `super.` inside a subtype, or a receiver typed to the owner or a
	 * subtype) is a rename target; one provably binding to a DIFFERENT owner (a sibling class's
	 * same-named field, reached through a differently-typed receiver) is IGNORED — neither renamed nor
	 * a blocker; a class declaring its OWN `name` is NOT such a case (the ignore arm is supertype-only),
	 * but when that class is provably UNRELATED to the owner its own declaration resolves its occurrences
	 * (`foreignBoundSpans`), and they are excluded too; an occurrence whose binding cannot be proven is left
	 * uncovered so the completeness gate blocks the whole rename (fail-closed). A distinctive-name
	 * `CommentTrivia` still renames along. Null on a parse failure or an unattributable active-code
	 * occurrence. This replaces the old blanket bail on any same-named sibling field.
	 */
	private static function otherFileRenameSpans(
		source: String, name: String, plugin: GrammarPlugin, distinctive: Bool, ownerName: String, shape: RefShape,
		resolutionIndex: SymbolIndex, file: String, support: NamingSupport, ?familySpans: Array<Span>
	): Null<Array<Span>> {
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		if (tree == null) return null;
		// This file declares an override of the member: its declaration and the reads its own type makes
		// of it are rename targets. Without them the declaration is an occurrence no receiver attributes,
		// and the completeness gate below vetoes the whole rename - which is how an override family used
		// to be refused rather than renamed.
		final family: Array<Span> = familySpans ?? [];
		final refs: {
			bareBound: Array<Span>,
			typedBound: Array<Span>,
			ignore: Array<Span>
		} = inheritedFieldRefSpans(source, tree, name, ownerName, plugin, shape, resolutionIndex);
		// Occurrences bound to ANOTHER declaration of the name in this file - an unrelated class's own
		// same-named member, a local, a parameter - are that declaration's, not this member's.
		final foreign: Array<Span> = foreignBoundSpans(source, tree, name, ownerName, plugin, support, shape, resolutionIndex, file);
		// A RECEIVER-typed access both halves claim is a contradiction no reading settles: refuse.
		if (refs.typedBound.exists(s -> OccurrenceScan.offsetWithinAny(s.from, foreign))) return null;
		// The BARE half is attributed by the enclosing class alone, so it also holds a read a same-named
		// parameter or local of a subtype's method binds - `override function setup(accountScreen) {
		// super.setup(accountScreen); }` beside the owner's `accountScreen` field. The foreign half
		// resolves that read scope-correctly, so it wins: renaming it would turn the argument into the
		// field, which compiles. With no foreign declaration the bare half stays the rename target, the
		// way it was when any such binding blocked the whole rename.
		final bare: Array<Span> = [
			for (s in refs.bareBound) if (!OccurrenceScan.offsetWithinAny(s.from, foreign)) s
		];
		final ownerBound: Array<Span> = mergeUniqueSpans(bare.concat(refs.typedBound), family);
		// Both the owner-bound targets AND the provably-different-owner occurrences are excluded from
		// the completeness scan: the former are renamed, the latter left as-is; only an occurrence that
		// is NEITHER (unprovable) stays uncovered and blocks the whole rename below.
		// Module paths and type references are inert here too — see `declaringFileRenameSpans`. A
		// subtype file naming a type after the member being renamed is the same shape, one file over.
		final excluded: Array<Span> = ownerBound.concat(refs.ignore)
			.concat(foreign)
			.concat(OccurrenceScan.modulePathSpans(tree, shape))
			.concat(typeReferenceSpans(source, tree, name, shape, plugin, { index: resolutionIndex, file: file }));
		final classified: Null<Array<ClassifiedOccurrence>> = OccurrenceScan.classifyOccurrences(
			source, name, plugin, 0, source.length, excluded
		);
		if (classified == null) return null;
		final spans: Array<Span> = ownerBound.copy();
		for (occ in classified) switch occ.kind {
			case OccurrenceClass.CommentTrivia if (distinctive):
				spans.push(occ.span);
			// Neither renamed nor a blocker — same reading as the declaring file's.
			case OccurrenceClass.StringWord, OccurrenceClass.CommentTrivia:
			case _:
				return null;
		}
		return spans;
	}

	/**
	 * The occurrences of `name` in one file that the resolver binds to a declaration of that name OTHER than `ownerName`'s
	 * member: a same-named member of a type provably outside `ownerName`'s hierarchy (neither a subtype nor a supertype), a
	 * local, a parameter, a catch variable. They are accounted for - not this member, so neither renamed nor a blocker - and
	 * a `private final _sc` in an unrelated class no longer vetoes the rename (or the privatize arm) of a `public final _sc`.
	 *
	 * Each such declaration's occurrence set is resolved exactly as its OWN rename would resolve it
	 * (`declaringFileRenameSpans`, receiver-typed accesses attributed through `inheritedFieldRefSpans`), so an occurrence is
	 * accounted for only when that resolution is complete: a declaration whose set cannot be proven contributes nothing, and
	 * its occurrences keep blocking. A same-named member of a RELATED type is a redefinition or an override, never another
	 * binding, and is left out. Deduped by offset.
	 */
	public static function foreignBoundSpans(
		source: String, tree: QueryNode, name: String, ownerName: String, plugin: GrammarPlugin, support: NamingSupport, shape: RefShape,
		resolutionIndex: SymbolIndex, file: String
	): Array<Span> {
		final out: Array<Span> = [];
		for (decl in support.project(tree, Naming.propertyFacts(plugin, source))) if (decl.name == name) {
			final span: Null<Span> = decl.span;
			final bodyScoped: Bool = isBodyScopedCategory(decl.category);
			final owner: Null<String> = decl.enclosingType;
			if (span == null || !bodyScoped && !unrelatedMember(decl, owner, ownerName, resolutionIndex)) continue;
			final ctx: RenameContext = bodyScoped || owner == null
				? { index: resolutionIndex, file: file }
				: { index: resolutionIndex, file: file, ownerName: owner };
			final spans: Null<Array<Span>> = declaringFileRenameSpans(
				source, tree, span.from, name, shape, plugin, isDistinctiveName(name), bodyScoped, ctx
			);
			if (spans != null) for (s in spans) if (!out.exists(o -> o.from == s.from)) out.push(s);
		}
		return out;
	}

	/** Whether `decl` is a MEMBER of a type `owner` provably unrelated to `ownerName` in either direction - see `foreignBoundSpans`. */
	private static function unrelatedMember(decl: NamedDecl, owner: Null<String>, ownerName: String, index: SymbolIndex): Bool {
		return RenameRefusal.isConfinableMemberCategory(decl.category) && owner != null
			&& index.subtypes.provablyNotSubtype(owner, ownerName) && index.subtypes.provablyNotSubtype(ownerName, owner);
	}

	/**
	 * Per-occurrence owner attribution for every occurrence of `name` in a subtype / `@:access` file,
	 * split into the spans that provably bind to `ownerName`'s inherited field (`ownerBound`, the
	 * rename targets) and those that provably bind to a DIFFERENT owner (`ignore`, left untouched but
	 * excluded from the blocker scan). A bare `IdentExpr` / `this.` / `super.` occurrence binds to its
	 * ENCLOSING class's field `name`; a `recv.name` access binds by the receiver's declared type. An
	 * occurrence whose enclosing class / receiver type cannot be resolved is in NEITHER set — the
	 * caller then sees it as an uncovered active-code occurrence and refuses the whole rename
	 * (fail-closed).
	 */
	private static function inheritedFieldRefSpans(
		source: String, tree: QueryNode, name: String, ownerName: String, plugin: GrammarPlugin, shape: RefShape,
		resolutionIndex: SymbolIndex
	): { bareBound: Array<Span>, typedBound: Array<Span>, ignore: Array<Span> } {
		final bareBound: Array<Span> = [];
		final typedBound: Array<Span> = [];
		final ignore: Array<Span> = [];
		final seenOwner: Array<Int> = [];
		final seenIgnore: Array<Int> = [];
		final bare: Array<{ off: Int, cls: Null<String> }> = [];
		final typed: Array<{ recv: QueryNode, fa: QueryNode }> = [];
		final recvNames: Array<String> = [];
		collectAttributedRefs(tree, name, source, null, bare, typed, recvNames, shape);
		// The two owner-bound halves are kept apart because their trustworthiness differs. `typedBound`
		// is attributed through a RECEIVER's declared type, which no scope resolver reproduces, so it is
		// safe to RENAME anywhere. `bareBound` is attributed by the enclosing CLASS alone — every bare
		// `name` read in the class lands there, including one bound to a local or parameter of that name
		// — so in a file where the scope-correct set is already known (the declaring file) it must not be
		// treated as edits; there it is `renameOccurrences` that says which bare reads are references.
		// Bare `IdentExpr` / `this.` / `super.` occurrences: attributed by their enclosing class — the
		// owner or a subtype of it binds to the inherited field (owner-bound); a class PROVABLY unrelated
		// to the owner that inherits `name` from elsewhere binds to that different owner (ignored). Any
		// other class is left uncovered so the completeness gate blocks (fail-closed) — including one
		// declaring its own same-named `name`, whose declaration token the gate flags on its own.
		// The ignore arm needs `provablyNotSubtype`, NOT merely a false `isSubtype`: that proof ends its
		// branch on an ambiguous simple name (two modules declaring `c`), while `supertypeDeclaresMember`
		// resolves straight through the ambiguity and answers for the OWNER's own member — so the pair
		// alone attributes a genuine inherited read to a "different owner" and silently drops it, leaving
		// the declaring file renamed and the subtype reading a name that no longer exists.
		for (occ in bare) {
			final cls: Null<String> = occ.cls;
			if (cls == null) continue;
			final c: String = cls;
			if (c == ownerName || resolutionIndex.subtypes.isSubtype(c, ownerName))
				OccurrenceScan.pushUniqueSpan(bareBound, seenOwner, occ.off, name.length);
			else if (resolutionIndex.subtypes.provablyNotSubtype(c, ownerName) && resolutionIndex.members.supertypeDeclaresMember(c, name))
				OccurrenceScan.pushUniqueSpan(ignore, seenIgnore, occ.off, name.length);
		}
		if (typed.length > 0)
			attributeTypedRefs(
				typed, recvNames, tree, source, name, ownerName, plugin, shape, resolutionIndex, typedBound, ignore, seenOwner, seenIgnore
			);
		return { bareBound: bareBound, typedBound: typedBound, ignore: ignore };
	}

	/**
	 * Collect every occurrence of `name` for owner attribution, carrying the ENCLOSING class name: a
	 * bare `IdentExpr` goes into `bare` (attributed by the class it sits in); a `FieldAccess` is routed
	 * by `collectFieldAccessRef`. Does NOT descend into `#if...#end` regions (their interior stays a
	 * `ConditionalRaw` blocker, like `Refs.find`).
	 */
	private static function collectAttributedRefs(
		node: QueryNode, name: String, source: String, currentClass: Null<String>, bare: Array<{ off: Int, cls: Null<String> }>,
		typed: Array<{ recv: QueryNode, fa: QueryNode }>, recvNames: Array<String>, shape: RefShape
	): Void {
		if (CondRegionScan.isConditionalKind(node.kind, shape)) return;
		final cls: Null<String> = CheckScan.isClassBodyKind(node.kind) && node.name != null ? node.name : currentClass;
		if (node.kind == 'IdentExpr' && node.name == name) {
			final s: Null<Span> = node.span;
			final off: Int = s == null ? -1 : SourceText.identTokenOffset(source, s, name);
			if (off >= 0) bare.push({ off: off, cls: cls });
		} else if (node.kind == 'FieldAccess' && node.name == name)
			collectFieldAccessRef(node, name, source, cls, bare, typed, recvNames);
		for (child in node.children) collectAttributedRefs(child, name, source, cls, bare, typed, recvNames, shape);
	}

	/** The binding-decl offset of the read / write hit at `recvFrom`, or null when it is unresolved. */
	private static function receiverBindingOffset(hits: Array<RefHit>, recvFrom: Int): Null<Int> {
		for (h in hits) if ((h.kind == RefKind.Read || h.kind == RefKind.Write) && h.span.from == recvFrom) {
			final b: Null<Span> = h.bindingSpan;
			return b?.from;
		}
		return null;
	}

	/**
	 * Every report file affected by renaming `owner`'s private member: the declaring file, every
	 * file declaring a TRANSITIVE subtype of `owner`, every file with an `@:access(owner)` grant, and every file in `grantees` (those
	 * an `@:allow` on the member opens it to). Deduped, in discovery order (declaring file first). All are report files (the index
	 * is report-scoped), hence editable.
	 */
	private static function affectedFiles(owner: String, declFile: String, index: SymbolIndex, ?grantees: Array<String>): Array<String> {
		final out: Array<String> = [declFile];
		final closure: Array<String> = [owner];
		var i: Int = 0;
		while (i < closure.length) {
			final parent: String = closure[i++];
			for (fi in index.allFiles()) for (t in fi.types) if (t.supertypes.contains(parent) && !closure.contains(t.name)) {
				closure.push(t.name);
				if (!out.contains(fi.file)) out.push(fi.file);
			}
		}
		for (fi in index.allFiles()) if (fi.accessGrants.contains(owner) && !out.contains(fi.file)) out.push(fi.file);
		for (file in grantees ?? []) if (!out.contains(file)) out.push(file);
		return out;
	}

	/**
	 * Why the cross-file rename path does NOT own this declaration's category — null when it does: a
	 * field / constant / method reached by an identifier, and not an `override`.
	 *
	 * Both hazards are `RenameRefusal.of`'s, stated for the same declarations by the same sentences. An
	 * `override` binds the name to the SUPERTYPE's declaration, so renaming the override alone orphans
	 * it, and a member with an `implicitReach` (a constructor, a magic name, an accessor, an annotated
	 * member, a type-registry constant) is reached through references no identifier-level completeness
	 * proof sees — for a FIELD or a CONSTANT exactly as for a method, which is the widening `of` takes
	 * too and which the Method-only spelling here kept this arm from making for the `Class<T>` registry
	 * it exists for. Visibility is not asked: a CONFINED private member is turned away later, by the
	 * proof that it is the single-file path's job.
	 *
	 * A `Null<String>` rather than a `Bool` because the caller must SAY it, and the sentence a reader
	 * gets is then this gate's own.
	 */
	private static function crossCategoryRefusal(decl: NamedDecl): Null<String> {
		final reach: Null<ImplicitReach> = decl.implicitReach;
		// An `@:allow` grant is this path's to carry (`crossFileCandidate` enumerates the grantees), not a refusal.
		final reached: Null<String> = reach == null || reach == ImplicitReach.AllowGrant ? null : RenameRefusal.implicitReach(reach);
		return switch decl.category {
			case NamingCategory.Field, NamingCategory.Constant: reached;
			case NamingCategory.Method: decl.mods.contains('override') ? RenameRefusal.OVERRIDE : reached;
			case _: RenameRefusal.NOT_A_MEMBER;
		}
	}

	/**
	 * The files a PUBLIC member's rename can touch: the owner's own `hierarchy` (declaring file, every
	 * subtype, every `@:access` grant) UNION every scope file whose source MENTIONS the old name. A public
	 * member is reachable from anywhere, so the subtype closure alone is not the affected set — but
	 * parsing the whole scope per finding is not one either. The textual pre-filter is safe in the
	 * conservative direction: an identifier reference — and a reflection string — must SPELL the name, so
	 * a file with no textual occurrence holds none. The `hierarchy` half stays in the union because a
	 * subtype that never mentions the old name can still declare the TARGET name, which the rename would
	 * turn into Haxe's "Redefinition of variable in subclass".
	 */
	private static function publicAffectedFiles(
		hierarchy: Array<String>, oldName: String, index: SymbolIndex, sourceByFile: Map<String, String>
	): Array<String> {
		final out: Array<String> = hierarchy.copy();
		for (fi in index.allFiles()) if (!out.contains(fi.file)) {
			final source: Null<String> = sourceByFile[fi.file];
			if (source != null && source.indexOf(oldName) >= 0) out.push(fi.file);
		}
		return out;
	}

	/**
	 * Which of `candidates` any OTHER indexed file reaches BY NAME through a reflection call
	 * (the current file is excluded — it is covered by the in-file completeness check). The
	 * verdict comes from the grammar's AST projection, `NamingSupport.reflectionMemberNames`:
	 * a name only counts when its string literal stands in an argument of a reflection call,
	 * so a menu-action id or an asset key that happens to spell a member does NOT veto its
	 * rename. The literal's own text is checked FIRST (`quotedMention`) purely as a
	 * pre-filter, so the overwhelming majority of files are dismissed at today's cost and
	 * only a handful are parsed.
	 *
	 * Sources come from the index's own `sourceOf`, which holds the exact bytes the index was
	 * built from. Reading by PATH instead — a `sys.io.File.getContent(fi.file)` — answers about
	 * the DISK rather than about the run: it puts this guard out of reach of every in-memory test
	 * (a synthetic library source has no file on disk), and mid-`--fix` it reports whatever an
	 * earlier pass wrote. It also needed a `#if (sys || nodejs)` around the whole scan, which
	 * silently disabled the `REFLECTION_NAME` refusal on any other target; that guard is gone and
	 * the refusal now fires everywhere. An unparseable file contributes nothing and is skipped.
	 */
	public static function reflectionNamesInOtherFiles(
		index: Null<SymbolIndex>, currentFile: String, candidates: Array<String>, plugin: GrammarPlugin, support: NamingSupport
	): Array<String> {
		final out: Array<String> = [];
		if (candidates.length == 0) return out;
		// The two quoted spellings of each candidate, built ONCE for the whole walk, per candidate so
		// the skip-parse branch below can still ask about ONE name. The walk is the WIDE scope —
		// report files UNION the resolution sources — and it runs once per `fix()` call, so
		// interpolating `'$name'` / `"$name"` INSIDE it would be two string allocations per
		// (scope file x candidate); that product, not the `scopeFiles` union, is where the widening's
		// cost sits.
		//
		// A quoted spelling is deliberately NOT a verdict: the same text matches a comment, a
		// `case 'name':` and an asset key, which is exactly the over-refusal the AST projection below
		// exists to end. It is a pre-filter, so a file holding no such text needs no parse.
		final quoted: Array<Array<String>> = [for (name in candidates) ['\'$name\'', '"$name"']];
		inline function spelled(source: String, forms: Array<String>): Bool {
			return forms.exists(form -> source.indexOf(form) >= 0);
		}
		for (entry in ReflectionScan.scopeFiles(index == null ? [] : indexSources(index), plugin)) if (entry.file != currentFile) {
			final source: String = entry.source;
			if (!quoted.exists(forms -> spelled(source, forms))) continue;
			final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
			// A file the parser could not read still SPELLS the name in quotes, and nothing downstream
			// can tell a `Reflect.field(x, 'name')` there from a menu key; skipping it (as a walk over
			// `SymbolIndex.allFiles()` would, since that drops a skip-parsed file entirely) is the
			// blindness. The conservative answer is the one `RawSourceScan.skippedMayReference` gives the
			// confinement proof beside it.
			if (tree == null) {
				for (i => forms in quoted) if (spelled(source, forms) && !out.contains(candidates[i])) out.push(candidates[i]);
				continue;
			}
			for (name in support.reflectionMemberNames(tree, source)) if (candidates.contains(name) && !out.contains(name)) out.push(name);
		}
		return out;
	}

	/**
	 * `index`'s files as raw sources — the FALLBACK half `ReflectionScan.scopeFiles` unions the
	 * resolution sources onto, for the runs that have no declared scope and whose whole reflection
	 * surface is therefore the report set this index was built over.
	 *
	 * Skipped files carry their retained source and are included: an index that dropped them here
	 * would put the skip-parse blindness back one layer down.
	 */
	private static function indexSources(index: SymbolIndex): Array<ScopeFile> {
		final files: Array<String> = [for (fi in index.allFiles()) fi.file].concat(index.skippedFiles());
		return [for (file in files) { file: file, source: index.sourceOf(file) ?? '' }];
	}

	/**
	 * Whether `name` is distinctive enough that a word-boundary match inside a comment is
	 * very unlikely to be prose: it carries an underscore or an uppercase letter (`_x`,
	 * `yMul`, `MAX_SIZE`). An all-lowercase name (`container`, `db`, `mixed`) is a common
	 * word or file-extension token, so a comment mention is treated as a blocker rather
	 * than renamed along with the code — avoiding prose / filename corruption in comments.
	 */
	public static function isDistinctiveName(name: String): Bool {
		for (i in 0...name.length) {
			final c: Int = name.fastCodeAt(i);
			if (c == '_'.code || (c >= 'A'.code && c <= 'Z'.code)) return true;
		}
		return false;
	}

	/**
	 * Route one `FieldAccess` named `name` to the right occurrence bucket: a `this.` / `super.` access
	 * is a bare occurrence bound by its enclosing `cls`; a `recv.name` access with an identifier
	 * receiver is a typed occurrence bound by the receiver's type. Any other receiver shape is dropped
	 * (unprovable — the completeness gate blocks it).
	 */
	private static function collectFieldAccessRef(
		node: QueryNode, name: String, source: String, cls: Null<String>, bare: Array<{ off: Int, cls: Null<String> }>,
		typed: Array<{ recv: QueryNode, fa: QueryNode }>, recvNames: Array<String>
	): Void {
		if (node.children.length == 0) return;
		final recv: QueryNode = node.children[0];
		final recvSpan: Null<Span> = recv.span;
		final faSpan: Null<Span> = node.span;
		final rn: Null<String> = recv.name;
		if (recvSpan == null || faSpan == null || recv.kind != 'IdentExpr' || rn == null) return;
		if (rn == 'this' || rn == 'super') {
			final off: Int = SourceText.identTokenOffset(source, new Span(recvSpan.to, faSpan.to), name);
			if (off >= 0) bare.push({ off: off, cls: cls });
		} else {
			typed.push({ recv: recv, fa: node });
			if (!recvNames.contains(rn)) recvNames.push(rn);
		}
	}

	/**
	 * Attribute every `recv.name` access in `typed` by the receiver's declared type: owner-bound when
	 * the type is `ownerName` or a subtype of it (pushed to `ownerBound`), a DIFFERENT owner when the
	 * type is PROVABLY not a subtype of the owner (pushed to `ignore`); an access whose receiver
	 * binding or type cannot be resolved — or whose type is merely not PROVEN a subtype, as an
	 * ambiguous simple name always is — is left in NEITHER (uncovered — block).
	 */
	private static function attributeTypedRefs(
		typed: Array<{ recv: QueryNode, fa: QueryNode }>, recvNames: Array<String>, tree: QueryNode, source: String, name: String,
		ownerName: String, plugin: GrammarPlugin, shape: RefShape, resolutionIndex: SymbolIndex, ownerBound: Array<Span>,
		ignore: Array<Span>, seenOwner: Array<Int>, seenIgnore: Array<Int>
	): Void {
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		final declared: Map<Int, String> = provider != null ? provider.declaredTypes(source) : [];
		final hitsByName: Map<String, Array<RefHit>> = Refs.findMulti(recvNames, tree, shape);
		for (cand in typed) {
			final rn: Null<String> = cand.recv.name;
			final recvSpan: Null<Span> = cand.recv.span;
			final faSpan: Null<Span> = cand.fa.span;
			if (rn == null || recvSpan == null || faSpan == null) continue;
			final bindingFrom: Null<Int> = receiverBindingOffset(hitsByName[rn] ?? [], recvSpan.from);
			if (bindingFrom == null) continue;
			final recvType: Null<String> = declared[bindingFrom];
			if (recvType == null) continue;
			final off: Int = SourceText.identTokenOffset(source, new Span(recvSpan.to, faSpan.to), name);
			if (off < 0) continue;
			if (recvType == ownerName || resolutionIndex.subtypes.isSubtype(recvType, ownerName))
				OccurrenceScan.pushUniqueSpan(ownerBound, seenOwner, off, name.length);
			else if (resolutionIndex.subtypes.provablyNotSubtype(recvType, ownerName))
				OccurrenceScan.pushUniqueSpan(ignore, seenIgnore, off, name.length);
		}
	}

	/**
	 * The spans where `name` names a TYPE rather than a value. Gated on the index first: unless the name
	 * resolves to a type in this file's scope (`SymbolIndex.declaresTypeInScope`), nothing is discounted.
	 *
	 * Two forms, because a type name reaches source through two projections:
	 *
	 *  - an ANNOTATION (`(e:Event)`, a `:Event` return, a type parameter) exists only in the parallel
	 *    type-ref tree — `parseFile` drops those positions, so neither `renameOccurrences` nor an
	 *    expression walk sees them, yet the raw completeness scan matches their text;
	 *  - a STATIC ACCESS's receiver root (`Event.ACTIVATE`), which projects the same `IdentExpr` as a
	 *    read of a same-named value and is told apart by binding to nothing visible there
	 *    (`TypeResolver.receiverRootIsUnboundType`).
	 *
	 * The index gate is what makes the second form safe. The unbound-root test alone also passes for a
	 * genuine reference the resolver failed to attribute — an inherited member read without `this.`,
	 * say — and discounting THAT would orphan a real use. `tabledStaticCall` gets its second opinion
	 * from a return-type table; here it comes from the file's imports and package.
	 */
	private static function typeReferenceSpans(
		source: String, tree: QueryNode, name: String, shape: RefShape, plugin: GrammarPlugin, ctx: RenameContext
	): Array<Span> {
		if (!ctx.index.declaresTypeInScope(name, ctx.file)) return [];
		final out: Array<Span> = [];
		final seen: Array<Int> = [];
		// Annotation positions (`(e:Event)`, `:Event` returns, type parameters) live only in the
		// PARALLEL type-ref projection — `parseFile` drops them, so neither `renameOccurrences` nor
		// the expression walk below can see them, yet the raw completeness scan matches their text.
		final typeTree: Null<QueryNode> = try plugin.parseFileTypeRefs(source) catch (exception: Exception) null;
		if (typeTree != null) for (hit in Uses.find(name, typeTree, plugin.typeRefShape())) {
			final off: Int = SourceText.identTokenOffset(source, hit.span, name);
			if (off >= 0) OccurrenceScan.pushUniqueSpan(out, seen, off, name.length);
		}
		collectTypeReferenceSpans(source, tree, tree, name, shape, out, seen);
		return out;
	}

	private static function collectTypeReferenceSpans(
		source: String, node: QueryNode, tree: QueryNode, name: String, shape: RefShape, out: Array<Span>, seen: Array<Int>
	): Void {
		final fieldKind: Null<String> = shape.fieldAccessKind;
		if (fieldKind != null && node.kind == fieldKind && node.children.length == 1) {
			final receiver: QueryNode = node.children[0];
			final rspan: Null<Span> = receiver.span;
			if (
				receiver.kind == shape.identKind && receiver.name == name && rspan != null
				&& TypeResolver.receiverRootIsUnboundType(receiver, tree, shape)
			) {
				final off: Int = SourceText.identTokenOffset(source, rspan, name);
				if (off >= 0) OccurrenceScan.pushUniqueSpan(out, seen, off, name.length);
			}
		}
		for (child in node.children) collectTypeReferenceSpans(source, child, tree, name, shape, out, seen);
	}

	/**
	 * Whether `newName` would collide with a binding reachable from `decl`'s scope. A FIELD / Constant
	 * (class-level) stays whole-file: it is visible everywhere in the type, and its inherited-member
	 * redefinition is separately gated. A Local / Param / CatchVar is SCOPE-AWARE - `newName` conflicts
	 * when it occurs anywhere in `decl`'s innermost enclosing FUNCTION (its whole body, INCLUDING the
	 * nested closures / local functions that capture `decl`), or at class / file level (an own member,
	 * static, or import). Only a function DISJOINT from that enclosing one (a sibling / unrelated body)
	 * is out of scope. An inherited member in another file never appears in-file, so a local legally
	 * shadowing one still renames.
	 *
	 * The Local / Param / CatchVar arm also subtracts every STRUCTURE-FIELD name
	 * (`RefactorSupport.structureFieldNameSpans`) — the counterpart of the `unrelatedTypeSpans`
	 * subtraction the class-level arm makes. A field of an anon structure binds nothing in any
	 * lexical scope, and it is never a `@:structInit` hazard here because a LOCAL is not a class
	 * member; without the subtraction a module-level `typedef Zoom = { x:Float, y:Float }` vetoed
	 * every `__x -> x` in its file.
	 */
	public static function collidesInScope(
		decl: NamedDecl, source: String, tree: QueryNode, newName: String, shape: RefShape, resolutionIndex: Null<SymbolIndex>,
		plugin: GrammarPlugin
	): Bool {
		final span: Null<Span> = decl.span;
		if (span == null) return true;
		if (!isBodyScopedCategory(decl.category)) {
			// Whole-file EXCEPT the sibling hierarchies sharing the module: a same-named member of an
			// UNRELATED class is not reachable from this one, so it is no collision (see `unrelatedTypeSpans`).
			final owner: Null<String> = decl.enclosingType;
			final unrelated: Array<Span> = owner == null || resolutionIndex == null
				? []
				: unrelatedTypeSpans(tree, owner, shape, resolutionIndex);
			// And EXCEPT the conditional branches that never compile with this declaration: a name bound
			// in `#if ios` cannot be duplicated or shadowed by a rename landing in `#elseif android`, and
			// reading it as a collision is what sent the pair to two DIFFERENT spellings — the shape that
			// strands every reference the rename rewrote (see `MemberBranchScan.exclusiveSpansAt`).
			final exclusive: Array<Span> = MemberBranchScan.exclusiveSpansAt(
				shape, source, tree, span.from, plugin.lexicalRegions.bind(source)
			);
			// And EXCEPT what a same-named member declared in one of those branches EXPLAINS. The scan
			// answers on lexical context, not on binding, so a plain read of that twin counts as the name
			// being taken - which is how `#if ios … key … #elseif android … _key … #end` got told its
			// obvious correction collided and answered with the rule's OTHER spelling instead. The twin's
			// own occurrence set is exactly the set that becomes a read of THIS declaration once the
			// rename lands; a binding of the name anywhere else - this declaration's own branch above all
			// - is outside it and still collides.
			final twin: Array<Span> = exclusiveTwinOccurrences(source, tree, shape, newName, exclusive);
			return OccurrenceScan.nameBoundInRange(source, newName, 0, source.length, unrelated.concat(exclusive).concat(twin), plugin);
		}
		// A local `inline function` is a function BODY for scope purposes even though it is not a
		// measured `functionKinds` unit (`complexity` folds it into its host): its parameters and
		// locals are visible only inside it, exactly as the plain local form's are. Without the union
		// a sibling helper's same-named parameter read as an in-scope collision and vetoed the rename.
		// BOTH callers see the widening - `NoUnderscorePrefix`'s underscore strip and this check's own
		// `renameEditsFor`, which is default-ON. They read a `true` DIFFERENTLY, so say it precisely:
		// the strip refuses outright, while `renameEditsFor` refuses only what `qualifiableBinding`
		// cannot repair - and that predicate is TRUE for every category this branch serves (Local /
		// Param / CatchVar), so there a `true` means "rename, naming the captured occurrences through
		// `this.`" (`qualifyCapturedEdits`). What both share is the reading of FALSE: emit the plain
		// rename. The widening produces more FALSEs, so the question is what it can hide.
		//
		// It hides exactly the spans of functions DISJOINT from `enclosing`, and every span this
		// rename rewrites lies inside `enclosing`, which stays fully scanned - so an occurrence that
		// could be shadow-broken is still seen and still vetoes. One binding IS hidden and IS visible
		// here: a sibling local function's own NAME, which lives in the enclosing body while its span
		// is the sibling's. Renaming past it produces a legal shadow of a name the target body never
		// mentions (a body that DOES mention it keeps the occurrence, and the veto stands - verified
		// both ways). That hazard is not new: it holds identically for the plain `LocalFnStmt`, which
		// `functionKinds` has always carried.
		final funcKinds: Array<String> = (shape.functionKinds ?? []).concat(shape.inlineFunctionKinds ?? []);
		// The binding is visible throughout its innermost enclosing function - INCLUDING the nested closures
		// / local functions that capture it - so a same-named binding anywhere in that function conflicts.
		// Only a function DISJOINT from it (a sibling / unrelated body) is out of scope. Fall back to a
		// whole-file scan when no enclosing function is found (defensive; a local / param always has one).
		// A local `function` statement is EXCLUDED from its own scope lookup: it is both a binding and
		// a function node, and the scope it binds into is the enclosing body. Reading its own span as
		// the scope would make every SIBLING local function look disjoint - and a sibling already
		// holding `newName` is a real collision.
		final enclosing: Null<Span> = BindingScope.enclosingScopeSpan(tree, funcKinds, span.from, shape);
		final excluded: Array<Span> = OccurrenceScan.structureFieldNameSpans(tree, source, shape);
		if (enclosing != null) collectDisjointFunctionSpans(tree, funcKinds, enclosing, excluded);
		return OccurrenceScan.nameBoundInRange(source, newName, 0, source.length, excluded, plugin);
	}

	/**
	 * Every occurrence of `newName` belonging to a member declared inside one of the `exclusive`
	 * branches - its declaration token and the reads that resolve to it - or empty when no branch
	 * declares it.
	 *
	 * The declaration is the SAME logical member as the one being renamed, one build over, so its
	 * reads are the reads the rename is about to inherit: a collision gate counting them reports that
	 * the target name is taken by the very declaration this rename unifies with. Resolved through
	 * `Rename.renameOccurrences`, the same authority the rename itself uses, so the set never widens
	 * past the reads that actually bind to the twin.
	 */
	private static function exclusiveTwinOccurrences(
		source: String, tree: QueryNode, shape: RefShape, newName: String, exclusive: Array<Span>
	): Array<Span> {
		if (exclusive.length == 0) return [];
		final out: Array<Span> = [];
		for (h in Refs.find(newName, tree, shape)) if (h.kind == RefKind.Decl) {
			final off: Int = SourceText.identTokenOffset(source, h.span, newName);
			if (off < 0 || !OccurrenceScan.offsetWithinAny(off, exclusive)) continue;
			for (occ in Rename.renameOccurrences(source, tree, h.span.from, shape)) if (!out.exists(s -> s.from == occ.from)) out.push(occ);
		}
		return out;
	}

	/**
	 * Collect the span of every function node DISJOINT from `enclosing` (no overlap) - a sibling /
	 * unrelated body whose locals & parameters are unreachable from the binding's scope, so a same-named
	 * binding there is not a collision. A function nested INSIDE `enclosing` (a capturing closure) or one
	 * that contains it is kept. Recursive.
	 */
	private static function collectDisjointFunctionSpans(
		node: QueryNode, functionKinds: Array<String>, enclosing: Span, out: Array<Span>
	): Void {
		if (functionKinds.contains(node.kind)) {
			final s: Null<Span> = node.span;
			if (s != null && (s.to <= enclosing.from || s.from >= enclosing.to)) out.push(s);
		}
		for (child in node.children) collectDisjointFunctionSpans(child, functionKinds, enclosing, out);
	}

	/**
	 * The spans of every top-level type declaration in `tree` that is NEITHER `ownerName` nor a
	 * subtype of it - a sibling hierarchy sharing the module. The target-name collision scan
	 * excludes them: a `_x` bound inside an UNRELATED class cannot clash with the owner's renamed
	 * inherited member (different class, different inherited field), yet a whole-file textual scan
	 * reads it as a collision and refuses the rename. Modules routinely park a small helper subtype
	 * next to a class of another hierarchy that already uses the same conventional name, so the
	 * blunt scan blocked most `__x -> _x` field renames. A type whose name or span is unresolvable,
	 * or one nested behind a `#if` (not a direct child), is NOT excluded - it keeps blocking
	 * (fail-closed). Unrelatedness must be PROVEN (`provablyNotSubtype`), never inferred from a false
	 * `isSubtype`: that proof ends its branch on an ambiguous simple name, so reading its `false` as
	 * "unrelated" excluded a REAL subtype's span, hid the collision the scan exists to find, and let
	 * the rename emit `Redefinition of variable in subclass` (verified). This exclusion set is the
	 * fail-OPEN direction - what it drops, nothing else re-checks.
	 */
	private static function unrelatedTypeSpans(
		tree: QueryNode, ownerName: String, shape: RefShape, resolutionIndex: SymbolIndex
	): Array<Span> {
		final kinds: Array<String> = shape.typeDeclKinds ?? [];
		if (kinds.length == 0) return [];
		final out: Array<Span> = [];
		for (child in tree.children) {
			final name: Null<String> = child.name;
			final span: Null<Span> = child.span;
			if (!kinds.contains(child.kind) || name == null || span == null) continue;
			final n: String = name;
			if (resolutionIndex.subtypes.provablyNotSubtype(n, ownerName)) out.push(span);
		}
		return out;
	}

	/**
	 * The name this rename will write and whether it still collides, or the refusal that stops it.
	 *
	 * What the owner INHERITS can forbid the corrected name outright (see `RenameRefusal.inherited`),
	 * and a name already bound where the rename lands would be duplicated or shadowed — the re-parse
	 * gate accepts that but it does not type-check. The collision test is scope-aware for a local /
	 * param / catch var (an occurrence in an UNRELATED function does not conflict) while a field /
	 * constant stays whole-file, see `collidesInScope`. A NON-STATIC member SURVIVES its collision
	 * when it is the param idiom, by naming the captured occurrences through `this.` — that is what
	 * the returned `collides` carries to `qualifyCapturedEdits`; everything else is refused here,
	 * before the expensive occurrence resolution.
	 *
	 * omega-naming-alt-spelling: only once that verdict is a refusal does the rule get asked for its
	 * SECOND conforming spelling, so every site that had no collision keeps the name it always got.
	 */
	private static function resolvedRename(
		decl: NamedDecl, corrected: String, rule: NamingRule, source: String, tree: QueryNode, shape: RefShape,
		resolutionIndex: Null<SymbolIndex>, plugin: GrammarPlugin, file: String
	): { name: String, collides: Bool, refusal: Null<String> } {
		final inherited: Null<String> = RenameRefusal.inherited(decl, corrected, resolutionIndex, file);
		final collides: Bool = inherited == null && collidesInScope(decl, source, tree, corrected, shape, resolutionIndex, plugin);
		final refusal: Null<String> = if (inherited != null)
			inherited
		else if (collides && !qualifiableBinding(decl))
			RenameRefusal.nameCollides(corrected)
		else
			null;
		if (refusal == null) return { name: corrected, collides: collides, refusal: null };
		// The second spelling passes the SAME gates — the reason the first was refused says nothing
		// about it — and the same post-conditions `correctedName` imposes on the first: a name that
		// path would also have been allowed to produce.
		final normalizeAlt: Null<String -> Null<String>> = rule.normalizeAlt;
		final second: Null<String> = normalizeAlt == null ? null : normalizeAlt(decl.name);
		if (second == null || second == decl.name || !rule.format.match(second))
			return { name: corrected, collides: collides, refusal: refusal };
		final candidate: String = second;
		final blocked: Bool = RenameRefusal.inherited(decl, candidate, resolutionIndex, file) != null
			|| collidesInScope(decl, source, tree, candidate, shape, resolutionIndex, plugin);
		return blocked ? { name: corrected, collides: collides, refusal: refusal } : { name: candidate, collides: false, refusal: null };
	}

	/**
	 * The `@:allow` paths reaching `decl` (`AllowGrants.reaching`), or null when that cannot be read - a declaration
	 * with no span or no enclosing type, or a grant the projection does not attribute. Asked by BOTH rename paths, so
	 * the single-file path's "confined" and the cross-file path's "not mine" are one answer and never two.
	 */
	private static function memberGrants(tree: QueryNode, source: String, plugin: GrammarPlugin, decl: NamedDecl): Null<Array<String>> {
		final span: Null<Span> = decl.span;
		final owner: Null<String> = decl.enclosingType;
		return span == null || owner == null ? null : AllowGrants.reaching(tree, source, plugin, span, owner);
	}

}

/**
 * What `declaringFileRenameSpans` needs from outside the file to discount an occurrence it cannot
 * attribute: the index and the file's own path, plus the owning type's name when the declaration is
 * a MEMBER.
 *
 * Two independent uses. `ownerName` drives the foreign-receiver attribution — an access on a
 * receiver of a provably unrelated type is not this member (absent for a body-scoped binding, which
 * owns no members). `index` + `file` alone drive the type-reference discount, which applies to ANY
 * declaration: a parameter named after an imported type (`Event` beside `Event.ACTIVATE`) needs it
 * just as much as a field does.
 */
typedef RenameContext = {
	final index: SymbolIndex;
	final file: String;
	@:optional final ownerName: String;
};

/**
 * A resolved cross-file rename candidate: the parsed declaring file, the flagged binding's cursor
 * offset, the old / corrected names, the owning type, and whether the old name is distinctive
 * (drives the comment-along gate). Passed from `crossFileCandidate` to the per-file span pass.
 */
typedef CrossFileCandidate = {
	final declFile: String;
	final source: String;
	final tree: QueryNode;
	final declFrom: Int;
	final oldName: String;
	final targetName: String;
	final ownerName: String;
	final distinctive: Bool;
	final isPublic: Bool;

	/** The files a private member's `@:allow` grants open it to (`AllowGrants.granteeFiles`); empty for a public one. */
	final grantees: Array<String>;

	/**
	 * The PROVEN override family of this declaration — every subtype redeclaring it, each with its
	 * file and declaration offset. Empty for a member nothing overrides. Renamed in the SAME edit
	 * set as the base: an override left behind overrides nothing and does not compile.
	 */
	final family: Array<OverrideFamilyMember>;
};

/**
 * A completed CROSS-FILE rename: the per-file edit slices the caller commits atomically, plus the
 * owning type and the new name. `crossFileFix` needs those two to record the rename with
 * `RenameClaims`, and the slices alone do not carry them.
 */
typedef CrossFileRename = {
	final slices: Array<CrossFileEdits>;
	final owner: String;
	final newName: String;
};

/**
 * A completed rename for one declaration within a single `Naming.fix` pass: the SPANS to
 * splice, the NEW NAME they introduce, and the SCOPE that name lands in. Carries all three
 * because the same-pass claim gate (`defersToAnAcceptedRename`) needs more than the spans — two renames can
 * share no span yet still collide by normalizing to the same new name in one scope.
 */
typedef DeclRename = {
	final newName: String;
	final edits: Array<{ span: Span, text: String }>;
	final scope: Span;
};

/**
 * Why a rename was withheld, one sentence per gate, plus the four ways a gate hands one to the
 * `Violation` it came from — read only by `apq lint --fix`'s per-rule unfixed ledger.
 *
 * The rename path is a long chain of independent proofs, and `Check.fix` has ONE spelling for
 * every failure of any of them: the empty edit list, which is also what a rule with no autofix at
 * all answers. On a tree where the rule reports hundreds of findings and writes nothing, the run can
 * therefore say only "its fix was called for these findings and returned no edit; the check
 * declares neither NoAutofix nor a decline reason" — and the first hypothesis a reader forms about
 * a wholesale zero is a gate closing by accident. It was not: `correctedName` had nothing to
 * return, because the policy in force came from the project's own `checkstyle.json` and a rule
 * adapted from one carries a `format` and no `normalize`. A legitimate refusal and a one-line
 * answer, and it cost a task to find because nothing carried it out of the check.
 *
 * Its own module-level type rather than a block of `Naming` statics: twenty-four constants and
 * their four writers are a third of that class's members, and a decomposition metric that counts
 * a check's SENTENCES against its complexity is measuring the wrong thing.
 *
 * The sentences are deliberately GENERIC — no name, type or file is interpolated into any of them.
 * The ledger groups declines by the reason TEXT, so a per-site detail would make every finding its
 * own "distinct reason" and turn a four-line summary into a two-hundred-line one. The site is
 * already on the finding; the reason is about the GATE.
 */
class RenameRefusal {

	/** A declaration the grammar itself marked unrenameable. */
	public static inline final RENAME_UNSAFE: String =
		'the grammar marked this declaration rename-unsafe — its identifier is a wire / accessor / `@:rtti` contract that a rewrite of the declaration alone cannot honour';

	/**
	 * A Type / EnumValue: no member-confinement proof applies, so neither member rename owns it — its fix is
	 * `NamingCrossRename`'s compiler-verified arm, which states its own reason when it declines.
	 */
	public static inline final NOT_A_MEMBER: String =
		'a type or enum-value rename reaches every file that names it, so only the cross-file `rename --scope` arm can fix it — applied only through the compiler oracle';

	/** A public member: reachable from anywhere holding a value of the owner's type. */
	public static inline final PUBLIC_MEMBER: String =
		'a public member is reachable from every file holding a value of its owner type, so the single-file rename never applies to one — the cross-file path owns it, and declined too';

	/** A public `_x` whose fix is the PRIVATIZE arm (`NamingPrivatize`) - the rename steps aside for it. */
	public static inline final PRIVATIZE_ARM: String =
		'nothing outside its type reads this public `_`-prefixed member, so the fix makes it private instead of renaming it — applied only through the compiler oracle';

	/** No cross-file index: nothing can prove the member is unreferenced elsewhere. */
	public static inline final NO_INDEX: String =
		'this run built no cross-file index, so no proof that the member is referenced nowhere else is available';

	/** An override binds the SUPERTYPE's name. */
	public static inline final OVERRIDE: String =
		'the method is an `override`, so its name is the SUPERTYPE declaration\'s — renaming this one alone would leave it overriding nothing';

	/** The member is the type's CONSTRUCTOR. */
	public static inline final IS_CONSTRUCTOR: String =
		'the method is the type\'s CONSTRUCTOR — `new` is the language\'s own spelling for it, reached by every `new Owner(…)` and by no identifier a rename could follow';

	/** A magic name the runtime itself calls. */
	public static inline final MAGIC_NAME: String =
		'the method carries a magic name the runtime calls directly (`__init__`), so renaming it disables the code silently instead of moving a reference';

	/** A property accessor: its spelling is the property's. */
	public static inline final IS_ACCESSOR: String =
		'the method is a property ACCESSOR — its spelling is the PROPERTY\'s, invoked through that property\'s `(get, set)` and by no identifier naming the method, so correcting it alone would leave the property demanding an accessor that no longer exists';

	/** Metadata-bearing member: a macro / framework can reach it by name. */
	public static inline final CARRIES_METADATA: String =
		'the member carries metadata, so a macro / `@:keep` / framework may reach it by NAME through references no identifier-level proof sees';

	/** A `static final` bound to a type reference: a `Class<T>` registry entry. */
	public static inline final TYPE_REGISTRY: String =
		'the member is a `static final` bound to a TYPE reference — a `Class<T>` registry entry a macro / framework resolves by NAME, through references no identifier-level proof sees';

	/** The program's entry point: the build names it, not the sources. */
	public static inline final ENTRY_POINT: String =
		'the method is the program\'s ENTRY POINT (`static function main()`), named by the build — `-main`, a generated launcher, `--run` — and by no identifier a rename could follow';

	/** An `@:allow` grant opens the member to another type: only the cross-file rename, which enumerates the grantees, can carry it. */
	public static inline final ALLOW_GRANT: String =
		'the member carries an `@:allow` grant, which opens it to another type, so the rename must cross into the grantee files';

	/** No enclosing type: the confinement proof has nothing to scope to. */
	public static inline final NO_OWNER: String = 'the declaration reports no enclosing type, and the confinement proof is scoped to one';

	/** A reflection call in ANOTHER file names this member. */
	public static inline final REFLECTION_NAME: String =
		'another indexed file reaches this member by NAME through a reflection call, and a rename breaks such a reference silently';

	/** The private member is reachable from some other file in the index. */
	public static inline final NOT_CONFINED: String =
		'the private member is not provably confined to this file — a subtype, an `@:access` / `@:allow` grant or a file the grammar could not read can reach it, so the rewrite must cross files';

	/** No rule in the policy selects this declaration. */
	public static inline final NO_RULE: String =
		'no rule in the naming policy in force selects this declaration\'s category and modifier set, so there is no format to correct towards';

	/**
	 * The policy states a format and no way to reach it. THE dominant decline on any project that
	 * ships a `checkstyle.json`: `CheckstyleConfigLoader` maps each naming check's `format` regex
	 * onto a rule and attaches no `normalize`, so the check can prove a name wrong and has nothing
	 * to propose.
	 */
	public static inline final NO_NORMALIZER: String =
		'the naming policy in force states a FORMAT this name fails but no mechanical normalizer that could produce a conforming one — no correction is attached to a category whose rename reaches every file that names it, so the check can say the name is wrong and not what it should be';

	/** The normalizer ran and what it produced was not usable. */
	public static inline final NORMALIZER_DECLINED: String =
		'the policy\'s normalizer ran and produced no usable name — it answered nothing, answered the name unchanged, answered one that still fails the rule\'s own format, or (under a project config) answered two different conforming ones, which is a preference the config never stated';

	/** A supertype may already declare the corrected name. */
	public static inline final INHERITED_COLLISION: String =
		'the owner\'s supertype closure cannot be proved free of a member already carrying the corrected name, which Haxe rejects as a redefinition (a method, as a missing `override`)';

	/** The owner is in an `@:rtti` hierarchy. */
	public static inline final RTTI_HIERARCHY: String =
		'the owner sits in an `@:rtti` hierarchy, which serializes by member NAME — a rename would invalidate saved data';

	/** An occurrence of the old name is not accounted for. */
	public static inline final OCCURRENCE_UNRESOLVED: String =
		'some textual occurrence of the name is not accounted for by the resolved rename spans — a `#if` branch, a name-shaped string literal, a `noqa`, or an active-code reference the resolver does not attribute — so the rewrite would be incomplete';

	/** Another accepted rename in this run already claims the name. */
	public static inline final NAME_CLAIMED: String =
		'another rename accepted earlier in this run already claims the corrected name in an overlapping scope';

	/** The plugin projects no naming declarations at all. */
	public static inline final NO_SUPPORT: String =
		'the grammar plugin projects no naming declarations, so the check has nothing to rename';

	/** The file did not re-parse for the fix pass. */
	public static inline final NO_TREE: String = 'the file did not re-parse in the fix pass, so no declaration could be located in it';

	/** The declaring file holds an `@:allow` the projection does not attribute, so whom it reaches is unknown. */
	public static inline final CROSS_ALLOW_GRANT: String =
		'the cross-file rename cannot enumerate who reaches the owner — the declaring file carries an `@:allow` the projection does not attribute to a declaration, so which members it opens, and to whom, is unknown';

	/** A member of the override family sits outside the files the rename would edit. */
	public static inline final CROSS_FAMILY_UNREACHABLE: String =
		'the rename would have to carry the whole override family, and one of its declarations sits outside the files this run would edit — half a family leaves a declaration overriding nothing';

	/** A file the rename must touch could not be read or parsed. */
	public static inline final CROSS_FILE_UNREADABLE: String =
		'a file the rename would have to edit is not in this run\'s source set, or did not parse';

	/** The target name is already bound in a file outside the declaring one. */
	public static inline final CROSS_COLLISION: String =
		'the corrected name is already bound in one of the files the rename would edit, where no `this.` qualification can disambiguate it';

	/**
	 * The corrected name is already bound where the rename lands. It NAMES that name: a reader told only
	 * that "the name collides" cannot see which binding to look for, and the neighbouring sentences once
	 * blamed a confinement proof that a local never needs.
	 */
	public static inline function nameCollides(target: String): String {
		return 'the corrected name \'$target\' is already bound where the rename would land (a parameter, local, member or import visible '
			+ 'there), and this declaration category cannot be disambiguated by qualifying the captured occurrences';
	}

	/** Qualification could not repair the collision; names the taken name, as `nameCollides` does. */
	public static inline function qualifyFailed(target: String): String {
		return 'the corrected name \'$target\' is already bound where the rename would land, by a binding other than the parameter idiom, '
			+ 'so qualifying the captured occurrences would not repair it';
	}

	/** An `@:allow` reaching the member names a grantee the index cannot enumerate. */
	public static inline function crossAllowUnenumerable(path: String): String {
		return 'the member is opened by an `@:allow` grant to `$path`, which names no type this run\'s index can enumerate - not a plain '
			+ 'dot path, or a type outside the scope - so the files that reach it are unknown';
	}

	/** A project file this run does not lint would have to change, or could not be proven not to. */
	public static inline function crossOutsideScope(file: String): String {
		return 'the rename would have to reach $file, a project file outside this run\'s sources ('
			+ 'a subtype, an `@:access` grant, or a reference to the member) - re-run over the project';
	}

	/** Is `category` one whose rename a per-file confinement proof can ever cover? */
	public static inline function isConfinableMemberCategory(category: NamingCategory): Bool {
		return category == NamingCategory.Field || category == NamingCategory.Constant || category == NamingCategory.Method;
	}

	/**
	 * The sentence for the mechanism that reaches `reach`'s member without an identifier naming it —
	 * one gate per `ImplicitReach`, where there used to be one sentence for all of them.
	 *
	 * A decline reason that names a mechanism the member does not have (`the member carries
	 * metadata` for a `private function new()`) sends the next reader after the wrong thing, which
	 * is worse than no reason at all — hence one sentence per reach.
	 *
	 * FOUR of the six are what `of` reaches: `TypeRegistry` needs a `FinalMember`, whose category
	 * is Constant or Field and never Method, so the question must be asked of every member and not
	 * under `category == Method`, or the arm that exists FOR a `Class<T>` registry refuses nothing.
	 * The two that remain unreachable THROUGH here are unreachable rather than dead: `MagicName`
	 * and `Accessor` make a Haxe declaration
	 * `reservedName`, so it carries no finding for a rename to be asked about. The switch stays
	 * total because the gate that keeps each of them away from here lives in another class, and a
	 * sentence that is right only while a distant gate holds is exactly what this function exists to
	 * stop.
	 */
	public static function implicitReach(reach: ImplicitReach): String {
		return switch reach {
			case ImplicitReach.Constructor: IS_CONSTRUCTOR;
			case ImplicitReach.MagicName: MAGIC_NAME;
			case ImplicitReach.Accessor: IS_ACCESSOR;
			case ImplicitReach.Annotation: CARRIES_METADATA;
			case ImplicitReach.TypeRegistry: TYPE_REGISTRY;
			case ImplicitReach.EntryPoint: ENTRY_POINT;
			case ImplicitReach.AllowGrant: ALLOW_GRANT;
		}
	}

	/**
	 * The unresolvable-hierarchy sentence for the files the grammar could not read, NAMING them.
	 *
	 * Every other refusal here is a constant, and that is exactly what the gate this serves used to
	 * be able to afford: it answered `skippedFiles().length > 0` for the whole RUN, so there was no
	 * subject to name and no file for a reader to go and look at. A per-declaration gate has both.
	 */
	public static function crossSkipParse(files: Array<String>): String {
		return 'the cross-file rename cannot enumerate who reaches the owner — the file(s) below did not parse, and each either '
			+ 'spells this member\'s name, its owner\'s, or the corrected name, or was not retained to be read at all, so one may '
			+ 'hold a reference, an override, or a declaration the rename cannot see: ${files.join(', ')}';
	}

	/**
	 * The other half of the unresolvable-hierarchy gate: the owner's simple name does not resolve to
	 * exactly one declaration, so no subtype match can be attributed to THIS owner.
	 *
	 * It shared one sentence with `CROSS_ALLOW_GRANT` and the sentence listed both causes with an
	 * `or` — a reader could not tell which had fired, and went looking for an `@:allow` a duplicate
	 * type name had actually caused. This half is the one the index knows exactly, so it is asked
	 * FIRST and it names the files.
	 *
	 * The empty-`files` arm is DEFENSIVE, not a case seen in this codebase: both callers build the
	 * index over the same file set the declaration came from, so the declaring file is always in it.
	 * `crossFileFix` takes its index as a public parameter, which is the only way a caller could hand
	 * in one that does not contain it.
	 */
	public static function crossOwnerNotUnique(owner: String, files: Array<String>): String {
		return 'the cross-file rename cannot enumerate who reaches the owner — ${files.length} file(s) this run can read declare a type '
			+ 'named "$owner", not exactly one, so a subtype match cannot be attributed to this declaration'
			+ (files.length == 0 ? '' : ': ${files.join(', ')}');
	}

	/**
	 * Write `reason` on `v` unless something already spoke for it.
	 *
	 * FIRST writer wins. The cross-file pass runs BEFORE the per-file one inside a `--fix` pass and
	 * answers a strictly more specific question for the members it owns, so a reason it has already
	 * written must not be replaced by the per-file path's "a public member is the cross-file path's
	 * job". A null `v` is a declaration that carries no finding — nothing to tell.
	 */
	public static function note(v: Null<Violation>, reason: String): Void {
		if (v != null && v.declineReason == null) v.declineReason = reason;
	}

	/** `note` for a gate addressed by declaration position, answering the `Null<DeclRename>` it must return. */
	public static function rename(flaggedAt: Map<Int, Violation>, declFrom: Int, reason: String): Null<DeclRename> {
		note(flaggedAt[declFrom], reason);
		return null;
	}

	/** `note` for the cross-file candidate path, whose declining gates answer `Null<CrossFileCandidate>`. */
	public static function candidate(v: Violation, reason: String): Null<CrossFileCandidate> {
		note(v, reason);
		return null;
	}

	/** `note` for the cross-file rename path, whose declining gates answer `Null<CrossFileRename>`. */
	public static function crossRename(v: Violation, reason: String): Null<CrossFileRename> {
		note(v, reason);
		return null;
	}

	/**
	 * Write `reason` on EVERY violation of a whole-file refusal and answer the empty edit list.
	 *
	 * `Check.fix` has one spelling for "nothing here" and it is also what a check with NO autofix
	 * answers, so a whole-scope refusal that returns it silently is indistinguishable from a rule
	 * that cannot fix at all — which is exactly the reading this rule's 231-finding zero drew.
	 */
	public static function all(violations: Array<Violation>, reason: String): Array<{ span: Span, text: String }> {
		for (v in violations) v.declineReason = reason;
		return [];
	}

	/**
	 * Why the single-file rename of `decl`'s binding is not provably complete within `source` — null
	 * when every proof passes and the rename may go ahead.
	 *
	 * This was `isRenameSafe`, a `Bool`, and eight different refusals reached the caller as one
	 * `false`. Returning the SENTENCE instead is the whole conversion: the reason a reader gets is
	 * then the guard's own and cannot drift from the condition that produced it.
	 */
	public static function of(
		decl: NamedDecl, source: String, confinementIndex: Null<SymbolIndex>, reflectionNames: Array<String>,
		confinedMemo: Map<String, Bool>, ?grants: Null<Array<String>>, ?file: String
	): Null<String> {
		// A declaration the grammar marked rename-unsafe (a typedef / anon-structure
		// field whose name is a wire contract, or a property backed by physical
		// get_/set_ accessors a single-decl rename would orphan) is report-only -
		// the check still warns, but the autofix must not rewrite it.
		if (decl.renameUnsafe == true) return RENAME_UNSAFE;
		final category: NamingCategory = decl.category;
		if (category == NamingCategory.Local || category == NamingCategory.Param || category == NamingCategory.CatchVar) return null;
		// Three refusals that were ONE `if` while the caller only needed a yes/no. They are three
		// different answers to "why not mine", so the reader gets three sentences.
		if (!isConfinableMemberCategory(category)) return NOT_A_MEMBER;
		if (decl.mods.contains('public')) return PUBLIC_MEMBER;
		if (confinementIndex == null) return NO_INDEX;
		// An `override` is a METHOD-only hazard - it binds the name to the SUPERTYPE's declaration, so
		// renaming the override alone orphans it. `implicitReach` is EVERY member's: a member reached
		// without an identifier naming it is reached that way whatever its category, and the OTHER check
		// that asks this field (`UnusedPrivate.violationFor`) asks it with no category qualifier at all.
		// Asking it under `category == Method` would let TWO arms through on a Field or a Constant: an
		// ANNOTATED member, and a `TypeRegistry` constant - whose arm has no other category to be
		// reached in, since `isTypeReferenceInit` requires a `FinalMember` and a `FinalMember` is
		// Constant or Field and never Method - so `private static final _BAD_ENTRY = SomeType;`, which
		// `unused-private` declines even to REPORT because a macro may reach it by NAME, would be
		// renamed. A name a rename breaks is broken exactly as a deletion breaks it. WHICH mechanism is
		// what `implicitReach` names and this refusal repeats, rather than claiming metadata for all
		// of them.
		if (category == NamingCategory.Method && decl.mods.contains('override')) return OVERRIDE;
		final reach: Null<ImplicitReach> = decl.implicitReach;
		// An `@:allow` grant is not a reach by name: the confinement proof below asks it of THIS member
		// (`grants`) and hands a granted one to the cross-file rename, which enumerates the grantees.
		if (reach != null && reach != ImplicitReach.AllowGrant) return implicitReach(reach);
		final owner: Null<String> = decl.enclosingType;
		if (owner == null) return NO_OWNER;
		// Cross-file reflection guard: a private member reached from ANOTHER file by a
		// reflection call naming it (`Reflect.field(x, 'name')`) breaks silently after a
		// rename — the identifier-level confinement proof cannot see it. The names come from
		// the grammar's own AST projection (`NamingSupport.reflectionMemberNames`), NOT from a
		// text scan: a string that merely SPELLS the member (a menu-action id, an asset key,
		// a `case 'name':`) is not a reference to it and must not veto the rename. The
		// declaring file is already covered by the in-file completeness check.
		if (reflectionNames.contains(decl.name)) return REFLECTION_NAME;
		// Memoize confinement per owner-type within this fix() call: a type with
		// many flagged private constants would otherwise redo the identical
		// project-wide subtype / access-grant / `@:allow` scan once per finding.
		// Keyed by owner AND member: the skipped-file half of the proof is per-NAME now (a file
		// the grammar cannot read can only reach a member it spells), so two members of one type
		// no longer share an answer.
		//
		// The key carries no INDEX, and it does not need one: the map is built per `fix()` call and
		// this is its only writer, so every entry in it was decided against the one
		// `confinementIndex` that call resolved. A second index reaching the same map would make the
		// first answer serve the second question — so a future caller must pass its own map, not
		// share this one.
		final memoKey: String = '$owner\t${decl.name}';
		final cached: Null<Bool> = confinedMemo[memoKey];
		if (cached != null) return cached ? null : NOT_CONFINED;
		final confined: Bool = RefactorSupport.isPrivateMemberConfined(owner, decl.name, source, confinementIndex, grants, file);
		confinedMemo[memoKey] = confined;
		return confined ? null : NOT_CONFINED;
	}

	/**
	 * Why `newName` cannot be given to `decl` because of what its OWNER inherits — null when nothing
	 * objects, and null at once for a category with no supertype hazard.
	 *
	 * A private INSTANCE field renamed to `_x` must not REDEFINE a field named `_x` inherited from a
	 * supertype - Haxe rejects "Redefinition of variable in subclass" (verified). A METHOD has the
	 * same hazard with a different message ("Field f should be declared with 'override' since it is
	 * inherited from superclass"), so both member categories take this gate. A local / param renamed
	 * to a bare name only SHADOWS an inherited member, which Haxe permits (verified) - the whole-file
	 * textual collision scan in the caller covers that case. The proof walks the FULL supertype
	 * closure through `resolutionIndex` (the RESOLUTION scope — report files UNION the configured
	 * libraries — when the plugin carries one, else the report index): an `openfl` / `lime`
	 * subclass's inherited members are then resolvable rather than unprovable. Refuse when the
	 * inherited-`_x` possibility cannot be ruled out (a still-unresolvable supertype closure), and
	 * refuse a member of a `@:rtti` / drill-Node hierarchy whose subtype-ward `@:rtti` only the index
	 * reveals (the direct-`@:rtti` case is already refused by `of`): such a class serializes by
	 * reflecting on member NAMES, so a rename would break saved files.
	 */
	public static function inherited(decl: NamedDecl, newName: String, resolutionIndex: Null<SymbolIndex>, file: String): Null<String> {
		if (decl.category != NamingCategory.Field && decl.category != NamingCategory.Method) return null;
		final owner: Null<String> = decl.enclosingType;
		if (owner == null) return NO_OWNER;
		if (resolutionIndex == null) return NO_INDEX;
		final idx: SymbolIndex = resolutionIndex;
		return if (!idx.members.typeProvablyLacksMember(owner, newName, file))
			INHERITED_COLLISION
		else if (idx.traits.transitivelyCarriesRtti(owner))
			RTTI_HIERARCHY
		else
			null;
	}

}
