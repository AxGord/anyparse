package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.Refs.RefKind;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;
using Lambda;

/**
 * A declaration / import node from `declNodes`, tagged with whether it was
 * LIFTED out of a `#if ... #end` region (`guarded`) or written at the file
 * top level. `extractFileInfo` carries the tag onto each `ImportInfo`; type
 * declarations ignore it (a guarded type is indexed exactly like a plain one).
 */
private typedef GuardedNode = {
	var node: QueryNode;
	var guarded: Bool;
};

/**
 * The grammar kinds `collectMembers` reads while walking a type body: the modifier
 * siblings whose run it tracks (`visibilityKinds` / `overrideKind` / `staticKind` /
 * `inlineKind`) and the conditional-compilation host kind that marks a member `guarded`.
 * Passed as ONE value so a seam added later needs no new parameter.
 */
private typedef MemberSeams = {
	final visibilityKinds: Array<String>;
	final overrideKind: Null<String>;
	final staticKind: Null<String>;
	final inlineKind: Null<String>;
	final macroKind: Null<String>;
	final conditionalKind: Null<String>;
};

/**
 * The EXTRACTION half of `SymbolIndex`: it parses each `(file, source)` entry with the
 * grammar plugin and walks the resulting trees into the per-file `FileInfo` records the
 * index is built from. Split out of `SymbolIndex` so the cross-file QUERY surface and the
 * grammar-walking extraction — two bodies of code sharing nothing but the `FileInfo` shape —
 * can be read and changed apart. `SymbolIndex` stays the public face: its `build` delegates the
 * whole extraction to `extract`, and its `moduleOf` forwards to the one here.
 */
@:nullSafety(Strict)
final class SymbolIndexBuilder {

	/** The anonymous-structure node a `typedef T = {…}` projects as its body. */
	private static inline final ANON_KIND: String = 'Anon';

	/** The grammar kind a `typedef` declaration projects as. */
	private static inline final TYPEDEF_DECL_KIND: String = 'TypedefDecl';

	/** A `> Base,` structural extension written inside an anonymous structure. */
	private static inline final EXTENDS_FIELD_KIND: String = 'ExtendsField';

	/**
	 * The bodyless declaration heads a `CondSharedBodyDecl` region can carry,
	 * mapped to the decl kind the same declaration projects as when written
	 * whole. `HxDeclHead` has exactly these two branches (`class` / `abstract`
	 * are the only forms observed splitting a header across `#if`).
	 */
	private static final DECL_HEAD_KINDS: Map<String, String> = [
		'ClassHead' => 'ClassDecl',
		'AbstractHead' => 'AbstractDecl'
	];

	/**
	 * The shorthand anon-structure field forms `name:T` / `?name:T`. Counted as members ONLY
	 * directly under an `Anon` — the same two kinds project a FUNCTION PARAMETER elsewhere, and
	 * a parameter is not a member of anything.
	 */
	private static final ANON_SHORT_FIELD_KINDS: Array<String> = ['Required', 'Optional'];

	/**
	 * Parse every entry with `plugin` and extract its `FileInfo`. Entries whose source does not
	 * parse are collected into `skipped` and excluded; every parsed entry's source is retained in
	 * `sources` so a later body scan can inspect a declaration's raw span. The three results are
	 * exactly the state `SymbolIndex`'s constructor takes.
	 */
	public static function extract(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin
	): { files: Array<FileInfo>, skipped: Array<String>, sources: Map<String, String> } {
		final infos: Array<FileInfo> = [];
		final skipped: Array<String> = [];
		final sources: Map<String, String> = [];
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		final shape: RefShape = plugin.refShape();
		final abstractKinds: Array<String> = shape.underlyingThisTypeKinds ?? [];
		final memberSeams: MemberSeams = memberSeamsOf(shape);
		for (entry in files) {
			final tree: Null<QueryNode> = try plugin.parseFile(entry.source) catch (_: Exception) null;
			if (tree == null) {
				skipped.push(entry.file);
				continue;
			}
			sources[entry.file] = entry.source;
			final accessors: Map<Int, Bool> = provider != null ? provider.propertyAccessors(entry.source) : [];
			final writeAccessors: Map<Int, Bool> = provider != null ? provider.propertyWriteAccessors(entry.source) : [];
			final returnTypes: Map<Int, String> = provider != null ? provider.returnTypes(entry.source) : [];
			final typeSources: Map<Int, String> = provider != null ? provider.declaredTypeSources(entry.source) : [];
			infos.push(extractFileInfo(
				entry.file, entry.source, tree, accessors, writeAccessors, returnTypes, typeSources, shape, memberSeams, abstractKinds
			));
		}
		return { files: infos, skipped: skipped, sources: sources };
	}

