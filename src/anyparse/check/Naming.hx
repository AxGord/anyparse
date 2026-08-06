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

	/**
	 * A lowercase head over an all-uppercase / digit tail of four or more characters - see `normalizerArtifactName`.
	 */
	private static final ARTIFACT_NAME_PATTERN: EReg = new EReg("^[a-z][A-Z0-9]{4,}$", '');

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
		final resolutionIndex: Null<SymbolIndex> = RefactorSupport.resolutionIndexOf(plugin) ?? index;

		final edits: Array<{ span: Span, text: String }> = [];
		for (decl in support.project(tree)) {
			final rename: Null<Array<{ span: Span, text: String }>> = renameEditsFor(
				decl, source, tree, policy, shape, plugin, flaggedFroms, otherSources, confinedMemo, resolutionIndex, index,
				violations[0].file
			);
			// Two flagged declarations can want the SAME token: the qualification arm rewrites a bare
			// reference to a MEMBER that may itself be flagged and renamed in this very pass. Overlapping
			// edits have no defined winner in `applyEdits` (`dropContainedEdits` resolves by array index),
			// so the second declaration DEFERS - `naming` is a full-scope check, and a rename deferred by a
			// same-file conflict re-fires on the next pass, by which time the first one has landed.
			if (rename != null && !RefactorSupport.editsOverlapAny(rename, edits)) for (edit in rename) edits.push(edit);
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
		final resolutionIndex: SymbolIndex = RefactorSupport.resolutionIndexOf(plugin) ?? idx;
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
	 * location to report), as is one no rule applies to and one whose name is a
	 * language idiom outside any policy (`NamedDecl.reservedName`).
	 */
	public static function violationsFor(file: String, decls: Array<NamedDecl>, policy: NamingPolicy): Array<Violation> {
		final out: Array<Violation> = [];
		for (decl in decls) {
			final span: Null<Span> = decl.span;
			if (span == null || decl.reservedName == true) continue;
			final rule: Null<NamingRule> = applicableRule(decl, policy);
			if (rule == null) continue;
			final artifact: Null<String> = artifactCorrection(decl.name, rule);
			if (artifact == null && rule.format.match(decl.name)) continue;
			out.push({
				file: file,
				span: span,
				rule: 'naming',
				severity: Severity.Warning,
				message: artifact == null
					? '${rule.label}: \'${decl.name}\''
					: 'all-caps tail after a lowercase head (normalizer artifact): \'${decl.name}\''
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
	 * The lowercased spelling of `name` when it is a normalizer ARTIFACT - a lowercase head over an
	 * all-uppercase / digit tail of at least FOUR characters (`hEIGHT`, `wIDTH`), the shape the
	 * former first-letter-lowercasing normalizer produced out of a screaming constant. Null when
	 * `name` is not one, or when lowercasing changes nothing (a digit-only tail such as `x1234`).
	 *
	 * The four-character floor is a deliberate TRADE-OFF, not a complete test. A head plus a
	 * three-letter acronym is a name people write on purpose (`sRGB`, `xDPI`, `dBFS`, `mRNA`) and is
	 * spelled identically to an artifact of a three-letter constant (`HTML` -> `hTML`), so the two
	 * cannot be told apart here. The floor buys silence on the deliberate names at the cost of
	 * letting three-letter-acronym artifacts through; lowercasing an `sRGB` someone chose is the
	 * worse error, since the check's own autofix would destroy it.
	 */
	private static function normalizerArtifactName(name: String): Null<String> {
		if (!ARTIFACT_NAME_PATTERN.match(name)) return null;
		final lowered: String = name.toLowerCase();
		return lowered == name ? null : lowered;
	}

	/**
	 * The lowercased correction for a name the policy's `format` ACCEPTS but that is a normalizer
	 * artifact, or null when `name` is not one or the correction is not what `rule` wants. The
	 * `rule.format.match(lowered)` gate is load-bearing: it keeps the arm inside whatever policy
	 * governs the file - a checkstyle policy spelling the category UPPER_SNAKE rejects `height`, and
	 * there the arm stays silent instead of reporting a violation nothing can correct - and it
	 * guarantees every reported artifact is fixable.
	 */
	private static function artifactCorrection(name: String, rule: NamingRule): Null<String> {
		final lowered: Null<String> = normalizerArtifactName(name);
		return lowered != null && rule.format.match(lowered) ? lowered : null;
	}

	/**
	 * The corrected spelling for `name` under `rule`: the normalizer ARTIFACT correction when the
	 * name is one, else the rule's own `normalize`. Null when neither applies, the result is
	 * unchanged, or it does not itself satisfy the rule's format. The single decision point for
	 * what a name should become, shared by the report side and both fix paths so they cannot drift.
	 */
	private static function correctedName(name: String, rule: NamingRule): Null<String> {
		final artifact: Null<String> = artifactCorrection(name, rule);
		if (artifact != null) return artifact;
		final normalize: Null<String -> Null<String>> = rule.normalize;
		if (normalize == null) return null;
		final newName: Null<String> = normalize(name);
		return newName == null || newName == name || !rule.format.match(newName) ? null : newName;
	}

	/**
	 * Is the rename of `decl`'s binding provably complete within `source`? A
	 * declaration the grammar marked `renameUnsafe` (a structural / anon-struct
	 * field, a property backed by physical accessors) never is. Otherwise a
	 * function-body-scoped binding always is; a private field, private
	 * static-final constant or private method is only when the cross-file `index`
	 * plus in-file checks prove it cannot be referenced from outside its file.
	 * Every other category (types, public members) is not.
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
		if (!isConfinableMemberCategory(category) || decl.mods.contains('public') || index == null) return false;
		// A METHOD carries two hazards no field has. An `override` binds the name to the
		// SUPERTYPE's declaration, so renaming the override alone orphans it. And an
		// `implicitlyReachable` member - one carrying metadata, which a macro / `@:keep` /
		// framework can reach by NAME - has references no identifier-level completeness proof
		// sees. Both are refusals; the inherited-member and confinement proofs cover the rest.
		if (category == NamingCategory.Method && (decl.mods.contains('override') || decl.implicitlyReachable == true)) return false;
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

	/**
	 * Whether `category` is a type MEMBER whose privacy the cross-file index can turn into a
	 * confinement proof - a field, a static-final constant or a method. A type or a
	 * function-body binding is neither (the former is never confinable, the latter always is).
	 */
	private static inline function isConfinableMemberCategory(category: NamingCategory): Bool {
		return category == NamingCategory.Field || category == NamingCategory.Constant || category == NamingCategory.Method;
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
	private static function renameEditsFor(
		decl: NamedDecl, source: String, tree: QueryNode, policy: NamingPolicy, shape: RefShape, plugin: GrammarPlugin,
		flaggedFroms: Array<Int>, otherSources: Array<String>, confinedMemo: Map<String, Bool>, resolutionIndex: Null<SymbolIndex>,
		index: Null<SymbolIndex>, file: String
	): Null<Array<{ span: Span, text: String }>> {
		final span: Null<Span> = decl.span;
		if (span == null || !flaggedFroms.contains(span.from) || !isRenameSafe(decl, source, index, otherSources, confinedMemo))
			return null;
		final rule: Null<NamingRule> = applicableRule(decl, policy);
		if (rule == null) return null;
		final corrected: Null<String> = correctedName(decl.name, rule);
		if (corrected == null) return null;
		final newName: String = corrected;
		// A private INSTANCE field renamed to `_x` must not REDEFINE a field named `_x`
		// inherited from a supertype - Haxe rejects "Redefinition of variable in subclass"
		// (verified). A METHOD has the same hazard with a different message ("Field f should be
		// declared with 'override' since it is inherited from superclass"), so both member
		// categories take this gate. A local / param renamed to a bare name only SHADOWS an
		// inherited member, which Haxe permits (verified) - the whole-file textual collision scan
		// below covers that case. The proof walks the FULL supertype
		// closure through `resolutionIndex` (the RESOLUTION scope — report files UNION the
		// configured libraries — when the plugin carries one, else the report index): an `openfl`
		// / `lime` subclass's inherited members are then resolvable rather than unprovable. Skip
		// when the inherited-`_x` possibility cannot be ruled out (a still-unresolvable supertype
		// closure), and skip a member of a `@:rtti` / drill-Node hierarchy whose subtype-ward
		// `@:rtti` only the index reveals (the direct-`@:rtti` case is already `renameUnsafe`):
		// such a class serializes by reflecting on member NAMES, so a rename would break saved files.
		if (decl.category == NamingCategory.Field || decl.category == NamingCategory.Method) {
			final owner: Null<String> = decl.enclosingType;
			if (owner == null || resolutionIndex == null) return null;
			final idx: SymbolIndex = resolutionIndex;
			if (!idx.typeProvablyLacksMember(owner, newName) || idx.transitivelyCarriesRtti(owner)) return null;
		}
		// Collision: a `newName` already bound where the rename lands would be duplicated or shadowed
		// (the re-parse gate accepts it but it does not type-check). Scope-aware for a local /
		// param / catch var - an occurrence in an UNRELATED function does not conflict; a field / constant
		// stays whole-file (see `collidesInScope`). A NON-STATIC member survives the collision when it is
		// the param idiom, by naming the captured occurrences through `this.` (see `qualifyCapturedEdits`);
		// everything else is refused here, before the expensive occurrence resolution below.
		final collides: Bool = collidesInScope(decl, source, tree, newName, shape, resolutionIndex, plugin);
		if (collides && !qualifiableBinding(decl)) return null;
		// Completeness + comment-along: the SAME scope-correct occurrence resolution + classifyOccurrences
		// gate the cross-file path applies to its declaring file — a `#if` / string / `noqa` / resolver-missed
		// active-code occurrence bails, a distinctive comment mention renames along (see `declaringFileRenameSpans`).
		final renameSpans: Null<Array<Span>> = declaringFileRenameSpans(
			source, tree, span.from, decl.name, shape, plugin, isDistinctiveName(decl.name), isBodyScopedCategory(decl.category)
		);
		if (renameSpans == null) return null;
		final spans: Array<Span> = renameSpans;
		final edits: Array<{ span: Span, text: String }> = [for (occ in spans) { span: occ, text: newName }];
		return
			collides ? qualifyCapturedEdits(source, tree, span.from, spans, newName, shape, plugin, edits, resolutionIndex, file) : edits;
	}

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
			case NamingCategory.Field | NamingCategory.Method: !decl.mods.contains('static');
			case NamingCategory.Local | NamingCategory.Param | NamingCategory.CatchVar: true;
			case _: false;
		}
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
		final rewritten: String = RefactorSupport.applyEdits(source, edits);
		final newTree: Null<QueryNode> = CheckScan.parseOrNull(plugin, rewritten);
		if (newTree == null) return null;
		final tr: QueryNode = newTree;
		final mismatch: Array<Capture> = Rename.captureMismatch(rewritten, tr, renameSpans, resolved, newName, declFrom, shape);
		if (mismatch.length == 0) return null;
		final reachable: Bool = Rename.selfReachableBindingAt(source, tree, declFrom, shape);
		final qualification: Null<Qualification> = Rename.qualifyCaptured(
			rewritten, tr, mismatch, newName, shape, reachable, resolutionIndex, file
		);
		if (qualification == null) return null;
		final q: Qualification = qualification;
		switch Rename.verifyQualified(q, renameSpans, resolved, newName, declFrom, plugin, shape) {
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
		for (offset in q.insertions) {
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
	 * no derivable correction (see `correctedName`), a supertype that already declares the name
	 * (Haxe's "Redefinition of variable in subclass"), or a transitive `@:rtti` serialization
	 * hierarchy (renaming a reflected field name breaks saved files). `ownerName` / `resolutionIndex`
	 * drive the inheritance + rtti guards through the resolution scope.
	 */
	private static function correctedFieldName(
		decl: NamedDecl, policy: NamingPolicy, ownerName: String, resolutionIndex: SymbolIndex
	): Null<String> {
		final rule: Null<NamingRule> = applicableRule(decl, policy);
		if (rule == null) return null;
		final newName: Null<String> = correctedName(decl.name, rule);
		if (newName == null) return null;
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
			final fileTree: Null<QueryNode> = file == c.declFile ? c.tree : CheckScan.parseOrNull(plugin, fsrc);
			if (fileTree == null) return null;
			final spans: Null<Array<Span>> = file == c.declFile
				? declaringFileRenameSpans(fsrc, c.tree, c.declFrom, c.oldName, shape, plugin, c.distinctive)
				: otherFileRenameSpans(fsrc, c.oldName, plugin, c.distinctive, c.ownerName, shape, resolutionIndex);
			if (spans == null) return null;
			// A `targetName` already bound where the rename lands would collide once it does - scanned
			// across the OWNER's own hierarchy in this file only, since a sibling hierarchy's same-named
			// member is not reachable from it (see `unrelatedTypeSpans`).
			final unrelated: Array<Span> = unrelatedTypeSpans(fileTree, c.ownerName, shape, resolutionIndex);
			if (RefactorSupport.nameBoundInRange(fsrc, c.targetName, 0, fsrc.length, unrelated, plugin)) return null;
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
	 *
	 * `bodyScoped` marks a binding visible only from its declaration on (a local, a parameter, a
	 * catch variable); an occurrence resolved BEFORE the declaration is then the resolver
	 * over-reaching past a shadowed member and the whole rename is refused. A MEMBER's references
	 * legitimately precede it, so the flag defaults off.
	 *
	 * `extraSpans` carries occurrences of the SAME binding that the reference walker does not
	 * index and the CALLER resolved instead - a simple `$name` string-interpolation read, which
	 * `no-underscore-prefix` collects through the grammar's `stringInterpIdentKind`. They join
	 * the rewritten set and stop blocking the gate; absent, the behaviour is unchanged.
	 */
	private static function declaringFileRenameSpans(
		source: String, tree: QueryNode, declFrom: Int, name: String, shape: RefShape, plugin: GrammarPlugin, distinctive: Bool,
		bodyScoped: Bool = false, ?extraSpans: Array<Span>
	): Null<Array<Span>> {
		final resolved: Array<Span> = Rename.renameOccurrences(source, tree, declFrom, shape);
		if (resolved.length == 0) return null;
		final covered: Array<Span> = extraSpans == null ? resolved : resolved.concat(extraSpans);
		// A body-scoped binding (local / param / catch variable) is visible from its DECLARATION on -
		// no language here hoists one - so an occurrence resolved BEFORE `declFrom` is the scope
		// resolver over-reaching: it binds a whole block to the declaration, while the compiler binds
		// the earlier read to whatever it shadows (a member, a static, an import). Rewriting that read
		// emits an unknown identifier, so the whole rename is refused. Never true for a MEMBER, whose
		// references legitimately precede its declaration - hence the caller-supplied flag.
		if (bodyScoped) for (occ in covered) if (occ.from < declFrom) return null;
		// Attribute every OTHER same-name occurrence to its binding: one provably bound to a DIFFERENT
		// binding (a param / loop var / sibling local sharing the name) is neither a rename target nor a
		// blocker for THIS binding, so it joins the resolved set as an excluded span. An occurrence whose
		// binding is unresolved is left uncovered so the completeness gate below blocks (fail-closed).
		final excluded: Array<Span> = covered.concat(otherBindingSpans(source, tree, name, declFrom, shape));
		final classified: Null<Array<ClassifiedOccurrence>> = RefactorSupport.classifyOccurrences(
			source, name, plugin, 0, source.length, excluded
		);
		if (classified == null) return RefactorSupport.referencedInRange(source, name, 0, source.length, excluded) ? null : covered;
		final spans: Array<Span> = covered.copy();
		// A distinctive comment mention renames along, but only within the binding's own lexical container:
		// the same distinctive name can name an UNRELATED binding elsewhere in the file, and a comment about
		// THAT one must not be rewritten (nor block this rename). A field's container is its type, so its
		// comment-along still spans the whole class.
		final container: Null<Span> = innermostSpanOfKinds(
			tree, shape.scopeKinds.concat(['CaseBranch', 'DefaultBranch']), declFrom, localFunctionDeclSpan(tree, declFrom, shape)
		);
		for (occ in classified) switch occ.kind {
			case OccurrenceClass.CommentTrivia if (distinctive):
				if (container != null && occ.span.from >= container.from && occ.span.from < container.to) spans.push(occ.span);
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
	 * a blocker; a class declaring its OWN `name` is NOT such a case (the ignore arm is supertype-only,
	 * so it stays uncovered and blocks); an occurrence whose binding cannot be proven is left
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
			if (c == ownerName || resolutionIndex.isSubtype(c, ownerName))
				RefactorSupport.pushUniqueSpan(ownerBound, seenOwner, occ.off, name.length);
			else if (resolutionIndex.provablyNotSubtype(c, ownerName) && resolutionIndex.supertypeDeclaresMember(c, name))
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
		final cls: Null<String> = (CheckScan.isClassBodyKind(node.kind) && node.name != null) ? node.name : currentClass;
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
			else if (resolutionIndex.provablyNotSubtype(recvType, ownerName))
				RefactorSupport.pushUniqueSpan(ignore, seenIgnore, off, name.length);
		}
	}


	/**
	 * Every same-name occurrence in the DECLARING file that provably binds to a DIFFERENT binding than
	 * the one at `declFrom` - a param / loop var / sibling local sharing the name. Attributed via the
	 * scope resolver's per-hit binding (a Decl self-binds, a Read / Write follows its `bindingSpan`) AND
	 * verified to sit inside that binding's own lexical container: the resolver can leak a case-branch
	 * local past its branch and mis-bind a bare field use to it, so an occurrence OUTSIDE the attributed
	 * binding's container is NOT excluded. Excluded occurrences drop out of the completeness scan
	 * (neither renamed with `declFrom`'s binding nor a blocker). An occurrence whose binding is
	 * unresolved, or resolves outside its container, is NOT returned - it stays uncovered so the
	 * completeness gate blocks the rename (fail-closed).
	 */
	private static function otherBindingSpans(source: String, tree: QueryNode, name: String, declFrom: Int, shape: RefShape): Array<Span> {
		final out: Array<Span> = [];
		final seen: Array<Int> = [];
		final containerKinds: Array<String> = shape.scopeKinds.concat(['CaseBranch', 'DefaultBranch']);
		for (h in Refs.find(name, tree, shape)) {
			final bindingSpan: Null<Span> = h.bindingSpan;
			final boundFrom: Null<Int> = h.kind == RefKind.Decl ? h.span.from : (bindingSpan == null ? null : bindingSpan.from);
			if (boundFrom == null || boundFrom == declFrom) continue;
			final off: Int = RefactorSupport.identTokenOffset(source, h.span, name);
			if (off < 0) continue;
			// Fail-closed attribution: exclude this occurrence as belonging to a DIFFERENT binding only when
			// it sits inside that binding's own lexical container. A scope resolver can leak a case-branch
			// local past its branch (a `case` opens no scope frame), mis-binding a bare field use to it; such
			// a use lies OUTSIDE the binding's container, so it is left uncovered and the completeness gate
			// blocks the whole rename rather than silently excluding - and orphaning - a real reference.
			final container: Null<Span> = innermostSpanOfKinds(tree, containerKinds, boundFrom);
			if (container == null || off < container.from || off >= container.to) continue;
			RefactorSupport.pushUniqueSpan(out, seen, off, name.length);
		}
		return out;
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
	private static function collidesInScope(
		decl: NamedDecl, source: String, tree: QueryNode, newName: String, shape: RefShape, resolutionIndex: Null<SymbolIndex>,
		plugin: GrammarPlugin
	): Bool {
		final span: Null<Span> = decl.span;
		if (span == null) return true;
		if (!isBodyScopedCategory(decl.category)) {
			// Whole-file EXCEPT the sibling hierarchies sharing the module: a same-named member of an
			// UNRELATED class is not reachable from this one, so it is no collision (see `unrelatedTypeSpans`).
			final owner: Null<String> = decl.enclosingType;
			final unrelated: Array<Span> = (owner == null || resolutionIndex == null)
				? []
				: unrelatedTypeSpans(tree, owner, shape, resolutionIndex);
			return RefactorSupport.nameBoundInRange(source, newName, 0, source.length, unrelated, plugin);
		}
		// A local `inline function` is a function BODY for scope purposes even though it is not a
		// measured `functionKinds` unit (`complexity` folds it into its host): its parameters and
		// locals are visible only inside it, exactly as the plain local form's are. Without the union
		// a sibling helper's same-named parameter read as an in-scope collision and vetoed the strip.
		final funcKinds: Array<String> = (shape.functionKinds ?? []).concat(shape.inlineFunctionKinds ?? []);
		// The binding is visible throughout its innermost enclosing function - INCLUDING the nested closures
		// / local functions that capture it - so a same-named binding anywhere in that function conflicts.
		// Only a function DISJOINT from it (a sibling / unrelated body) is out of scope. Fall back to a
		// whole-file scan when no enclosing function is found (defensive; a local / param always has one).
		// A local `function` statement is EXCLUDED from its own scope lookup: it is both a binding and
		// a function node, and the scope it binds into is the enclosing body. Reading its own span as
		// the scope would make every SIBLING local function look disjoint - and a sibling already
		// holding `newName` is a real collision.
		final enclosing: Null<Span> = innermostSpanOfKinds(tree, funcKinds, span.from, localFunctionDeclSpan(tree, span.from, shape));
		final excluded: Array<Span> = RefactorSupport.structureFieldNameSpans(tree, source, shape);
		if (enclosing != null) collectDisjointFunctionSpans(tree, funcKinds, enclosing, excluded);
		return RefactorSupport.nameBoundInRange(source, newName, 0, source.length, excluded, plugin);
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
	 * The tightest enclosing node span (whose kind is in `kinds`) containing `pos`, or null when none
	 * does. `exclude` drops the node occupying exactly that span from consideration - what a DECLARATION
	 * that is itself a scope opener needs (a local `function` statement), since the scope it binds INTO
	 * is the enclosing one, never its own.
	 */
	private static function innermostSpanOfKinds(node: QueryNode, kinds: Array<String>, pos: Int, ?exclude: Span): Null<Span> {
		// Re-bound as Ints: strict null-safety does not narrow a captured parameter inside the
		// nested walker. A null `exclude` becomes an impossible span, matching nothing.
		final excludeFrom: Int = exclude == null ? -1 : exclude.from;
		final excludeTo: Int = exclude == null ? -1 : exclude.to;
		var bestFrom: Int = -1;
		var best: Null<Span> = null;
		function walk(n: QueryNode): Void {
			final s: Null<Span> = n.span;
			if (
				s != null && s.from <= pos && pos < s.to && kinds.contains(n.kind) && s.from > bestFrom
				&& (s.from != excludeFrom || s.to != excludeTo)
			) {
				bestFrom = s.from;
				best = s;
			}
			for (c in n.children) walk(c);
		}
		walk(node);
		return best;
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
			if (resolutionIndex.provablyNotSubtype(n, ownerName)) out.push(span);
		}
		return out;
	}


	/**
	 * The span of the local FUNCTION declared at `declFrom`, or null when the declaration there is
	 * anything else. A local `function` is the one declaration kind that opens a scope its own NAME
	 * does not bind into - the name belongs to the enclosing body - so every scope lookup made FROM
	 * such a declaration must exclude the declaration's own node. A self-scoped binding (a loop
	 * iterator, a catch variable) is the opposite case and is deliberately not matched: its own node
	 * IS the scope its name lives in.
	 */
	private static function localFunctionDeclSpan(tree: QueryNode, declFrom: Int, shape: RefShape): Null<Span> {
		final kinds: Array<String> = (shape.localFunctionKinds ?? []).concat(shape.inlineFunctionKinds ?? []);
		if (kinds.length == 0) return null;
		var found: Null<Span> = null;
		function walk(n: QueryNode): Void {
			final s: Null<Span> = n.span;
			if (s != null && s.from == declFrom && kinds.contains(n.kind)) found = s;
			for (c in n.children) walk(c);
		}
		walk(tree);
		return found;
	}


	/**
	 * Whether `category` is a binding scoped to one function BODY - a local, a parameter, a catch
	 * variable. The three categories the scope-aware collision proof governs, and the ones whose
	 * references can never precede their declaration.
	 */
	private static inline function isBodyScopedCategory(category: NamingCategory): Bool {
		return category == NamingCategory.Local || category == NamingCategory.Param || category == NamingCategory.CatchVar;
	}

}

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
