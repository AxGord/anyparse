package anyparse.query;

import anyparse.query.CondDirectives.CondDirective;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.GuardedImportCarry.GuardedCarry;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.Refs.RefHit;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;
using Lambda;

/**
 * Which `import` / `using` statements must travel with a declaration a move takes out of its
 * file, and when carrying one has to be REFUSED instead.
 *
 * The question is not "what does the moved code reference" — that is a scan — but "does each
 * reference still mean the same thing after the move". Answering it needs a model of the
 * destination's own name-resolution ladder (a module's own types, then its imports, then its
 * package, then the ambient top level), which is what the `bindingOf` family below is; every
 * refusal in this module is a place where the two files' ladders disagree about one simple name
 * and carrying the source's statement would silently rebind one side or the other.
 *
 * Split out of `MoveSymbol` in S81: the file answered "what binds this name here" in seven
 * hand-rolled predicates whose comment policies had drifted apart, and nothing in the tree named
 * the family. Only THREE of the seven could have a lexical policy at all, and they moved to
 * `NameMentionScan`; what is below is the INDEX half, and the difference is load-bearing. 20 of
 * these 29 members — the whole `bindingOf` ladder and every refusal built on it — take no source
 * string, so no comment or string rule can apply to them. The 9 that do take one ask it for span
 * and statement TEXT; the one reference question any of them asks ("does the destination name this
 * dependency at all") goes through `NameMentionScan.destinationNamesType`.
 */
@:nullSafety(Strict)
final class DependencyCarry {

	/**
	 * The explicit statements the moved decl's body depends on that the
	 * destination lacks. A dependency name `D` is a reference INSIDE the
	 * decl's span that is either a TYPE POSITION or the upper-initial
	 * RECEIVER of a member access (`D.go()`). For each such `D` the source
	 * binds by an explicit statement (any kind but `Wild`) whose BOUND name
	 * is `D`, and that the destination does not already carry verbatim, the
	 * statement is returned as READY TEXT for the destination.
	 *
	 * Beside those, EVERY unguarded `using` of the source file the destination
	 * lacks is returned when the decl holds a member access at all — see
	 * `usingLinesToCarry`, which is where the skip-rather-than-refuse rule for
	 * a colliding `using` lives.
	 *
	 * Text rather than the `ImportInfo`, because two callers used to spell
	 * that statement themselves and `raw` is the ALIAS for an `Alias` one:
	 * either would have emitted `import D;` the moment an alias dependency
	 * became carriable. The path comes from the project's one decoder
	 * (`SymbolIndex.pathImportedBy`) and the `as` / `in` suffix from the
	 * statement's own text, so a bound name is never re-spelled twice.
	 *
	 * A same-package dependency is auto-visible at the destination only when the destination is in that
	 * same package — the claim here read "the move is same-package" until 2026-08-31, which stopped
	 * being true at S40. A cross-package move prices such a name through `bindingOf` like any other and
	 * refuses when the two sides disagree.
	 *
	 * A carry is REFUSED, not performed, when the destination already binds that simple name to a
	 * different module. Three shapes, all measured on the base engine at 11f22a25, all compiled and
	 * run to a CHANGED runtime class with rc 0 and no diagnostic: the destination module declares
	 * the name itself (its own type wins over any import, so the MOVED code silently rebinds to
	 * it); the destination imports the name from elsewhere (Haxe resolves the last import, so the
	 * DESTINATION's code silently rebinds to the carried module); and a sibling module of the
	 * destination's package declares it (an import beats same-package visibility, same rebind).
	 * The alias spelling is the same defect in different clothes — `import q.Thing as D;` carried
	 * next to `import r.Thing as D;` produced the identical rebind — and one gate on the BOUND
	 * name covers both. The destination-side reference test over-counts (a name in a comment or a
	 * string reads as a use), which is the conservative direction for a refusal.
	 */
	public static function dependencyImportLinesToCarry(
		source: String, declSpan: Span, cursorInfo: FileInfo, destInfo: FileInfo, destSource: String, index: SymbolIndex,
		plugin: GrammarPlugin, typeRefShape: TypeRefShape, typeName: String
	): CarryResult {
		// The type-ref projection and the grammar shape are built ONCE here and threaded down: the
		// dependency walk and the `using` carry both read them, and a plugin without a parse cache
		// (which is what the unit suite passes) would otherwise parse the file twice and rebuild a
		// 227-field shape struct for each.
		final tree: QueryNode = plugin.parseFileTypeRefs(source);
		final shape: RefShape = plugin.refShape();
		final depNames: Array<String> = dependencyNames(tree, shape, source, declSpan, cursorInfo, plugin, typeRefShape, typeName);
		// One copy of the file list for the whole carry — `allFiles()` copies, and the binding walk
		// runs once per dependency name on each side.
		final files: Array<FileInfo> = index.allFiles();
		final carried: Array<String> = [];
		final destRegions: Array<LexRegion> = plugin.lexicalRegions(destSource);
		// The cursor file's `#if` directives, read at most once and only when a dependency turns out to
		// have no unguarded provider — a file without a single directive never pays for the scan, and
		// `MoveMember` runs this whole carry once per moved member.
		var cursorDirectives: Null<Array<CondDirective>> = null;
		// Guarded statements to carry, grouped by the condition that guards them: one `#if … #end`
		// block per condition, emitted after the walk so two names guarded by one condition do not
		// arrive as two blocks spelling it twice.
		final guarded: Array<{ condition: String, lines: Array<String> }> = [];
		for (dep in depNames) {
			// A DOTTED type path carries its own question and its own refusal — see
			// `qualifiedHeadRefusal`. Nothing about it can be carried either way, so the loop is done
			// with it whichever answer comes back.
			if (dep.indexOf('.') > 0) {
				final headErr: Null<String> = qualifiedHeadRefusal(dep, cursorInfo, destInfo, files);
				if (headErr != null) return CarryErr(headErr);
				continue;
			}
			// The source's explicit TOP-LEVEL statement that BINDS `dep` — for a plain import /
			// using that is a path whose last segment is `dep`, for an alias it is the alias
			// itself, and `raw` is exactly the bound name in both. The kinds are listed rather
			// than `!= Wild`: this writes a statement into ANOTHER file, so a kind nobody has
			// thought about yet must be refused, not admitted. An alias whose path did not decode
			// names nothing to carry. A guarded (`#if`) provider is skipped: it would be carried
			// into the destination as an unconditional import, which could be platform-inappropriate.
			final direct: Null<ImportInfo> = unguardedProviderOf(dep, cursorInfo);
			// What the SOURCE means by `dep`: its own explicit import when it has one, else the same
			// resolution ladder the destination is measured on — a dependency reached by same-package
			// visibility has no import statement to carry and was therefore never checked at all, which
			// left the headline defect open through a second route (compile-proved: a bare `Dep` from
			// `p/Dep.hx` moved into a `p/Host.hx` holding `import r.Dep;` returned `r.Dep` where it had
			// returned `p.Dep`, rc 0, nothing carried, nothing reported).
			final wanted: Null<String> = direct != null ? SymbolIndex.pathImportedBy(direct) : bindingOf(dep, cursorInfo, files)?.path;
			// A MODULE import binds every type the module declares, so the statement that provides
			// `dep` need not spell it. That rung has been PRICED by `bindingOf` since S29 and carried by
			// nobody, which cost a refusal naming "no import to carry" over an import that was right
			// there (compile-proved: the same move writes and the tree types clean once it is carried).
			final provider: Null<ImportInfo> = direct ?? moduleStatementBinding(dep, wanted, cursorInfo);
			// A binding the destination has and the moved code does not share is the one thing carrying
			// cannot repair: whichever of the two wins, code that compiled before means a different
			// type, with no diagnostic anywhere. `wanted == null` is NOT a licence to skip the gate —
			// the source binding is then merely unnameable, and it is exactly the case the base engine
			// fell through on for a stdlib name, a package wildcard and a `#if`-guarded import alike.
			final collision: Null<String> = carryCollision(
				dep, wanted, cursorInfo, destInfo, destSource, files, provider != null, destRegions
			);
			if (collision != null) return CarryErr(collision);
			if (provider == null) {
				// The unguarded ladder has nothing to bring, which is the silent answer for every
				// dependency reached through the stdlib, a wildcard or the ambient top level — and was
				// also the silent answer for a `#if`-guarded import, which DOES have a statement.
				// 72 destinations of one 767-module sweep lost their guarded block that way, with
				// nothing naming a file. Asked only where the destination cannot already reach the
				// name: the collision gate above has just proved that whatever it does reach it by is
				// one of the source's own candidates, so there is nothing to add.
				if (guardedImportPath(dep, destInfo) != null || bindingOf(dep, destInfo, files) != null) continue;
				final directives: Array<CondDirective> = cursorDirectives ?? GuardedImportCarry.directivesOf(source, plugin);
				cursorDirectives = directives;
				final refusal: Null<String> = foldGuardedCarry(dep, source, cursorInfo, directives, shape, guarded);
				if (refusal != null) return CarryErr(refusal);
				continue;
			}
			// The destination already sees `dep` as `wanted` with no statement of its own, so the
			// carried line would bind nothing new — see `destinationSeesWithoutStatement`. Only a plain
			// `import` is skipped: a `using` grants extension methods no visibility rung grants, and an
			// alias introduces a NAME the destination has no other way to spell.
			if (provider.kind == ImportKind.Import && destinationSeesWithoutStatement(dep, wanted, destInfo, files)) continue;
			// Already present in the destination → no carry. The PATH is part of the identity: two
			// alias statements binding one name to different modules share a `raw`, and reading
			// them as the same statement would silently leave the moved decl on the DESTINATION's
			// binding instead of its own. The differing-path case no longer reaches here at all —
			// the collision gate above refuses it, for the plain and the alias spelling alike.
			if (destAlreadyHolds(destInfo, provider)) continue;
			// De-dup the carry list (a single import line could provide more
			// than one referenced name only via wildcards, which we skipped —
			// and via a MODULE import, which now reaches here and repeats).
			final line: String = DependencyCarry.importLineFor(provider, source);
			if (!carried.contains(line)) carried.push(line);
		}
		final wildRefusal: Null<String> = foldWildcardCarry(
			source, declSpan, cursorInfo, destInfo, files, plugin, carried, guarded, cursorDirectives
		);
		if (wildRefusal != null) return CarryErr(wildRefusal);
		for (group in guarded) carried.push(GuardedImportCarry.blockText(group.condition, group.lines, shape));
		return CarryOk(usingLinesToCarry(
			source, tree, memberAccessKinds(shape), declSpan, cursorInfo, destInfo, destSource, files, carried,
			plugin.lexicalRegions(destSource)
		));
	}

