package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.NamingPolicy.NamedDecl;
import anyparse.query.NamingPolicy.NamingPolicy;
import anyparse.query.NamingPolicy.NamingRule;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

import anyparse.query.Rename;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.SymbolIndex;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndexHost;
import anyparse.query.RefactorSupport.ClassifiedOccurrence;
import anyparse.query.RefactorSupport.OccurrenceClass;
import anyparse.check.Check.CrossFileFix;
import anyparse.check.Check.CrossFileEdits;
import anyparse.query.Refs;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.query.TypeInfoProvider;

/**
 * Flags declarations whose identifier violates a naming convention. The check
 * is grammar-agnostic: it asks the plugin's `NamingSupport` to project the
 * declarations worth checking (each with a neutral category and modifier set)
 * and to resolve the effective `NamingPolicy` for the file — a discovered
 * `checkstyle.json` when present, else the grammar's built-in default. Every
 * declaration is matched against the first applicable rule; a name failing the
 * rule's `format` is a `Warning`.
 *
 * ## checkstyle compatibility
 *
 * The policy comes from the plugin: for Haxe, `HaxeNamingSupport.policyFor`
 * adapts an existing `checkstyle.json` via `CheckstyleConfigLoader`, mirroring
 * how the writer honours an `hxformat.json`. A project that already ships a
 * checkstyle config gets its naming rules out of the box; the check itself
 * never parses that format — it stays language- and config-neutral.
 *
 * ## No naming support → no-op
 *
 * A grammar without a naming convention (a binary format) returns null from
 * `namingSupport`; the check skips it. Report-only for now — `fix` returns no
 * edits (a rename-based autofix is a later slice).
 */
@:nullSafety(Strict)
final class Naming implements Check implements CrossFileFix {

	public function new() {}

	public function id(): String {
		return 'naming';
	}

	public function description(): String {
		return 'declaration name violates the naming convention (default, or a discovered checkstyle.json)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final support: Null<NamingSupport> = plugin.namingSupport();
		if (support == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			for (v in violationsFor(entry.file, support.project(tree), support.policyFor(entry.file))) violations.push(v);
		}
		return violations;
	}

