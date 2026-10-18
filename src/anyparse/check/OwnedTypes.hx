package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.FileGated;
import anyparse.check.Check.NoAutofix;
import anyparse.check.Check.Violation;
import anyparse.check.ConfiguredTypes.OwnedMember;
import anyparse.check.OwnedTypesDeclaration.TypeOwnership;
import anyparse.query.Glob;
import anyparse.query.GrammarPlugin;
import anyparse.query.IndexScope;
import anyparse.query.NominalTypes;
import anyparse.query.ParseGate;
import anyparse.query.QueryNode;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeNameBinding;
import anyparse.query.TypeRefIndex;
import anyparse.query.TypeResolver;
import anyparse.query.Uses;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;
using StringTools;

/**
 * One owned subject of a run, resolved against the index: a type (`member` null) or a member of one.
 */
typedef OwnedSubject = {
	/** The declared path, as a finding names it: `pkg.Mod.T`, `pkg.Mod.T.build`. */
	final label: String;

	/** The owned type's simple name — the spelling a mention is first looked for by. */
	final simple: String;

	/** The identity of every declaration the type path names (`TypeRefIndex.seenKey`); empty when it names none. */
	final keys: Array<String>;

	/** The modules declaring the type: every mention inside one is owned. */
	final modules: Array<String>;

	/** The owned member's name (`new` for construction), or null for a type subject. */
	final member: Null<String>;

	/** Whether the owned member is static — and, for a member the index cannot place, whether it is assumed to be. */
	final isStatic: Bool;

	/** The declaration the subject came from. */
	final declaration: TypeOwnership;
}

/** One file's scan: what every step of `OwnedTypes.scanFile` reads, and the findings it makes. */
typedef FileScan = {
	final file: String;
	final source: String;
	final info: FileInfo;
	final index: SymbolIndex;
	final plugin: GrammarPlugin;
	final shape: RefShape;
	final subjects: Array<OwnedSubject>;

	/** Each name a type subject may be written under in the file (`OwnedTypes.spellingsOf`). */
	final spellings: Map<String, Array<OwnedSubject>>;

	/**
	 * What each simple name denotes (`OwnedTypes.typesNamed`), asked once per file — once per site in a file holding a
	 * `#if`-guarded import, whose own branch decides it.
	 */
	final denoted: Map<String, Null<Denoted>>;

	/** Whether the file writes a `#if`-guarded import, so a use site's branch decides what a name binds. */
	final guardedImports: Bool;

	/** `from:to:label` of every finding made, so a site two steps see is reported once. */
	final reported: Array<String>;

	final out: Array<Violation>;

	/** The shared typer over the file's tree, built on the first instance-member question (`typerBuilt`). */
	var typer: Null<(QueryNode) -> Null<String>>;

	var typerBuilt: Bool;
}

/**
 * What a written type name denotes (`OwnedTypes.typesNamed`): the declarations of the index and the paths of types outside
 * it that it may be, or `open` when it may be something nothing here reads.
 */
typedef Denoted = {
	final decls: Array<ResolvedType>;
	final outside: Array<String>;
	final open: Bool;
}

