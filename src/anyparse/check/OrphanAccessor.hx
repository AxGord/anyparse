package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.Span;

using Lambda;

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
 * `hasSetter`, which needs a `TypeInfoProvider` (the Haxe plugin supplies one). An `override`
 * accessor needs NO property redeclaration in the subclass — the chain walk finds the
 * supertype's property and the method is legit.
 *
 * ## Three arms
 *
 * 1. `X` IS declared somewhere in the chain but WITHOUT the matching slot — PROVEN orphan
 *    (`Warning`). Haxe forbids redeclaring an inherited field, so a second declaration of `X`
 *    behind an unresolvable supertype cannot exist; the proof holds even with an unresolved link
 *    in the chain.
 * 2. No `X` anywhere AND every supertype link resolved — PROVEN orphan (`Warning`).
 * 3. No `X` anywhere but a supertype link did NOT resolve — `Info`, report-only: the property may
 *    live in the unread type. Never fixed.
 *
 * A supertype the index cannot resolve by IMPORT VISIBILITY — Haxe needs no import to name a type
 * from a PARENT package, a visibility the index does not model — is still walked when its simple
 * name has exactly ONE project-wide declaration, but SPECULATIVELY: such a type may prove a slot
 * EXISTS (so arm 3 stays silent) and never that the property is declared WITHOUT one, and the link
 * stays counted as unresolved. A chain resolved only that way is therefore never deleted from, and
 * the fallback can only silence a finding — never raise one.
 *
 * ## Autofix
 *
 * The fix DELETES the method (with its modifier / metadata run and its leading doc comment, via
 * `docExtendedSpan`), and only for arms 1 and 2, when TWO further gates hold: no report file
 * skip-parses (a file the parser could not read might hold a call), and the method name has ZERO
 * direct call references project-wide — no `IdentExpr` / `FieldAccess` node carries it anywhere in
 * report scope. The zero-call gate is NOT the orphan test: a REAL accessor is invoked through
 * property access and shows zero textual calls too, which is exactly why the orphan test is the
 * property-slot absence. It gates only the DELETE, catching the case where `get_X` is also called
 * by hand as an ordinary method.
 *
 * Scope is class bodies (`CheckScan.classBodies`: `class` / `final class` / `abstract class`).
 * An `interface` declares no accessor bodies; an `abstract` type's accessors are left alone (its
 * `@:forward` / `@:op` members reach the underlying type by rules the index does not model).
 */
@:nullSafety(Strict)
final class OrphanAccessor implements Check implements DefaultOff {

	/** The read-accessor method-name prefix; its length also slices the property name off. */
	private static inline final GET_PREFIX: String = 'get_';

	/** The write-accessor method-name prefix (same length as `GET_PREFIX`, which slices both). */
	private static inline final SET_PREFIX: String = 'set_';