	/**
	 * Autofix: rename each flagged binding to a mechanically-corrected name when
	 * the rename is provably complete in this one file. A function-body-scoped
	 * binding (Local / Param / CatchVar) is a candidate; a private FIELD is one
	 * only when the cross-file `index` proves it confined (no subtype, no
	 * `@:access`, no `@:allow`, no skip-parse file that could hide one). Every
	 * candidate is then held to two in-file guards: every textual occurrence of
	 * the old name must be covered by the resolved rename spans (an uncovered one
	 * — a bare `$name` interpolation the resolver misses, a reflection string —
	 * means an incomplete rename, so bail), and the new name must not already be
	 * bound in the file (a collision would duplicate or shadow it). The new name
	 * comes from the applicable `normalize`; the occurrences from
	 * `Rename.renameOccurrences`, emitted as edits the caller batches and
	 * re-parse-validates.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		if (violations.length == 0) return [];
		final support: Null<NamingSupport> = plugin.namingSupport();
		if (support == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];

		final policy: NamingPolicy = support.policyFor(violations[0].file);
		final shape: RefShape = plugin.refShape();

		final flaggedFroms: Array<Int> = [];
		for (v in violations) {
			final s: Null<Span> = v.span;
			if (s != null) flaggedFroms.push(s.from);
		}

		// Hoisted ONCE per fix() call (not per finding): every OTHER indexed file's
		// source, for the cross-file reflection-string rename guard, plus a per-owner
		// confinement memo so a type with many flagged private members runs the
		// project-wide confinement scan a single time.
		final otherSources: Array<String> = index == null ? [] : otherIndexedSources(index, violations[0].file);
		final confinedMemo: Map<String, Bool> = [];
		// The inherited-member proof of a `_`-prefix field rename walks the FULL supertype
		// closure, so it resolves through the plugin's resolution scope (report files UNION the
		// configured libraries) when present — a field of an `openfl` / `lime` subclass is then
		// provable rather than blocked as unresolvable. The report-scope `index` still backs the
		// confinement / reflection-string proofs (they reason about report-file reachability).
		final resolutionIndex: Null<SymbolIndex> = resolutionIndexOf(plugin) ?? index;

		final edits: Array<{ span: Span, text: String }> = [];
		for (decl in support.project(tree)) {
			final rename: Null<RenameEdits> = renameEditsFor(
				decl, source, tree, policy, shape, plugin, flaggedFroms, otherSources, confinedMemo, resolutionIndex, index
			);
			if (rename != null) for (occ in rename.occurrences) edits.push({ span: occ, text: rename.name });
		}
		return edits;
	}

	/**
	 * Cross-file autofix (the `CrossFileFix` seam): rename each flagged NON-confined
	 * private field / constant whose references reach into its subtypes / `@:access`-grant
	 * files. The single-file `fix` skips such a member (it is not confined); here the
	 * rename is proven complete across EVERY affected report file and emitted as one atomic
	 * multi-file edit set. The declaring file resolves scope-correctly (the T29 occurrence
	 * set + completeness gate); each subtype / grant file classifies every occurrence of the
	 * old name — an `ActiveCode` one is a reference to rename, a `CommentTrivia` one renames
	 * along when the name is distinctive, and a `ConditionalRaw` / `StringLiteral` /
	 * `DirectiveComment` occurrence (or a `targetName` already colliding in a file, an
	 * unresolvable hierarchy, an `@:rtti` / reflection-string hazard) turns the WHOLE rename
	 * report-only. The caller (`apq lint --fix`) commits every affected file or none.
	 */
	public function crossFileFix(
		files: Array<{ file: String, source: String }>, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<Array<CrossFileEdits>> {
		if (violations.length == 0 || index == null) return [];
		final support: Null<NamingSupport> = plugin.namingSupport();
		if (support == null) return [];
		final idx: SymbolIndex = index;
		final shape: RefShape = plugin.refShape();
		final resolutionIndex: SymbolIndex = resolutionIndexOf(plugin) ?? idx;
		final sourceByFile: Map<String, String> = [for (f in files) f.file => f.source];
		final out: Array<Array<CrossFileEdits>> = [];
		for (v in violations) {
			final rename: Null<Array<CrossFileEdits>> = crossFileRenameFor(v, sourceByFile, support, shape, plugin, idx, resolutionIndex);
			if (rename != null) out.push(rename);
		}
		return out;
	}

	/**
	 * The violations for `decls` under `policy`: each declaration is tested
	 * against the first rule whose category matches and whose `requireMods` are
	 * all present and `forbidMods` all absent; a name failing that rule's
	 * `format` is a `Warning`. A declaration with no span is skipped (no
	 * location to report), as is one no rule applies to.
	 */
	public static function violationsFor(file: String, decls: Array<NamedDecl>, policy: NamingPolicy): Array<Violation> {
		final out: Array<Violation> = [];
		for (decl in decls) {
			final span: Null<Span> = decl.span;
			if (span == null) continue;
			final rule: Null<NamingRule> = applicableRule(decl, policy);
			if (rule == null || rule.format.match(decl.name)) continue;
			out.push({
				file: file,
				span: span,
				rule: 'naming',
				severity: Severity.Warning,
				message: '${rule.label}: \'${decl.name}\''
			});
		}
		return out;
	}

	/** The first rule in `policy` applicable to `decl` (category + modifier filters), or null. */
	private static function applicableRule(decl: NamedDecl, policy: NamingPolicy): Null<NamingRule> {
		return policy.find(
			rule ->
				rule.category == decl.category && rule.requireMods.foreach(m -> decl.mods.contains(m))
				&& !rule.forbidMods.exists(m -> decl.mods.contains(m))
		);
	}

	/**
	 * Is the rename of `decl`'s binding provably complete within `source`? A
	 * declaration the grammar marked `renameUnsafe` (a structural / anon-struct
	 * field, a property backed by physical accessors) never is. Otherwise a
	 * function-body-scoped binding always is; a private field or private
	 * static-final constant is only when the cross-file `index` plus in-file
	 * checks prove it cannot be referenced from outside its file. Every other
	 * category (types, public members) is not.
	 */
	private static function isRenameSafe(
		decl: NamedDecl, source: String, index: Null<SymbolIndex>, otherSources: Array<String>, confinedMemo: Map<String, Bool>
	): Bool {
		// A declaration the grammar marked rename-unsafe (a typedef / anon-structure
		// field whose name is a wire contract, or a property backed by physical
		// get_/set_ accessors a single-decl rename would orphan) is report-only -
		// the check still warns, but the autofix must not rewrite it.
		if (decl.renameUnsafe == true) return false;
		final category: NamingCategory = decl.category;
		if (category == NamingCategory.Local || category == NamingCategory.Param || category == NamingCategory.CatchVar) return true;
		if ((category == NamingCategory.Field || category == NamingCategory.Constant) && !decl.mods.contains('public') && index != null) {
			final owner: Null<String> = decl.enclosingType;
			if (owner == null) return false;
			// Cross-file reflection guard: a private member reached from ANOTHER file
			// by a reflection string (`Reflect.field(x, 'name')`, a string-keyed field
			// map, `Type.createInstance` field names) breaks silently after a rename —
			// the identifier-level confinement proof cannot see it. Refuse when the old
			// name occurs as a quoted string literal in any other indexed file (the
			// declaring file is already covered by the in-file completeness check).
			if (referencedAsStringLiteral(decl.name, otherSources)) return false;
			// Memoize confinement per owner-type within this fix() call: a type with
			// many flagged private constants would otherwise redo the identical
			// project-wide subtype / access-grant / `@:allow` scan once per finding.
			final cached: Null<Bool> = confinedMemo[owner];
			if (cached != null) return cached;
			final confined: Bool = RefactorSupport.isPrivateMemberConfined(owner, source, index);
			confinedMemo[owner] = confined;
			return confined;
		}
		return false;
	}

	/**
	 * The rename to apply to one projected declaration, or null when it must be
	 * skipped: not among the flagged spans, not rename-safe, no applicable rule
	 * with a normalizer, already conformant, a rename to a name already bound in
	 * the file (a collision), or an incomplete rename — the old name still occurs
	 * outside the resolved spans as active code, inside a `#if...#end` region, in a
	 * string literal, or on a `noqa` directive line. A plain comment mention does
	 * NOT block: its occurrence is added to the returned spans and renamed together
	 * with the code. When non-null, every returned occurrence span is rewritten to
	 * `name`.
	 */
	private static function renameEditsFor(
		decl: NamedDecl, source: String, tree: QueryNode, policy: NamingPolicy, shape: RefShape, plugin: GrammarPlugin,
		flaggedFroms: Array<Int>, otherSources: Array<String>, confinedMemo: Map<String, Bool>, resolutionIndex: Null<SymbolIndex>,
		?index: SymbolIndex
	): Null<RenameEdits> {
		final span: Null<Span> = decl.span;
		if (span == null || !flaggedFroms.contains(span.from) || !isRenameSafe(decl, source, index, otherSources, confinedMemo))
			return null;
		final rule: Null<NamingRule> = applicableRule(decl, policy);
		if (rule == null) return null;
		final normalize: Null<String -> Null<String>> = rule.normalize;
		if (normalize == null) return null;
		final newName: Null<String> = normalize(decl.name);
		if (newName == null || newName == decl.name || !rule.format.match(newName)) return null;
		// A private INSTANCE field renamed to `_x` must not REDEFINE a field named `_x`
		// inherited from a supertype - Haxe rejects "Redefinition of variable in subclass"
		// (verified). A local / param renamed to a bare name only SHADOWS an inherited member,
		// which Haxe permits (verified) - the whole-file textual collision scan below covers
		// that case - so the inheritance gate is FIELD-only. The proof walks the FULL supertype
		// closure through `resolutionIndex` (the RESOLUTION scope — report files UNION the
		// configured libraries — when the plugin carries one, else the report index): an `openfl`
		// / `lime` subclass's inherited members are then resolvable rather than unprovable. Skip
		// when the inherited-`_x` possibility cannot be ruled out (a still-unresolvable supertype
		// closure), and skip a field of a `@:rtti` / drill-Node hierarchy whose subtype-ward
		// `@:rtti` only the index reveals (the direct-`@:rtti` case is already `renameUnsafe`):
		// such a class serializes by reflecting on field NAMES, so a rename would break saved files.
		if (decl.category == NamingCategory.Field) {
			final owner: Null<String> = decl.enclosingType;
			if (owner == null || resolutionIndex == null) return null;
			final idx: SymbolIndex = resolutionIndex;
			if (!idx.typeProvablyLacksMember(owner, newName) || idx.transitivelyCarriesRtti(owner)) return null;
		}
		// Collision: a `newName` already bound where the rename lands would be duplicated or shadowed
		// (the re-parse gate accepts it but it does not type-check), so skip. Scope-aware for a local /
		// param / catch var - an occurrence in an UNRELATED function does not conflict; a field / constant
		// stays whole-file (see `collidesInScope`).
		if (collidesInScope(decl, source, tree, newName, shape)) return null;
		// Completeness + comment-along: the SAME scope-correct occurrence resolution + classifyOccurrences
		// gate the cross-file path applies to its declaring file — a `#if` / string / `noqa` / resolver-missed
		// active-code occurrence bails, a distinctive comment mention renames along (see `declaringFileRenameSpans`).
		final renameSpans: Null<Array<Span>> = declaringFileRenameSpans(
			source, tree, span.from, decl.name, shape, plugin, isDistinctiveName(decl.name)
		);
		return renameSpans == null ? null : {
			occurrences: renameSpans,
			name: newName
		};
	}

	/**
	 * The resolved cross-file rename CANDIDATE for one flagged violation, or null when it must be
	 * skipped: not a NON-confined private field / constant, something the single-file path already
	 * covers (a confined member), an unenumerable hierarchy (a skip-parse file hiding a subtype, an
	 * `@:allow` grant, a non-unique owner), no derivable corrected name, or a blocked
	 * inherited-member / `@:rtti` guard. Carries the parsed declaring file plus the names the
	 * per-file span pass needs.
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
		final declTree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (declTree == null) return null;
		final tree: QueryNode = declTree;
		final decl: Null<NamedDecl> = support.project(tree).find(d -> d.span != null && d.span.from == vspan.from);
		if (decl == null) return null;
		// Candidate: a NON-confined private field / constant the single-file `fix` skips.
		if (decl.renameUnsafe == true) return null;
		final cat: NamingCategory = decl.category;
		if (!((cat == NamingCategory.Field || cat == NamingCategory.Constant) && !decl.mods.contains('public'))) return null;
		final owner: Null<String> = decl.enclosingType;
		if (owner == null) return null;
		final ownerName: String = owner;
		// A confined member is the single-file path's job; only a non-confined one crosses files.
		if (RefactorSupport.isPrivateMemberConfined(ownerName, source, index)) return null;
		// Unresolvable hierarchy: a skip-parse file could hide a subtype / grant we never see; an
		// `@:allow` grants an unenumerable type; a non-unique owner makes the subtype match ambiguous.
		if (index.skippedFiles().length > 0 || source.indexOf('@:allow') >= 0 || index.declaringFiles(ownerName).length != 1) return null;
		final targetName: Null<String> = correctedFieldName(decl, support.policyFor(declFile), ownerName, resolutionIndex);
		if (targetName == null) return null;
		return {
			declFile: declFile,
			source: source,
			tree: tree,
			declFrom: vspan.from,
			oldName: decl.name,
			targetName: targetName,
			ownerName: ownerName,
			distinctive: isDistinctiveName(decl.name)
		};
	}

	/**
	 * The corrected name for `decl` under `policy`, or null when there is none / it must not apply:
	 * no normalizer, an unchanged or non-conformant result, a supertype that already declares the
	 * name (Haxe's "Redefinition of variable in subclass"), or a transitive `@:rtti` serialization
	 * hierarchy (renaming a reflected field name breaks saved files). `ownerName` / `resolutionIndex`
	 * drive the inheritance + rtti guards through the resolution scope.
	 */
	private static function correctedFieldName(
		decl: NamedDecl, policy: NamingPolicy, ownerName: String, resolutionIndex: SymbolIndex
	): Null<String> {
		final rule: Null<NamingRule> = applicableRule(decl, policy);
		if (rule == null) return null;
		final normalize: Null<String -> Null<String>> = rule.normalize;
		if (normalize == null) return null;
		final newName: Null<String> = normalize(decl.name);
		if (newName == null || newName == decl.name || !rule.format.match(newName)) return null;
		if (!resolutionIndex.typeProvablyLacksMember(ownerName, newName) || resolutionIndex.transitivelyCarriesRtti(ownerName)) return null;
		return newName;
	}

	/**
	 * The cross-file rename fixing one flagged NON-confined private field / constant, or null when
	 * it cannot be proven complete. Resolves the candidate (`crossFileCandidate`), then collects and
	 * gates each affected file's occurrence spans; a bail in ANY file makes the whole rename
	 * report-only. Returns the per-file `CrossFileEdits` slices.
	 */
	private static function crossFileRenameFor(
		v: Violation, sourceByFile: Map<String, String>, support: NamingSupport, shape: RefShape, plugin: GrammarPlugin,
		index: SymbolIndex, resolutionIndex: SymbolIndex
	): Null<Array<CrossFileEdits>> {
		final candidate: Null<CrossFileCandidate> = crossFileCandidate(v, sourceByFile, support, plugin, index, resolutionIndex);
		if (candidate == null) return null;
		final c: CrossFileCandidate = candidate;
		final slices: Array<CrossFileEdits> = [];
		for (file in affectedFiles(c.ownerName, c.declFile, index)) {
			final fileSource: Null<String> = sourceByFile[file];
			if (fileSource == null) return null;
			final fsrc: String = fileSource;
			final spans: Null<Array<Span>> = file == c.declFile
				? declaringFileRenameSpans(fsrc, c.tree, c.declFrom, c.oldName, shape, plugin, c.distinctive)
				: otherFileRenameSpans(fsrc, c.oldName, plugin, c.distinctive, c.ownerName, shape, resolutionIndex);
			if (spans == null) return null;
			// A `targetName` already bound in this file would collide once the rename lands.
			if (RefactorSupport.referencedInRange(fsrc, c.targetName, 0, fsrc.length, [])) return null;
			if (spans.length > 0) slices.push({ file: file, edits: [for (s in spans) { span: s, text: c.targetName }] });
		}
		return slices.length == 0 ? null : slices;
	}

	/**
	 * The occurrence spans to rewrite in the DECLARING file — the T29 single-file model: the
	 * scope-correct resolved reference set (decl + reads / writes + `this.<name>`), gated for
	 * completeness. Any resolved-outside occurrence that is `ActiveCode` (a reference the
	 * resolver missed) or a `ConditionalRaw` / `StringLiteral` / `DirectiveComment` bails
	 * (null); a distinctive-name `CommentTrivia` mention renames along. Null on a parse failure
	 * when the fail-closed raw scan finds an uncovered mention.
	 */
	private static function declaringFileRenameSpans(
		source: String, tree: QueryNode, declFrom: Int, name: String, shape: RefShape, plugin: GrammarPlugin, distinctive: Bool
	): Null<Array<Span>> {
		final resolved: Array<Span> = Rename.renameOccurrences(source, tree, declFrom, shape);
		if (resolved.length == 0) return null;
		// Attribute every OTHER same-name occurrence to its binding: one provably bound to a DIFFERENT
		// binding (a param / loop var / sibling local sharing the name) is neither a rename target nor a
		// blocker for THIS binding, so it joins the resolved set as an excluded span. An occurrence whose
		// binding is unresolved is left uncovered so the completeness gate below blocks (fail-closed).
		final excluded: Array<Span> = resolved.concat(otherBindingSpans(source, tree, name, declFrom, shape));
		final classified: Null<Array<ClassifiedOccurrence>> = RefactorSupport.classifyOccurrences(
			source, name, plugin, 0, source.length, excluded
		);
		if (classified == null) return RefactorSupport.referencedInRange(source, name, 0, source.length, excluded) ? null : resolved;
		final spans: Array<Span> = resolved.copy();
		for (occ in classified) switch occ.kind {
			case OccurrenceClass.CommentTrivia if (distinctive):
				spans.push(occ.span);
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
	 * same-named field, reached through a differently-typed receiver or a self-declaring class) is
	 * IGNORED — neither renamed nor a blocker; an occurrence whose binding cannot be proven is left
	 * uncovered so the completeness gate blocks the whole rename (fail-closed). A distinctive-name
	 * `CommentTrivia` still renames along. Null on a parse failure or an unattributable active-code
	 * occurrence. This replaces the old blanket bail on any same-named sibling field.
	 */
	private static function otherFileRenameSpans(
		source: String, name: String, plugin: GrammarPlugin, distinctive: Bool, ownerName: String, shape: RefShape,
		resolutionIndex: SymbolIndex
	): Null<Array<Span>> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return null;
		final refs: { ownerBound: Array<Span>, ignore: Array<Span> } = inheritedFieldRefSpans(
			source, tree, name, ownerName, plugin, shape, resolutionIndex
		);
		// Both the owner-bound targets AND the provably-different-owner occurrences are excluded from
		// the completeness scan: the former are renamed, the latter left as-is; only an occurrence that
		// is NEITHER (unprovable) stays uncovered and blocks the whole rename below.
		final excluded: Array<Span> = refs.ownerBound.concat(refs.ignore);
		final classified: Null<Array<ClassifiedOccurrence>> = RefactorSupport.classifyOccurrences(
			source, name, plugin, 0, source.length, excluded
		);
		if (classified == null) return null;
		final spans: Array<Span> = refs.ownerBound.copy();
		for (occ in classified) switch occ.kind {
			case OccurrenceClass.CommentTrivia if (distinctive):
				spans.push(occ.span);
			case _:
				return null;
		}
		return spans;
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
	): { ownerBound: Array<Span>, ignore: Array<Span> } {
		final ownerBound: Array<Span> = [];
		final ignore: Array<Span> = [];
		final seenOwner: Array<Int> = [];
		final seenIgnore: Array<Int> = [];
		final bare: Array<{ off: Int, cls: Null<String> }> = [];
		final typed: Array<{ recv: QueryNode, fa: QueryNode }> = [];
		final recvNames: Array<String> = [];
		collectAttributedRefs(tree, name, source, null, bare, typed, recvNames);
		// Bare `IdentExpr` / `this.` / `super.` occurrences: attributed by their enclosing class — the
		// owner or a subtype of it binds to the inherited field (owner-bound); a class inheriting `name`
		// from a NON-owner supertype binds to that different owner (ignored). Any other class is left
		// uncovered so the completeness gate blocks (fail-closed) — including one declaring its own
		// same-named `name`, whose declaration token the gate flags on its own.
		for (occ in bare) {
			final cls: Null<String> = occ.cls;
			if (cls == null) continue;
			final c: String = cls;
			if (c == ownerName || resolutionIndex.isSubtype(c, ownerName))
				RefactorSupport.pushUniqueSpan(ownerBound, seenOwner, occ.off, name.length);
			else if (resolutionIndex.supertypeDeclaresMember(c, name))
				RefactorSupport.pushUniqueSpan(ignore, seenIgnore, occ.off, name.length);
		}
		if (typed.length > 0)
			attributeTypedRefs(
				typed, recvNames, tree, source, name, ownerName, plugin, shape, resolutionIndex, ownerBound, ignore, seenOwner, seenIgnore
			);
		return { ownerBound: ownerBound, ignore: ignore };
	}

	/**
	 * Collect every occurrence of `name` for owner attribution, carrying the ENCLOSING class name: a
	 * bare `IdentExpr` goes into `bare` (attributed by the class it sits in); a `FieldAccess` is routed
	 * by `collectFieldAccessRef`. Does NOT descend into `#if...#end` regions (their interior stays a
	 * `ConditionalRaw` blocker, like `Refs.find`).
	 */
	private static function collectAttributedRefs(
		node: QueryNode, name: String, source: String, currentClass: Null<String>, bare: Array<{ off: Int, cls: Null<String> }>,
		typed: Array<{ recv: QueryNode, fa: QueryNode }>, recvNames: Array<String>
	): Void {
		if (RefactorSupport.isConditionalKind(node.kind)) return;
		final cls: Null<String> = (node.kind == 'ClassDecl' && node.name != null) ? node.name : currentClass;
		if (node.kind == 'IdentExpr' && node.name == name) {
			final s: Null<Span> = node.span;
			final off: Int = s == null ? -1 : RefactorSupport.identTokenOffset(source, s, name);
			if (off >= 0) bare.push({ off: off, cls: cls });
		} else if (node.kind == 'FieldAccess' && node.name == name)
			collectFieldAccessRef(node, name, source, cls, bare, typed, recvNames);
		for (child in node.children) collectAttributedRefs(child, name, source, cls, bare, typed, recvNames);
	}


	/** The binding-decl offset of the read / write hit at `recvFrom`, or null when it is unresolved. */
	private static function receiverBindingOffset(hits: Array<RefHit>, recvFrom: Int): Null<Int> {
		for (h in hits) if ((h.kind == RefKind.Read || h.kind == RefKind.Write) && h.span.from == recvFrom) {
			final b: Null<Span> = h.bindingSpan;
			return b == null ? null : b.from;
		}
		return null;
	}

	/**
	 * Every report file affected by renaming `owner`'s private member: the declaring file, every
	 * file declaring a TRANSITIVE subtype of `owner`, and every file with an `@:access(owner)`
	 * grant. Deduped, in discovery order (declaring file first). All are report files (the index
	 * is report-scoped), hence editable.
	 */
	private static function affectedFiles(owner: String, declFile: String, index: SymbolIndex): Array<String> {
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
		return out;
	}

	/**
	 * Every OTHER indexed file's source (the current file excluded — it is covered
	 * by the in-file completeness check). Read from disk via the paths the index
	 * holds, since `SymbolIndex` retains no sources; a file that cannot be read is
	 * skipped. Used ONLY for the cross-file reflection-string guard. WANT: a
	 * `SymbolIndex.sourceOf(file)` accessor would reuse the already-parsed sources
	 * and drop this disk read entirely.
	 */
	private static function otherIndexedSources(index: SymbolIndex, currentFile: String): Array<String> {
		final out: Array<String> = [];
		for (fi in index.allFiles()) if (fi.file != currentFile) {
			#if (sys || nodejs)
			try
				out.push(sys.io.File.getContent(fi.file))
			catch (exception: Exception)
				continue;
			#end
		}
		return out;
	}

	/**
	 * Whether `name` occurs as a quoted string literal (`'name'` or `"name"`, the
	 * quotes hugging the exact name) in any of `sources`. A reflection reference
	 * (`Reflect.field`, a string-keyed field map) writes the field name as its own
	 * whole string, so this whole-content match catches it while a substring of a
	 * longer string or a bare identifier does not falsely trip it. Refuse-on-doubt:
	 * a comment mention counts too, which is acceptably conservative.
	 */
	private static function referencedAsStringLiteral(name: String, sources: Array<String>): Bool {
		final single: String = '\'$name\'';
		final double: String = '"$name"';
		return sources.exists(src -> src.indexOf(single) >= 0 || src.indexOf(double) >= 0);
	}


	/**
	 * The plugin's memoised resolution-scoped `SymbolIndex` (report files UNION the
	 * configured library roots) when it carries a resolution scope, else null — the
	 * field inheritance proof then falls back to the report-only index. Mirrors
	 * `RefactorSupport.lazySymbolIndex`'s host resolution.
	 */
	private static function resolutionIndexOf(plugin: GrammarPlugin): Null<SymbolIndex> {
		final host: Null<SymbolIndexHost> = (plugin is SymbolIndexHost) ? cast plugin : null;
		return (host != null && host.hasResolutionScope()) ? host.resolutionIndex() : null;
	}


	/**
	 * Whether `name` is distinctive enough that a word-boundary match inside a comment is
	 * very unlikely to be prose: it carries an underscore or an uppercase letter (`_x`,
	 * `yMul`, `MAX_SIZE`). An all-lowercase name (`container`, `db`, `mixed`) is a common
	 * word or file-extension token, so a comment mention is treated as a blocker rather
	 * than renamed along with the code — avoiding prose / filename corruption in comments.
	 */
	private static function isDistinctiveName(name: String): Bool {
		for (i in 0...name.length) {
			final c: Int = StringTools.fastCodeAt(name, i);
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
			final off: Int = RefactorSupport.identTokenOffset(source, new Span(recvSpan.to, faSpan.to), name);
			if (off >= 0) bare.push({ off: off, cls: cls });
		} else {
			typed.push({ recv: recv, fa: node });
			if (!recvNames.contains(rn)) recvNames.push(rn);
		}
	}


	/**
	 * Attribute every `recv.name` access in `typed` by the receiver's declared type: owner-bound when
	 * the type is `ownerName` or a subtype of it (pushed to `ownerBound`), a provably DIFFERENT owner
	 * for any other resolvable type (pushed to `ignore`); an access whose receiver binding or type
	 * cannot be resolved is left in NEITHER (uncovered — block).
	 */
	private static function attributeTypedRefs(
		typed: Array<{ recv: QueryNode, fa: QueryNode }>, recvNames: Array<String>, tree: QueryNode, source: String, name: String,
		ownerName: String, plugin: GrammarPlugin, shape: RefShape, resolutionIndex: SymbolIndex, ownerBound: Array<Span>,
		ignore: Array<Span>, seenOwner: Array<Int>, seenIgnore: Array<Int>
	): Void {
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
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
			final off: Int = RefactorSupport.identTokenOffset(source, new Span(recvSpan.to, faSpan.to), name);
			if (off < 0) continue;
			if (recvType == ownerName || resolutionIndex.isSubtype(recvType, ownerName))
				RefactorSupport.pushUniqueSpan(ownerBound, seenOwner, off, name.length);
			else
				RefactorSupport.pushUniqueSpan(ignore, seenIgnore, off, name.length);
		}
	}