/**
 * Reports every reach past a layer's boundary the project declares in `apqlint.json` `ownedTypes`: a mention of an
 * owned TYPE outside its `owners`, and a read or call of an owned MEMBER outside them. `Warning`, report-only, INERT
 * until the key declares something; the message is `<path> belongs to <owners> — <why>`. The full contract and its
 * named limits are in `docs/cli-query-tool.md` § "`owned-types`".
 *
 * A type is mentioned by an `import` / `using` of its path (an alias, a field import and a field wildcard under it
 * included), by every TYPE position the type-reference projection surfaces (`Uses.find` over
 * `TypeRefShape.typeRefKinds`: annotations, type arguments, heritage, `new T`, `cast(x, T)`, `x is T`), and by every
 * expression naming it (`T.x`, a class value `T`, a qualified `p.T`).
 *
 * What a written name means is asked of the SHARED resolvers only — this rule is the guard of exactly that principle,
 * so it grows no resolver of its own. A simple name goes through `TypeNameBinding.tierOf`, asked AT the use site, so a
 * `#if`-guarded import decides a use inside its own branch: `Bound` to the owned declaration is reported; `Bound`
 * elsewhere and `Free` are not; `Unknown` is REPORTED, because an unproved reach is a reach — unless every type it may be
 * is read (`TypeNameBinding.unknownCandidates`) and none is the owned one. A qualified spelling goes through
 * `TypeRefIndex.resolveTypeRefAll`; one that resolves to nothing is reported when its last segment is the owned name. An
 * identifier the scope binds to a value is no type.
 *
 * A STATIC member is reached through a type receiver resolved the same way — that type itself, since Haxe resolves no
 * static through a subtype; a receiver whose meaning is `Unknown` with no readable candidate set is reported — the one
 * name-only report. An INSTANCE member is reached through a receiver the shared typer types
 * (`CheckScan.typeNominalResolver` over `NominalTypes.expressionTypeNominal`, which types a local written with no type
 * by the construction initialising it), its member looked up through the supertypes by `ConfiguredTypes.memberOf`; an untyped receiver
 * is not reported. `new T(…)` reaches `T.new`.
 *
 * Owners are globs over qualified names (`Glob.qualifiedNames`, the syntax of `reflectiveClasses`), matched against
 * the module a mention is written in and the qualified path of the type declaration enclosing it. The module declaring
 * an owned type always owns it.
 *
 * Grammar-agnostic: driven by `identKind`, `fieldAccessKind`, `newExprKind` and `TypeRefShape.typeRefKinds`.
 */
@:nullSafety(Strict)
final class OwnedTypes implements Check implements ConfigAware implements FileGated implements NoAutofix {

	/** The rule id. */
	private static inline final RULE_ID: String = 'owned-types';

	/** The member name a constructor is declared and owned under. */
	private static inline final CONSTRUCTOR: String = 'new';

	/** The suffix a wildcard import's path carries. */
	private static inline final WILDCARD_SUFFIX: String = '.*';

	/** Each glob of a declaration, compiled once per run. */
	private final _globs: Map<String, EReg> = [];