	/** Whether `kind` is a metadata node — a bare `@:x` (`Meta`) or an argument-bearing `@:x(...)` (`MetaCall`). */
	private static inline function isMetaNodeKind(kind: String): Bool {
		return kind == 'Meta' || kind == 'MetaCall';
	}

	/**
	 * The type declaration `node` carries, across all three grammar shapes: a
	 * plain decl, a `final`-wrapped one (both via `RefactorSupport.typeDeclOf`)
	 * and a split-header conditional region. One resolver so the lifting done
	 * by `declNodes` and the indexing done by `extractFileInfo` can never
	 * disagree about what counts as a declaration.
	 */
	private static inline function typeDeclAt(node: QueryNode): Null<TypeDeclMatch> {
		return RefactorSupport.typeDeclOf(node) ?? condSharedBodyDeclOf(node);
	}

	/**
	 * The MODULE portion of a dotted import path: the segments up to and
	 * INCLUDING the first upper-case-initial segment (packages are
	 * lower-case, modules / types upper-case). Any remaining segments are
	 * sub-type access and are dropped. So `anyparse.query.Refs.RefHit` →
	 * `anyparse.query.Refs` (module `Refs`, sub-type `RefHit`),
	 * `anyparse.query.Rename` → `anyparse.query.Rename` (no sub-type),
	 * `pkg.sub.Foo` → `pkg.sub.Foo`. A path with no upper-case segment
	 * (all lower-case) is returned verbatim — there is no module segment
	 * to anchor on.
	 * Build a `FileInfo` from a parsed `parseFile` tree: walk the
	 * module's declarations for the `PackageDecl`, the import /
	 * using statements, and the type declarations. The basename
	 * drives the module path and the per-type `isMain` flag.
	 *
	 * The walk runs over `declNodes`, not over `tree.children`
	 * directly, so a type declared inside a `#if ... #end` region is
	 * indexed like a plain top-level one, and a guarded `import` /
	 * `using` is LIFTED into the file's import scope (deduped against
	 * the top-level imports by `declNodes`, so a guarded copy of a
	 * top-level import does not double it).
	 */
	private static function extractFileInfo(
		file: String, source: String, tree: QueryNode, accessors: Map<Int, Bool>, writeAccessors: Map<Int, Bool>,
		returnTypes: Map<Int, String>, typeSources: Map<Int, String>, shape: RefShape, memberSeams: MemberSeams,
		abstractKinds: Array<String>
	): FileInfo {
		final basename: String = RefactorSupport.baseNameOf(file);
		var pkg: String = '';
		final imports: Array<ImportInfo> = [];
		final types: Array<TypeDeclInfo> = [];
		var pendingMeta: Array<String> = [];
		// The EXTERN modifier projects as a NAMELESS sibling node preceding its declaration
		// (`(Extern) (ClassDecl Date …)`), the same splice shape a visibility modifier takes, so it
		// is carried forward like `pendingMeta` and consumed by the next type declaration.
		final externModifierKind: Null<String> = shape.externModifierKind;
		var pendingExtern: Bool = false;

		for (gn in declNodes(tree, externModifierKind)) {
			final node: QueryNode = gn.node;
			if (externModifierKind != null && node.kind == externModifierKind) {
				pendingExtern = true;
				continue;
			}
			final typeDecl: Null<TypeDeclMatch> = typeDeclAt(node);
			if (typeDecl != null) {
				final supersRaw: Array<String> = collectSupertypesRaw(node);
				final isAbstract: Bool = abstractKinds.contains(typeDecl.kind);
				final paramsText: Null<String> = declTypeParamListText(source, typeDecl);
				final paramSegments: Array<String> = paramsText == null ? [] : NominalTypes.splitTypeArgumentList(paramsText);
				types.push({
					name: typeDecl.name,
					kind: typeDecl.kind,
					span: typeDecl.fullSpan,
					isMain: typeDecl.name == basename,
					isExtern: pendingExtern,
					typeParamArity: paramSegments.length,
					typeParamNames: declTypeParamNames(paramSegments),
					supertypes: supersRaw.map(simpleName),
					supertypesRaw: supersRaw,
					interfaces: collectImplementsRaw(node).map(simpleName),
					// A `typedef X = {…}` projects an `Anon` child; its fields can
					// never be properties, so field access on it is side-effect-free.
					isAnonStruct: typeDecl.kind == TYPEDEF_DECL_KIND && node.children.exists(c -> c.kind == ANON_KIND),
					aliasTargetNominal: aliasTargetOf(source, typeDecl, node, gn.guarded),
					hasRtti: pendingMeta.contains('@:rtti'),
					hasBuild: pendingMeta.contains('@:build'),
					hasAutoBuild: pendingMeta.contains('@:autoBuild'),
					hasKeep: pendingMeta.contains('@:keep'),
					members: collectMembers(node, source, accessors, writeAccessors, returnTypes, typeSources, memberSeams),
					abstractSelfRebind: isAbstract && abstractRebindsThisScan(node, shape, pendingMeta),
					abstractForwardUnderlying: isAbstract ? forwardUnderlyingOf(node, pendingMeta) : null
				});
				pendingMeta = [];
				pendingExtern = false;
				continue;
			}

			if (isMetaNodeKind(node.kind)) {
				final metaName: Null<String> = node.name;
				if (metaName != null) pendingMeta.push(metaName);
				continue;
			}
			// A modifier (`private` / `extern`), comment or other module node between a meta (or a
			// split `extern`) and its decl PRESERVES the pending run — over-attaching a meta or an
			// extern to the wrong decl only makes the abstract gate / `isExtern` more conservative,
			// while dropping either is the unsound direction. Only an import / package / using
			// statement ends the run (neither a meta nor an extern can legally precede one); each
			// clears BOTH `pendingMeta` and `pendingExtern` below, so a stray guarded `extern` with
			// no declaration of its own in its branch cannot leak past one onto an unrelated type.
			final nullableName: Null<String> = node.name;
			final nullableSpan: Null<Span> = node.span;
			if (nullableName == null || nullableSpan == null) {
				if (node.kind == 'PackageDecl' && nullableName != null) pkg = nullableName;
				continue;
			}
			final name: String = nullableName;
			final span: Span = nullableSpan;
			switch node.kind {
				case 'PackageDecl':
					pkg = name;
					pendingMeta = [];
					pendingExtern = false;
				case 'ImportDecl':
					imports.push({
						raw: name,
						kind: ImportKind.Import,
						alias: null,
						span: span,
						guarded: gn.guarded
					});
					pendingMeta = [];
					pendingExtern = false;
				case 'ImportAliasDecl' | 'ImportAliasInDecl':
					imports.push({
						raw: name,
						kind: ImportKind.Alias,
						alias: name,
						span: span,
						guarded: gn.guarded
					});
					pendingMeta = [];
					pendingExtern = false;
				case 'ImportWildDecl':
					imports.push({
						raw: name,
						kind: ImportKind.Wild,
						alias: null,
						span: span,
						guarded: gn.guarded
					});
					pendingMeta = [];
					pendingExtern = false;
				case 'UsingDecl':
					imports.push({
						raw: name,
						kind: ImportKind.Using,
						alias: null,
						span: span,
						guarded: gn.guarded
					});
					pendingMeta = [];
					pendingExtern = false;
				case _:
			}
		}

		final module: String = pkg == '' ? basename : '$pkg.$basename';
		return {
			file: file,
			pkg: pkg,
			module: module,
			imports: imports,
			types: types,
			accessGrants: collectAccessGrants(tree)
		};
	}