	/**
	 * What `info`'s file ALREADY means by the simple name `name`, or null when nothing in the indexed
	 * scope binds it. Null is UNKNOWN, never "nothing binds it": the name may still resolve through the
	 * AMBIENT top-level scope — the standard library, or a root-package module outside the scope — which
	 * no scope-limited index can see. Reading null as "free" is what let a carried import shadow a
	 * stdlib name with no diagnostic, so every caller must decide what an unknown means for its own
	 * direction rather than fall through.
	 *
	 * The order IS Haxe's resolution order, measured on 4.3.7 rather than read off the spec: a type the
	 * file's own module declares beats an import; an EXPLICIT import beats a WILDCARD one whichever is
	 * written first; a wildcard beats a sibling module of the same package; and the package beats the
	 * TOP LEVEL. Among explicit imports the LAST one wins, which is why the fold keeps the last match
	 * instead of the first. A `#if`-guarded import is skipped here — it binds the name in some
	 * configurations only, so it is not a rung of any one build's ladder; `guardedImportPath` asks about
	 * it separately, and the caller refuses on it rather than ranking it.
	 *
	 * Asked of the DESTINATION it says what a carried import would collide with; asked of the SOURCE it
	 * says what the moved code means today, which is the only way to price a dependency the source
	 * reaches with no import statement at all.
	 */
	public static function bindingOf(name: String, info: FileInfo, files: Array<FileInfo>): Null<NameBinding> {
		for (t in info.types) if (t.name == name) return { path: t.isMain ? info.module : '${info.module}.${t.name}', ownModule: true };
		final imported: Null<String> = importBinding(name, info, files);
		if (imported != null) return { path: imported, ownModule: false };
		final wild: Null<String> = wildcardBinding(name, info, files);
		if (wild != null) return { path: wild, ownModule: false };
		final scoped: Null<String> = packageOrTopLevelBinding(name, info, files);
		return scoped == null ? null : { path: scoped, ownModule: false };
	}

	/**
	 * The source's explicit TOP-LEVEL statement that BINDS `dep`, or null when it has none.
	 *
	 * For a plain import / using that is a path whose last segment is `dep`, for an alias it is the
	 * alias itself, and `raw` is exactly the bound name in both. The kinds are listed rather than
	 * `!= Wild`: this writes a statement into ANOTHER file, so a kind nobody has thought about yet
	 * must be refused, not admitted. An alias whose path did not decode names nothing to carry. A
	 * guarded (`#if`) provider is not one of these — it is carried separately, under its own
	 * condition, by `foldGuardedCarry`.
	 */
	private static function unguardedProviderOf(dep: String, cursorInfo: FileInfo): Null<ImportInfo> {
		return cursorInfo.imports.find(
			imp ->
				!imp.guarded && (imp.kind == ImportKind.Import || imp.kind == ImportKind.Using || imp.kind == ImportKind.Alias)
				&& SymbolIndex.pathImportedBy(imp) != null && SourceText.lastSegment(imp.raw) == dep
		);
	}

	/**
	 * Whether the destination already holds `provider`'s exact statement, so there is nothing to carry.
	 *
	 * The PATH is part of the identity: two alias statements binding one name to different modules
	 * share a `raw`, and reading them as the same statement would silently leave the moved decl on the
	 * DESTINATION's binding instead of its own. The differing-path case no longer reaches here at all —
	 * the collision gate refuses it, for the plain and the alias spelling alike.
	 */
	private static function destAlreadyHolds(destInfo: FileInfo, provider: ImportInfo): Bool {
		return destInfo.imports.exists(
			imp ->
				imp.kind == provider.kind && imp.raw == provider.raw
				&& SymbolIndex.pathImportedBy(imp) == SymbolIndex.pathImportedBy(provider)
		);
	}

	/**
	 * The refusal a DOTTED dependency path owes, or null when it changes nothing.
	 *
	 * `dep` can be `Mod.Sub`, because a dotted type path is ONE leaf. Its head is not resolved by any
	 * import — `import q.Mod;` does NOT make `Mod.Sub` legal (`Type not found : Mod` on 4.3.7) — it is
	 * a MODULE looked up in the file's own package and then at the top level. So the PACKAGE decides
	 * it, a same-package move cannot move it, and a cross-package one silently can: compile-run
	 * through the base engine, `Mod.Sub` went `p.Sub` -> `s.Sub` with rc 0. A lowercase head is a
	 * fully-qualified path and is absolute everywhere.
	 */
	private static function qualifiedHeadRefusal(
		dep: String, cursorInfo: FileInfo, destInfo: FileInfo, files: Array<FileInfo>
	): Null<String> {
		final head: String = dep.substring(0, dep.indexOf('.'));
		if (!SourceText.isUpperInitial(head)) return null;
		final mineHead: Null<String> = headModuleOf(head, cursorInfo, files);
		final theirsHead: Null<String> = headModuleOf(head, destInfo, files);
		// Equal includes null == null: a head the index cannot see is a top-level module, which
		// resolves the same from every package.
		return mineHead == theirsHead
			? null
			: 'the moved code writes the qualified type "$dep", whose head "$head" is a module resolved through the '
				+ 'file\'s own package: ${cursorInfo.file} reaches ${mineHead == null ? 'the top level' : '$mineHead'} and '
				+ '${destInfo.file} reaches ${theirsHead == null ? 'the top level' : '$theirsHead'} — the reference would '
				+ 'silently change meaning; spell it fully qualified, or move the head module too';
	}

	/**
	 * Fold one dependency's `#if`-guarded providers into `guarded`, grouped by the condition that
	 * guards them, or return the refusal naming why no single condition carries it.
	 *
	 * Split out of the carry loop for its own sake: that loop already answers the qualified-path, the
	 * collision and the same-package questions, and one more `switch` inside it put the function over
	 * the complexity budget. Nothing else calls this.
	 */
	private static function foldGuardedCarry(
		dep: String, source: String, cursorInfo: FileInfo, directives: Array<CondDirective>, shape: RefShape,
		guarded: Array<{ condition: String, lines: Array<String> }>
	): Null<String> {
		return foldGuardedResult(GuardedImportCarry.carryFor(dep, cursorInfo.file, source, cursorInfo, directives, shape), source, guarded);
	}