	/** The linter's memoised per-file config resolver; null when run outside it. */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a mention of a type, or a read or call of a member, that the project\'s `ownedTypes` declaration gives to another layer';
	}

	public function noAutofixReason(): String {
		return 'whether the access should go through the owning layer\'s API or the code should move into that layer is a design call';
	}

	/** `needs-config` while the file's config declares no `ownedTypes`. */
	public function skipReason(file: String, config: LintConfig): Null<String> {
		return config.ownedTypes().length == 0 ? 'needs-config' : null;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		if (files.length == 0) return [];
		final index: Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin)();
		if (index == null) return [];
		final out: Array<Violation> = [];
		var declared: Null<Array<TypeOwnership>> = null;
		var subjects: Array<OwnedSubject> = [];
		for (entry in files) {
			final declarations: Array<TypeOwnership> = LintConfig.resolveWith(_resolveConfig, entry.file).ownedTypes();
			if (declarations.length == 0) continue;
			if (declarations != declared) {
				declared = declarations;
				subjects = subjectsOf(declarations, index);
			}
			final info: Null<FileInfo> = index.fileInfo(entry.file);
			if (info != null) scanFile(entry.file, entry.source, info, subjects, index, plugin, out);
		}
		out.sort((a, b) -> a.file != b.file ? (a.file < b.file ? -1 : 1) : (a.span?.from ?? 0) - (b.span?.from ?? 0));
		return out;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** Every reach past an owner in one file — its imports, its type positions, its expressions — appended to `out`. */
	private function scanFile(
		file: String, source: String, info: FileInfo, subjects: Array<OwnedSubject>, index: SymbolIndex, plugin: GrammarPlugin,
		out: Array<Violation>
	): Void {
		final scan: FileScan = {
			file: file,
			source: source,
			info: info,
			index: index,
			plugin: plugin,
			shape: plugin.refShape(),
			subjects: subjects,
			spellings: spellingsOf(subjects, info),
			denoted: [],
			guardedImports: info.imports.exists(i -> i.guarded),
			reported: [],
			out: out,
			typer: null,
			typerBuilt: false
		};
		scanImports(scan);
		final typeTree: Null<QueryNode> = CheckScan.parseTypeRefsOrNull(plugin, source);
		if (typeTree != null)
			for (name => candidates in scan.spellings)
				for (hit in Uses.find(name, typeTree, plugin.typeRefShape(), true))
					for (s in typeSubjectsDenoted(scan, hit.name, candidates, hit.span.from)) report(scan, s, hit.span);
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		if (tree != null) walk(scan, tree, tree);
	}

	/** Record `subject`'s finding at `span` unless an owner owns the site or the site was already reported. */
	private function report(scan: FileScan, subject: OwnedSubject, span: Span): Void {
		final key: String = '${span.from}:${span.to}:${subject.label}';
		if (scan.reported.contains(key) || ownedAt(subject, scan.info, span.from)) return;
		scan.reported.push(key);
		scan.out.push({
			file: scan.file,
			span: span,
			rule: RULE_ID,
			severity: Severity.Warning,
			message: '${subject.label} belongs to ${subject.declaration.owners.join(', ')} — ${subject.declaration.why}'
		});
	}

	/** Every import of the file naming an owned type, and every field import naming an owned member. */
	private function scanImports(scan: FileScan): Void {
		for (imp in scan.info.imports) {
			final imported: Null<String> = SymbolIndex.pathImportedBy(imp);
			if (imported == null) continue;
			final path: String = imported.endsWith(WILDCARD_SUFFIX)
				? imported.substr(0, imported.length - WILDCARD_SUFFIX.length)
				: imported;
			for (s in scan.subjects) if (s.member != null ? path == s.label : importNames(path, s, scan.index)) report(scan, s, imp.span);
		}
	}

	/** `node` and its subtree: every expression naming an owned type, reaching an owned member, or constructing one. */
	private function walk(scan: FileScan, tree: QueryNode, node: QueryNode): Void {
		final name: Null<String> = node.name;
		final span: Null<Span> = node.span;
		if (name != null && span != null) {
			final candidates: Null<Array<OwnedSubject>> = scan.spellings[name];
			if (candidates != null) visitTypeName(scan, tree, node, name, span, candidates);
			if (node.kind == scan.shape.fieldAccessKind && node.children.length == 1) visitMemberAccess(scan, tree, node, name, span);
			if (node.kind == scan.shape.newExprKind) visitNew(scan, name, span);
		}
		for (c in node.children) walk(scan, tree, c);
	}

	/**
	 * An identifier — or a qualified field chain over a package's first segment (`pkg.T.make()`) — spelling one of
	 * `candidates` as a type, and not a value the scope binds.
	 */
	private function visitTypeName(
		scan: FileScan, tree: QueryNode, node: QueryNode, name: String, span: Span, candidates: Array<OwnedSubject>
	): Void {
		final spelled: Null<String> = if (node.kind == scan.shape.identKind)
			name
		else if (node.kind == scan.shape.fieldAccessKind)
			pathOf(scan, node)?.join('.')
		else
			null;
		if (spelled != null && !valueBound(scan, tree, spelled.split('.')[0], span))
			for (s in typeSubjectsDenoted(scan, spelled, candidates, span.from)) report(scan, s, span);
	}

	/** A field access naming an owned member, reported when its receiver reaches the owned declaration (`reaches`). */
	private function visitMemberAccess(scan: FileScan, tree: QueryNode, node: QueryNode, name: String, span: Span): Void {
		for (s in scan.subjects) if (s.member == name && reaches(scan, tree, s, node.children[0])) report(scan, s, span);
	}

	/** A `new` of a type whose construction is owned (`T.new`) — that type exactly, never a same-named one elsewhere. */
	private function visitNew(scan: FileScan, name: String, span: Span): Void {
		for (s in scan.subjects) if (s.member == CONSTRUCTOR && SourceText.lastSegment(name) == s.simple) {
			final made: Null<Denoted> = typesNamed(scan, name, span.from);
			if (made != null && denotes(scan, made, s)) report(scan, s, span);
		}
	}

	/**
	 * Whether a mention of `subject` at `offset` of `info` is owned: written in a module declaring the type, or in a
	 * module or under a type declaration whose qualified path an owner glob matches.
	 */
	private function ownedAt(subject: OwnedSubject, info: FileInfo, offset: Int): Bool {
		if (subject.modules.contains(info.module)) return true;
		final names: Array<String> = [info.module];
		final enclosing: Null<TypeDeclInfo> = info.types.find(t -> t.span.from <= offset && offset < t.span.to);
		if (enclosing != null) names.push(TypeRefIndex.importPathFor(info, enclosing));
		return subject.declaration.owners.exists(glob -> {
			final re: EReg = globOf(glob);
			names.exists(n -> re.match(n));
		});
	}

	private function globOf(glob: String): EReg {
		final held: Null<EReg> = _globs[glob];
		if (held != null) return held;
		final compiled: EReg = Glob.qualifiedNames(glob);
		_globs[glob] = compiled;
		return compiled;
	}

	/** Whether the scope at `span` binds `name` to a value — a local, a parameter, a field — which is then no type. */
	private static inline function valueBound(scan: FileScan, tree: QueryNode, name: String, span: Span): Bool {
		return TypeResolver.resolveBindingFrom(name, span, tree, scan.shape) != null;
	}

	/** Every subject `declarations` own, resolved against `index`; a path the index cannot place is said once. */
	private static function subjectsOf(declarations: Array<TypeOwnership>, index: SymbolIndex): Array<OwnedSubject> {
		final out: Array<OwnedSubject> = [];
		for (d in declarations) {
			for (path in d.types) {
				final types: Array<ResolvedType> = resolvedOrSaid(path, index);
				out.push({
					label: path,
					simple: SourceText.lastSegment(path),
					keys: [for (t in types) index.refs.seenKey(t)],
					modules: [for (t in types) t.file.module],
					member: null,
					isStatic: false,
					declaration: d
				});
			}
			for (path in d.members) {
				final typePath: String = SourceText.parentPath(path);
				final name: String = SourceText.lastSegment(path);
				final types: Array<ResolvedType> = resolvedOrSaid(typePath, index);
				final declaredAs: Null<OwnedMember> = types.length == 0 ? null : ConfiguredTypes.memberOf(index, types[0], name);
				if (types.length > 0 && declaredAs == null && name != CONSTRUCTOR)
					ConfiguredTypes.warn(RULE_ID, '"$path" names no member of $typePath — matched as a static by name');
				out.push({
					label: path,
					simple: SourceText.lastSegment(typePath),
					keys: [for (t in types) index.refs.seenKey(t)],
					modules: [for (t in types) t.file.module],
					member: name,
					isStatic: name != CONSTRUCTOR && (declaredAs?.member.isStatic ?? true),
					declaration: d
				});
			}
		}
		return out;
	}

	/** The declarations `path` names; none, said once, when it names nothing the index holds. */
	private static function resolvedOrSaid(path: String, index: SymbolIndex): Array<ResolvedType> {
		final types: Array<ResolvedType> = index.refs.resolveQualifiedRefAll(path);
		if (types.length == 0) ConfiguredTypes.warn(RULE_ID, '"$path" names no type in the resolution scope — matched by name');
		return types;
	}

	/** The names a type subject may be written under in `info`: its own, and every alias an import binds to it. */
	private static function spellingsOf(subjects: Array<OwnedSubject>, info: FileInfo): Map<String, Array<OwnedSubject>> {
		final types: Array<OwnedSubject> = subjects.filter(s -> s.member == null);
		final out: Map<String, Array<OwnedSubject>> = [];
		for (s in types) out[s.simple] = (out[s.simple] ?? []).concat([s]);
		for (alias => targets in TypeRefIndex.importAliasEdges(info, true)) {
			final aliased: Array<OwnedSubject> = types.filter(s -> targets.contains(s.simple));
			if (aliased.length > 0) out[alias] = (out[alias] ?? []).concat(aliased);
		}
		return out;
	}

	/**
	 * Whether the access of `subject`'s member on `receiver` reaches the owned declaration: a static through
	 * the type the receiver names (`receiverTypes`), an instance member through the type the shared typer
	 * gives it (`typedReceiver`). A receiver whose meaning is unknown is reported — a static's only when the owned type
	 * may be among what it denotes (`denotes`).
	 */
	private static function reaches(scan: FileScan, tree: QueryNode, subject: OwnedSubject, receiver: QueryNode): Bool {
		final member: Null<String> = subject.member;
		if (member == null) return false;
		// A static is reached only through its own type: Haxe resolves no static through a subtype (`Class<B> has no field`).
		if (subject.isStatic) {
			final named: Null<Denoted> = receiverTypes(scan, tree, receiver);
			return named != null && denotes(scan, named, subject);
		}
		final types: Null<Array<ResolvedType>> = typedReceiver(scan, tree, receiver, subject);
		if (types == null) return false;
		// An untyped receiver of the owned type's own name is unknown rather than another type.
		if (types.length == 0) return true;
		return types.exists(t -> {
			final found: Null<OwnedMember> = ConfiguredTypes.memberOf(scan.index, t, member);
			found != null && subject.keys.contains(scan.index.refs.seenKey(found.owner));
		});
	}

	/**
	 * The declarations the shared typer's type of `receiver` resolves to, for an instance member of `subject`: null when the
	 * typer cannot type it, or types it as a type that resolves to nothing and is not the subject's; EMPTY for the latter
	 * case when the name IS the subject's, which is unknown rather than another type.
	 */
	private static function typedReceiver(
		scan: FileScan, tree: QueryNode, receiver: QueryNode, subject: OwnedSubject
	): Null<Array<ResolvedType>> {
		final nominal: Null<String> = receiverType(scan, tree, receiver);
		if (nominal == null) return null;
		final typed: Array<ResolvedType> = scan.index.refs.resolveTypeRefAll(nominal, scan.info);
		return if (typed.length > 0)
			typed
		else if (nominal == subject.simple)
			[]
		else
			null;
	}

	/** What a TYPE receiver denotes (`typesNamed`); null for a receiver that is no path or is a value. */
	private static function receiverTypes(scan: FileScan, tree: QueryNode, receiver: QueryNode): Null<Denoted> {
		final path: Null<Array<String>> = pathOf(scan, receiver);
		final span: Null<Span> = receiver.span;
		return if (path == null || span == null)
			null
		else if (valueBound(scan, tree, path[0], span))
			null
		else
			typesNamed(scan, path.join('.'), span.from);
	}

	/** The shared typer's nominal for `receiver` in member-lookup position, the typer built on the first question. */
	private static function receiverType(scan: FileScan, tree: QueryNode, receiver: QueryNode): Null<String> {
		if (!scan.typerBuilt) {
			scan.typerBuilt = true;
			scan.typer = CheckScan.typeNominalResolver(scan.source, scan.plugin, tree, scan.file, scan.index, true);
		}
		final typeOf: Null<(QueryNode) -> Null<String>> = scan.typer;
		return typeOf == null ? null : try typeOf(receiver) catch (exception: Exception) null;
	}

	/** The dotted segments of a plain identifier / field chain (`NominalTypes.pathOf`), or null for any other node. */
	private static function pathOf(scan: FileScan, node: QueryNode): Null<Array<String>> {
		final fieldKind: Null<String> = scan.shape.fieldAccessKind;
		return fieldKind == null ? null : NominalTypes.pathOf(node, scan.shape.identKind, fieldKind);
	}

	/**
	 * What `spelled` names from `info` as a TYPE, written at offset `at`: a simple name through the compiler's resolution
	 * order (`TypeNameBinding.tierOf` at the use site, memoised per file), a dotted one through
	 * `TypeRefIndex.resolveTypeRefAll`. Null when it provably names no type here (`Free`). For an `Unknown` simple name, the
	 * candidates it may be when every one is read (`TypeNameBinding.unknownCandidates`), else `open` — as for a dotted
	 * spelling nothing resolves.
	 */
	private static function typesNamed(scan: FileScan, spelled: String, at: Int): Null<Denoted> {
		if (spelled.indexOf('.') >= 0) {
			final decls: Array<ResolvedType> = scan.index.refs.resolveTypeRefAll(spelled, scan.info);
			return { decls: decls, outside: [], open: decls.length == 0 };
		}
		final key: String = scan.guardedImports ? '$spelled@$at' : spelled;
		if (scan.denoted.exists(key)) return scan.denoted[key];
		final names: TypeNameBinding = scan.index.refs.names;
		final named: Null<Denoted> = switch names.tierOf(spelled, scan.info, at) {
			case Bound(decls): { decls: decls, outside: [], open: false };
			case Unknown: denotedBy(names.unknownCandidates(spelled, scan.info, at));
			case Free: null;
		};
		scan.denoted[key] = named;
		return named;
	}

	/**
	 * Which of `candidates` — the type subjects `spelled`, written at offset `at`, may be written for — it denotes: those
	 * it may be (`denotes`); every candidate when what it names is open, though for a dotted spelling only one whose last
	 * segment is the subject's own name; none when it provably names another type, or none.
	 */
	private static function typeSubjectsDenoted(
		scan: FileScan, spelled: String, candidates: Array<OwnedSubject>, at: Int
	): Array<OwnedSubject> {
		final named: Null<Denoted> = typesNamed(scan, spelled, at);
		return if (named == null)
			[]
		else if (named.open && spelled.indexOf('.') >= 0)
			candidates.filter(s -> SourceText.lastSegment(spelled) == s.simple)
		else
			candidates.filter(s -> denotes(scan, named, s));
	}

	/**
	 * Whether what a name denotes may be `subject`'s type: it is open, or one of its declarations is the subject's, or one of
	 * its outside paths ends in the subject's name — the reading a dotted spelling nothing resolves gets.
	 */
	private static function denotes(scan: FileScan, named: Denoted, subject: OwnedSubject): Bool {
		return named.open || named.decls.exists(t -> subject.keys.contains(scan.index.refs.seenKey(t)))
			|| named.outside.exists(path -> SourceText.lastSegment(path) == subject.simple);
	}

	/** What an `Unknown` name denotes: the candidates `targets` it may be, each read; open when they are null. */
	private static function denotedBy(targets: Null<Array<NameTarget>>): Denoted {
		if (targets == null) return { decls: [], outside: [], open: true };
		final decls: Array<ResolvedType> = [];
		final outside: Array<String> = [];
		for (t in targets) switch t {
			case InIndex(found):
				for (d in found) decls.push(d);
			case OutOfIndex(path):
				outside.push(path);
		}
		return { decls: decls, outside: outside, open: false };
	}

	/**
	 * Whether the import of `path` names the type `subject`: the path resolves to it; or the path resolves
	 * to no type and still spells it — the owned path under a field import or a field wildcard (`p.T.f`,
	 * `p.T.*` with the suffix cut), or an unresolvable path ending in its name, the unknown case.
	 */
	private static function importNames(path: String, subject: OwnedSubject, index: SymbolIndex): Bool {
		final own: Array<ResolvedType> = index.refs.resolveQualifiedRefAll(path);
		return own.length > 0
			? own.exists(t -> subject.keys.contains(index.refs.seenKey(t)))
			: SourceText.lastSegment(path) == subject.simple || SourceText.parentPath(path) == subject.label;
	}

}
