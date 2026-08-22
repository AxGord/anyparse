package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.ReflectionScan.ReflectionSurface;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberBranchScan;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Flags a `get_X` / `set_X` method that no property slot ever reaches — the accessor half of a
 * property whose declaration was changed to `(default, set)` / a plain field, or removed, while
 * the method stayed behind. Haxe never calls such a method: an accessor runs because the
 * property's `(get, …)` / `(…, set)` clause names it, so with the slot gone the body is dead
 * weight that still reads like live behaviour. DEFAULT OFF (`apqlint.json`
 * `"rules": { "orphan-accessor": { "enabled": true } }`, or an explicit `--rule`).
 *
 * ## What counts as declaring the slot
 *
 * The property `X` is resolved through the WHOLE inheritance chain — the class itself, then its
 * `extends` superclass and every `implements` interface, transitively (`supertypesRaw` resolved
 * through the index, so a qualified / imported supertype resolves to ONE declaring type). A
 * member named `X` declares the read slot when its accessor clause's READ ident is anything other
 * than `default` / `null` / `never` (`get`, and `dynamic` too — a dynamic accessor is a real,
 * re-bindable one), and the write slot symmetrically; that test is `MemberInfo.hasGetter` /
 * `hasSetter`, which is populated only when the plugin supplies a `TypeInfoProvider` — the Haxe
 * plugin does, and under a grammar that does not every slot reads as absent, so the rule is
 * meaningful only where property accessors are reported. An `override` accessor needs NO property
 * redeclaration in the subclass — the chain walk finds the supertype's property and the method is
 * legit.
 *
 * Statics and instance members are separate namespaces, so a candidate matches only a member of
 * its OWN staticness: a `static var v(get, never)` is not the property an instance `get_v` serves,
 * and reading it as one hides a real orphan in one direction and reports a live accessor in the
 * other. The accessor's staticness (and its `@:keep`) come from the modifier / metadata run
 * preceding it, which resets at every MEMBER — a `static` written on a preceding FIELD belongs to
 * that field.
 *
 * Haxe resolves an accessor UPWARD from the property, so the chain is not the whole story: a
 * property declared by a SUBTYPE is legitimately served by a method inherited from here. That is
 * checked (`SymbolIndex.subtypeDeclaresMember`) on the found-nothing arm only — an `X` found at or
 * above this class forbids a subtype redeclaring the same field, so the declared-without-slot arm
 * cannot be reached that way. That query walks from the subtype DECLARATION and treats an
 * ambiguous supertype link as a MAY, since here `true` means "leave the method alone".
 *
 * ## Three arms
 *
 * 1. `X` IS declared somewhere in the chain but WITHOUT the matching slot — PROVEN orphan
 *    (`Warning`). Haxe forbids redeclaring an inherited field, so a second declaration of `X`
 *    behind an unresolvable supertype cannot exist; the proof holds even with an unresolved link
 *    in the chain.
 * 2. No `X` anywhere in the chain OR below it, AND every supertype link resolved — PROVEN orphan
 *    (`Warning`).
 * 3. No `X` anywhere but a supertype link did NOT resolve — `Info`, report-only: the property may
 *    live in the unread type. Never fixed.
 *
 * Two macro shapes take the class out of scope entirely, because their generated members never
 * reach the index and the property may be among them: `@:build` on the class itself, and
 * `@:autoBuild` on ANY ancestor — that one generates into DESCENDANTS, not into its carrier, so it
 * is read while walking the chain rather than off the class in hand.
 *
 * A supertype the index cannot resolve by IMPORT VISIBILITY — Haxe needs no import to name a type
 * from a PARENT package, a visibility `SymbolIndex.simpleRefInScope` does not model — is still
 * walked when its simple name has exactly ONE project-wide declaration, but SPECULATIVELY: such a
 * type may prove a slot EXISTS (so arm 3 stays silent) and never that the property is declared
 * WITHOUT one, and the link stays counted as unresolved. A chain resolved only that way is
 * therefore never deleted from, and the fallback can only silence a finding — never raise one.
 * (The proper fix is a parent-package arm in `simpleRefInScope` itself, which would serve every
 * other consumer of that predicate; that is a wider change than this rule.)
 *
 * ## Autofix
 *
 * The fix DELETES the method (with its modifier / metadata run and its leading doc comment, via
 * `docExtendedSpan`), and only for arms 1 and 2, when four further gates hold: no report file
 * skip-parses (a file the parser could not read might hold a call); neither the class nor the
 * member carries `@:keep` (they are reached by machinery no scan models); the method name has ZERO
 * direct call or value references — no `IdentExpr` / `FieldAccess` / string-interpolation ident
 * carries it anywhere in REPORT SCOPE; and no string literal in that scope names it, a possible
 * `Reflect.field` target whose breakage is SILENT at runtime rather than a compile error. An
 * INTERPOLATED string is matched the other way round — `literalOf` answers null for one by
 * contract, so its static `Literal` fragments are collected and a fragment CONTAINED IN the method
 * name blocks the deletion (`'get_$suffix'` may name it at runtime); fragments shorter than an
 * accessor prefix carry no intent and are ignored.
 *
 * The zero-reference gate is NOT the orphan test: a REAL accessor is invoked through property
 * access and shows zero textual calls too, which is exactly why the orphan test is the
 * property-slot absence. It gates only the DELETE, catching the case where `get_X` is also called
 * by hand as an ordinary method.
 *
 * REPORT SCOPE is the boundary of every scan here — the reference scans, the string scans, and the
 * subtype query all see the file set the lint was given (widened to the resolution scope where one
 * is configured). A narrowed scope therefore narrows both halves: `--fix` over a subdirectory can
 * delete a method the rest of the project calls, and a REPORT over a subdirectory can raise a
 * `Warning` on an accessor whose property is declared by a subtype outside it. Run the rule
 * whole-project; a subdirectory run is a preview, not a verdict.
 *
 * Scope is class bodies (`CheckScan.classBodies`: `class` / `final class` / `abstract class`).
 * An `interface` declares no accessor bodies; an `abstract` type's accessors are left alone (its
 * `@:forward` / `@:op` members reach the underlying type by rules the index does not model).
 */