	/**
	 * Fold one already-computed guarded carry into `guarded`, grouped by the condition that guards
	 * it, or return the refusal it carries.
	 *
	 * Split from `foldGuardedCarry` so the module-static WILDCARD arm can reuse it: that arm selects
	 * its own providers (a `pkg.Mod.*` statement is not reachable by the last-segment match
	 * `GuardedImportCarry.carryFor` does), and everything after the selection is identical.
	 */
	private static function foldGuardedResult(
		result: GuardedCarry, source: String, guarded: Array<{ condition: String, lines: Array<String> }>
	): Null<String> {
		switch result {
			case GuardedNone:
			case GuardedRefusal(message):
				return message;
			case GuardedProviders(condition, imports):
				final group: { condition: String, lines: Array<String> } = guarded.find(g ->
					g.condition == condition
				) ?? { condition: condition, lines: [] };
				if (!guarded.contains(group)) guarded.push(group);
				for (imp in imports) {
					final line: String = DependencyCarry.importLineFor(imp, source);
					if (!group.lines.contains(line)) group.lines.push(line);
				}
		}
		return null;
	}

	/**
	 * The module path an unguarded EXPLICIT import / using of `info`'s file binds `name` to, or null.
	 * The LAST such statement wins, which is why the fold keeps the last match rather than the first.
	 *
	 * A MODULE import binds every type the module declares, not only the one that shares its name:
	 * `import q.Mod;` makes `q.Mod.Sub` reachable as bare `Sub` — compile-run on 4.3.7, and
	 * `Type.getClassName` on what it built came back `q.Sub`. Reading only the import's last segment
	 * left every such name unbound, and an unbound SOURCE name is what the collision gate refuses on.
	 * An ALIAS is excluded: `import q.Mod as X;` binds X and nothing else.
	 */
	private static function importBinding(name: String, info: FileInfo, files: Array<FileInfo>): Null<String> {
		var imported: Null<String> = null;
		for (imp in info.imports) if (!imp.guarded) {
			final path: Null<String> = SymbolIndex.pathImportedBy(imp);
			if (path == null) continue;
			if (SourceText.lastSegment(imp.raw) == name) {
				imported = path;
				continue;
			}
			if (imp.kind != ImportKind.Import && imp.kind != ImportKind.Using) continue;
			for (fi in files) if (fi.module == path) for (t in fi.types) if (t.name == name && !t.isPrivate) imported = '$path.$name';
		}
		return imported;
	}

	/**
	 * The IMPLICIT rungs of the ladder, in their measured order: a sibling MODULE of `info`'s own
	 * package first, then each ANCESTOR package above it, nearest first, ending with the TOP LEVEL — a
	 * module of the root package, visible by simple name from every file in the project exactly as the
	 * standard library's own top-level types are.
	 *
	 * The ancestor rungs are not an extrapolation from the root one: compiled on 4.3.7, `p.sub.deep.C`
	 * names `p.A` with no import at all while a sibling `q.D` does not (`Type not found : A`), and with
	 * both `p.A` and `p.sub.A` present the deep file answers `p.sub.A` — nearest first. Modelling only
	 * the same package and the root left a descendant-package file out of `statementlessRepairEdits`
	 * entirely, so a move wrote two files at rc 0 over a tree that then read `Type not found`.
	 *
	 * `isMain` FILTERS every rung, where the module-own branch of `bindingOf` only spells a path with it: a
	 * sibling module's SUB-module type is not visible by simple name from another file of the package
	 * — this file's own header proves it, importing `SymbolIndex.ImportKind` from its own package — so
	 * counting one was a refusal against a binding that does not exist (`Type not found : Dep` on
	 * 4.3.7). `isPrivate` filters for the same reason one step further in: `private class Dep` in
	 * `p/Dep.hx` is equally `Type not found` from `p/Host.hx`.
	 */
	private static function packageOrTopLevelBinding(name: String, info: FileInfo, files: Array<FileInfo>): Null<String> {
		for (pkg in packageChainOf(info.pkg)) for (fi in files) if (fi.pkg == pkg && fi.file != info.file) {
			for (t in fi.types) if (t.name == name && t.isMain && !t.isPrivate) return fi.module;
		}
		return null;
	}

	/**
	 * `pkg` and every ANCESTOR package above it, nearest first, ending with the root — the chain Haxe
	 * walks for an unqualified type name. The root is the last rung rather than a separate one, which
	 * is why a root-package file's chain has exactly one entry.
	 */
	private static function packageChainOf(pkg: String): Array<String> {
		final out: Array<String> = [pkg];
		var at: String = pkg;
		while (at != '') {
			final dot: Int = at.lastIndexOf('.');
			at = dot < 0 ? '' : at.substring(0, dot);
			out.push(at);
		}
		return out;
	}

	/**
	 * The module path a `#if`-guarded import of `info`'s file binds `name` to, or null when it has
	 * none. Kept OUT of `bindingOf`'s ladder on purpose: a guarded import is a rung in some builds and
	 * absent in others, so ranking it would answer one configuration and hide the rest.
	 *
	 * The caller uses it as a VETO rather than as an answer. Both directions were compile-run on 4.3.7
	 * with a destination holding `#if neko import r.Dep; #end`: with the carried line written ABOVE the
	 * guard the guarded import wins under `-D neko` and the MOVED code rebinds (`q.Dep` -> `r.Dep`);
	 * with an unguarded import below the guard the carried line lands last and the DESTINATION's own
	 * code rebinds (`r.Dep` -> `q.Dep`). Both exited 0 with no output. Which of the two happens is
	 * decided by where the anchor puts the line, so the veto does not ask.
	 */
	private static function guardedImportPath(name: String, info: FileInfo): Null<String> {
		var found: Null<String> = null;
		for (imp in info.imports) if (imp.guarded && SourceText.lastSegment(imp.raw) == name) {
			final path: Null<String> = SymbolIndex.pathImportedBy(imp);
			if (path != null) found = path;
		}
		return found;
	}

	/**
	 * The module path a WILDCARD import of `info`'s file binds `name` to, or null when none of them
	 * does — including when the wildcard names a package the scope index does not hold, where the
	 * honest answer is "unknown" and the caller's unknown handling takes over.
	 *
	 * Only ONE of the two `.*` spellings binds a TYPE. `import pkg.*` brings in each MODULE of `pkg`
	 * under its main type's name — a SUB-module type stays unbound, which is why `isMain` filters here as
	 * it does on the package rung. `import pkg.Module.*` binds no type at all: it imports that
	 * module's STATIC FIELDS, measured on 4.3.7 (`trace(STATIC_FIELD)` prints, `new Mod()` and
	 * `new Sub()` are both `Type not found`), so it is not a rung and modelling it as one INVENTED a
	 * binding — which then matched `wanted` and cancelled the very ambient refusal this slice added.
	 * Privacy filters what remains: a module-`private` type is not importable by any spelling.
	 *
	 * Without this rung a wildcard was simply invisible, and the collision gate read the destination as
	 * binding nothing: `p/Host.hx` holding `import r.*` next to a moved decl reaching `q.Dep` had the
	 * carried `import q.Dep;` win over the wildcard, and `Host.dep()` came back `q.Dep` where it had
	 * been `r.Dep`, rc 0.
	 */
	private static function wildcardBinding(name: String, info: FileInfo, files: Array<FileInfo>): Null<String> {
		var found: Null<String> = null;
		for (imp in info.imports) if (!imp.guarded && imp.kind == ImportKind.Wild && imp.raw.endsWith('.*')) {
			final head: String = imp.raw.substring(0, imp.raw.length - 2);
			for (fi in files) if (fi.pkg == head) for (t in fi.types) if (t.name == name && t.isMain && !t.isPrivate) found = fi.module;
		}
		return found;
	}

	/**
	 * Whether `path` — a MODULE some file imports — could bind `name`. A module the index HOLDS is
	 * asked and answers definitively; a module OUTSIDE the scope cannot be asked and answers YES,
	 * because the constructed `<path>.<name>` is the only handle there is on `import haxe.macro.Expr;`
	 * providing `Field`.
	 *
	 * The unproven YES cannot manufacture a FALSE agreement between two files, which is what every
	 * membership test on `importCandidates` rests on. For the constructed path to EQUAL a real binding
	 * path on the other side, that side must hold an import spelling `<path>.<name>` — and on 4.3.7
	 * such an import means the SUB-TYPE of module `<path>` whenever a module `<path>` exists at all
	 * (verified with a module `P.hx` and a package `P/` both declaring `Dep`: `import P.Dep;` bound the
	 * module's sub-type). If `<path>` were only a package, the `import <path>;` this YES was read off
	 * does not compile at all (`Type not found : P`, verified) — so no source Haxe accepts reaches the
	 * disagreement, and two files that agree on such a path are naming the same type.
	 *
	 * A CARRY reads the answer rather than testing membership, so it cannot survive the unproven YES —
	 * `moduleStatementBinding`, which picks the line a carry writes, deliberately does not call this,
	 * and the measurement that forced that is recorded there.
	 */
	private static function moduleMayDeclare(path: String, name: String, files: Array<FileInfo>): Bool {
		final known: Null<FileInfo> = files.find(fi -> fi.module == path);
		return known == null || known.types.exists(t -> t.name == name && !t.isPrivate);
	}

