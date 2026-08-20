package anyparse.check;

import anyparse.check.Check.CrossFileEdits;
import anyparse.check.Check.CrossFileFix;
import anyparse.check.Check.Violation;
import anyparse.check.ConstantHoist.Hoist;
import anyparse.query.GrammarPlugin;
import anyparse.query.NamingPolicy.NamedDecl;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.NamingPolicy.NamingPolicy;
import anyparse.query.NamingPolicy.NamingRule;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.Refs;
import anyparse.query.Rename;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.query.Uses;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;
using Lambda;

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
 * `namingSupport`; the check skips it.
 *
 * ## Not every odd name is a finding
 *
 * A declaration the grammar marks `contractName` — a field of an anonymous structure / typedef,
 * whose identifier is part of the structural type and of whatever wire format it mirrors — is not
 * reported at all: the project does not own that name, so there is nothing to correct. Distinct
 * from `renameUnsafe` (an accessor-backed property, an `@:rtti` member), which IS the project's
 * own name and stays reported — only the autofix keeps away from it.
 */
@:nullSafety(Strict)
final class Naming implements Check implements CrossFileFix {

	/**
	 * A lowercase head over an all-uppercase / digit tail of four or more characters - see `normalizerArtifactName`.
	 */
	private static final ARTIFACT_NAME_PATTERN: EReg = new EReg("^[a-z][A-Z0-9]{4,}$", '');