	/**
	 * The VERBATIM written names of the `extends` / `implements` targets under
	 * `node` — its supertypes, qualified when written qualified — by reading each
	 * `Named` child of an `ExtendsClause` / `ImplementsClause`. The parallel
	 * simple-name form is derived by the caller; this preserves the dotted path a
	 * simple-name reduction loses, so a reference can be resolved to a single type.
	 */
	private static function collectSupertypesRaw(node: QueryNode): Array<String> {
		final out: Array<String> = [];
		collectInto(node, n -> {
			if (n.kind == 'ExtendsClause' || n.kind == 'ImplementsClause') for (c in n.children) {
				final nm: Null<String> = c.name;
				if (nm != null) out.push(nm);
			}
		});
		// A structural extension (`typedef T = { > Base, … }`) IS a supertype link, but it is
		// written INSIDE the anonymous structure rather than as an `extends` clause. Read only
		// the declaration's OWN top-level `Anon` — a nested anonymous structure in a member's
		// type annotation may carry its own `> Base` that belongs to that type, not to this one.
		for (c in node.children) if (c.kind == ANON_KIND) for (f in c.children) if (f.kind == EXTENDS_FIELD_KIND) {
			final nm: Null<String> = f.name;
			if (nm != null && !out.contains(nm)) out.push(nm);
		}
		return out;
	}