	/**
	 * The file's LAST unguarded MODULE statement whose sub-type rung spells `wanted` — the statement
	 * that PRODUCED the binding `bindingOf` reports for `name`, and therefore the one line a carry may
	 * write into another file. Null when the ladder's answer came from anywhere else (the module's own
	 * types, an explicit import, a wildcard, the package), where this statement is not what the moved
	 * code means by the name.
	 *
	 * Asking which statement produced the ANSWER, rather than which statement COULD have, is what keeps
	 * an out-of-scope module out of the carry: nothing in the ladder ever constructs
	 * `<out-of-scope-module>.<name>`, so such a statement can never match. Admitting them on their own —
	 * the `moduleMayDeclare` answer, which is right for a membership test and wrong for a carry — makes
	 * EVERY out-of-scope module import a candidate for EVERY unbound name, `String` / `Int` / `Void` /
	 * `Array` included: measured over 285 same-package moves on the Pony tree, that priced ambient names
	 * to paths like `StringTools.String` and `haxe.MainLoop.Void` and turned 62 of 147 accepted moves
	 * into refusals.
	 */
	private static function moduleStatementBinding(name: String, wanted: Null<String>, info: FileInfo): Null<ImportInfo> {
		if (wanted == null) return null;
		var found: Null<ImportInfo> = null;
		for (imp in info.imports) if (!imp.guarded && (imp.kind == ImportKind.Import || imp.kind == ImportKind.Using)) {
			final path: Null<String> = SymbolIndex.pathImportedBy(imp);
			if (path != null && '$path.$name' == wanted) found = imp;
		}
		return found;
	}

	/**
	 * The module a QUALIFIED type path's head segment names from `info`'s position — the same package chain
	 * `packageChainOf` walks for a bare type name — its own package, each ancestor above it, then the
	 * top level, and compile-proved on the head form of its own accord (`p.sub.deep.C` resolves
	 * `Mod.Sub` against `p.Mod` while a sibling `q.D` reads `Type not found : Mod`). Imports do not
	 * enter this ladder: `import q.Mod;` does not make
	 * `Mod.Sub` resolve (`Type not found : Mod` on 4.3.7), which is what makes a head PACKAGE-relative
	 * and a cross-package move able to rebind it. Null means the head is not a module this index holds,
	 * which for a head with no package of its own is the ambient top level — the same answer from every
	 * file, so two nulls agree.
	 */
	private static function headModuleOf(head: String, info: FileInfo, files: Array<FileInfo>): Null<String> {
		for (pkg in packageChainOf(info.pkg))
			for (fi in files)
				if (fi.pkg == pkg && SourceText.lastSegment(fi.module) == head) return fi.module;
		return null;
	}

	/**
	 * Every module path an import / using statement of `info`'s file could bind `name` to — the
	 * statement's own path when its last segment IS `name`, and `<path>.<name>` for a module import,
	 * which brings the module's other types along. Guarded statements are included: this answers "could
	 * the two files mean the same thing by this name", not "what does this build mean by it".
	 *
	 * The reconciliation half of the collision gate. `bindingOf` deliberately cannot name a binding that
	 * comes from a `#if`-guarded import or from a module OUTSIDE the indexed scope — and a refusal built
	 * on "cannot name it" then fires on the commonest macro-file shape there is, where BOTH files carry
	 * the same `#if macro import haxe.macro.Expr;`. Measured on the Pony tree: four of eleven changed
	 * outcomes in a 60-case census were exactly that, and each names a path both sides already agree on.
	 *
	 * The set is deliberately not proof of a binding — an entry is a path the statement WOULD produce if
	 * the module declares `name`, which an out-of-scope module cannot be asked. It is only ever used to
	 * cancel a refusal whose other side names one of these paths exactly, so a wrong entry costs a
	 * missed refusal on a shape where the two files already spell the same import.
	 */
	private static function importCandidates(name: String, info: FileInfo, files: Array<FileInfo>): Array<String> {
		final out: Array<String> = [];
		for (imp in info.imports) if (imp.kind != ImportKind.Wild) {
			final path: Null<String> = SymbolIndex.pathImportedBy(imp);
			if (path == null) continue;
			if (SourceText.lastSegment(imp.raw) == name) {
				if (!out.contains(path)) out.push(path);
				continue;
			}
			if (imp.kind == ImportKind.Alias) continue;
			if (!moduleMayDeclare(path, name, files)) continue;
			final candidate: String = '$path.$name';
			if (!out.contains(candidate)) out.push(candidate);
		}
		return out;
	}

	/**
	 * The reason a dependency must NOT follow the moved declaration into the destination, or null when
	 * nothing about it changes meaning. A collision is a binding the destination already has for the
	 * same simple name, resolving to a different module.
	 *
	 * Which SIDE silently moves decides both whether the collision is observable at all and what its
	 * author has to do about it, so there is one sentence per arm rather than one for the gate.
	 * `carried` says whether there is an import statement to bring along: without one the moved code
	 * takes the destination's own resolution and always moves; with one the carried line wins over
	 * everything except a type the destination module declares itself, so the side that moves is the
	 * destination's own code — and only when it names `dep`.
	 */
	private static function carryCollision(
		dep: String, wanted: Null<String>, cursorInfo: FileInfo, destInfo: FileInfo, destSource: String, files: Array<FileInfo>,
		hasProvider: Bool, regions: Array<LexRegion>
	): Null<String> {
		final standing: Null<NameBinding> = bindingOf(dep, destInfo, files);
		final guardedDest: Null<String> = guardedImportPath(dep, destInfo);
		if (wanted == null) return unnameableSourceCollision(dep, cursorInfo, destInfo, files, standing, guardedDest);
		// A DOTLESS path no module in the index spells is the AMBIENT TOP LEVEL — `StringTools`, `Std`,
		// `Math`. A top-level module name is unique across a classpath, so it resolves to the same type
		// from every file: neither side can be rebound by carrying it, and the destination's own
		// unqualified references to that name already mean exactly what the carried statement gives them.
		// The index holding a module of that name (a root-package `StringTools.hx` of the project's own)
		// takes the exemption away, which is the case the gate below is really for.
		//
		// Dormant until the receiver scan started pricing `Std.int(...)` and `StringTools.trim(...)`:
		// measured, without this a `using StringTools;` carried past a destination that merely WRITES
		// `StringTools.trim(x)` was refused, and 2 of 15 accepted Pony `move-member` cases were lost.
		if (standing == null && guardedDest == null && wanted.indexOf('.') < 0 && !files.exists(fi -> fi.module == wanted)) return null;
		// A guarded import at the destination is a rung of SOME build's ladder and of no other, so
		// whether the carried line wins or loses is a per-configuration question. Refuse either way:
		// both directions were compile-run to a changed runtime class with rc 0.
		if (guardedDest != null && guardedDest != wanted && !importCandidates(dep, cursorInfo, files).contains(guardedDest))
			return 'the moved code reaches "$dep" as $wanted, and ${destInfo.file} binds "$dep" to $guardedDest inside a `#if` '
				+ 'guard — under that guard one of the two imports is last and the other loses, silently rebinding either the '
				+ 'moved code or the destination\'s; alias one of the two imports, or move the dependency too';
		if (standing == null) {
			// Nothing the index can name binds `dep` at the destination, which is NOT "nothing binds
			// it": the ambient top-level scope is invisible from here. Two ways that bites, one per
			// side of the move.
			return if (!hasProvider)
				// No carry, so the moved code takes the destination's ladder, and the ladder's visible
				// rungs are all empty — what is left is the ambient scope. Compile-proved: `p/Date.hx`
				// shadowing the stdlib `Date` for a same-package source, moved to a destination the
				// index says nothing about, resolved to the STDLIB `Date` with rc 0.
				'the moved code reaches "$dep" as $wanted with no import to carry, and nothing in the indexed scope binds '
					+ '"$dep" at ${destInfo.file} — the moved code would take that file\'s own resolution, which this index '
					+ 'cannot see; import "$dep" explicitly at the source first, or move the dependency too';
			else if (
				NameMentionScan.destinationNamesType(destSource, destInfo, dep, regions)
				&& !importCandidates(dep, destInfo, files).contains(wanted)
			)
				// The destination NAMES `dep` and the index cannot say what it means by it, so it means
				// something ambient — and a carried import outranks the ambient scope. Compile-proved
				// twice: a stdlib `Date` and a root-package `Dep.hx` at the destination each came back
				// as the carried module's type instead, rc 0, no output.
				'the moved code reaches "$dep" as $wanted, and ${destInfo.file} references "$dep" while nothing in the '
					+ 'indexed scope binds it there — it resolves through the ambient top level (a stdlib or top-level type, or '
					+ 'an out-of-scope package), which a carried import outranks, so carrying it would silently rebind that '
					+ 'file\'s own references to $wanted; alias the import, or qualify the references';
			else
				null;
		}
		if (standing.path == wanted) return null;
		final head: String = 'the moved code reaches "$dep" as $wanted, and ${destInfo.file} ';
		return if (!hasProvider)
			// Nothing to carry — the source reaches `dep` with no import statement, so at the
			// destination the moved code takes the DESTINATION's ladder. Always observable: the moved
			// declaration references `dep` by construction, which is why it is in the dependency set.
			'${head}resolves "$dep" to ${standing.path} instead, and the source binds it with no import to carry — so the moved '
				+ 'code would silently rebind to ${standing.path}; import it explicitly at the source first, or move the dependency too';
		else if (standing.ownModule)
			// A type the destination MODULE declares beats every import, so the carried line would be
			// inert and the MOVED code is the side that changes meaning — true whether or not the
			// destination names `dep` anywhere, which is why this arm does not ask.
			'${head}declares "$dep" itself (${standing.path}) — a module\'s own type wins over an import, so carrying the import '
				+ 'would silently rebind the moved code to ${standing.path}; rename one of the two, or move the dependency too';
		else if (NameMentionScan.destinationNamesType(destSource, destInfo, dep, regions))
			// An import or a same-package sibling loses to the carried line instead, so the side that
			// changes meaning is the destination's own code — and only if it names `dep` at all.
			'${head}already binds "$dep" to ${standing.path} — Haxe resolves the last import, so carrying the import would '
				+ 'silently rebind that file\'s own references from ${standing.path} to $wanted; alias one of the two imports, or '
				+ 'qualify the references';
		else
			null;
	}

