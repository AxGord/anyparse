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
final class Naming implements Check {

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

		final edits: Array<{ span: Span, text: String }> = [];
		for (decl in support.project(tree)) {
			final rename: Null<RenameEdits> = renameEditsFor(
				decl, source, tree, policy, shape, flaggedFroms, otherSources, confinedMemo, index
			);
			if (rename != null) for (occ in rename.occurrences) edits.push({ span: occ, text: rename.name });
		}
		return edits;
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
	 * with a normalizer, already conformant, an incomplete rename whose old name
	 * still occurs outside the resolved spans (a bare `$name` interpolation the
	 * resolver misses, a reflection string), or a rename to a name already bound
	 * in the file (a collision). When non-null, every returned occurrence span is
	 * rewritten to `name`.
	 */
	private static function renameEditsFor(
		decl: NamedDecl, source: String, tree: QueryNode, policy: NamingPolicy, shape: RefShape, flaggedFroms: Array<Int>,
		otherSources: Array<String>, confinedMemo: Map<String, Bool>, ?index: SymbolIndex
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
		// that case - so the inheritance gate is FIELD-only. Skip when the inherited-`_x`
		// possibility cannot be ruled out (an unresolvable supertype closure), and skip a field
		// of a `@:rtti` / drill-Node hierarchy whose subtype-ward `@:rtti` only the index reveals
		// (the direct-`@:rtti` case is already `renameUnsafe`): such a class serializes by
		// reflecting on field NAMES, so a rename would silently break saved files.
		if (decl.category == NamingCategory.Field) {
			final owner: Null<String> = decl.enclosingType;
			if (owner == null || index == null) return null;
			final idx: SymbolIndex = index;
			if (!idx.typeProvablyLacksMember(owner, newName) || idx.transitivelyCarriesRtti(owner)) return null;
		}
		final occurrences: Array<Span> = Rename.renameOccurrences(source, tree, span.from, shape);
		// Completeness: the scope resolver can miss a reference the rename must
		// also rewrite — a bare field access whose binding span disagrees with the
		// decl node, or a simple `$name` string interpolation (the braced
		// `${name}` form IS resolved, the bare `$name` form is not). Any textual
		// occurrence of the old name left outside the resolved spans means an
		// incomplete rename that would dangle, so bail. This applies to EVERY
		// category, not only fields: a local read solely through `$name`
		// interpolation hits the same gap, and without the guard `--fix` would
		// emit non-compiling source.
		// Collision: a `newName` already occurring as an identifier in the file
		// (another member of the same type, a sibling local) would be duplicated
		// or shadowed by the rename — the re-parse gate accepts the result but it
		// does not type-check, so skip that too.
		return occurrences.length == 0 || RefactorSupport.referencedInRange(source, decl.name, 0, source.length, occurrences)
			|| RefactorSupport.referencedInRange(source, newName, 0, source.length, [])
			? null
			: {
				occurrences: occurrences,
				name: newName
			};
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

}

/**
 * A computed rename for one declaration: every span to rewrite and the new
 * identifier to write at each.
 */
private typedef RenameEdits = {
	final occurrences: Array<Span>;
	final name: String;
};