	/** Simple names of every type referenced in an `@:access(...)` metadata in `tree`. */
	private static function collectAccessGrants(tree: QueryNode): Array<String> {
		final out: Array<String> = [];
		collectInto(tree, n -> {
			if (n.kind == 'MetaCall' && n.name == '@:access') for (c in n.children) {
				final nm: Null<String> = c.name;
				if (nm != null) out.push(simpleName(nm));
			}
		});
		return out;
	}

	/** Visit `node` and every descendant, applying `visit` to each. */
	private static function collectInto(node: QueryNode, visit: QueryNode -> Void): Void {
		visit(node);
		for (child in node.children) collectInto(child, visit);
	}

	/**
	 * `collectInto` restricted to the nodes that can HOST a member declaration: it descends
	 * through wrappers — a `#if` region puts a member one level down, a typedef puts its
	 * fields under an `Anon` — but stops at the two places an anonymous structure can be
	 * written as a TYPE rather than as a member list: inside a member (its annotation or
	 * its body) and in the declaration's own header (a type-parameter constraint, a
	 * heritage type argument). An `{ var x:Int; }` there projects the very kinds a member
	 * does (`VarField` / `FinalField`), so descending would report its fields as members of
	 * the enclosing type.
	 * Whether `kind` declares a member — the same test `collectMembers` records on. Beyond
	 * the shared `FIELD_MEMBER_KINDS` it names the enum constructors and the three
	 * conditional member forms `HxClassMember` dispatches BEFORE their plain twins
	 * (`var x … #if … ;`, `function #if a f #else g #end`, a `#if` splice at member scope).
	 * Each carries a signature and a body like any member, so the walk must stop at them
	 * too — else the anonymous structures written there leak back in as members.
	 * The last `.`-separated segment of `path` (its simple name).
	 */
	private static function simpleName(path: String): String {
		final segments: Array<String> = path.split('.');
		final last: Null<String> = segments[segments.length - 1];
		return last ?? path;
	}

	/**
	 * The directly-declared members of the type rooted at `node` — every
	 * field-member-kind descendant (a type body's own `var`/`final`/`fn` members;
	 * a method's LOCAL vars are `VarStmt`, a different kind, so excluded) — paired
	 * with its getter-property flag from the `accessors` span map (absent = plain)
	 * and its modifier-run visibility / override / static / inline / macro info. Modifier
	 * siblings precede the member they attach to inside the same parent, so each
	 * visited node scans its CHILDREN with a running modifier state, reset at every
	 * member. The kind seams arrive pre-resolved as `seams`, so nothing here reads
	 * `RefShape` directly.
	 */
	private static function collectMembers(
		node: QueryNode, source: String, accessors: Map<Int, Bool>, writeAccessors: Map<Int, Bool>, returnTypes: Map<Int, String>,
		typeSources: Map<Int, String>, seams: MemberSeams
	): Array<MemberInfo> {
		final out: Array<MemberInfo> = [];
		RefactorSupport.eachMemberHost(node, n -> {
			// `guarded` is a property of the HOST, not of the member's own modifier run:
			// `eachMemberHost` descends INTO a conditional-compilation region, so a member
			// written under `#if` is visited with that region as its host node.
			final guarded: Bool = seams.conditionalKind != null && n.kind == seams.conditionalKind;
			var runVisibility: Null<String> = null;
			var runOverride: Bool = false;
			var runStatic: Bool = false;
			var runInline: Bool = false;
			var runMacro: Bool = false;
			for (child in n.children) {
				final sp: Null<Span> = child.span;
				// Enum constructors (`SimpleCtor` / `ParamCtor`) are captured as members too, so a bare
				// `import pkg.Enum;` whose constructors are used as bare identifiers is not judged unused.
				// Enum-abstract values are already `FIELD_MEMBER_KINDS`.
				if (RefactorSupport.isMemberDeclKind(child.kind) || (n.kind == ANON_KIND && ANON_SHORT_FIELD_KINDS.contains(child.kind))) {
					final nm: Null<String> = child.name;
					if (nm != null && sp != null) {
						// Re-bind to a non-null local — Strict null-safety takes a struct
						// literal's field type from the declared type, not the narrowed one.
						final memberName: String = nm;
						out.push({
							name: memberName,
							hasGetter: accessors[sp.from] ?? false,
							hasSetter: writeAccessors[sp.from] ?? false,
							returnNominal: returnTypes[sp.from],
							typeSource: typeSources[sp.from],
							visibility: runVisibility,
							isOverride: runOverride,
							kind: child.kind,
							declFrom: sp.from,
							isStatic: runStatic,
							isInline: runInline,
							isMacro: runMacro,
							guarded: guarded
						});
					}
					runVisibility = null;
					runOverride = false;
					runStatic = false;
					runInline = false;
					runMacro = false;
				} else if (sp != null && seams.visibilityKinds.contains(child.kind))
					runVisibility = source.substring(sp.from, sp.to);
				else if (child.kind == seams.overrideKind)
					runOverride = true;
				else if (child.kind == seams.staticKind)
					runStatic = true;
				else if (child.kind == seams.inlineKind)
					runInline = true;
				else if (child.kind == seams.macroKind)
					runMacro = true;
			}
		});
		return out;
	}