	/**
	 * The `wanted == null` half of the collision gate: the SOURCE's own binding for `dep` is not
	 * nameable — the moved code reaches it through the ambient top level (the stdlib, or a module
	 * outside the scope), a wildcard whose package the index does not hold, or a `#if`-guarded import.
	 * Nothing is carried for any of those, so at the destination the moved code takes the DESTINATION's
	 * ladder, and there are only two answers: the destination's ladder is ALSO ambient, which is the
	 * same scope in every file and so cannot differ — or it names something, and then it names
	 * something else.
	 *
	 * Except when the two files spell the SAME statement for `dep`. Two macro modules each carrying
	 * `#if macro import haxe.macro.Expr;` is the commonest shape in the tree, and there the index can
	 * name neither side while the two agree perfectly — four of eleven changed outcomes in a 60-case
	 * `move` census over the Pony tree were exactly that.
	 */
	private static function unnameableSourceCollision(
		dep: String, cursorInfo: FileInfo, destInfo: FileInfo, files: Array<FileInfo>, standing: Null<NameBinding>,
		guardedDest: Null<String>
	): Null<String> {
		if (standing == null && guardedDest == null) return null;
		final reachable: Array<String> = importCandidates(dep, cursorInfo, files);
		if ((standing == null || reachable.contains(standing.path)) && (guardedDest == null || reachable.contains(guardedDest)))
			return null;
		// The path once, and the `#if` note once beside it — interpolating a pre-suffixed string into
		// both slots produced "rebind to X under a #if guard under a #if guard".
		final theirs: String = standing != null ? standing.path : '$guardedDest';
		final howTheirs: String = standing != null ? '' : ' inside a `#if` guard';
		final mine: Null<String> = guardedImportPath(dep, cursorInfo);
		final why: String = mine != null
			? 'the source binds it to $mine inside a `#if` guard, which is not carried'
			: 'the source reaches it outside the indexed scope (a stdlib or top-level type, or a package wildcard)';
		return 'the moved code reaches "$dep" through a binding this index cannot name — $why — and ${destInfo.file} binds '
			+ '"$dep" to $theirs$howTheirs, so the moved code would silently rebind to $theirs; import "$dep" explicitly at '
			+ 'the source first, or qualify its references';
	}

	/**
	 * Append to `out` the distinct names `node`'s subtree references in a TYPE position INSIDE
	 * `declSpan` — the moved declaration's dependency set, minus the declaration's own name. Walks
	 * every hit of the type-ref projection and keeps the ones the span contains.
	 */
	private static function collectDependencyNames(
		node: QueryNode, declSpan: Span, typeRefShape: TypeRefShape, typeName: String, out: Array<NameSpan>
	): Void {
		final name: Null<String> = node.name;
		final span: Null<Span> = node.span;
		if (
			name != null && span != null && typeRefShape.typeRefKinds.contains(node.kind) && span.from >= declSpan.from
			&& span.to <= declSpan.to && name != typeName
		)
			pushNameSpan(out, name, span);
		for (c in node.children) collectDependencyNames(c, declSpan, typeRefShape, typeName, out);
	}

	/**
	 * The kinds a MEMBER ACCESS projects as — the node whose receiver child is the head of a
	 * `Helper.go()`. Read off the shape rather than spelled here, so a second grammar's own spellings
	 * arrive with it; a shape that declares none contributes no receiver names at all.
	 */
	private static function memberAccessKinds(shape: RefShape): Array<String> {
		final out: Array<String> = [];
		for (kind in [shape.fieldAccessKind, shape.nullSafeAccessKind, shape.forceFieldAccessKind]) if (kind != null && !out.contains(kind))
			out.push(kind);
		return out;
	}

	/**
	 * Every UPPER-INITIAL name written as the RECEIVER of a member access inside `declSpan` —
	 * the `Helper` of `Helper.go()`, of `Helper.CONST` and of `@:build(Helper.make())`.
	 *
	 * These are dependencies exactly as a type position is, and until 2026-08-31 the carry could not
	 * see them at all: the projection it reads answers TYPE positions, so `apq uses Helper` returns 0
	 * hits on a file whose only reference is `Helper.go()`. The op's own doc called the residue LOUD —
	 * "the destination fails to COMPILE, never a silent semantic change" — and that claim is FALSE in
	 * the direction that matters. Measured on 4.3.7 through the base engine: a `Moved` reaching
	 * `r.Helper` through the source file's `import r.Helper;`, moved into a destination whose own
	 * package declares a `p.Helper`, came back bound to `p.Helper` — `Moved.use()` went from 42 to 7,
	 * rc 0, three files written and nothing to read. Priced here, the same move carries the import.
	 *
	 * Only the receiver slot, not every upper-initial identifier: a VALUE position
	 * (`Type.createInstance(Bar, [])`) and a constructor pattern (`case Red:`) are the same gap one
	 * step further out, and both are named in `NEW BACKLOG` rather than smuggled in — a bare `Red` is
	 * an enum CONSTRUCTOR far more often than a module, and `bindingOf` cannot tell the two apart.
	 *
	 * A dotted receiver needs no special case: `p.Mod.go()` projects the receiver as a nested member
	 * access whose own receiver is the lower-initial `p`, so only the innermost head is ever an
	 * `identKind` child and a package prefix is filtered by its case.
	 */
	private static function collectReceiverNames(
		node: QueryNode, declSpan: Span, identKind: String, accessKinds: Array<String>, typeName: String, out: Array<NameSpan>
	): Void {
		if (accessKinds.contains(node.kind)) for (child in node.children) {
			final name: Null<String> = child.name;
			final span: Null<Span> = child.span;
			if (
				name != null && span != null && child.kind == identKind && SourceText.isUpperInitial(name) && span.from >= declSpan.from
				&& span.to <= declSpan.to && name != typeName
			)
				pushNameSpan(out, name, span);
		}
		for (c in node.children) collectReceiverNames(c, declSpan, identKind, accessKinds, typeName, out);
	}