@:nullSafety(Strict)
final class OrphanAccessor implements Check implements DefaultOff {

	/**
	 * `<file>#<from>:<to>` of every flagged accessor whose deletion `run` PROVED safe. The
	 * deletion gates (chain resolution, project-wide call scan, skip-parse completeness) are all
	 * whole-project, and `fix` sees one file — so the verdict is computed once where the whole
	 * file set is in hand and read back by span. A finding with no entry here is report-only;
	 * `fix` called without a preceding `run` therefore edits nothing (fail-closed).
	 */
	private var _deletable: Array<String> = [];

	public function new() {}

	public function id(): String {
		return 'orphan-accessor';
	}

	public function description(): String {
		return
			'a get_X / set_X method whose property X declares no matching accessor slot anywhere in the inheritance chain — an accessor '
				+ 'Haxe never calls';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		_deletable = [];
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final out: Array<Violation> = [];
		// Supertypes resolve over report UNION resolution scope: a base class in a configured
		// library (openfl's DisplayObject) declares the property slot a report-only index cannot
		// see, and reading it as absent would flag every inherited accessor.
		final wide: SymbolIndex = RefactorSupport.resolutionIndexOf(plugin) ?? index;
		final reflection: ReflectionSurface = ReflectionScan.reflectionSurface(files, plugin);
		final ctx: Ctx = {
			referenced: referencedAccessorNames(files, plugin),
			reflected: reflection.whole,
			fragments: reflection.fragments,
			scanComplete: index.skippedFiles().length == 0,
			retainedMeta: plugin.refShape().retainedDeclMetaName
		};
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			// The resolution index carries the report files too, but only when a scope reached
			// the run at all — fall back to the report index rather than skipping the file.
			final scope: SymbolIndex = wide.fileInfo(entry.file) == null ? index : wide;
			final info: Null<FileInfo> = scope.fileInfo(entry.file);
			if (info == null) continue;
			final branch: MemberBranchSeams = MemberBranchScan.seamsOf(plugin.refShape(), entry.source);
			for (cls in CheckScan.classBodies(tree)) considerClass(out, cls, scope, info, ctx, branch);
		}
		return out;
	}

	/**
	 * Delete each flagged accessor `run` proved deletable — the method with its modifier /
	 * metadata run (`declGroupSpan`) and its leading doc comment (`docExtendedSpan`), then the
	 * whole line (`lineExtendedSpan`), so no orphaned doc comment or blank modifier line is left
	 * behind. A finding absent from `_deletable` (arm 3, a live call, a skip-parse in scope)
	 * yields no edit.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return CheckScan.deleteMethodsFix(plugin, source, violations, _deletable);
	}

	/**
	 * Flag every `get_` / `set_` method of `cls` whose property slot the inheritance chain does
	 * not declare, and record the ones whose deletion is proven safe. `host` is the class's own
	 * declaring file, `scope` the index the chain walk resolves supertypes through.
	 */
	private function considerClass(
		out: Array<Violation>, cls: QueryNode, scope: SymbolIndex, host: FileInfo, ctx: Ctx, branch: MemberBranchSeams
	): Void {
		final className: Null<String> = cls.name;
		if (className == null) return;
		// Re-bound to a non-null local: the narrowing does not reach into the member callback below.
		final owner: String = className;
		final declared: Null<TypeDeclInfo> = host.types.find(t -> t.name == owner);
		if (declared == null) return;
		// A `@:build` macro can declare the very property the accessor serves, and its members are
		// invisible to the index — the class is skipped whole rather than mis-flagged. `@:autoBuild`
		// on the class ITSELF generates into its descendants, never here; the chain walk reads that.
		if (declared.hasBuild) return;
		final decl: TypeDeclInfo = declared;
		final file: String = host.file;
		final deleting: Array<QueryNode> = [];
		// The run resets at EVERY member, not only at a method: a `static` / `@:keep` written on a
		// preceding FIELD would otherwise carry onto the next accessor and answer for it. A member
		// written inside a member-position `#if` region is visited too, with its own branch's run.
		MemberBranchScan.eachMember(branch, cls, child -> RefactorSupport.isMemberDeclKind(child.kind), (child, run, certain) -> {
			final isMethod: Bool = CheckScan.METHOD_KINDS.contains(child.kind);
			final name: Null<String> = child.name;
			final span: Null<Span> = child.span;
			// A modifier run only SOME builds see cannot answer `static`, which this rule reads as
			// enabling: a guarded `static` would make the accessor read as static everywhere, stop it
			// pairing with its instance property, and produce a finding whose fix DELETES a live
			// accessor. See `MemberBranchScan.joinRuns`.
			if (!certain || !isMethod || name == null || span == null) return;
			final retained: Null<String> = ctx.retainedMeta;
			final memberKept: Bool = retained != null && runCarries(run, retained, true);
			final isStatic: Bool = runCarries(run, 'Static', false);
			final target: Null<{ prop: String, getter: Bool }> = accessorTargetOf(name);
			if (target == null) return;
			final prop: String = target.prop;
			final wantGetter: Bool = target.getter;
			final found: Resolution = {
				declared: false,
				withSlot: false,
				unresolved: false,
				generated: false
			};
			walkChain(scope, host, decl, prop, wantGetter, isStatic, found, [], false);
			// A `@:autoBuild` ancestor generates members INTO this class, the property among them
			// possibly — its member set is not knowable, so the method is left alone.
			if (found.withSlot || found.generated) return;
			// Haxe resolves an accessor UPWARD from the property, so a property declared by a
			// SUBTYPE is legitimately served by this inherited method. Only the found-nothing arm
			// needs the check: a declaration found at or above this class forbids a subtype
			// redeclaring the same field, so arm 1 cannot be reached this way.
			if (!found.declared && scope.subtypeDeclaresMember(owner, prop)) return;
			if (!reportOrphan(out, file, span, name, prop, owner, wantGetter, found)) return;
			if (deletable(ctx, decl.hasKeep || memberKept, name)) deleting.push(child);
		});
		// Emptying a `#if` region of members leaves a shape the grammar does not model, and the
		// re-parse gate would then drop EVERY edit the pass had for this file — so the question is
		// asked once over the whole class's edit set, not per member. The findings above stay.
		for (member in MemberBranchScan.survivingDeletions(branch, cls, deleting, isDeclKind)) {
			final span: Null<Span> = member.span;
			if (span != null) _deletable.push(CheckScan.spanKey(file, span));
		}
	}

	/** One finding of this rule. */
	private static inline function violation(file: String, span: Span, severity: Severity, message: String): Violation {
		return {
			file: file,
			span: span,
			rule: 'orphan-accessor',
			severity: severity,
			message: message
		};
	}

	/**
	 * Whether the flagged accessor `name` may be DELETED: the report scan must be complete (no
	 * skip-parse file could hide a use), the owning class must not be `@:keep` (its members are
	 * reached by machinery no scan sees), the name must have no direct call / value reference,
	 * and it must appear in no string literal in scope — a possible `Reflect.field` target, whose
	 * breakage is SILENT at runtime rather than a compile error.
	 */
	private static function deletable(ctx: Ctx, kept: Bool, name: String): Bool {
		// A LITERAL FRAGMENT of an interpolated string (`Reflect.field(o, 'get_$suffix')`) is only
		// ever part of the runtime name, so containment is asked the other way round — the shared
		// `runtimeNameFragment`, which also owns the floor below which a fragment carries no intent.
		return ctx.scanComplete && !kept && !ctx.referenced.contains(name) && !ctx.reflected.exists(content -> content.indexOf(name) >= 0)
			&& !ReflectionScan.runtimeNameFragment(ctx.fragments, name);
	}

	/**
	 * Accumulate into `found` whether `prop` is declared by `type` or anywhere above it, and
	 * whether the declaration carries the wanted accessor slot. A supertype reference that
	 * resolves to no indexed declaration sets `unresolved` — the caller's proof of ABSENCE then
	 * fails, while a declaration already found stays conclusive (Haxe forbids redeclaring an
	 * inherited field, so an unread supertype cannot hold a second `prop`).
	 */
	private static function walkChain(
		scope: SymbolIndex, host: FileInfo, type: TypeDeclInfo, prop: String, wantGetter: Bool, wantStatic: Bool, found: Resolution,
		seen: Array<String>, speculative: Bool
	): Void {
		// The key carries `speculative`: a type stamped during a speculative walk deliberately
		// withheld its `declared` evidence, so reaching it again through a RESOLVED link must
		// re-visit it — else an arm-1 proof is lost purely because of supertype-clause order.
		final visited: String = '${host.file}#${type.name}#$speculative';
		if (found.withSlot || seen.contains(visited)) return;
		seen.push(visited);
		// Statics and instance members live in separate namespaces: a static `v` can never be the
		// property an instance `get_v` serves, and vice versa. Matching without this reads a
		// same-named static as the property and both directions are wrong — one hides a real
		// orphan, the other reports a live accessor whose real property sits in the other namespace.
		for (m in type.members) if (m.name == prop && m.isStatic == wantStatic) {
			if (wantGetter ? m.hasGetter : m.hasSetter) {
				found.withSlot = true;
				return;
			}
			// A SPECULATIVE type may not be the real supertype, so its member list is evidence
			// only in the suppressing direction — it can prove a slot EXISTS, never that the
			// property is declared-without-one (which arm 1 would delete on).
			if (!speculative) found.declared = true;
		}
		for (raw in type.supertypesRaw) {
			final resolved: Array<{ file: FileInfo, type: TypeDeclInfo }> = scope.resolveTypeRefsFrom(raw, host.file);
			// Import-visibility resolution misses a supertype the file reaches by simple name
			// through a PARENT package (Haxe needs no import for that, and the index models only
			// same-package / root / explicit-import / wildcard visibility). Fall back to a
			// project-wide UNIQUE simple name so its slots still count — but keep the link marked
			// unresolved and walk it speculatively, so the fallback can only silence a finding,
			// never create a `Warning` or license a deletion on a type it guessed at.
			final speculate: Bool = resolved.length == 0;
			final supers: Array<{ file: FileInfo, type: TypeDeclInfo }> = speculate ? uniqueDeclaration(scope, raw) : resolved;
			if (speculate) found.unresolved = true;
			for (s in supers) {
				// `@:autoBuild` generates into DESCENDANTS, so an ancestor carrying it owns an
				// invisible member set on the class the walk started from. Read speculatively too:
				// suppressing on a type that may not be the real ancestor is the safe direction.
				if (s.type.hasAutoBuild) found.generated = true;
				walkChain(scope, s.file, s.type, prop, wantGetter, wantStatic, found, seen, speculative || speculate);
			}
		}
	}

	/** The single project-wide declaration of `raw`'s simple name, or nothing when it is absent or ambiguous. */
	private static function uniqueDeclaration(scope: SymbolIndex, raw: String): Array<{ file: FileInfo, type: TypeDeclInfo }> {
		final dot: Int = raw.lastIndexOf('.');
		final simple: String = dot < 0 ? raw : raw.substr(dot + 1);
		final declarers: Array<FileInfo> = scope.declaringFiles(simple);
		if (declarers.length != 1) return [];
		final owner: FileInfo = declarers[0];
		final type: Null<TypeDeclInfo> = owner.types.find(t -> t.name == simple);
		return type == null ? [] : [{ file: owner, type: type }];
	}

	/**
	 * Every `get_` / `set_`-prefixed name that appears in report scope as an identifier or a
	 * field access — a direct call (`get_x()`, `this.get_x()`, `super.get_x()`, `o.get_x()`) or a
	 * value reference (`f.bind(get_x)`). Declarations project as member kinds, not as these, so a
	 * name occurring ONLY as its own declaration is absent from the result.
	 */
	private static function referencedAccessorNames(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<String> {
		final shape: RefShape = plugin.refShape();
		final kinds: Array<String> = [shape.identKind];
		final fieldAccess: Null<String> = shape.fieldAccessKind;
		if (fieldAccess != null) kinds.push(fieldAccess);
		// A simple `$name` inside an interpolated string projects as its OWN kind, not as
		// `identKind` — without it `'$get_x'` reads as no reference at all and the method goes.
		final interpolated: Null<String> = shape.stringInterpIdentKind;
		if (interpolated != null) kinds.push(interpolated);
		final out: Array<String> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) collectReferences(tree, kinds, out);
		}
		return out;
	}

	/** Collect into `out` the accessor-shaped names `node` and its descendants carry on a `kinds` node. */
	private static function collectReferences(node: QueryNode, kinds: Array<String>, out: Array<String>): Void {
		final name: Null<String> = node.name;
		if (
			name != null && kinds.contains(node.kind)
			&& (StringTools.startsWith(name, CheckScan.GET_PREFIX) || StringTools.startsWith(name, CheckScan.SET_PREFIX))
			&& !out.contains(name)
		)
			out.push(name);
		for (child in node.children) collectReferences(child, kinds, out);
	}

	/** `RefactorSupport.isMemberDeclKind` as a node predicate — the member set every region guard counts. */
	private static function isDeclKind(node: QueryNode): Bool {
		return RefactorSupport.isMemberDeclKind(node.kind);
	}

	/**
	 * Whether the modifier run `run` carries `wanted` — an annotation NAME when `isMeta`, otherwise a
	 * modifier KIND. A metadata node's name and a plain modifier's kind live in different slots, so
	 * the two questions cannot share one `contains`.
	 */
	private static function runCarries(run: Array<QueryNode>, wanted: String, isMeta: Bool): Bool {
		for (mod in run) {
			final meta: Bool = RefactorSupport.META_KINDS.contains(mod.kind);
			if (meta == isMeta && (isMeta ? mod.name == wanted : mod.kind == wanted)) return true;
		}
		return false;
	}

	/**
	 * The property an accessor method name serves — `get_x` / `set_x` → `x`, plus which slot it
	 * fills — or null when the name carries no accessor prefix or names an empty property.
	 */
	private static function accessorTargetOf(name: String): Null<{ prop: String, getter: Bool }> {
		final wantGetter: Bool = name.startsWith(CheckScan.GET_PREFIX);
		if (!wantGetter && !name.startsWith(CheckScan.SET_PREFIX)) return null;
		final prop: String = name.substr(CheckScan.GET_PREFIX.length);
		return prop == '' ? null : { prop: prop, getter: wantGetter };
	}

	/**
	 * Push the finding for an accessor no property serves and report whether the verdict was PROVEN:
	 * an unresolvable supertype leaves it unproven, which is `Info` and never deletable, while a
	 * fully resolved chain is a `Warning` whose method the deletion gate may then consider.
	 */
	private static function reportOrphan(
		out: Array<Violation>, file: String, span: Span, name: String, prop: String, owner: String, wantGetter: Bool, found: Resolution
	): Bool {
		if (!found.declared && found.unresolved) {
			out.push(violation(
				file, span, Severity.Info,
				'$name may have no property to serve: no $prop is declared in $owner'
				+ ' or in the supertypes that resolved, and an unresolvable supertype leaves it unproven'
			));
			return false;
		}
		final slot: String = wantGetter ? 'get' : 'set';
		out.push(violation(
			file, span, Severity.Warning,
			found.declared
				? '$name has no property to serve: $prop declares no $slot accessor'
				: '$name has no property to serve: neither $owner nor its supertypes declare $prop'
		));
		return true;
	}

}