	/**
	 * The `RefShape` kinds `collectMembers` reads, resolved ONCE per run rather than per
	 * type: the modifier siblings it recognises and the conditional-compilation host kind
	 * that marks a member `guarded`.
	 */
	private static function memberSeamsOf(shape: RefShape): MemberSeams {
		return {
			visibilityKinds: shape.visibilityModifierKinds ?? [],
			overrideKind: shape.overrideModifierKind,
			staticKind: shape.staticModifierKind,
			inlineKind: shape.inlineModifierKind,
			macroKind: shape.macroModifierKind,
			conditionalKind: shape.conditionalMemberKind
		};
	}

	/**
	 * Whether the abstract rooted at `node` may rebind its underlying `this`: it carries a
	 * `@:build` / `@:autoBuild` (any macro-generated member is invisible to the scan, so treat it as
	 * possibly-rebinding) or writes `this` in a member other than the constructor. `pendingMeta` holds
	 * the module-level meta names accumulated before the decl.
	 */
	private static function abstractRebindsThisScan(node: QueryNode, shape: RefShape, pendingMeta: Array<String>): Bool {
		return pendingMeta.contains('@:build') || pendingMeta.contains('@:autoBuild') || memberRebindsThis(node, shape);
	}

	/**
	 * Whether any `FnMember` under `node` other than the constructor writes `this` — a non-`new`
	 * `this =` compiles only in an `inline` member and makes the abstract rebind on that call. The
	 * `new` subtree is skipped whole (a constructor `this =` is compiler-legal and final-safe); every
	 * other member is scanned with the write walker, so a write hidden in a `#if` branch counts too.
	 */
	private static function memberRebindsThis(node: QueryNode, shape: RefShape): Bool {
		if (node.kind == 'FnMember') {
			if (node.name == 'new') return false;
			for (h in Refs.find('this', node, shape)) if (h.kind == RefKind.Write) return true;
			return false;
		}
		for (c in node.children) if (memberRebindsThis(c, shape)) return true;
		return false;
	}

	/**
	 * The SIMPLE underlying-type name of a `@:forward` abstract `node` — its first `Named` child, last
	 * dot-segment, type parameters stripped — or null when `pendingMeta` carries no `@:forward` or the
	 * decl has no underlying.
	 */
	private static function forwardUnderlyingOf(node: QueryNode, pendingMeta: Array<String>): Null<String> {
		if (!pendingMeta.contains('@:forward')) return null;
		final named: Null<QueryNode> = node.children.find(c -> c.kind == 'Named');
		if (named == null) return null;
		final raw: Null<String> = named.name;
		return raw == null ? null : simpleName(StringTools.trim(raw.split('<')[0]));
	}

	/**
	 * The INNER text of the `<...>` type-parameter list written on `decl`'s header
	 * (`class Cell<Data, K:B>` -> `Data, K:B`), or null when the header carries no
	 * `<` after its name or the bracket run never closes. Locate the name token in
	 * the header text (the projection drops `<...>` params entirely, so no node's
	 * span points AT the name), then bracket-match the following `<...>` (a `->`
	 * return arrow's `>` is not a closer).
	 *
	 * The scan starts at `decl.nameNode`'s span, falling back to `fullSpan`. The
	 * name node IS the header for every shape - the inner `ClassForm` of a `final
	 * class`, the `*Head` of a split-header conditional region - so the scan never
	 * has to cross a `final` keyword or a whole `#if` line to reach the name.
	 *
	 * ONE scan answers both header questions: the arity (`splitTypeArgumentList`'s
	 * segment count) and the parameter NAMES. They used to be separate scans with
	 * separate comma logic, which is how they could have disagreed.
	 */
	private static function declTypeParamListText(source: String, decl: TypeDeclMatch): Null<String> {
		final anchor: Null<Span> = decl.nameNode.span;
		final from: Int = anchor == null ? decl.fullSpan.from : anchor.from;
		final bodyAt: Int = source.indexOf('{', from);
		final nameAt: Int = source.indexOf(decl.name, from);
		if (nameAt < 0 || (bodyAt >= 0 && nameAt > bodyAt)) return null;
		var i: Int = nameAt + decl.name.length;
		while (i < source.length && source.isSpace(i)) i++;
		if (i >= source.length || source.fastCodeAt(i) != '<'.code) return null;
		final start: Int = i + 1;
		var depth: Int = 0;
		while (i < source.length) {
			switch source.fastCodeAt(i) {
				case '<'.code:
					depth++;
				case '>'.code if (source.fastCodeAt(i - 1) != '-'.code):
					depth--;
					if (depth == 0) return source.substring(start, i);
				case _:
			}
			i++;
		}
		return null;
	}