	/**
	 * Record `name` at `span` — the re-bind an anonymous-structure literal needs, in ONE place.
	 *
	 * Both collectors reach here with a narrowed `Null<String>` / `Null<Span>` pair, and a narrowed
	 * local does not reach a literal whose expected field type is non-nullable; a non-null PARAMETER
	 * does. `collectDependencyNames` spelled the two re-binding locals inline, and
	 * `collectReceiverNames` (new in this slice) repeated them, which is the shape `duplicate-code`
	 * names.
	 */
	private static function pushNameSpan(out: Array<NameSpan>, name: String, span: Span): Void {
		out.push({ name: name, span: span });
	}

	/**
	 * Does the declaration at `declSpan` write a member access anywhere inside it?
	 *
	 * The one necessary condition a `using` carry can be gated on. A static extension is only ever
	 * reached as `expr.method(...)`, so a declaration with no member access needs no `using` — and
	 * WHICH `using` supplies a given method is a question the tree cannot answer at all, which is why
	 * this asks the weaker one.
	 */
	private static function declHasMemberAccess(node: QueryNode, declSpan: Span, accessKinds: Array<String>): Bool {
		final span: Null<Span> = node.span;
		if (accessKinds.contains(node.kind) && span != null && span.from >= declSpan.from && span.to <= declSpan.to) return true;
		return node.children.exists(c -> declHasMemberAccess(c, declSpan, accessKinds));
	}

	/**
	 * The source module's `using` statements the destination lacks, appended to `carried`.
	 *
	 * A `using` grants STATIC EXTENSIONS, and an extension call spells the METHOD name and nothing else
	 * — no name scan can see which module supplied it. S40 settled the destination side on exactly that
	 * evidence (a destination `using` is KEPT unconditionally rather than name-scanned), and the source
	 * side is the mirror it did not close: the moved body's `s.trim()` arrived at a destination holding
	 * no `using StringTools;` and read `String has no field trim` at rc 0, one of four census cases
	 * (`Int has no field hex`, `Array<String> has no field exists`, `Float has no field int`).
	 *
	 * Carried unconditionally, with ONE necessary condition the tree can actually answer: a static
	 * extension is invoked as `expr.method(...)`, so a declaration holding no member access at all can
	 * need none. That keeps the line off the pure-data moves — a typedef, an enum of bare constructors
	 * — without ever guessing WHICH extension a body uses, which is the guess this exists to avoid.
	 *
	 * A `#if`-guarded statement is skipped for the reason every other carry skips one: it binds under
	 * its own flag and under no other, and an unconditional line at the destination does not reproduce
	 * that.
	 */
	private static function usingLinesToCarry(
		source: String, tree: QueryNode, accessKinds: Array<String>, declSpan: Span, cursorInfo: FileInfo, destInfo: FileInfo,
		destSource: String, files: Array<FileInfo>, carried: Array<String>, destRegions: Array<LexRegion>
	): Array<String> {
		if (!declHasMemberAccess(tree, declSpan, accessKinds)) return carried;
		for (imp in cursorInfo.imports) if (!imp.guarded && imp.kind == ImportKind.Using) {
			final path: Null<String> = SymbolIndex.pathImportedBy(imp);
			if (path == null) continue;
			// `!other.guarded` is what makes this the right question. A guarded statement is a rung of
			// SOME build's ladder and of no other, so a `#if js using StringTools; #end` at the
			// destination satisfies nothing for the default configuration — compile-proved: without the
			// filter the move wrote two files at rc 0 and the tree read `String has no field trim` on
			// neko. It is the same filter `addImportEdit` applies for the same reason.
			final already: Bool = destInfo.imports.exists(
				other -> !other.guarded && other.kind == ImportKind.Using && SymbolIndex.pathImportedBy(other) == path
			);
			if (already) continue;
			// The statement binds its module's own TYPE name beside the extensions, so it faces the same
			// collision gate a carried import does. But a collision SKIPS the line instead of refusing
			// the move, and the asymmetry with the dependency carry above is the whole point: there the
			// moved code PROVABLY names the dependency, so a destination that means something else by
			// that name is unrepairable and must be refused; here the need is unproven — the gate fired
			// on `using pony.Tools;` for a declaration that only ever writes `this.x` — so refusing
			// would cost a correct refactor for a statement nothing shows the moved code wants.
			// Skipping cannot rebind a TYPE name. It can leave the moved body's `x.f()` on whatever
			// extension the destination already supplies — the same residual `carriedDestEdits` names —
			// and otherwise it is a missing extension, which is loud.
			if (carryCollision(SourceText.lastSegment(imp.raw), path, cursorInfo, destInfo, destSource, files, true, destRegions) != null)
				continue;
			final line: String = DependencyCarry.importLineFor(imp, source);
			if (!carried.contains(line)) carried.push(line);
		}
		return carried;
	}

	/**
	 * The simple type names the moved declaration depends on, with every name that is really a TYPE
	 * PARAMETER of its own removed.
	 *
	 * Two kinds of parameter, subtracted two different ways. The DECLARATION's own (`class Moved<Key>`)
	 * shadow the whole span and come from the index, so the name goes at once — pricing one asked about
	 * a type the moved code never means, and `class Mover<Key>` beside a `p/Key.hx` was refused a move
	 * that was correct. A METHOD's are not indexed at all (the grammar projects no `<...>` list for a
	 * function at any depth), so they reach the type-ref walk only through the annotations that spell
	 * them and look exactly like a dependency on a module of that name — and they are subtracted PER
	 * OCCURRENCE, because `<Dep>` on one method shadows `Dep` inside that method and nowhere else.
	 * Dropping the NAME instead dropped a sibling `var d:Dep;` from the gate as well, which compile-ran
	 * to a changed runtime class with rc 0 on a move the base engine refused.
	 */
	private static function dependencyNames(
		tree: QueryNode, shape: RefShape, source: String, declSpan: Span, cursorInfo: FileInfo, plugin: GrammarPlugin,
		typeRefShape: TypeRefShape, typeName: String
	): Array<String> {
		final refs: Array<NameSpan> = [];
		collectDependencyNames(tree, declSpan, typeRefShape, typeName, refs);
		collectReceiverNames(tree, declSpan, shape.identKind, memberAccessKinds(shape), typeName, refs);
		final shadows: Array<NameSpan> = functionTypeParamNames(plugin, source, declSpan);
		for (t in cursorInfo.types)
			if (t.span.from <= declSpan.from && t.span.to >= declSpan.to)
				for (param in t.typeParamNames) shadows.push({ name: param, span: declSpan });
		final out: Array<String> = [];
		for (ref in refs) {
			final shadowed: Bool = shadows.exists(s -> s.name == ref.name && ref.span.from >= s.span.from && ref.span.to <= s.span.to);
			if (!shadowed && !out.contains(ref.name)) out.push(ref.name);
		}
		return out;
	}

	/**
	 * Every type-parameter name a FUNCTION inside `declSpan` declares (`function f<K, V>(...)`).
	 *
	 * The grammar does not project a function's `<...>` list — there is no node for it at any depth —
	 * so the names exist in the tree only as the type POSITIONS that spell them, indistinguishable
	 * from a dependency on a module of that name. This recovers them from the source the same way a
	 * type declaration's header parameters are recovered: the `<...>` run that closes immediately
	 * before the parameter list's `(`, split on its top-level commas.
	 *
	 * Anchored on the `(` rather than on the function's name, because a function node's span starts at
	 * the `function` keyword and searching forward for the name would match that keyword's own first
	 * letter. A multi-constraint parameter (`<T:(A, B)>`) puts a `(` inside the list and so is not
	 * read — the names stay priced, which costs a refusal rather than a miss.
	 */
	private static function functionTypeParamNames(plugin: GrammarPlugin, source: String, declSpan: Span): Array<NameSpan> {
		final shape: RefShape = plugin.refShape();
		final kinds: Array<String> = (shape.functionKinds ?? []).concat(shape.inlineFunctionKinds ?? []);
		if (kinds.length == 0) return [];
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (_: Exception) null;
		if (tree == null) return [];
		final out: Array<NameSpan> = [];
		collectFunctionTypeParams(tree, source, declSpan, kinds, out);
		return out;
	}