	/**
	 * The member renames this `--fix` PASS has already accepted, across BOTH seams the pass drives
	 * (`crossFileFix` and `fix`) — see `RenameClaims`.
	 */
	private final _runClaims: RenameClaims = new RenameClaims();

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
	 * `@:access`, no `@:allow`, no skip-parse file that could hide one) and no
	 * OTHER indexed file names it through a reflection call
	 * (`reflectionNamesInOtherFiles` — an AST verdict, not a text scan). Every
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

		// Hoisted ONCE per fix() call (not per finding): the flagged names any OTHER indexed
		// file reaches through a reflection call's string argument (the cross-file reflection
		// rename guard), plus a per-owner confinement memo so a type with many flagged private
		// members runs the project-wide confinement scan a single time.
		final decls: Array<NamedDecl> = support.project(tree);
		final flaggedNames: Array<String> = [];
		for (decl in decls) {
			final s: Null<Span> = decl.span;
			if (s != null && flaggedFroms.contains(s.from) && !flaggedNames.contains(decl.name)) flaggedNames.push(decl.name);
		}
		final reflectionNames: Array<String> = index == null
			? []
			: reflectionNamesInOtherFiles(index, violations[0].file, flaggedNames, plugin, support);
		final confinedMemo: Map<String, Bool> = [];
		// The inherited-member proof of a `_`-prefix field rename walks the FULL supertype
		// closure, so it resolves through the plugin's resolution scope (report files UNION the
		// configured libraries) when present — a field of an `openfl` / `lime` subclass is then
		// provable rather than blocked as unresolvable. The report-scope `index` still backs the
		// confinement / reflection proofs (they reason about report-file reachability).
		final resolutionIndex: Null<SymbolIndex> = RefactorSupport.resolutionIndexOf(plugin) ?? index;

		// The HOIST arm runs FIRST. A flagged LOCAL that is an author-intended CONSTANT — an
		// UPPER_SNAKE name over a compile-time-constant initializer — moves to its enclosing type
		// KEEPING its spelling, which at class level is what the Constant rule wants; camelCasing it
		// in place would destroy the intent the name states. Every gate failure leaves the
		// declaration to the ordinary rename arm below, silently. The occupancy gate reads THIS
		// check's own occurrence resolution, handed over as a resolver so `ConstantHoist` needs
		// nothing private of it.
		final hoists: Array<Hoist> = ConstantHoist.hoistsFor(
			decls, source, tree, policy, plugin, support, flaggedFroms, resolutionIndex, violations[0].file,
			(declFrom, name) ->
				resolutionIndex == null
					? null
					: declaringFileRenameSpans(
						source, tree, declFrom, name, shape, plugin, isDistinctiveName(name), true,
						{ index: resolutionIndex, file: violations[0].file }
					)
		);
		final hoistedFroms: Array<Int> = [for (h in hoists) h.declFrom];
		final edits: Array<{ span: Span, text: String }> = ConstantHoist.edits(hoists);
		final claims: Array<DeclRename> = [];
		for (decl in decls) {
			final declSpan: Null<Span> = decl.span;
			if (declSpan != null && hoistedFroms.contains(declSpan.from)) continue;
			final rename: Null<DeclRename> = renameEditsFor(
				decl, source, tree, policy, shape, plugin, flaggedFroms, reflectionNames, confinedMemo, resolutionIndex, index,
				violations[0].file
			);
			final owner: Null<String> = RenameClaims.memberOwnerOf(decl);
			if (rename == null || defersToAnAcceptedRename(rename, edits, claims, owner, resolutionIndex)) continue;
			_runClaims.claim(owner, rename.newName, resolutionIndex);
			claims.push(rename);
			for (edit in rename.edits) edits.push(edit);
		}
		return edits;
	}

	/**
	 * Cross-file autofix (the `CrossFileFix` seam): rename each flagged member whose references can reach
	 * beyond its declaring file — a NON-confined private field / constant / method (reachable from its
	 * subtypes / `@:access`-grant files), or ANY public one (reachable from anywhere). The single-file
	 * `fix` skips both (a non-confined member is not provably contained; a public one is refused outright
	 * by `isRenameSafe`); here the rename is proven complete across EVERY affected report file and emitted
	 * as one atomic multi-file edit set. The declaring file resolves scope-correctly (the T29 occurrence
	 * set + completeness gate), and a collision with a constructor PARAMETER there is repaired by
	 * qualifying through `this.` rather than refused; each other affected file classifies every occurrence
	 * of the old name — an `ActiveCode` one is a reference to rename, a `CommentTrivia` one renames along
	 * when the name is distinctive, and a `ConditionalRaw` / `StringLiteral` / `DirectiveComment`
	 * occurrence (or a `targetName` already colliding in a file, an unresolvable hierarchy, an `@:rtti` /
	 * reflection-string hazard) turns the WHOLE rename report-only. A public member's affected set is every
	 * scope file MENTIONING the name (plus the owner's own hierarchy), so the completeness proof spans the
	 * whole lint scope: a narrow `--fix` scope refuses rather than half-applying. The caller
	 * (`apq lint --fix`) commits every affected file or none.
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
			final rename: Null<CrossFileRename> = crossFileRenameFor(v, sourceByFile, support, shape, plugin, idx, resolutionIndex);
			if (rename == null || _runClaims.defers(rename.owner, rename.newName, resolutionIndex)) continue;
			_runClaims.claim(rename.owner, rename.newName, resolutionIndex);
			out.push(rename.slices);
		}
		return out;
	}

	/**
	 * Whether `rename` must DEFER to an edit already accepted in this pass, for any of the three
	 * reasons a same-pass conflict takes.
	 *
	 * Its spans OVERLAP an accepted edit: two flagged declarations can want the SAME token, because
	 * the qualification arm rewrites a bare reference to a MEMBER that may itself be flagged and
	 * renamed in this very pass, and overlapping edits have no defined winner in `applyEdits`
	 * (`dropContainedEdits` resolves by array index).
	 *
	 * Or an accepted rename already CLAIMED the same new name over an overlapping SCOPE. That reason
	 * exists because `collidesInScope` reads the ORIGINAL source, where the new name does not yet
	 * exist: `CAPS` and `Caps` both correcting to `_caps` each see a clean scope and would otherwise
	 * both land, producing the duplicate declaration `haxe` rejects. Overlap, not equality, is the
	 * scope test - a file-wide member claim covers every function scope inside it, and a closure's
	 * scope is nested in its host's, while two DISJOINT function scopes genuinely may share a target
	 * name (`remove(__id)` and `for (__id in ...)` both correcting to `id`).
	 *
	 * Or a rename accepted for ANOTHER FILE of this pass already claimed the same new name on a type in
	 * the same inheritance chain (`RenameClaims`, which `owner` and `index` address). The two
	 * reasons above are file-local, and `claims` only ever holds this one `fix(source, ...)` call's
	 * renames - a pass also drives `crossFileFix`, and a superclass and its subclass do not even take
	 * the same seam, since a type with a subtype is never confined.
	 *
	 * Deferral is not refusal, but the two kinds recover differently. A file-local loser re-fires on the
	 * next `--fix` pass: `naming` is a full-scope check and the file it lost in was edited, so the
	 * driver keeps it active, and by then the ordinary collision scan judges it against a source that
	 * holds the name. A RUN-CLAIM loser may be the only finding in its file, in which case that file
	 * receives no edit, drops out of the driver's `active` set, and waits for the next `--fix` RUN
	 * instead - which is why `RenameClaims` says "a later pass or run".
	 */
	private function defersToAnAcceptedRename(
		rename: DeclRename, edits: Array<{ span: Span, text: String }>, claims: Array<DeclRename>, owner: Null<String>,
		index: Null<SymbolIndex>
	): Bool {
		if (RefactorSupport.editsOverlapAny(rename.edits, edits)) return true;
		for (c in claims) if (c.newName == rename.newName && c.scope.from < rename.scope.to && rename.scope.from < c.scope.to) return true;
		return _runClaims.defers(owner, rename.newName, index);
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
			if (span == null || decl.reservedName == true || decl.contractName == true) continue;
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

	/**
	 * Whether `category` is a type MEMBER whose privacy the cross-file index can turn into a
	 * confinement proof - a field, a static-final constant or a method. A type or a
	 * function-body binding is neither (the former is never confinable, the latter always is).
	 */
	private static inline function isConfinableMemberCategory(category: NamingCategory): Bool {
		return category == NamingCategory.Field || category == NamingCategory.Constant || category == NamingCategory.Method;
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
	private static inline function isBodyScopedCategory(category: NamingCategory): Bool {
		return category == NamingCategory.Local || category == NamingCategory.Param || category == NamingCategory.CatchVar;
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
		decl: NamedDecl, source: String, index: Null<SymbolIndex>, reflectionNames: Array<String>, confinedMemo: Map<String, Bool>
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
		// Cross-file reflection guard: a private member reached from ANOTHER file by a
		// reflection call naming it (`Reflect.field(x, 'name')`) breaks silently after a
		// rename — the identifier-level confinement proof cannot see it. The names come from
		// the grammar's own AST projection (`NamingSupport.reflectionMemberNames`), NOT from a
		// text scan: a string that merely SPELLS the member (a menu-action id, an asset key,
		// a `case 'name':`) is not a reference to it and must not veto the rename. The
		// declaring file is already covered by the in-file completeness check.
		if (reflectionNames.contains(decl.name)) return false;
		// Memoize confinement per owner-type within this fix() call: a type with
		// many flagged private constants would otherwise redo the identical
		// project-wide subtype / access-grant / `@:allow` scan once per finding.
		// Keyed by owner AND member: the skipped-file half of the proof is per-NAME now (a file
		// the grammar cannot read can only reach a member it spells), so two members of one type
		// no longer share an answer.
		final memoKey: String = '$owner\t${decl.name}';
		final cached: Null<Bool> = confinedMemo[memoKey];
		if (cached != null) return cached;
		final confined: Bool = RefactorSupport.isPrivateMemberConfined(owner, decl.name, source, index);
		confinedMemo[memoKey] = confined;
		return confined;
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
		flaggedFroms: Array<Int>, reflectionNames: Array<String>, confinedMemo: Map<String, Bool>, resolutionIndex: Null<SymbolIndex>,
		index: Null<SymbolIndex>, file: String
	): Null<DeclRename> {
		final span: Null<Span> = decl.span;
		if (span == null || !flaggedFroms.contains(span.from) || !isRenameSafe(decl, source, index, reflectionNames, confinedMemo))
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
			if (!idx.typeProvablyLacksMember(owner, newName, file) || idx.transitivelyCarriesRtti(owner)) return null;
		}
		// Collision: a `newName` already bound where the rename lands would be duplicated or shadowed
		// (the re-parse gate accepts it but it does not type-check). Scope-aware for a local /
		// param / catch var - an occurrence in an UNRELATED function does not conflict; a field / constant
		// stays whole-file (see `collidesInScope`). A NON-STATIC member survives the collision when it is
		// the param idiom, by naming the captured occurrences through `this.` (see `qualifyCapturedEdits`);
		// everything else is refused here, before the expensive occurrence resolution below.
		final collides: Bool = collidesInScope(decl, source, tree, newName, shape, resolutionIndex, plugin);
		if (collides && !qualifiableBinding(decl)) return null;
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
		if (renameSpans == null) return null;
		final spans: Array<Span> = renameSpans;
		final edits: Array<{ span: Span, text: String }> = [for (occ in spans) { span: occ, text: newName }];
		final scope: Span = claimScope(tree, shape, span.from, bodyScoped, source.length);
		if (!collides) return { newName: newName, edits: edits, scope: scope };
		final qualified: Null<Array<{ span: Span, text: String }>> = qualifyCapturedEdits(
			source, tree, span.from, spans, newName, shape, plugin, edits, resolutionIndex, file
		);
		return qualified == null ? null : { newName: newName, edits: qualified, scope: scope };
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
		return enclosingScopeSpan(tree, funcKinds, from, shape) ?? whole;
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
	 * skipped: not a member this path owns (see `crossFileCategory`), something the single-file path
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
		final declTree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (declTree == null) return null;
		final tree: QueryNode = declTree;
		final decl: Null<NamedDecl> = support.project(tree).find(d -> d.span != null && d.span.from == vspan.from);
		if (decl == null) return null;
		// Candidate: a NON-confined private field / constant the single-file `fix` skips, or ANY public
		// member - `isRenameSafe` refuses every public declaration, so this is a public member's only path.
		if (decl.renameUnsafe == true) return null;
		final isPublic: Bool = decl.mods.contains('public');
		if (!crossFileCategory(decl)) return null;
		final owner: Null<String> = decl.enclosingType;
		if (owner == null) return null;
		final ownerName: String = owner;
		// A METHOD a SUBTYPE overrides renames as a FAMILY: the override is not a candidate of its own
		// (`crossFileCategory` turns one away), and renaming the base alone leaves `override function
		// __draw` overriding nothing - which the completeness gate catches across FILES, where the
		// subtype's declaration is an occurrence no receiver attributes, but not within ONE file. The
		// family carries every such declaration into the same edit set; `null` means one same-named
		// declaration's relation to the owner is unprovable, and a partial family is worse than none.
		// Asked of the RESOLUTION index, the superset - a family it reports too large only refuses more.
		final family: Null<Array<OverrideFamilyMember>> = decl.category == NamingCategory.Method
			? resolutionIndex.overrideFamilyOf(ownerName, decl.name)
			: [];
		if (family == null) return null;
		final overrides: Array<OverrideFamilyMember> = family;
		// A confined PRIVATE member is the single-file path's job; only a non-confined one crosses files.
		// A PUBLIC member is never confined in that sense - any file holding a value of the owner's type
		// reaches it - so the proof does not apply and it always crosses.
		if (!isPublic && RefactorSupport.isPrivateMemberConfined(ownerName, decl.name, source, index)) return null;
		// No reflection guard here, deliberately. `isRenameSafe`'s exists because the single-file path
		// never looks at another file; this path DOES - a public member's affected set is every scope file
		// mentioning the name (`publicAffectedFiles`), and `otherFileRenameSpans` already refuses on a
		// name-shaped string literal in any of them. Measured: with a duplicate AST-projected guard
		// removed, `Reflect.field(x, '__size')` in the declaring file AND in another file both still
		// refuse. A second mechanism answering the same question would only add a disk read per candidate
		// and a gate no in-memory test can reach.
		// Unresolvable hierarchy: a skip-parse file could hide a subtype / grant we never see; an
		// `@:allow` grants an unenumerable type; a non-unique owner makes the subtype match ambiguous.
		if (index.skippedFiles().length > 0 || source.indexOf('@:allow') >= 0 || index.declaringFiles(ownerName).length != 1) return null;
		final targetName: Null<String> = correctedFieldName(decl, support.policyFor(declFile), ownerName, resolutionIndex, declFile);
		return targetName == null ? null : {
			declFile: declFile,
			source: source,
			tree: tree,
			declFrom: vspan.from,
			oldName: decl.name,
			targetName: targetName,
			ownerName: ownerName,
			distinctive: isDistinctiveName(decl.name),
			isPublic: isPublic,
			family: overrides
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
		decl: NamedDecl, policy: NamingPolicy, ownerName: String, resolutionIndex: SymbolIndex, declFile: String
	): Null<String> {
		final rule: Null<NamingRule> = applicableRule(decl, policy);
		if (rule == null) return null;
		final newName: Null<String> = correctedName(decl.name, rule);
		return if (newName == null)
			null
		else if (
			!resolutionIndex.typeProvablyLacksMember(ownerName, newName, declFile) || resolutionIndex.transitivelyCarriesRtti(ownerName)
		)
			null
		else
			newName;
	}

	/**
	 * The cross-file rename fixing one flagged NON-confined private, or public, field / constant / method,
	 * or null when it cannot be proven complete. Resolves the candidate (`crossFileCandidate`), then
	 * collects and gates each affected file's occurrence spans; a bail in ANY file makes the whole rename
	 * report-only. Returns the per-file `CrossFileEdits` slices.
	 */
	private static function crossFileRenameFor(
		v: Violation, sourceByFile: Map<String, String>, support: NamingSupport, shape: RefShape, plugin: GrammarPlugin,
		index: SymbolIndex, resolutionIndex: SymbolIndex
	): Null<CrossFileRename> {
		final candidate: Null<CrossFileCandidate> = crossFileCandidate(v, sourceByFile, support, plugin, index, resolutionIndex);
		if (candidate == null) return null;
		final c: CrossFileCandidate = candidate;
		final slices: Array<CrossFileEdits> = [];
		final hierarchy: Array<String> = affectedFiles(c.ownerName, c.declFile, index);
		final scanned: Array<String> = c.isPublic ? publicAffectedFiles(hierarchy, c.oldName, index, sourceByFile) : hierarchy;
		// An override the edit set cannot reach makes the base unrenameable: the family is resolved
		// against the RESOLUTION index, which sees files the lint scope does not, and half a family
		// leaves a declaration overriding nothing.
		for (fm in c.family) if (!scanned.contains(fm.file)) return null;
		for (file in scanned) {
			final fileSource: Null<String> = sourceByFile[file];
			if (fileSource == null) return null;
			final fsrc: String = fileSource;
			final fileTree: Null<QueryNode> = file == c.declFile ? c.tree : CheckScan.parseOrNull(plugin, fsrc);
			if (fileTree == null) return null;
			final familySpans: Array<Span> = familyOccurrences(c.family, file, fsrc, fileTree, shape);
			final spans: Null<Array<Span>> = file == c.declFile
				? declaringFileRenameSpans(
					fsrc, c.tree, c.declFrom, c.oldName, shape, plugin, c.distinctive, false,
					{ index: resolutionIndex, file: c.declFile, ownerName: c.ownerName }, familySpans
				)
				: otherFileRenameSpans(fsrc, c.oldName, plugin, c.distinctive, c.ownerName, shape, resolutionIndex, file, familySpans);
			if (spans == null) return null;
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
			final edits: Null<Array<{ span: Span, text: String }>> = if (!RefactorSupport.nameBoundInRange(
				fsrc, c.targetName, 0, fsrc.length, unrelated, plugin
			))
				baseEdits;
			else if (file != c.declFile)
				null;
			else
				qualifyCapturedEdits(fsrc, c.tree, c.declFrom, spans, c.targetName, shape, plugin, baseEdits, resolutionIndex, file);
			if (edits == null) return null;
			// Re-bound: a narrowed local does not stay narrowed inside an anonymous structure literal.
			final fileEdits: Array<{ span: Span, text: String }> = edits;
			if (spans.length > 0) slices.push({ file: file, edits: fileEdits });
		}
		return slices.length == 0 ? null : { slices: slices, owner: c.ownerName, newName: c.targetName };
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
		for (fm in family) if (fm.file == file) for (occ in Rename.renameOccurrences(source, tree, fm.declFrom, shape)) if (
			!out.exists(s -> s.from == occ.from)
		)
			out.push(occ);
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
	 */
	private static function declaringFileRenameSpans(
		source: String, tree: QueryNode, declFrom: Int, name: String, shape: RefShape, plugin: GrammarPlugin, distinctive: Bool,
		bodyScoped: Bool = false, ?ctx: RenameContext, ?familySpans: Array<Span>
	): Null<Array<Span>> {
		// A subtype declared beside its base overrides the member in THIS file; its declaration and own
		// reads are rename targets, and excluded from the completeness scan for the same reason the
		// base's own occurrences are.
		final family: Array<Span> = familySpans ?? [];
		final covered: Array<Span> = Rename.renameOccurrences(source, tree, declFrom, shape);
		if (covered.length == 0) return null;
		// A body-scoped binding (local / param / catch variable) is visible from its DECLARATION on -
		// no language here hoists one - so an occurrence resolved BEFORE `declFrom` is the scope
		// resolver over-reaching: it binds a whole block to the declaration, while the compiler binds
		// the earlier read to whatever it shadows (a member, a static, an import). Rewriting that read
		// emits an unknown identifier, so the whole rename is refused. Never true for a MEMBER, whose
		// references legitimately precede its declaration - hence the caller-supplied flag. Asked
		// first of the two refusals: it walks `covered`, while the interpolation one below re-walks
		// the whole tree.
		if (bodyScoped) for (occ in covered) if (occ.from < declFrom) return null;
		// A `$name` read whose identifier token is not in the raw bytes — an escape-spelled `$`
		// or name — is DROPPED by `renameOccurrences`, not rewritten, so the rename would strand
		// it on a name the fix has removed. `rename` refuses the same shape; the completeness
		// scan below cannot see it, since the occurrence sits inside a string literal.
		if (RefactorSupport.unrewrittenInterpRead(Refs.find(name, tree, shape), declFrom, covered) != null) return null;
		// An unparsed conditional-compilation region is the same drop one level lower: its interior
		// projects no nodes at all, so neither `renameOccurrences` nor the completeness scan below can
		// see a read of `name` written inside it, and the fix would strand it on the old spelling.
		if (RefactorSupport.opaqueCondRegionMentioning(tree, source, name, shape) != null) return null;
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
		final ownerBound: Array<Span> = [for (s in attributed.typedBound) if (!RefactorSupport.offsetWithinAny(s.from, covered)) s];
		// A receiver that is a TYPE, not a value: `Event.ACTIVATE` beside a parameter named `Event`
		// projects the same `IdentExpr` as a read of that parameter, so the resolver leaves it
		// unattributed and the gate refuses. Discount it when BOTH hold — the identifier binds to no
		// value visible there, and the index resolves the name to a type in this file's scope.
		final typeRefs: Array<Span> = ctx == null ? [] : typeReferenceSpans(source, tree, name, shape, plugin, ctx);
		// A `package` / `import` path is a dotted module path, not a reference — a field named after
		// its own package (`package touches;` beside `var touches`) or after a package some import
		// traverses would otherwise leave an unattributable occurrence and veto the rename.
		final excluded: Array<Span> = covered.concat(otherBindingSpans(source, tree, name, declFrom, shape))
			.concat(ownerBound)
			.concat(foreign)
			.concat(typeRefs)
			.concat(family)
			.concat(RefactorSupport.modulePathSpans(tree, shape));
		final classified: Null<Array<ClassifiedOccurrence>> = RefactorSupport.classifyOccurrences(
			source, name, plugin, 0, source.length, excluded
		);
		final renamed: Array<Span> = mergeUniqueSpans(covered.concat(ownerBound), family);
		if (classified == null) return RefactorSupport.referencedInRange(source, name, 0, source.length, excluded) ? null : renamed;
		final spans: Array<Span> = renamed;
		// A distinctive comment mention renames along, but only within the binding's own lexical container:
		// the same distinctive name can name an UNRELATED binding elsewhere in the file, and a comment about
		// THAT one must not be rewritten (nor block this rename). A field's container is its type, so its
		// comment-along still spans the whole class.
		final container: Null<Span> = enclosingScopeSpan(tree, shape.scopeKinds.concat(['CaseBranch', 'DefaultBranch']), declFrom, shape);
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
	 * a blocker; a class declaring its OWN `name` is NOT such a case (the ignore arm is supertype-only,
	 * so it stays uncovered and blocks); an occurrence whose binding cannot be proven is left
	 * uncovered so the completeness gate blocks the whole rename (fail-closed). A distinctive-name
	 * `CommentTrivia` still renames along. Null on a parse failure or an unattributable active-code
	 * occurrence. This replaces the old blanket bail on any same-named sibling field.
	 */
	private static function otherFileRenameSpans(
		source: String, name: String, plugin: GrammarPlugin, distinctive: Bool, ownerName: String, shape: RefShape,
		resolutionIndex: SymbolIndex, file: String, ?familySpans: Array<Span>
	): Null<Array<Span>> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
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
		// No scope-correct reference set exists for a file that does not declare the binding, so BOTH
		// owner-bound halves are the rename targets here.
		final ownerBound: Array<Span> = mergeUniqueSpans(refs.bareBound.concat(refs.typedBound), family);
		// Both the owner-bound targets AND the provably-different-owner occurrences are excluded from
		// the completeness scan: the former are renamed, the latter left as-is; only an occurrence that
		// is NEITHER (unprovable) stays uncovered and blocks the whole rename below.
		// Module paths and type references are inert here too — see `declaringFileRenameSpans`. A
		// subtype file naming a type after the member being renamed is the same shape, one file over.
		final excluded: Array<Span> = ownerBound.concat(refs.ignore)
			.concat(RefactorSupport.modulePathSpans(tree, shape))
			.concat(typeReferenceSpans(source, tree, name, shape, plugin, { index: resolutionIndex, file: file }));
		final classified: Null<Array<ClassifiedOccurrence>> = RefactorSupport.classifyOccurrences(
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
		collectAttributedRefs(tree, name, source, null, bare, typed, recvNames);
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
			if (c == ownerName || resolutionIndex.isSubtype(c, ownerName))
				RefactorSupport.pushUniqueSpan(bareBound, seenOwner, occ.off, name.length);
			else if (resolutionIndex.provablyNotSubtype(c, ownerName) && resolutionIndex.supertypeDeclaresMember(c, name))
				RefactorSupport.pushUniqueSpan(ignore, seenIgnore, occ.off, name.length);
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
		typed: Array<{ recv: QueryNode, fa: QueryNode }>, recvNames: Array<String>
	): Void {
		if (RefactorSupport.isConditionalKind(node.kind)) return;
		final cls: Null<String> = CheckScan.isClassBodyKind(node.kind) && node.name != null ? node.name : currentClass;
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
			return b?.from;
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
	 * Whether the cross-file rename path OWNS this declaration's category: a field / constant, or a
	 * METHOD that is neither an `override` nor `implicitlyReachable`. Those two are the hazards
	 * `isRenameSafe` names for a method — an `override` binds the name to the SUPERTYPE's declaration, so
	 * renaming the override alone orphans it, and an annotation-bearing member can be reached by NAME from
	 * a macro / `@:keep` / framework, references no identifier-level completeness proof sees. Visibility is
	 * not asked here: a CONFINED private member is turned away later, by the proof that it is the
	 * single-file path's job.
	 */
	private static function crossFileCategory(decl: NamedDecl): Bool {
		return switch decl.category {
			case NamingCategory.Field, NamingCategory.Constant: true;
			case NamingCategory.Method:
				!decl.mods.contains('override') && decl.implicitlyReachable != true;
			case _: false;
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
	 * Sources are read from disk via the paths the index holds, since `SymbolIndex` retains
	 * none; an unreadable or unparseable file is skipped. WANT: a `SymbolIndex.sourceOf(file)`
	 * accessor would reuse the already-parsed sources and drop the disk read entirely — it
	 * would also make this guard reachable from an in-memory unit test, which today it is not.
	 */
	private static function reflectionNamesInOtherFiles(
		index: SymbolIndex, currentFile: String, candidates: Array<String>, plugin: GrammarPlugin, support: NamingSupport
	): Array<String> {
		final out: Array<String> = [];
		if (candidates.length == 0) return out;
		for (fi in index.allFiles()) if (fi.file != currentFile) {
			#if (sys || nodejs)
			final source: Null<String> = try sys.io.File.getContent(fi.file) catch (exception: Exception) null;
			if (source == null || !quotedMention(source, candidates)) continue;
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
			if (tree == null) continue;
			for (name in support.reflectionMemberNames(tree, source)) if (candidates.contains(name) && !out.contains(name)) out.push(name);
			#end
		}
		return out;
	}

	/**
	 * Whether any of `names` occurs in `source` as a quoted token (`'name'` / `"name"`, the
	 * quotes hugging the exact name). The cheap pre-filter of
	 * `reflectionNamesInOtherFiles`: a file with no such text cannot hold a reflection call
	 * naming one of them, so it needs no parse. Deliberately NOT a verdict of its own — the
	 * same text also matches a comment, a `case 'name':` and an asset key, which is exactly
	 * the over-refusal the AST projection exists to end.
	 */
	private static function quotedMention(source: String, names: Array<String>): Bool {
		return names.exists(name -> source.indexOf('\'$name\'') >= 0 || source.indexOf('"$name"') >= 0);
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
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
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
			final off: Int = RefactorSupport.identTokenOffset(source, hit.span, name);
			if (off >= 0) RefactorSupport.pushUniqueSpan(out, seen, off, name.length);
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
				final off: Int = RefactorSupport.identTokenOffset(source, rspan, name);
				if (off >= 0) RefactorSupport.pushUniqueSpan(out, seen, off, name.length);
			}
		}
		for (child in node.children) collectTypeReferenceSpans(source, child, tree, name, shape, out, seen);
	}

	private static function otherBindingSpans(source: String, tree: QueryNode, name: String, declFrom: Int, shape: RefShape): Array<Span> {
		final out: Array<Span> = [];
		final seen: Array<Int> = [];
		final containerKinds: Array<String> = shape.scopeKinds.concat(['CaseBranch', 'DefaultBranch']);
		for (h in Refs.find(name, tree, shape)) {
			final bindingSpan: Null<Span> = h.bindingSpan;
			final boundFrom: Null<Int> = h.kind == RefKind.Decl ? h.span.from : (bindingSpan?.from);
			if (boundFrom == null || boundFrom == declFrom) continue;
			final off: Int = RefactorSupport.identTokenOffset(source, h.span, name);
			if (off < 0) continue;
			// Fail-closed attribution: exclude this occurrence as belonging to a DIFFERENT binding only when
			// it sits inside that binding's own lexical container. The guard outlives the leak it was written
			// for (a `case` arm now opens its own frame, `RefShape.branchScopeKinds`, so an arm local no
			// longer captures a bare field use): any resolver over-reach puts the occurrence OUTSIDE the
			// binding's container, where it stays uncovered and the completeness gate blocks the whole rename
			// rather than silently excluding - and orphaning - a real reference.
			final container: Null<Span> = visibleRegion(tree, containerKinds, boundFrom, shape);
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
			final unrelated: Array<Span> = owner == null || resolutionIndex == null
				? []
				: unrelatedTypeSpans(tree, owner, shape, resolutionIndex);
			return RefactorSupport.nameBoundInRange(source, newName, 0, source.length, unrelated, plugin);
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
		final enclosing: Null<Span> = enclosingScopeSpan(tree, funcKinds, span.from, shape);
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
	 * The tightest enclosing scope span (whose kind is in `kinds`) containing `pos`, with the local
	 * FUNCTION declared AT `pos` excluded from the answer - the form every lookup made FROM a
	 * declaration position needs, and the reason `innermostSpanOfKinds` should not be called with one
	 * directly.
	 *
	 * A local `function` / `inline function` declaration is BOTH a binding and a `scopeKinds` node, so
	 * the raw walk answers with the declaration's OWN span while the scope its name binds into is the
	 * ENCLOSING one. Five sites need that pairing; three wrote it out by hand, `otherBindingSpans` and
	 * `NoUnderscorePrefix.isUnreferenced` did not. In `otherBindingSpans` the omission made a local
	 * function's call sites fall outside its "container", stay unattributed, and the completeness gate
	 * refuse an UNRELATED same-named binding's rename.
	 *
	 * NOT the only such kind: a method (`FnMember`) and a type declaration are `scopeKinds` nodes and
	 * decl hosts too, and `localFunctionDeclSpan` deliberately does not match them - widening it would
	 * change the comment-along container for members, which is a separate decision. The same
	 * unattributed-call-site refusal therefore still holds for a bare call to a same-named METHOD; it
	 * is fail-closed (a lost rename, never a wrong one) and is left standing.
	 */
	private static function enclosingScopeSpan(tree: QueryNode, kinds: Array<String>, pos: Int, shape: RefShape): Null<Span> {
		return innermostSpanOfKinds(tree, kinds, pos, localFunctionDeclSpan(tree, pos, shape));
	}

	/**
	 * The region in which the binding declared at `declFrom` is VISIBLE: its enclosing scope, but
	 * starting AT the declaration when the declaration is itself a scope opener (a local `function`).
	 *
	 * A STRICTER contract than `enclosingScopeSpan`, and the two must not be conflated. The four
	 * callers of that one read its answer as "the region I must SCAN", where a wider span means more
	 * vetoes - fail-closed. `otherBindingSpans` reads this one as "the region inside which I may
	 * EXCLUDE an occurrence from the completeness gate", where a wider span means FEWER vetoes and a
	 * rename that ships with a real reference unrewritten. Haxe does not hoist a local function, so a
	 * read before its declaration binds to whatever it shadows - a parameter, a member - and must stay
	 * uncovered. Clamping the lower bound is what keeps that read blocking while the call sites AFTER
	 * the declaration are still attributed. `declaringFileRenameSpans` applies the same rule to the
	 * binding being renamed (`bodyScoped`); this is its counterpart for the OTHER bindings.
	 */
	private static function visibleRegion(tree: QueryNode, kinds: Array<String>, declFrom: Int, shape: RefShape): Null<Span> {
		final own: Null<Span> = localFunctionDeclSpan(tree, declFrom, shape);
		final scope: Null<Span> = innermostSpanOfKinds(tree, kinds, declFrom, own);
		return if (scope == null)
			null
		else if (own == null)
			scope
		else
			new Span(declFrom, scope.to);
	}

	/**
	 * The tightest enclosing node span (whose kind is in `kinds`) containing `pos`, or null when none
	 * does. `exclude` drops the node occupying exactly that span from consideration.
	 *
	 * The raw walk, with `exclude` REQUIRED rather than optional so a caller has to decide: the two that
	 * exist (`enclosingScopeSpan`, `visibleRegion`) both derive it from `localFunctionDeclSpan`. Reach it
	 * through one of them, never directly from a declaration position.
	 */
	private static function innermostSpanOfKinds(node: QueryNode, kinds: Array<String>, pos: Int, exclude: Null<Span>): Null<Span> {
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
	 * does not bind into - the name belongs to the enclosing body - so a scope lookup made FROM such a
	 * declaration must exclude the declaration's own node. `enclosingScopeSpan` is the one place that
	 * pairs this with the walk; nothing else needs it. A self-scoped binding (a loop iterator, a catch
	 * variable) is the opposite case and is deliberately not matched: its own node IS the scope its
	 * name lives in.
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
private typedef RenameContext = {
	final index: SymbolIndex;
	final file: String;
	@:optional final ownerName: String;
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
	final isPublic: Bool;

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
private typedef CrossFileRename = {
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
private typedef DeclRename = {
	final newName: String;
	final edits: Array<{ span: Span, text: String }>;
	final scope: Span;
};