	/**
	 * The WRITTEN name of one header type-parameter segment (`K:Base` -> `K`), or null when the
	 * segment does not start with a plain identifier. The name ends at the first `:` (constraint),
	 * `=` (default) or whitespace - the only three things Haxe lets follow it.
	 *
	 * Metadata on a type parameter (`class C<@:const N>`) is deliberately NOT stepped over: the
	 * grammar does not parse that declaration at all, so such a file is skipped by the index long
	 * before this runs. Were it ever to parse, the segment would yield no identifier and refuse
	 * the whole header - which is the fail-closed direction anyway.
	 */
	private static function typeParamNameOf(segment: String): Null<String> {
		final text: String = segment.trim();
		var end: Int = 0;
		while (end < text.length) {
			final ch: Int = text.fastCodeAt(end);
			if (ch == ':'.code || ch == '='.code || RefactorSupport.isSpace(ch)) break;
			end++;
		}
		final name: String = text.substring(0, end);
		return RefactorSupport.isIdentifier(name) ? name : null;
	}

	/**
	 * Every segment's parameter name, or EMPTY when ANY segment fails to yield one -
	 * a partial list would silently mis-index a substitution, so all-or-nothing is
	 * the only safe answer. Empty is also what a non-generic header gives, which is
	 * why `TypeDeclInfo.typeParamNames` must never be read as proof of non-genericity.
	 */
	private static function declTypeParamNames(segments: Array<String>): Array<String> {
		final out: Array<String> = [];
		for (segment in segments) {
			final name: Null<String> = typeParamNameOf(segment);
			if (name == null) return [];
			out.push(name);
		}
		return out;
	}

	/**
	 * `tree`'s top-level children with every conditional-compilation region
	 * REPLACED, in document order, by the type declarations it guards - the
	 * input `extractFileInfo` walks, so a type declared inside `#if ... #end`
	 * is indexed like a plain top-level one. Non-declaration children of a
	 * region (its imports, metadata and modifiers) are DROPPED: they are the
	 * caller's other concern and this slice does not change how they are read.
	 *
	 * Two grammar shapes carry a guarded declaration. A `Conditional` wrapper
	 * holds the region's decls FLATTENED - every branch's decls are its
	 * siblings, with no branch boundary visible in the projection (the shape
	 * `AddImport.guardedDuplicate` reads) - and is descended into. A
	 * `CondSharedBodyDecl` wrapper (a header split across `#if`, see
	 * `HxCondSharedBodyDecl`) is passed through as ITSELF: it is the node its
	 * declaration resolves from (`condSharedBodyDeclOf`).
	 *
	 * `externModifierKind` is threaded through so a guarded `extern` modifier -
	 * whether co-located with its declaration (`#if js extern class B {} #end`)
	 * or SPLIT from it (`#if cpp extern #end class Native {}`, the "extern on
	 * this target only" idiom) - is lifted like a guarded leading meta, instead
	 * of being dropped as an ordinary modifier. Null when the grammar names no
	 * extern modifier kind, matching every other `shape`-gated seam here.
	 */
	private static function declNodes(tree: QueryNode, externModifierKind: Null<String>): Array<GuardedNode> {
		final out: Array<GuardedNode> = [];
		final guardedNames: Array<String> = [];
		// Every top-level import's dedup key, seeded up front so a guarded import
		// duplicating ANY top-level one is dropped regardless of document order,
		// while a genuine top-level duplicate stays in `out` for `duplicate-import`.
		final seenImports: Array<String> = [];
		for (node in tree.children) {
			final key: Null<String> = importDedupKey(node);
			if (key != null && !seenImports.contains(key)) seenImports.push(key);
		}
		for (node in tree.children) switch node.kind {
			case 'Conditional':
				collectGuardedDecls(node, out, guardedNames, seenImports, externModifierKind);
			case 'CondSharedBodyDecl':
				pushGuardedDecl(node, out, guardedNames, seenImports, externModifierKind);
			case _:
				out.push({ node: node, guarded: false });
		}
		return out;
	}