	/** The recursive half of `functionTypeParamNames`. */
	private static function collectFunctionTypeParams(
		node: QueryNode, source: String, declSpan: Span, kinds: Array<String>, out: Array<NameSpan>
	): Void {
		final nullableSpan: Null<Span> = node.span;
		if (nullableSpan != null && kinds.contains(node.kind) && nullableSpan.from >= declSpan.from && nullableSpan.to <= declSpan.to) {
			final span: Span = nullableSpan;
			final list: Null<String> = typeParamListBefore(source, span);
			if (list != null) for (segment in NominalTypes.splitTypeArgumentList(list)) {
				final name: Null<String> = NominalTypes.typeParamNameOf(segment);
				// The FUNCTION's span, not the parameter's: that is the region the name shadows.
				if (name == null) continue;
				final param: String = name;
				out.push({ name: param, span: span });
			}
		}
		for (c in node.children) collectFunctionTypeParams(c, source, declSpan, kinds, out);
	}

	/**
	 * The text between the `<` and the `>` of the type-parameter list that closes immediately before
	 * the parameter list of the function starting at `span`, or null when there is none.
	 *
	 * Anchored on the `(` rather than on the function's name: a function node's span starts at the
	 * `function` keyword, so searching forward for the name would match that keyword's own first
	 * letter. A multi-constraint parameter (`<T:(A, B)>`) puts a `(` inside the list and so reads as
	 * "no list" — the names stay priced, which costs a refusal rather than a miss.
	 */
	private static function typeParamListBefore(source: String, span: Span): Null<String> {
		final open: Int = source.indexOf('(', span.from);
		if (open <= span.from || open >= span.to) return null;
		var close: Int = open - 1;
		while (close > span.from && SourceText.isSpace(source.fastCodeAt(close))) close--;
		if (source.fastCodeAt(close) != '>'.code) return null;
		var depth: Int = 0;
		var i: Int = close;
		while (i > span.from) {
			final ch: Int = source.fastCodeAt(i);
			if (ch == '>'.code && source.fastCodeAt(i - 1) != '-'.code)
				depth++;
			else if (ch == '<'.code) {
				depth--;
				if (depth == 0) break;
			}
			i--;
		}
		return depth == 0 && i > span.from ? source.substring(i + 1, close) : null;
	}

	/**
	 * Does the destination reach `dep`, meaning exactly `wanted`, with NO statement of its own?
	 *
	 * Two visibility rungs Haxe grants for free, and a carried import would bind nothing either one
	 * already binds. The PACKAGE CHAIN — compile-run on 4.3.7, a `package p.q;` module reads a bare
	 * `Dep` declared `package p;` and a bare `Root` declared at the top level with no import — which
	 * 281 of the 767 modules one campaign sweep moved received a redundant line for, every one of
	 * them removed again by the `redundant-import` pass. And the destination's OWN module, which
	 * `packageOrTopLevelBinding` structurally cannot answer: it skips `info.file` itself and reports
	 * MAIN types only. That gap wrote `import b.Dest;` and `import b.Dest.Payload;` into `b/Dest.hx`
	 * itself over a `move-member` into it (T518).
	 *
	 * `wanted == null` is never a yes: an unnameable source binding is exactly the case the carry
	 * must not skip on, and the collision gate above has already had its say about it.
	 */
	private static function destinationSeesWithoutStatement(
		dep: String, wanted: Null<String>, destInfo: FileInfo, files: Array<FileInfo>
	): Bool {
		if (wanted == null) return false;
		final own: Null<NameBinding> = bindingOf(dep, destInfo, files);
		if (own != null && own.ownModule && own.path == wanted) return true;
		return packageOrTopLevelBinding(dep, destInfo, files) == wanted;
	}

	/**
	 * `import <path>;` / `using <path>;` / `import <path> as <alias>;` text for a carried import,
	 * spelled out of `statementSource` — which MUST be the source of the file `imp` was read from,
	 * since the `as` / `in` keyword is recovered by slicing `imp.span` out of it. `raw` is the path
	 * for every kind but `Alias`, where it is the alias, so the path comes from the project's one
	 * decoder and the suffix from `importStatementText`, which already writes a repointed one.
	 *
	 * The undecodable case throws rather than falling back: the value a fallback would produce is
	 * `import <the alias>;`, the exact line this seam exists to stop emitting, and it would reach
	 * the destination file silently. The carry filter already drops such a statement, so widening
	 * that filter without widening this is what the throw is here to catch.
	 */
	@:access(anyparse.query.MoveSymbol)
	private static function importLineFor(imp: ImportInfo, statementSource: String): String {
		final path: Null<String> = SymbolIndex.pathImportedBy(imp);
		if (path == null) throw new Exception('importLineFor: carried import "${imp.raw}" names no decodable module path');
		return MoveSymbol.importStatementText(imp, path, statementSource.substring(imp.span.from, imp.span.to));
	}

	/**
	 * The `import <module>.*;` statements the moved declaration reaches a name through, appended to
	 * `carried` (or folded into `guarded` when the statement is `#if`-guarded), and the refusal a
	 * carry that would silently rebind owes instead.
	 *
	 * A MODULE-static wildcard binds no type at all — measured on 4.3.7, `import m.Mod.*;` brings in
	 * the MAIN type's static fields and, for an enum main type, its constructors; a SUB-module type's
	 * statics stay unbound (`Unknown identifier : fromSide`). So nothing the dependency walk asks
	 * about — a type position, an upper-initial receiver — can ever see one, and the whole class of
	 * name it provides was invisible to the carry: `move-member` wrote a destination reading
	 * `Unknown identifier : packOf` at rc 0, `wrote 2 file(s)`, with the advisory calling the miss
	 * best-effort (T559). For `src/anyparse/macro` that is not an edge: 20 files reach
	 * `MacroNames.*` this way, 73 reach `ExitCode.*`, and the moved body of the very member S87
	 * carried by hand reached `WriterLoweringSupport.optFieldAccess` through one.
	 *
	 * The refusals are the two ways a carry cannot repair the name. A member the DESTINATION's own
	 * type declares wins over any import (measured: a class declaring `fromMain` printed `own`, not
	 * the wildcard's), so the moved body would silently rebind to it. And a second module-static
	 * wildcard at the destination whose module declares any of the same names is decided by
	 * STATEMENT ORDER — the last one wins, measured, with no diagnostic — so whichever way the
	 * carried line is seated one of the two files changes meaning.
	 */
	private static function foldWildcardCarry(
		source: String, declSpan: Span, cursorInfo: FileInfo, destInfo: FileInfo, files: Array<FileInfo>, plugin: GrammarPlugin,
		carried: Array<String>, guarded: Array<{ condition: String, lines: Array<String> }>, directives: Null<Array<CondDirective>>
	): Null<String> {
		final shape: RefShape = plugin.refShape();
		final providers: Array<WildProvider> = wildcardStaticProviders(cursorInfo, files, shape);
		if (providers.length == 0) return null;
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (_: Exception) null;
		if (tree == null) return null;
		final free: Array<String> = freeNamesInside(tree, declSpan, shape, providers);
		if (free.length == 0) return null;
		var scanned: Null<Array<CondDirective>> = directives;
		for (provider in providers) {
			final wanted: Array<String> = provider.names.filter(name -> free.contains(name));
			if (wanted.length == 0) continue;
			// Asked BEFORE the already-present skip: a destination that declares the name shadows the
			// moved body whether or not anything is carried, so a statement already standing there is
			// no reason to stay silent about it.
			final shadow: Null<String> = shadowedByDestMember(provider, wanted, destInfo);
			if (shadow != null) return shadow;
			if (destInfo.imports.exists(imp -> imp.kind == ImportKind.Wild && imp.raw == provider.imp.raw)) continue;
			final refusal: Null<String> = rivalWildcardCollision(provider, wanted, destInfo, files, shape);
			if (refusal != null) return refusal;
			if (!provider.imp.guarded) {
				final line: String = DependencyCarry.importLineFor(provider.imp, source);
				if (!carried.contains(line)) carried.push(line);
				continue;
			}
			final walk: Array<CondDirective> = scanned ?? GuardedImportCarry.directivesOf(source, plugin);
			scanned = walk;
			final guardRefusal: Null<String> = foldGuardedResult(
				GuardedImportCarry.carryForProviders([provider.imp], wanted[0], cursorInfo.file, source, walk, shape), source, guarded
			);
			if (guardRefusal != null) return guardRefusal;
		}
		return null;
	}

