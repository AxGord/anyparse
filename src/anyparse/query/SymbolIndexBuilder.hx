package anyparse.query;

import anyparse.query.GrammarPlugin.AmbientImportSource;
import anyparse.query.GrammarPlugin.AmbientImports;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.Refs.RefKind;
import anyparse.query.SymbolIndex.AmbientImportGroup;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.query.TypeSyntax;
import anyparse.runtime.Span;
import haxe.Exception;
import haxe.io.Path;

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

	/**
	 * True for a type declaration a conditional region of the file already declared the name of — another branch's
	 * declaration of the same type, which `extractFileInfo` folds into the one listed (`withAlternate`).
	 */
	var ?alternate: Bool;
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
	final dynamicKind: Null<String>;
	final externKind: Null<String>;
	final overloadKind: Null<String>;

	/** The operator-overload annotation NAME (`RefShape.operatorOverloadMetaName`), or null when the grammar has none. */
	final operatorMetaName: Null<String>;

	/** The signature-overload annotation NAME (`RefShape.signatureOverloadMetaName`), or null when the grammar has none. */
	final overloadMetaName: Null<String>;

	/** The implicit-conversion annotation NAME (`ExecutionShape.implicitConversionMetaName`), or null when the grammar has none. */
	final conversionMetaName: Null<String>;

	/** The annotations under which the language calls a member implicitly (`ExecutionShape.implicitCallMetaNames`). */
	final implicitCallMetaNames: Array<String>;

	/** The annotations that keep a static out of the extension channel (`ExecutionShape.extensionExcludingMetaNames`). */
	final extensionExcludingMetaNames: Array<String>;
	final conditionalKind: Null<String>;
	final paramKinds: Array<String>;
	final functionKinds: Array<String>;
	final annotationKinds: Array<String>;
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

	/** The type node a named type reference projects as. */
	private static inline final NAMED_KIND: String = 'Named';

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
	 * The anon-structure field forms `var name:T;` / `final name:T;`, whose DECLARATION sits one
	 * node deeper than the member: the grammar wraps it in an optional-marker node (`var ?name:T`)
	 * that owns the name and the annotation. The span-info walk keys every type map on the node
	 * carrying the `type` field, so a lookup at the MEMBER's own span answers nothing for
	 * these two, and almost every indexed anon-struct member then reads as unannotated.
	 */
	private static final ANON_WRAPPED_FIELD_KINDS: Array<String> = ['VarField', 'FinalField'];

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
			// The SOURCE is retained for a skipped file too. Nothing structural can be read from
			// it, but its raw text still answers the one question every confinement gate asks —
			// could this file reference the member at all — and that turns a whole-project veto
			// into a per-member one (`RawSourceScan.skippedMayReference`).
			sources[entry.file] = entry.source;
			if (tree == null) {
				skipped.push(entry.file);
				continue;
			}
			final accessors: Map<Int, Bool> = provider != null ? provider.propertyAccessors(entry.source) : [];
			final writeAccessors: Map<Int, Bool> = provider != null ? provider.propertyWriteAccessors(entry.source) : [];
			final returnTypes: Map<Int, String> = provider != null ? provider.returnTypes(entry.source) : [];
			final typeSources: Map<Int, String> = provider != null ? provider.declaredTypeSources(entry.source) : [];
			final typeParams: Map<Int, Array<String>> = provider != null ? provider.typeParamNames(entry.source) : [];
			infos.push(extractFileInfo(
				entry.file, entry.source, tree, accessors, writeAccessors, returnTypes, typeSources, typeParams, shape, memberSeams,
				abstractKinds, plugin.typeSyntax
			));
		}
		attachAmbientImports(infos, plugin, shape, memberSeams, abstractKinds, provider);
		return { files: infos, skipped: skipped, sources: sources };
	}

	/**
	 * Whether an INDEXED path and an ambient source's path name one file. The index carries paths as
	 * the caller spelled them, the chain carries what the walk resolved, so equality alone answers
	 * only when both are absolute; a relative indexed path is the tail of its own absolute form.
	 */
	private static inline function sameFile(indexed: String, resolved: String): Bool {
		return resolved == indexed || resolved.endsWith('/$indexed');
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

	/** Whether `pendingMeta` holds the grammar's (optional) tag `name` — false when the grammar names none. */
	private static inline function carriesMeta(pendingMeta: Array<String>, name: Null<String>): Bool {
		return name != null && pendingMeta.contains(name);
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
		returnTypes: Map<Int, String>, typeSources: Map<Int, String>, typeParams: Map<Int, Array<String>>, shape: RefShape,
		memberSeams: MemberSeams, abstractKinds: Array<String>, typeSyntax: TypeSyntaxReader
	): FileInfo {
		final basename: String = RefactorSupport.baseNameOf(file);
		var pkg: String = '';
		final imports: Array<ImportInfo> = [];
		final types: Array<TypeDeclInfo> = [];
		var pendingMeta: Array<String> = [];
		// the members a pending `@:forward(...)` names, null when it names none (it forwards them all)
		var pendingForwarded: Null<Array<String>> = null;
		// The EXTERN modifier projects as a NAMELESS sibling node preceding its declaration
		// (`(Extern) (ClassDecl Date …)`), the same splice shape a visibility modifier takes, so it
		// is carried forward like `pendingMeta` and consumed by the next type declaration.
		final externModifierKind: Null<String> = shape.externModifierKind;
		var pendingExtern: Bool = false;
		// A module-`private` type's modifier takes that same nameless-sibling shape, and is carried
		// forward the same way. Spelled as "the visibility modifier that is not the public one" so no
		// grammar kind name is written here; a grammar declaring no visibility modifiers yields an
		// empty set and every type indexes as public, which is the pre-existing answer.
		final privateModifierKinds: Array<String> = privateVisibilityKinds(shape);
		var pendingPrivate: Bool = false;

		for (gn in declNodes(tree, source, externModifierKind)) {
			final node: QueryNode = gn.node;
			if (externModifierKind != null && node.kind == externModifierKind) {
				pendingExtern = true;
				continue;
			}
			if (privateModifierKinds.contains(node.kind)) {
				pendingPrivate = true;
				continue;
			}
			final typeDecl: Null<TypeDeclMatch> = typeDeclAt(node);
			if (typeDecl != null) {
				final supersRaw: Array<String> = collectSupertypesRaw(node);
				final aliasPath: Null<String> = aliasTargetPathOf(source, typeDecl, node, gn.guarded, typeSyntax);
				final isAbstract: Bool = abstractKinds.contains(typeDecl.kind);
				final paramNames: Array<String> = declTypeParams(typeParams, typeDecl);
				final info: TypeDeclInfo = {
					name: typeDecl.name,
					kind: typeDecl.kind,
					span: typeDecl.fullSpan,
					isMain: typeDecl.name == basename,
					isPrivate: pendingPrivate,
					isExtern: pendingExtern,
					typeParamArity: paramNames.length,
					typeParamNames: paramNames,
					supertypes: supersRaw.map(simpleName),
					supertypesRaw: supersRaw,
					supertypesWritten: collectSupertypesWritten(node, source),
					interfaces: collectImplementsRaw(node).map(simpleName),
					// A `typedef X = {…}` projects an `Anon` child; its fields can
					// never be properties, so field access on it is side-effect-free.
					isAnonStruct: typeDecl.kind == TYPEDEF_DECL_KIND && node.children.exists(c -> c.kind == ANON_KIND),
					aliasTargetNominal: aliasPath == null ? null : simpleName(aliasPath),
					aliasTargetRaw: aliasPath,
					hasRtti: carriesMeta(pendingMeta, shape.reflectedDeclMetaName),
					hasBuild: carriesOwnBuildMacro(pendingMeta, shape),
					hasAutoBuild: carriesAnyMeta(pendingMeta, shape.descendantBuildMacroMetaNames),
					hasKeep: carriesMeta(pendingMeta, shape.retainedDeclMetaName),
					constructsFromLiteral: carriesAnyMeta(pendingMeta, shape.execution?.implicitConstructionTypeMetaNames),
					bringsExtensions: carriesAnyMeta(pendingMeta, shape.execution?.extensionTypeMetaNames),
					members: collectMembers(node, source, accessors, writeAccessors, returnTypes, typeSources, typeParams, memberSeams),
					abstractSelfRebind: isAbstract && abstractRebindsThisScan(node, shape, pendingMeta),
					abstractForwardUnderlying: isAbstract ? forwardUnderlyingOf(node, pendingMeta, shape) : null,
					underlyingRaw: underlyingPathOf(typeDecl.nameNode, isAbstract, gn.guarded),
					guarded: gn.guarded,
					forwardedMembers: pendingForwarded
				};
				// another branch's declaration of a type already listed is the same type in another build: folded into it
				final listed: Null<Int> = gn.alternate == true ? lastIndexNamed(types, typeDecl.name) : null;
				if (listed == null)
					types.push(info)
				else
					types[listed] = withAlternate(types[listed], info);
				pendingMeta = [];
				pendingForwarded = null;
				pendingExtern = false;
				pendingPrivate = false;
				continue;
			}

			if (isMetaNodeKind(node.kind)) {
				final metaName: Null<String> = node.name;
				if (metaName != null) pendingMeta.push(metaName);
				// `@:forward(a, b)` forwards only the members it names
				pendingForwarded = forwardedArgsOf(node, shape, pendingForwarded);
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
					pendingForwarded = null;
					pendingExtern = false;
					pendingPrivate = false;
				case 'ImportDecl':
					imports.push({
						raw: name,
						kind: ImportKind.Import,
						alias: null,
						aliasTarget: null,
						span: span,
						guarded: gn.guarded
					});
					pendingMeta = [];
					pendingForwarded = null;
					pendingExtern = false;
					pendingPrivate = false;
				case 'ImportAliasDecl', 'ImportAliasInDecl':
					// The grammar's name slot for these two kinds is the ALIAS; the aliased path is
					// only in the statement text, so it is decoded there — through the project's one
					// decoder of that text, rather than a second spelling of the same scan.
					final target: String = ModuleScan.aliasTargetOf(source.substring(span.from, span.to));
					imports.push({
						raw: name,
						kind: ImportKind.Alias,
						alias: name,
						aliasTarget: target == '' ? null : target,
						span: span,
						guarded: gn.guarded
					});
					pendingMeta = [];
					pendingForwarded = null;
					pendingExtern = false;
					pendingPrivate = false;
				case 'ImportWildDecl':
					imports.push({
						raw: name,
						kind: ImportKind.Wild,
						alias: null,
						aliasTarget: null,
						span: span,
						guarded: gn.guarded
					});
					pendingMeta = [];
					pendingForwarded = null;
					pendingExtern = false;
					pendingPrivate = false;
				case 'UsingDecl':
					imports.push({
						raw: name,
						kind: ImportKind.Using,
						alias: null,
						aliasTarget: null,
						span: span,
						guarded: gn.guarded
					});
					pendingMeta = [];
					pendingForwarded = null;
					pendingExtern = false;
					pendingPrivate = false;
				case _:
					// A module-level declaration that is not a TYPE — Haxe 4.2's module-level statics
					// project as `(Private) (FnDecl helper)`, so the visibility modifier reaches this loop
					// with no type to attach to. It must NOT be carried forward the way `pendingMeta` and
					// `pendingExtern` are: over-attaching those two only makes a consumer more
					// conservative, while over-attaching `isPrivate` REMOVES a binding, and a removed
					// binding is what `MoveSymbol`'s gate reads as "nothing binds this name" — the
					// direction that refuses LESS.
					pendingPrivate = false;
			}
		}

		final module: String = pkg == '' ? basename : '$pkg.$basename';
		return {
			file: file,
			pkg: pkg,
			module: module,
			imports: imports,
			types: types,
			// Filled by `attachAmbientImports` once every file's own imports exist; a chain member is
			// usually an indexed file, and its extracted list is not there while this pass runs.
			ambientImports: [],
			ambientImportsBounded: true,
			accessGrants: collectAccessGrants(tree, shape)
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

	/**
	 * The `extends` / `implements` targets of the declaration `node` as the source writes them, type arguments
	 * included (`Box<W>`), in clause order — what a consumer binding the supertype's parameters reads.
	 */
	private static function collectSupertypesWritten(node: QueryNode, source: String): Array<String> {
		final out: Array<String> = [];
		for (clause in node.children) if (clause.kind == 'ExtendsClause' || clause.kind == 'ImplementsClause') for (c in clause.children) {
			final span: Null<Span> = c.span;
			if (span != null) out.push(source.substring(span.from, span.to));
		}
		return out;
	}

	/**
	 * Simple names of every type this file TAKES private access to — the arguments of every
	 * `RefShape.takesPrivateAccessMetaName` annotation in `tree` (Haxe `@:access(pkg.Type)`). Empty
	 * when the grammar names no such tag. The opposite direction (`grantsPrivateAccessMetaName`) is
	 * NOT collected: its arguments are unenumerable by construction, so its consumers read only
	 * whether it is present at all.
	 */
	private static function collectAccessGrants(tree: QueryNode, shape: RefShape): Array<String> {
		final out: Array<String> = [];
		final tag: Null<String> = shape.takesPrivateAccessMetaName;
		if (tag == null) return out;
		collectInto(tree, n -> {
			if (n.kind == 'MetaCall' && n.name == tag) for (c in n.children) {
				final nm: Null<String> = c.name;
				if (nm != null) out.push(simpleName(nm));
			}
		});
		return out;
	}

	/** Whether `pendingMeta` holds any of the grammar's (optional) tag list `names`. */
	private static function carriesAnyMeta(pendingMeta: Array<String>, names: Null<Array<String>>): Bool {
		return (names ?? []).exists(name -> pendingMeta.contains(name));
	}

	/**
	 * Whether `pendingMeta` holds a build-macro tag that rewrites the CARRIER's own member set —
	 * `typeBuildMacroMetaNames` minus the descendant-ward `descendantBuildMacroMetaNames` (Haxe:
	 * `@:build` / `@:genericBuild`, but not `@:autoBuild`, which builds subtypes). The two flags are
	 * read while climbing a chain UPWARD, where the union a file-scoped text scan uses would answer
	 * the wrong question; a tag the grammar puts in the union and nowhere else counts as own-ward,
	 * the direction that can only make a consumer bail out more often.
	 */
	private static function carriesOwnBuildMacro(pendingMeta: Array<String>, shape: RefShape): Bool {
		final descendant: Array<String> = shape.descendantBuildMacroMetaNames ?? [];
		return (shape.typeBuildMacroMetaNames ?? []).exists(name -> !descendant.contains(name) && pendingMeta.contains(name));
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
		typeSources: Map<Int, String>, typeParams: Map<Int, Array<String>>, seams: MemberSeams
	): Array<MemberInfo> {
		// noqa: complexity
		final out: Array<MemberInfo> = [];
		MemberKinds.eachMemberHost(node, n -> {
			// `guarded` is a property of the HOST, not of the member's own modifier run:
			// `eachMemberHost` descends INTO a conditional-compilation region, so a member
			// written under `#if` is visited with that region as its host node.
			final guarded: Bool = seams.conditionalKind != null && n.kind == seams.conditionalKind;
			var runVisibility: Null<String> = null;
			var runOverride: Bool = false;
			var runStatic: Bool = false;
			var runInline: Bool = false;
			var runMacro: Bool = false;
			var runOperators: Array<String> = [];
			var runImplicitConversion: Bool = false;
			var runImplicitCall: Bool = false;
			var runImplicitMetas: Array<String> = [];
			var runDynamic: Bool = false;
			var runNoExtension: Bool = false;
			var runOverloadMeta: Bool = false;
			var runExtern: Bool = false;
			var runOverload: Bool = false;
			var runMetaNames: Array<String> = [];
			for (child in n.children) {
				final sp: Null<Span> = child.span;
				// Enum constructors (`SimpleCtor` / `ParamCtor`) are captured as members too, so a bare
				// `import pkg.Enum;` whose constructors are used as bare identifiers is not judged unused.
				// Enum-abstract values are already `FIELD_MEMBER_KINDS`.
				if (MemberKinds.isMemberDeclKind(child.kind) || (n.kind == ANON_KIND && ANON_SHORT_FIELD_KINDS.contains(child.kind))) {
					final nm: Null<String> = child.name;
					if (nm != null && sp != null) {
						// Re-bind to a non-null local — Strict null-safety takes a struct
						// literal's field type from the declared type, not the narrowed one.
						final memberName: String = nm;
						final typeKey: Int = typeInfoKeyOf(child, sp);
						out.push({
							name: memberName,
							hasGetter: accessors[typeKey] ?? false,
							hasSetter: writeAccessors[typeKey] ?? false,
							returnNominal: returnTypes[typeKey],
							returnSource: seams.functionKinds.contains(child.kind)
								? CallGraphNames.returnSourceOf(child, source, seams.annotationKinds)
								: null,
							typeSource: typeSources[typeKey],
							typeParamNames: typeParams[typeKey] ?? [],
							firstParamTypeSource: firstParamTypeSourceOf(child, typeSources, seams.paramKinds),
							paramTypeSources: paramTypeSourcesOf(child, typeSources, seams.paramKinds),
							visibility: runVisibility,
							isOverride: runOverride,
							kind: child.kind,
							declFrom: sp.from,
							isStatic: runStatic,
							isInline: runInline,
							isMacro: runMacro,
							operatorOverloads: runOperators,
							isImplicitConversion: runImplicitConversion,
							isImplicitCall: runImplicitCall,
							implicitCallMetas: runImplicitMetas,
							isDynamic: runDynamic,
							isExtern: runExtern,
							isOverload: runOverload,
							metaNames: runMetaNames,
							excludedFromExtensions: runNoExtension,
							hasOverloadMeta: runOverloadMeta,
							guarded: guarded
						});
					}
					runVisibility = null;
					runOverride = false;
					runStatic = false;
					runInline = false;
					runMacro = false;
					runOperators = [];
					runImplicitConversion = false;
					runImplicitCall = false;
					runImplicitMetas = [];
					runDynamic = false;
					runNoExtension = false;
					runOverloadMeta = false;
					runExtern = false;
					runOverload = false;
					runMetaNames = [];
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
				else if (child.kind == seams.dynamicKind)
					runDynamic = true;
				else if (child.kind == seams.externKind)
					runExtern = true;
				else if (child.kind == seams.overloadKind)
					runOverload = true;
				else {
					if (MemberKinds.META_KINDS.contains(child.kind) && child.name != null) runMetaNames.push(child.name ?? '');
					final operatorKind: Null<String> = operatorKindOf(child, seams);
					if (operatorKind != null) runOperators.push(operatorKind);
					if (isConversionMeta(child, seams)) runImplicitConversion = true;
					if (MemberKinds.META_KINDS.contains(child.kind) && seams.extensionExcludingMetaNames.contains(child.name ?? ''))
						runNoExtension = true;
					if (MemberKinds.META_KINDS.contains(child.kind) && child.name != null && child.name == seams.overloadMetaName)
						runOverloadMeta = true;
					if (isImplicitCallMeta(child, seams)) {
						runImplicitCall = true;
						runImplicitMetas.push(child.name ?? '');
					}
				}
			}
		});
		return out;
	}

	/**
	 * The span offset the four type maps are keyed on for `member` — its own declaration span,
	 * except for the anon-structure `var` / `final` field kinds, whose declaration sits one node
	 * deeper (`ANON_WRAPPED_FIELD_KINDS`). The inner node must re-declare the SAME name, so an
	 * initializer or any other single child can never stand in for the declaration.
	 *
	 * `declFrom` deliberately keeps the MEMBER's own offset: it is a rename cursor, not a key
	 * into a type map.
	 */
	private static function typeInfoKeyOf(member: QueryNode, own: Span): Int {
		if (!ANON_WRAPPED_FIELD_KINDS.contains(member.kind)) return own.from;
		final decl: Null<QueryNode> = member.children[0];
		if (decl == null || decl.name != member.name) return own.from;
		final declSpan: Null<Span> = decl.span;
		return declSpan == null ? own.from : declSpan.from;
	}

	/** The written types of every parameter of `member`, in order, `null` for one written without a type. */
	private static function paramTypeSourcesOf(
		member: QueryNode, typeSources: Map<Int, String>, paramKinds: Array<String>
	): Array<Null<String>> {
		return [
			for (c in member.children) if (paramKinds.contains(c.kind)) c.span == null ? null : typeSources[c.span.from]
		];
	}

	/** Whether `node` is an annotation under which the language calls the member implicitly (`MemberSeams.implicitCallMetaNames`). */
	private static function isImplicitCallMeta(node: QueryNode, seams: MemberSeams): Bool {
		return MemberKinds.META_KINDS.contains(node.kind) && seams.implicitCallMetaNames.contains(node.name ?? '');
	}

	/**
	 * The VERBATIM `:Type` source of `member`'s FIRST parameter — the type a `using` static
	 * extension accepts as its receiver — or null when it declares no parameter, the first one
	 * carries no annotation, or the member is not a function at all.
	 *
	 * Read off the SAME `declaredTypeSources` map the member's own `typeSource` comes from: a
	 * parameter is an ordinary typed binding, keyed by its declaration span. Only the first
	 * parameter is captured, because that is the only one a `using` gives a meaning to; the rest
	 * stay ordinary call arguments no cross-file query has ever asked about.
	 */
	private static function firstParamTypeSourceOf(
		member: QueryNode, typeSources: Map<Int, String>, paramKinds: Array<String>
	): Null<String> {
		for (child in member.children) if (paramKinds.contains(child.kind)) {
			final sp: Null<Span> = child.span;
			return sp == null ? null : typeSources[sp.from];
		}
		return null;
	}

	/**
	 * The node KIND the argument of the operator-overload annotation `meta` projects as —
	 * `@:op(A + B)` gives the grammar addition kind — or null when `meta` is not that annotation
	 * or does not carry exactly one argument.
	 *
	 * The KIND is what a consumer can compare against an operator node it is already holding, so
	 * neither the index nor the check ever spells an operator symbol; the grammar decides which
	 * form is which, including the two that share a symbol (`A - B` against `-A`).
	 */
	private static function operatorKindOf(meta: QueryNode, seams: MemberSeams): Null<String> {
		final metaName: Null<String> = seams.operatorMetaName;
		return metaName == null || meta.name != metaName || !isMetaNodeKind(meta.kind) || meta.children.length != 1
			? null
			: meta.children[0].kind;
	}

	/**
	 * Whether `meta` is the implicit-conversion annotation the grammar names — a `@:from` on an
	 * abstract member. Unlike `operatorKindOf` the ARGUMENT carries nothing a consumer needs: the
	 * question is only whether a conversion exists at all, so a bare tag and an argument-bearing
	 * one answer alike.
	 */
	private static function isConversionMeta(meta: QueryNode, seams: MemberSeams): Bool {
		final metaName: Null<String> = seams.conversionMetaName;
		return metaName != null && meta.name == metaName && isMetaNodeKind(meta.kind);
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
			dynamicKind: shape.dynamicModifierKind,
			externKind: shape.externModifierKind,
			overloadKind: shape.overloadModifierKind,
			operatorMetaName: shape.operatorOverloadMetaName,
			overloadMetaName: shape.signatureOverloadMetaName,
			conversionMetaName: shape.execution?.implicitConversionMetaName,
			implicitCallMetaNames: shape.execution?.implicitCallMetaNames ?? [],
			extensionExcludingMetaNames: shape.execution?.extensionExcludingMetaNames ?? [],
			conditionalKind: shape.conditionalMemberKind,
			paramKinds: shape.paramKinds ?? [],
			functionKinds: shape.functionKinds ?? [],
			annotationKinds: shape.typeAnnotationKinds ?? []
		};
	}

	/**
	 * Whether the abstract rooted at `node` may rebind its underlying `this`: it carries any
	 * build-macro tag the grammar names (any macro-generated member is invisible to the scan, so
	 * treat it as possibly-rebinding) or writes `this` in a member other than the constructor.
	 * `pendingMeta` holds the module-level meta names accumulated before the decl. The DIRECTION
	 * split the two index flags make is deliberately not made here: this is the conservative union,
	 * the same one `MemberWriteScan.carriesBuildMacro` matches, and an over-declined abstract only
	 * keeps the looser answer.
	 */
	private static function abstractRebindsThisScan(node: QueryNode, shape: RefShape, pendingMeta: Array<String>): Bool {
		return carriesAnyMeta(pendingMeta, shape.typeBuildMacroMetaNames) || memberRebindsThis(node, shape);
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
		return node.children.exists(c -> memberRebindsThis(c, shape));
	}

	/**
	 * The members the forwarding annotation `meta` names (`@:forward(a, b)`), or `pending` — what the run of
	 * annotations before it already said — when `meta` is not one or names none.
	 */
	private static function forwardedArgsOf(meta: QueryNode, shape: RefShape, pending: Null<Array<String>>): Null<Array<String>> {
		if (meta.name != shape.forwardingDeclMetaName || meta.children.length == 0) return pending;
		return [for (c in meta.children) if (c.name != null) c.name ?? ''];
	}

	/**
	 * The SIMPLE underlying-type name of a FORWARDING abstract `node` — its first `Named` child, last
	 * dot-segment, type parameters stripped — or null when `pendingMeta` carries no
	 * `RefShape.forwardingDeclMetaName` (Haxe `@:forward`) or the decl has no underlying.
	 */
	private static function forwardUnderlyingOf(node: QueryNode, pendingMeta: Array<String>, shape: RefShape): Null<String> {
		if (!carriesMeta(pendingMeta, shape.forwardingDeclMetaName)) return null;
		final named: Null<QueryNode> = node.children.find(c -> c.kind == NAMED_KIND);
		if (named == null) return null;
		final raw: Null<String> = named.name;
		return raw == null ? null : simpleName(raw);
	}

	/**
	 * The head path of the underlying type an abstract declares (`TypeDeclInfo.underlyingRaw`) — the
	 * `QueryNode.type` slot of the node naming it — or null for a non-abstract (`isAbstract`), a `guarded`
	 * one, one that writes none, or one that writes something other than a named type.
	 */
	private static function underlyingPathOf(nameNode: QueryNode, isAbstract: Bool, guarded: Bool): Null<String> {
		final underlying: Null<QueryNode> = isAbstract && !guarded ? nameNode.type : null;
		return underlying != null && underlying.kind == NAMED_KIND ? underlying.name : null;
	}

	/** The type-parameter names `decl` declares — `typeParams` keyed by the node naming it (`TypeInfoProvider.typeParamNames`). */
	private static function declTypeParams(typeParams: Map<Int, Array<String>>, decl: TypeDeclMatch): Array<String> {
		return typeParams[(decl.nameNode.span ?? decl.fullSpan).from] ?? [];
	}

	/**
	 * The visibility-modifier kinds that DENY outside-the-module access — every entry of the
	 * grammar's visibility set except the public one. Empty for a grammar that declares neither,
	 * which indexes every type as non-private: the answer this record carried before the flag.
	 */
	private static function privateVisibilityKinds(shape: RefShape): Array<String> {
		final all: Null<Array<String>> = shape.visibilityModifierKinds;
		if (all == null) return [];
		final publicKind: Null<String> = shape.publicModifierKind;
		return [for (kind in all) if (kind != publicKind) kind];
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
	private static function declNodes(tree: QueryNode, source: String, externModifierKind: Null<String>): Array<GuardedNode> {
		final out: Array<GuardedNode> = [];
		final guardedNames: Array<String> = [];
		// Every top-level import's dedup key, seeded up front so a guarded import
		// duplicating ANY top-level one is dropped regardless of document order,
		// while a genuine top-level duplicate stays in `out` for `duplicate-import`.
		final seenImports: Array<String> = [];
		for (node in tree.children) {
			final key: Null<String> = importDedupKey(node, source);
			if (key != null && !seenImports.contains(key)) seenImports.push(key);
		}
		for (node in tree.children) switch node.kind {
			case 'Conditional':
				collectGuardedDecls(node, source, out, guardedNames, seenImports, externModifierKind);
			case 'CondSharedBodyDecl':
				pushGuardedDecl(node, source, out, guardedNames, seenImports, externModifierKind);
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
	 * ambiguity that does not exist, so `pushGuardedDecl` marks every later
	 * same-named declaration an ALTERNATE, which `extractFileInfo` folds into
	 * the first one's record (`withAlternate`): ONE type of the name, whose
	 * members, supertypes and code-running metadata are what any branch
	 * declares. Dropping the alternate lost those - a property with a getter,
	 * a supertype, only the second branch writes was no part of the type, and
	 * a call graph built on the index followed no accessor and no dispatch
	 * there. Distinct names across branches (`#if js class A {} #elseif cpp
	 * class B {} #else typedef C = Int; #end`) are all kept.
	 */
	private static function collectGuardedDecls(
		node: QueryNode, source: String, out: Array<GuardedNode>, guardedNames: Array<String>, seenImports: Array<String>,
		externModifierKind: Null<String>
	): Void {
		for (child in node.children) if (child.kind == 'Conditional')
			collectGuardedDecls(child, source, out, guardedNames, seenImports, externModifierKind);
		else
			pushGuardedDecl(child, source, out, guardedNames, seenImports, externModifierKind);
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
		node: QueryNode, source: String, out: Array<GuardedNode>, guardedNames: Array<String>, seenImports: Array<String>,
		externModifierKind: Null<String>
	): Void {
		final decl: Null<TypeDeclMatch> = typeDeclAt(node);
		if (decl != null) {
			final alternate: Bool = guardedNames.contains(decl.name);
			if (!alternate) guardedNames.push(decl.name);
			out.push({ node: node, guarded: true, alternate: alternate });
			return;
		}
		// A guarded leading meta: lift it so it reaches `extractFileInfo`'s meta run and attaches to
		// the abstract it guards. An `#if`-split abstract carries its `@:forward` INSIDE the region
		// (openfl `Vector`), and document-order preserves the meta-before-decl attachment.
		if (isMetaNodeKind(node.kind)) {
			// a region holding only metadata projects it under a nameless wrapper: lift each one it holds
			final held: Array<QueryNode> = node.name == null ? [for (c in node.children) if (isMetaNodeKind(c.kind)) c] : [];
			if (held.length == 0) out.push({ node: node, guarded: true });
			for (m in held) out.push({ node: m, guarded: true });
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
		final key: Null<String> = importDedupKey(node, source);
		if (key == null || seenImports.contains(key)) return;
		seenImports.push(key);
		out.push({ node: node, guarded: true });
	}

	/** The index in `types` of the last declaration named `name`, or null. */
	private static function lastIndexNamed(types: Array<TypeDeclInfo>, name: String): Null<Int> {
		var i: Int = types.length;
		while (i-- > 0) if (types[i].name == name) return i;
		return null;
	}

	/**
	 * The record of the type `first` lists once another branch of a conditional region declares it as `alternate`: one type,
	 * of the first's name, kind, span and type parameters, holding what either branch says. Its members are both lists,
	 * a name both declare twice (`CallGraphTypes` joins them); its supertypes the union; what makes code run or a member
	 * set unknowable (an extern, a build macro, reflection, a rebinding abstract) either's; what narrows (an anonymous
	 * structure, a module-private name) both's; an alias or a forwarded underlying both spell alike, else none.
	 */
	private static function withAlternate(first: TypeDeclInfo, alternate: TypeDeclInfo): TypeDeclInfo {
		final supertypes: Array<String> = first.supertypes.copy();
		final raw: Array<String> = first.supertypesRaw.copy();
		for (i in 0...alternate.supertypesRaw.length) if (!raw.contains(alternate.supertypesRaw[i])) {
			raw.push(alternate.supertypesRaw[i]);
			supertypes.push(alternate.supertypes[i]);
		}
		final forwarded: Null<Array<String>> = first.forwardedMembers;
		final alsoForwarded: Null<Array<String>> = alternate.forwardedMembers;
		final sameAlias: Bool = first.aliasTargetRaw == alternate.aliasTargetRaw;
		return {
			name: first.name,
			kind: first.kind,
			span: first.span,
			isMain: first.isMain,
			isPrivate: first.isPrivate && alternate.isPrivate,
			isExtern: first.isExtern || alternate.isExtern,
			typeParamArity: first.typeParamArity,
			typeParamNames: first.typeParamNames,
			supertypes: supertypes,
			supertypesRaw: raw,
			supertypesWritten: union(first.supertypesWritten, alternate.supertypesWritten),
			interfaces: union(first.interfaces, alternate.interfaces),
			isAnonStruct: first.isAnonStruct && alternate.isAnonStruct,
			aliasTargetNominal: sameAlias ? first.aliasTargetNominal : null,
			aliasTargetRaw: sameAlias ? first.aliasTargetRaw : null,
			hasRtti: first.hasRtti || alternate.hasRtti,
			hasBuild: first.hasBuild || alternate.hasBuild,
			hasAutoBuild: first.hasAutoBuild || alternate.hasAutoBuild,
			hasKeep: first.hasKeep || alternate.hasKeep,
			constructsFromLiteral: first.constructsFromLiteral || alternate.constructsFromLiteral,
			bringsExtensions: first.bringsExtensions || alternate.bringsExtensions,
			members: first.members.concat(alternate.members),
			abstractSelfRebind: first.abstractSelfRebind || alternate.abstractSelfRebind,
			abstractForwardUnderlying: first.abstractForwardUnderlying == alternate.abstractForwardUnderlying
				? first.abstractForwardUnderlying
				: null,
			underlyingRaw: first.underlyingRaw == alternate.underlyingRaw ? first.underlyingRaw : null,
			guarded: true,
			forwardedMembers: forwarded == null || alsoForwarded == null ? null : union(forwarded, alsoForwarded)
		};
	}

	/** Every entry of `a`, then each of `b` it lacks. */
	private static function union(a: Array<String>, b: Array<String>): Array<String> {
		return a.concat([for (x in b) if (!a.contains(x)) x]);
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
	 * name — the dotted path for `import` / `using`, `pkg.*` for a wildcard, the alias
	 * for an alias import (so two distinct
	 * aliases of one path stay distinct) — which with the import kind uniquely
	 * identifies a repeat across `#if` branches or a top-level / guarded pair. The `as` and
	 * `in` alias forms share one key, so a cross-form alias duplicate collapses too.
	 *
	 * An alias key also carries the PATH the statement binds, decoded from `source` through
	 * `ModuleScan.aliasTargetOf`. Keyed on the alias name alone, `#if js import p.A as T;
	 * #else import p.B as T; #end` collapsed to its first branch and the other compilation's
	 * supertype was left with no subtype at all — the direction that DELETES, compile-proved:
	 * `unused-private --fix` removed `B`s private constructor and the non-js build stopped at
	 * `p.B does not have a constructor`. Both branches now reach `ImportInfo`, and a
	 * same-path repeat still collapses. A statement whose path does not decode keys on the
	 * empty string, which is the pre-existing collapse for that shape.
	 */
	private static function importDedupKey(node: QueryNode, source: String): Null<String> {
		final raw: Null<String> = node.name;
		if (raw == null) return null;
		final name: String = raw;
		return switch node.kind {
			case 'ImportDecl': 'import|$name';
			case 'ImportAliasDecl', 'ImportAliasInDecl':
				final span: Null<Span> = node.span;
				'alias|$name|${span == null ? '' : ModuleScan.aliasTargetOf(source.substring(span.from, span.to))}';
			case 'ImportWildDecl': 'wild|$name';
			case 'UsingDecl': 'using|$name';
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
	 * The WRITTEN head path a plain `typedef T = <Target>;` re-points at — type arguments stripped,
	 * package PRESERVED (`haxe.ds.List<T>` -> `haxe.ds.List`) — or null for every other
	 * declaration. `TypeDeclInfo.aliasTargetNominal` is `simpleName` of this and
	 * `aliasTargetRaw` is this verbatim; both are derived from ONE read so they can never
	 * disagree, the same pairing `supertypes` / `supertypesRaw` carries.
	 *
	 * The target is the declaration's `QueryNode.type` slot, read by the grammar
	 * (`GrammarPlugin.typeSyntax`) and accepted only as a named type (`Widget`, `pkg.Deep.Thing`,
	 * `Array<Int>`). Null must be read by every consumer as "the alias is not resolvable", never
	 * as "it aliases nothing". Five shapes yield it:
	 *
	 *  - an anon-struct typedef — its fields ARE its members and the index already models them;
	 *  - a FUNCTION type (`Holder<Int> -> String`), or a named type holding one — refused whole;
	 *  - an intersection (`typedef A = B & C;`), which aliases neither half;
	 *  - anything else that is not a named type;
	 *  - a `#if`-GUARDED declaration. Every branch projects under one `Conditional` and the
	 *    index keeps the FIRST decl of a name, so a followed alias would silently commit to
	 *    whichever branch happened to be indexed and be wrong for the other compilation.
	 */
	private static function aliasTargetPathOf(
		source: String, decl: TypeDeclMatch, node: QueryNode, guarded: Bool, typeSyntax: TypeSyntaxReader
	): Null<String> {
		final aliased: Null<Span> = node.type?.span;
		if (guarded || decl.kind != TYPEDEF_DECL_KIND || aliased == null) return null;
		// An intersection (`typedef A = B & C;`) follows the slot's type; it aliases neither half.
		final rest: String = source.substring(aliased.to, decl.fullSpan.to).trim();
		if (rest != '' && rest != ';') return null;
		final t: Null<TypeSyntax> = typeSyntax(source.substring(aliased.from, aliased.to));
		if (t == null || t.holdsFunction()) return null;
		return switch t.shape {
			case Nominal(path, _): path;
			case _: null;
		};
	}

	/**
	 * Fill every file's ambient imports from the chain the plugin finds for it.
	 *
	 * A SECOND pass because a chain member is usually an indexed file too, and then its already
	 * extracted imports are the ones to use — the pass that builds them has not finished while the
	 * first one runs. A member OUTSIDE the indexed set is parsed here instead, which is what lets a
	 * run narrowed to one file still see a chain member its scope does not cover.
	 *
	 * Every memo is a local of this call: a chain is a read of the tree at one moment, so nothing
	 * here may outlive the run.
	 */
	private static function attachAmbientImports(
		infos: Array<FileInfo>, plugin: GrammarPlugin, shape: RefShape, memberSeams: MemberSeams, abstractKinds: Array<String>,
		provider: Null<TypeInfoProvider>
	): Void {
		final chains: Map<String, AmbientImports> = [];
		final extracted: Map<String, Null<Array<ImportInfo>>> = [];
		for (fi in infos) {
			final key: String = '${Path.directory(fi.file)}#${fi.pkg}';
			var chain: Null<AmbientImports> = chains[key];
			if (chain == null) {
				chain = plugin.ambientImportSources(fi.file, fi.pkg);
				chains[key] = chain;
			}
			var bounded: Bool = chain.bounded;
			final groups: Array<AmbientImportGroup> = [];
			for (ambient in chain.sources) if (!sameFile(fi.file, ambient.file)) {
				final imports: Null<Array<ImportInfo>> = ambientImportsOf(
					ambient, infos, extracted, plugin, shape, memberSeams, abstractKinds, provider
				);
				// A source that does not PARSE is a chain member whose bindings are unknown, which is the
				// same state as one that could not be read: the reader must not be pinned against it, and
				// an empty group would claim it binds nothing.
				if (imports == null)
					bounded = false
				else {
					// Re-bound: strict null-safety does not carry a narrowed local into a structure literal.
					final read: Array<ImportInfo> = imports;
					groups.push({ file: ambient.file, imports: read });
				}
			}
			fi.ambientImportsBounded = bounded;
			fi.ambientImports = groups;
		}
	}

	/**
	 * One ambient source's import statements, read through the SAME extraction a file's own go
	 * through so there is no second import scanner to keep in step.
	 *
	 * An indexed file's already-extracted list wins over a re-read: a pass that rewrote it holds the
	 * current text, while the chain carries what was on disk when the plugin walked. A source that
	 * does not parse contributes nothing.
	 */
	private static function ambientImportsOf(
		ambient: AmbientImportSource, infos: Array<FileInfo>, extracted: Map<String, Null<Array<ImportInfo>>>, plugin: GrammarPlugin,
		shape: RefShape, memberSeams: MemberSeams, abstractKinds: Array<String>, provider: Null<TypeInfoProvider>
	): Null<Array<ImportInfo>> {
		// The memo comes FIRST: one ambient source serves every file below it, so the scan for its
		// indexed record runs once per source rather than once per reader.
		if (extracted.exists(ambient.file)) return extracted[ambient.file];
		final indexed: Null<FileInfo> = infos.find(f -> sameFile(f.file, ambient.file));
		final tree: Null<QueryNode> = indexed != null ? null : try plugin.parseFile(ambient.source) catch (_: Exception) null;
		final imports: Null<Array<ImportInfo>> = if (indexed != null)
			indexed.imports;
		else if (tree == null)
			null;
		else
			extractFileInfo(
				ambient.file, ambient.source, tree, provider != null ? provider.propertyAccessors(ambient.source) : [],
				provider != null ? provider.propertyWriteAccessors(ambient.source) : [],
				provider != null ? provider.returnTypes(ambient.source) : [],
				provider != null ? provider.declaredTypeSources(ambient.source) : [],
				provider != null ? provider.typeParamNames(ambient.source) : [], shape, memberSeams, abstractKinds, plugin.typeSyntax
			).imports;
		extracted[ambient.file] = imports;
		return imports;
	}

}