/** The accumulated verdict of one inheritance-chain walk for a single property name. */
private typedef Resolution = {

	/** Whether a member of that name was found anywhere in the resolved chain. */
	var declared: Bool;

	/** Whether such a member declares the wanted accessor slot — the walk stops as soon as it does. */
	var withSlot: Bool;

	/** Whether a supertype reference resolved to no indexed declaration, leaving absence unproven. */
	var unresolved: Bool;

	/** Whether an ancestor carries `@:autoBuild` — it generates members into the class the walk started from. */
	var generated: Bool;

};

/** The whole-run deletion evidence, gathered once where the entire file set is in hand. */
private typedef Ctx = {

	/** Accessor-shaped names that occur as an identifier / field access / interpolated ident in report scope. */
	var referenced: Array<String>;

	/** Every WHOLE, non-interpolated string-literal content in report scope — the reflection surface. */
	var reflected: Array<String>;

	/** The static text FRAGMENTS of every interpolated string in scope — a partially computed reflection name. */
	var fragments: Array<String>;

	/** Whether every report file parsed, so the two scans above saw the whole scope. */
	var scanComplete: Bool;

	/**
	 * `RefShape.retainedDeclMetaName` — the tag that pins a member against removal, because its
	 * uses are not all in the source. Carried here rather than read at the member walk so the
	 * grammar is asked once per run; null when the grammar names no such tag, and then no member
	 * is pinned by annotation (the type-level `hasKeep` flag still applies).
	 */
	var retainedMeta: Null<String>;

}