	/**
	 * The reason a name a module-static wildcard binds cannot survive the move at all, or null.
	 *
	 * A member the DESTINATION MODULE declares wins over every imported static — measured on 4.3.7, a
	 * class declaring `fromMain` printed `own` rather than the wildcard's — so the moved body would
	 * silently rebind to it. Asked whether or not the statement is carried, because carrying is not
	 * what creates the shadow.
	 *
	 * Every type of the destination FILE is asked, not the one type the member is landing in: this
	 * layer answers for a whole file and has no destination type to narrow to. A sibling type's
	 * member does not really shadow, so that costs a refusal rather than a rebind — the direction
	 * every gate in this module takes.
	 */
	private static function shadowedByDestMember(provider: WildProvider, wanted: Array<String>, destInfo: FileInfo): Null<String> {
		final shadowed: Null<String> = wanted.find(name -> destInfo.types.exists(t -> t.members.exists(m -> m.name == name)));
		return shadowed == null
			? null
			: 'the moved code reaches "$shadowed" through "import ${provider.imp.raw};", and ${destInfo.file} declares a member '
				+ '"$shadowed" of its own — a type\'s own member wins over an imported static, so the moved body would silently '
				+ 'rebind to it; rename one of the two, or qualify the reference as ${SourceText.lastSegment(provider.module)}.$shadowed';
	}

	/**
	 * The reason a module-static wildcard must not be CARRIED past a rival one the destination
	 * already has, or null.
	 *
	 * A second module-static wildcard declaring a name in common is decided by STATEMENT ORDER — the
	 * last one wins, measured on 4.3.7 with no diagnostic — so whichever way the carried line is
	 * seated one of the two files changes meaning.
	 *
	 * Asked of the whole name SET rather than of the names the moved body uses: an overlap the moved
	 * code does not touch is still an overlap the DESTINATION's own code may, and this gate has no
	 * way to tell a used one from an idle one. It costs a refusal on a shape where two wildcard
	 * modules merely share a name, which no file in this tree does.
	 */
	private static function rivalWildcardCollision(
		provider: WildProvider, wanted: Array<String>, destInfo: FileInfo, files: Array<FileInfo>, shape: RefShape
	): Null<String> {
		for (other in wildcardStaticProviders(destInfo, files, shape)) if (other.module != provider.module) {
			final clash: Null<String> = provider.names.find(name -> other.names.contains(name));
			if (clash != null)
				return 'the moved code reaches "${wanted[0]}" through "import ${provider.imp.raw};", and ${destInfo.file} already '
					+ 'carries "import ${other.imp.raw};" — both modules declare "$clash", and Haxe resolves the LAST wildcard, so '
					+ 'carrying this one would silently rebind either the moved code or that file\'s own; qualify the references, or '
					+ 'move the dependency too';
		}
		return null;
	}

	/**
	 * Every unguarded-or-guarded `import <module>.*;` of `info`'s file whose head names a MODULE the
	 * index holds, paired with the simple names it binds.
	 *
	 * A wildcard whose head is a PACKAGE is a different statement with a different answer —
	 * `wildcardBinding` prices that one, because it binds TYPES — and one whose head the index cannot
	 * see binds names this walk cannot enumerate, so it contributes nothing rather than a guess.
	 */
	private static function wildcardStaticProviders(info: FileInfo, files: Array<FileInfo>, shape: RefShape): Array<WildProvider> {
		final out: Array<WildProvider> = [];
		for (imp in info.imports) if (imp.kind == ImportKind.Wild && imp.raw.endsWith('.*')) {
			final head: String = imp.raw.substring(0, imp.raw.length - 2);
			final holder: Null<FileInfo> = files.find(fi -> fi.module == head);
			if (holder == null) continue;
			final names: Array<String> = staticNamesOf(holder, shape);
			if (names.length > 0) out.push({ imp: imp, module: head, names: names });
		}
		return out;
	}

	/**
	 * The simple names a module-static wildcard on `holder` binds: every member of its MAIN type that
	 * is reachable as `MainType.<name>` — a `static` one, an `enum abstract` value (static without
	 * carrying the modifier, which is what `implicitlyStaticMember` is for), and an enum
	 * constructor. Measured on 4.3.7: a SUB-module type's statics are NOT bound by the wildcard, so
	 * only the main type is read.
	 */
	private static function staticNamesOf(holder: FileInfo, shape: RefShape): Array<String> {
		final main: Null<TypeDeclInfo> = holder.types.find(t -> t.isMain);
		if (main == null) return [];
		final kind: String = main.kind;
		return [
			for (m in main.members)
				if (m.isStatic || MemberKinds.implicitlyStaticMember(kind, m.kind, shape) || MemberKinds.isEnumConstructorKind(m.kind))
					m.name
		];
	}

	/**
	 * Which of the wildcard-bound names the declaration at `declSpan` writes as a BARE identifier
	 * that nothing in its own file binds.
	 *
	 * Both halves are load-bearing. The mention has to be a NODE — a name inside a comment or a
	 * string is not a reference, and this answer WRITES an import. And it has to be unbound: a local,
	 * a parameter or a member of the source type that happens to share a name with one of the
	 * module's statics is resolved by the file itself, and carrying a statement for it would add an
	 * import nothing needs — `redundant-import` then reports the file the move just wrote.
	 */
	private static function freeNamesInside(
		tree: QueryNode, declSpan: Span, shape: RefShape, providers: Array<WildProvider>
	): Array<String> {
		final identKind: String = shape.identKind;
		final candidates: Array<String> = [];
		for (provider in providers) for (name in provider.names) if (!candidates.contains(name)) candidates.push(name);
		final mentioned: Array<String> = [];
		collectBareMentions(tree, declSpan, identKind, candidates, mentioned);
		if (mentioned.length == 0) return [];
		final hits: Map<String, Array<RefHit>> = Refs.findMulti(mentioned, tree, shape);
		return [
			for (name in mentioned)
				if (!(hits[name] ?? []).exists(h -> h.bindingSpan != null && h.span.from >= declSpan.from && h.span.to <= declSpan.to)) name
		];
	}

	/** The recursive half of `freeNamesInside`: distinct `identKind` names inside `declSpan` that are candidates. */
	private static function collectBareMentions(
		node: QueryNode, declSpan: Span, identKind: String, candidates: Array<String>, out: Array<String>
	): Void {
		final name: Null<String> = node.name;
		final span: Null<Span> = node.span;
		if (
			name != null && span != null && node.kind == identKind && span.from >= declSpan.from && span.to <= declSpan.to
			&& candidates.contains(name) && !out.contains(name)
		)
			out.push(name);
		for (c in node.children) collectBareMentions(c, declSpan, identKind, candidates, out);
	}

}

/**
 * Outcome of the dependency-import carry — the statements the moved code needs at the
 * destination, or the reason a move must not happen at all.
 *
 * The carry needs an error channel because a bound-name COLLISION is not a missing import it can
 * work around: the destination already binds that simple name to a different module, and every
 * way of proceeding changes what some existing code means. Emitting the second binding — what the
 * op did until 2026-08-27 — is the worst of them, because Haxe resolves the last import and says
 * nothing: `import b.Dep;` carried into a destination holding `import p.Dep;` compiled clean and
 * silently retyped the destination's own `new Dep()` from `p.Dep` to `b.Dep`.
 */
enum CarryResult {

	CarryOk(lines: Array<String>);
	CarryErr(message: String);

}

/**
 * One binding a file already has for a simple type name: the importable path it resolves to, and
 * whether that binding is the file's OWN module declaration — the half that decides which side of a
 * collision would silently change meaning, and therefore what the refusal tells its author to do
 * about it. Asked of the destination and of the source alike, which is why it is not named for
 * either.
 */
typedef NameBinding = {
	var path: String;
	var ownModule: Bool;
}

/**
 * A simple name paired with the source span it is written at. Two readings, both needing the span
 * the bare name loses: a type-POSITION occurrence inside the moved declaration, and the REGION a
 * function's type parameter shadows that name over.
 *
 * A method's `<Dep>` shadows `Dep` only inside that method, so the same name can be a parameter at
 * one occurrence and a genuine dependency at another in the same declaration — un-pricing it by
 * NAME dropped the dependency from the gate entirely, which a `pick<Dep>` beside a `var d:Dep;`
 * compile-ran to a changed runtime class with rc 0.
 */
typedef NameSpan = {
	var name: String;
	var span: Span;
}

/**
 * One module-static wildcard of a file (`import pkg.Mod.*;`): the statement, the MODULE its head
 * names, and the simple names it binds — the main type's statics, an `enum abstract`'s values and
 * an enum's constructors.
 *
 * The names are carried beside the statement because the statement's own text cannot answer for
 * them: `raw` ends in `*`, so which names a wildcard provides is an INDEX question, asked once per
 * provider and then read twice — for the moved body's free names and for the destination's own
 * wildcards, which is where the two answers have to be compared.
 */
private typedef WildProvider = {
	var imp: ImportInfo;
	var module: String;
	var names: Array<String>;
}