	/**
	 * Append every type declaration `node` - a `#if ... #end` region wrapper -
	 * guards to `out`, recursing through nested regions.
	 *
	 * The projection flattens all branches into one wrapper, so an `#if js
	 * class X {...} #else class X {...} #end` region yields TWO `ClassDecl X`
	 * children even though no compilation ever sees more than one of them.
	 * Indexing both would make `declaringFiles` (and `apq declares`) report an
	 * ambiguity that does not exist, so `pushGuardedDecl` keeps the FIRST
	 * declaration of a name and drops later same-named ones - the same
	 * "first branch live, alternates raw" rule the grammar already applies to
	 * split-header regions (`HxCondSharedBodyDecl`). Distinct names across
	 * branches (`#if js class A {} #elseif cpp class B {} #else typedef C =
	 * Int; #end`) are all kept.
	 */
	private static function collectGuardedDecls(
		node: QueryNode, out: Array<GuardedNode>, guardedNames: Array<String>, seenImports: Array<String>, externModifierKind: Null<String>
	): Void {
		for (child in node.children) if (child.kind == 'Conditional')
			collectGuardedDecls(child, out, guardedNames, seenImports, externModifierKind);
		else
			pushGuardedDecl(child, out, guardedNames, seenImports, externModifierKind);
	}

	/**
	  * Append `node` to `out` when it is a type declaration whose name no
	 * conditional region has contributed yet, recording the name. A guarded import / using is
	 * lifted (deduped) into the import scope, a guarded leading `Meta` / `MetaCall` is lifted so
	 * its abstract sees it, and a guarded `extern` modifier is lifted so it reaches
	 * `extractFileInfo`'s `pendingExtern` run - the same "no place of its own, forwarded to the
	 * decl it precedes" treatment the meta lift gets, since `pendingExtern` reads ANY node of
	 * `externModifierKind` in the flattened stream, guarded or not (`extractFileInfo`'s main
	 * loop does not distinguish). Any OTHER lifted modifier still has no place and is dropped.
	 */
	private static function pushGuardedDecl(
		node: QueryNode, out: Array<GuardedNode>, guardedNames: Array<String>, seenImports: Array<String>, externModifierKind: Null<String>
	): Void {
		final decl: Null<TypeDeclMatch> = typeDeclAt(node);
		if (decl != null) {
			if (guardedNames.contains(decl.name)) return;
			guardedNames.push(decl.name);
			out.push({ node: node, guarded: true });
			return;
		}
		// A guarded leading meta: lift it so it reaches `extractFileInfo`'s meta run and attaches to
		// the abstract it guards. An `#if`-split abstract carries its `@:forward` INSIDE the region
		// (openfl `Vector`), and document-order preserves the meta-before-decl attachment.
		if (isMetaNodeKind(node.kind)) {
			out.push({ node: node, guarded: true });
			return;
		}
		// A guarded `extern` modifier: lift it too, whether it shares its region with the
		// declaration (`#if js extern class B {} #end`) or is SPLIT from it (`#if cpp extern
		// #end class Native {}` - "extern on this target only"), so the modifier reaches
		// `extractFileInfo`'s `pendingExtern` run and marks the declaration it precedes.
		if (externModifierKind != null && node.kind == externModifierKind) {
			out.push({ node: node, guarded: true });
			return;
		}
		// A guarded import / using: lift it so it joins the per-file import scope,
		// deduped against every import already seen (a top-level one seeded up
		// front, or an earlier guarded branch). A non-import, non-declaration node
		// (a lifted modifier other than `extern`) has no key and is dropped.
		final key: Null<String> = importDedupKey(node);
		if (key == null || seenImports.contains(key)) return;
		seenImports.push(key);
		out.push({ node: node, guarded: true });
	}