	/**
	 * Every same-name occurrence in the DECLARING file that provably binds to a DIFFERENT binding than
	 * the one at `declFrom` - a param / loop var / sibling local sharing the name. Attributed via the
	 * scope resolver's per-hit binding: a Decl self-binds, a Read / Write follows its `bindingSpan`.
	 * Such occurrences are excluded from the completeness scan (neither renamed with `declFrom`'s
	 * binding nor a blocker). An occurrence whose binding is unresolved is NOT returned - it stays
	 * uncovered so the completeness gate blocks the rename (fail-closed).
	 */
	private static function otherBindingSpans(source: String, tree: QueryNode, name: String, declFrom: Int, shape: RefShape): Array<Span> {
		final out: Array<Span> = [];
		final seen: Array<Int> = [];
		for (h in Refs.find(name, tree, shape)) {
			final bindingSpan: Null<Span> = h.bindingSpan;
			final boundFrom: Null<Int> = h.kind == RefKind.Decl ? h.span.from : (bindingSpan == null ? null : bindingSpan.from);
			if (boundFrom == null || boundFrom == declFrom) continue;
			RefactorSupport.pushUniqueSpan(out, seen, RefactorSupport.identTokenOffset(source, h.span, name), name.length);
		}
		return out;
	}

	/**
	 * Whether `newName` would collide with a binding reachable from `decl`'s scope. A FIELD / Constant
	 * (class-level) stays whole-file: it is visible everywhere in the type, and its inherited-member
	 * redefinition is separately gated. A Local / Param / CatchVar is SCOPE-AWARE - `newName` conflicts
	 * only when it occurs in `decl`'s enclosing function (an enclosing / sibling local or param) or at
	 * class / file level (an own member, static, or import); an occurrence inside an UNRELATED function
	 * body (one that does not enclose `decl`) is out of scope. An inherited member in another file never
	 * appears in-file, so a local legally shadowing one still renames.
	 */
	private static function collidesInScope(decl: NamedDecl, source: String, tree: QueryNode, newName: String, shape: RefShape): Bool {
		final span: Null<Span> = decl.span;
		if (span == null) return true;
		final cat: NamingCategory = decl.category;
		if (cat != NamingCategory.Local && cat != NamingCategory.Param && cat != NamingCategory.CatchVar)
			return RefactorSupport.referencedInRange(source, newName, 0, source.length, []);
		final excluded: Array<Span> = [];
		collectUnrelatedFunctionSpans(tree, shape.functionKinds ?? [], span.from, excluded);
		return RefactorSupport.referencedInRange(source, newName, 0, source.length, excluded);
	}