	/** The class-body member kinds a method declaration projects as — a plain method and a `final` one. */
	private static final METHOD_KINDS: Array<String> = ['FnMember', 'FinalModifiedMember'];

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
			'a get_X / set_X method whose property X declares no matching accessor slot anywhere in the inheritance chain — an accessor Haxe never calls';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		_deletable = [];
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		// Supertypes resolve over report UNION resolution scope: a base class in a configured
		// library (openfl's DisplayObject) declares the property slot a report-only index cannot
		// see, and reading it as absent would flag every inherited accessor.
		final wide: SymbolIndex = RefactorSupport.resolutionIndexOf(plugin) ?? index;
		final referenced: Array<String> = referencedAccessorNames(files, plugin);
		final scanComplete: Bool = index.skippedFiles().length == 0;
		final out: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			// The resolution index carries the report files too, but only when a scope reached
			// the run at all — fall back to the report index rather than skipping the file.
			final scope: SymbolIndex = wide.fileInfo(entry.file) == null ? index : wide;
			final info: Null<FileInfo> = scope.fileInfo(entry.file);
			if (info == null) continue;
			final host: FileInfo = info;
			for (cls in CheckScan.classBodies(tree)) considerClass(out, cls, entry.file, scope, host, referenced, scanComplete);
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
	 * Flag every `get_` / `set_` method of `cls` whose property slot the inheritance chain does
	 * not declare, and record the ones whose deletion is proven safe. `host` is the class's own
	 * declaring file, `scope` the index the chain walk resolves supertypes through.
	 */
	private function considerClass(
		out: Array<Violation>, cls: QueryNode, file: String, scope: SymbolIndex, host: FileInfo, referenced: Array<String>,
		scanComplete: Bool
	): Void {
		final owner: Null<String> = cls.name;
		if (owner == null) return;
		final declared: Null<TypeDeclInfo> = host.types.find(t -> t.name == owner);
		if (declared == null) return;
		final self: TypeDeclInfo = declared;
		for (child in cls.children) if (METHOD_KINDS.contains(child.kind)) {
			final name: Null<String> = child.name;
			final span: Null<Span> = child.span;
			if (name == null || span == null) continue;
			final wantGetter: Bool = StringTools.startsWith(name, GET_PREFIX);
			if (!wantGetter && !StringTools.startsWith(name, SET_PREFIX)) continue;
			final prop: String = name.substr(GET_PREFIX.length);
			if (prop == '') continue;
			final found: Resolution = { declared: false, withSlot: false, unresolved: false };
			walkChain(scope, host, self, prop, wantGetter, found, [], false);
			if (found.withSlot) continue;
			final slot: String = wantGetter ? 'get' : 'set';
			if (!found.declared && found.unresolved) {
				out.push(violation(
					file, span, Severity.Info,
					'$name may have no property to serve: no $prop is declared in $owner or in the supertypes that resolved, and an unresolvable supertype leaves it unproven'
				));
				continue;
			}
			out.push(violation(
				file, span, Severity.Warning,
				found.declared
					? '$name has no property to serve: $prop declares no $slot accessor'
					: '$name has no property to serve: neither $owner nor its supertypes declare $prop'
			));
			if (scanComplete && !referenced.contains(name)) _deletable.push(key(file, span));
		}
	}

	/**
	 * Accumulate into `found` whether `prop` is declared by `type` or anywhere above it, and
	 * whether the declaration carries the wanted accessor slot. A supertype reference that
	 * resolves to no indexed declaration sets `unresolved` — the caller's proof of ABSENCE then
	 * fails, while a declaration already found stays conclusive (Haxe forbids redeclaring an
	 * inherited field, so an unread supertype cannot hold a second `prop`).
	 */
	private static function walkChain(
		scope: SymbolIndex, host: FileInfo, type: TypeDeclInfo, prop: String, wantGetter: Bool, found: Resolution, seen: Array<String>,
		speculative: Bool
	): Void {
		final visited: String = '${host.file}#${type.name}';
		if (found.withSlot || seen.contains(visited)) return;
		seen.push(visited);
		for (m in type.members) if (m.name == prop) {
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
			for (s in supers) walkChain(scope, s.file, s.type, prop, wantGetter, found, seen, speculative || speculate);
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
			&& (StringTools.startsWith(name, GET_PREFIX) || StringTools.startsWith(name, SET_PREFIX)) && !out.contains(name)
		)
			out.push(name);
		for (child in node.children) collectReferences(child, kinds, out);
	}

	/** The whole-line deletion of `node` including its modifier / metadata run and its doc comment. */
	private static function deletionEdit(source: String, node: QueryNode, parent: QueryNode, span: Span): { span: Span, text: String } {
		final group: Span = RefactorSupport.declGroupSpan(node, parent, span);
		return { span: RefactorSupport.lineExtendedSpan(source, RefactorSupport.docExtendedSpan(source, group)), text: '' };
	}

	/** The `_deletable` key of one accessor declaration. */
	private static inline function key(file: String, span: Span): String {
		return '$file#${span.from}:${span.to}';
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

}

/** The accumulated verdict of one inheritance-chain walk for a single property name. */
private typedef Resolution = {

	/** Whether a member of that name was found anywhere in the resolved chain. */
	var declared: Bool;

	/** Whether such a member declares the wanted accessor slot — the walk stops as soon as it does. */
	var withSlot: Bool;

	/** Whether a supertype reference resolved to no indexed declaration, leaving absence unproven. */
	var unresolved: Bool;

};