	/**
	 * The FIRST branch's type declaration of a split-header conditional region
	 * (`CondSharedBodyDecl`), or null for any other node and for a region
	 * carrying no recognised head. The head child holds the name, the type
	 * parameters and the heritage; the shared members are that head's
	 * SIBLINGS, written after `#end`.
	 *
	 * `fullSpan` is the WRAPPER's span, not the head's. It is the only span
	 * that CONTAINS the members, so a span-containment lookup (the
	 * innermost-enclosing-type scan in `RedundantBypassAccessor`) resolves
	 * them; and it is the only one that is a complete syntactic unit - the
	 * head stops at the `{` it opens, so a mutation addressed by the head span
	 * would leave a dangling `#else ... #end` and an unmatched `}`. `nameNode`
	 * is the head, which keeps the type-parameter scan anchored past the `#if`
	 * line.
	 */
	private static function condSharedBodyDeclOf(node: QueryNode): Null<TypeDeclMatch> {
		if (node.kind != 'CondSharedBodyDecl') return null;
		final span: Null<Span> = node.span;
		if (span == null) return null;
		// A plain `find` would have to re-read the map for the kind, so the head is
		// resolved and mapped in one pass.
		for (child in node.children) {
			final kind: Null<String> = DECL_HEAD_KINDS[child.kind];
			final name: Null<String> = child.name;
			if (kind != null && name != null) return {
				name: name,
				kind: kind,
				nameNode: child,
				declNode: node,
				fullSpan: span
			};
		}
		return null;
	}

	/**
	 * The `(kind, raw)` dedup key of an import-declaration `node`, or null when
	 * `node` is not an import / using declaration. `raw` is the node's exposed
	 * name — the dotted path for `import` / `using`, `pkg.*` for a wildcard, the
	 * alias for an alias import (so two distinct aliases of one path stay
	 * distinct) — which with the import kind uniquely identifies a repeat across
	 * `#if` branches or a top-level / guarded pair. The `as` and `in` alias forms
	 * share one key, so a cross-form alias duplicate collapses too.
	 */
	private static function importDedupKey(node: QueryNode): Null<String> {
		final raw: Null<String> = node.name;
		return raw == null
			? null
			: switch node.kind {
				case 'ImportDecl': 'import|$raw';
				case 'ImportAliasDecl' | 'ImportAliasInDecl': 'alias|$raw';
				case 'ImportWildDecl': 'wild|$raw';
				case 'UsingDecl': 'using|$raw';
				case _: null;
			};
	}

	/**
	 * The RAW written names of a decl's `implements` targets only (its `ImplementsClause`
	 * children), excluding the `extends` `ExtendsClause`. Parallel to `collectSupertypesRaw`
	 * but interface-scoped, so a class's implemented interfaces can be enumerated apart from
	 * its superclass.
	 */
	private static function collectImplementsRaw(node: QueryNode): Array<String> {
		final out: Array<String> = [];
		collectInto(node, n -> {
			if (n.kind == 'ImplementsClause') for (c in n.children) {
				final nm: Null<String> = c.name;
				if (nm != null) out.push(nm);
			}
		});
		return out;
	}

	/**
	 * The SIMPLE outer nominal a plain `typedef T = <Target>;` re-points at, or null for every
	 * other declaration. The projection carries NO alias link — a `TypedefDecl` aliasing a named
	 * type has no children at all — so the target is read from the declaration's own source: the
	 * text after the first `=`, stripped of a trailing `;`, accepted only when
	 * `NominalTypes.outerNominalOf` recognises it as a nominal path (`Widget`, `pkg.Deep.Thing`,
	 * `Array<Int>`). Null must be read by every consumer as "the alias is not resolvable", never
	 * as "it aliases nothing". Four shapes yield it:
	 *
	 *  - an anon-struct typedef — its fields ARE its members and the index already models them;
	 *  - a FUNCTION type (`Holder<Int> -> String`), whose head `outerNominalOf` would otherwise
	 *    read as the nominal `Holder` and prove absence against a type the alias never denotes;
	 *  - anything else `outerNominalOf` does not recognise as a nominal path;
	 *  - a `#if`-GUARDED declaration. Every branch projects under one `Conditional` and the
	 *    index keeps the FIRST decl of a name, so a followed alias would silently commit to
	 *    whichever branch happened to be indexed and be wrong for the other compilation.
	 */
	private static function aliasTargetOf(source: String, decl: TypeDeclMatch, node: QueryNode, guarded: Bool): Null<String> {
		if (guarded || decl.kind != TYPEDEF_DECL_KIND || node.children.exists(c -> c.kind == ANON_KIND)) return null;
		final text: String = source.substring(decl.fullSpan.from, decl.fullSpan.to);
		final eq: Int = text.indexOf('=');
		if (eq == -1) return null;
		final tail: String = text.substring(eq + 1).trim();
		final body: String = tail.endsWith(';') ? tail.substring(0, tail.length - 1) : tail;
		// A `->` anywhere makes the alias a function type: its head is not the type the alias
		// denotes. Over-refusing a `Holder<Int -> Void>` argument the same way is harmless.
		return body.indexOf('->') != -1 ? null : NominalTypes.outerNominalOf(body.trim());
	}

}