	/**
	 * Collect the span of every function node that does NOT enclose `declFrom` - an unrelated /
	 * sibling-nested body whose locals & parameters are unreachable from the binding's scope, so a
	 * same-named binding there is not a collision. Recursive; the enclosing function(s) are kept.
	 */
	private static function collectUnrelatedFunctionSpans(
		node: QueryNode, functionKinds: Array<String>, declFrom: Int, out: Array<Span>
	): Void {
		if (functionKinds.contains(node.kind)) {
			final s: Null<Span> = node.span;
			if (s != null && !(s.from <= declFrom && declFrom < s.to)) out.push(s);
		}
		for (child in node.children) collectUnrelatedFunctionSpans(child, functionKinds, declFrom, out);
	}

}

/**
 * A computed rename for one declaration: every span to rewrite and the new
 * identifier to write at each.
 */
private typedef RenameEdits = {
	final occurrences: Array<Span>;
	final name: String;
};

/**
 * A resolved cross-file rename candidate: the parsed declaring file, the flagged binding's cursor
 * offset, the old / corrected names, the owning type, and whether the old name is distinctive
 * (drives the comment-along gate). Passed from `crossFileCandidate` to the per-file span pass.
 */
private typedef CrossFileCandidate = {
	final declFile: String;
	final source: String;
	final tree: QueryNode;
	final declFrom: Int;
	final oldName: String;
	final targetName: String;
	final ownerName: String;
	final distinctive: Bool;
};
