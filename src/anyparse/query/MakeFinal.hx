package anyparse.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;
using Lambda;

/** One scope file parsed once. */
private typedef Parsed = {
	final file: String;
	final source: String;
	final tree: QueryNode;
};

/**
 * `make-final` — turn a mutable `var` field into `final` when it is never
 * reassigned after its single initialisation. Directly unblocks the
 * `move-member` instance path, whose sibling-fields contract accepts only
 * FINAL fields: `make-final` first, then the instance member moves.
 *
 * A field qualifies when every write to it (bare `field = …`, `this.field
 * = …`, `field++`, cross-file `obj.field = …`, and the compound-assign
 * forms) lands INSIDE the declaring type's constructor — that write is the
 * final's one initialisation — and it has a declaration initialiser xor a
 * constructor write (so the result is neither uninitialised nor
 * double-initialised). Any write outside the constructor refuses the
 * change, listed by file. Conservative: a `.field` write on an unrelated
 * type of the same field name also refuses (a false refusal, never a
 * wrong rewrite).
 *
 * The rewrite is a single `var` → `final` keyword splice, re-parsed before
 * it is returned; formatting is otherwise untouched.
 */
@:nullSafety(Strict)
final class MakeFinal {

	/** Assignment / increment operator kinds whose first child is the write target. */
	private static final INCR_KINDS: Array<String> = ['PreIncr', 'PostIncr', 'PreDecr', 'PostDecr'];

	/** The mutable field keyword this op replaces with `final`. */
	private static final VAR: String = 'var';

	/**
	 * Make the `var` field `fieldName` of `typeName` (declared in `srcFile`)
	 * `final` when no reassignment survives under `scopeFiles`. Returns
	 * `Ok(newSource)` for `srcFile` or an `Err`. PURE.
	 */
	public static function makeFinal(
		srcFile: String, typeName: String, fieldName: String, scopeFiles: Array<{ file: String, source: String }>, plugin: GrammarPlugin
	): EditResult {
		final parsed: Array<Parsed> = [];
		for (entry in scopeFiles) {
			final tree: Null<QueryNode> = try plugin.parseFile(entry.source) catch (exception: Exception) null;
			if (tree == null) return Err('cannot check writes: ${entry.file} does not parse');
			final treeNN: QueryNode = tree;
			parsed.push({ file: entry.file, source: entry.source, tree: treeNN });
		}

		final srcEntry: Null<Parsed> = parsed.find(p -> p.file == srcFile);
		if (srcEntry == null) return Err('source file $srcFile is not in the scope file set');
		final src: Parsed = srcEntry;

		final shape: RefShape = plugin.refShape();
		final fieldNode: Null<QueryNode> = resolveVarField(
			src.tree, typeName, fieldName, src.source, shape, plugin.lexicalRegions.bind(src.source)
		);
		if (fieldNode == null) return Err('no mutable var field "$fieldName" on a unique type "$typeName" in $srcFile');
		final fNode: QueryNode = fieldNode;
		final fieldSpan: Null<Span> = fNode.span;
		if (fieldSpan == null) return Err('field "$fieldName" carries no span');
		final fieldSpanNN: Span = fieldSpan;

		// The whole op rests on `classifyWrites` seeing every assignment. An unparsed
		// conditional-compilation region projects no nodes, so a write inside one reads as
		// absent and the field is made `final` over an assignment the compiler still performs.
		final opaque: Null<String> = CondRegionScan.opaqueCondRegionInAny(parsed, fieldName, shape, 'making "$fieldName" final');
		if (opaque != null) return Err(opaque);

		final ctorSpan: Null<Span> = constructorSpan(src.tree, typeName, src.source, shape, plugin.lexicalRegions.bind(src.source));
		final hasInit: Bool = fNode.children.length > 0;
		final writes: { ctorWrites: Int, outside: Array<String> } = classifyWrites(parsed, srcFile, fieldName, ctorSpan);
		if (writes.outside.length > 0)
			return Err('"$fieldName" is reassigned outside the constructor — cannot make it final: ${writes.outside.join(', ')}');
		if (!hasInit && writes.ctorWrites == 0) return Err('"$fieldName" is never assigned — cannot make it final');
		if (hasInit && writes.ctorWrites > 0)
			return Err('"$fieldName" is assigned both at its declaration and in the constructor — cannot make it final');

		if (keywordAt(src.source, fieldSpanNN.from) != VAR)
			return Err('field "$fieldName" does not start with the `var` keyword — cannot make it final');

		// Core-API gate, before the index because it is a pure text scan: a `@:coreApi` type
		// replaces a standard-library core type whose declaration lives in the compiler's own std
		// path, which no `--scope` can contain, and `var` -> `final` there is "Field <name> has
		// different property access than core type". The same shared predicate the four field
		// rules take.
		if (MemberWriteScan.coreApiPinsMemberShape(src.source))
			return Err('"$fieldName" belongs to a @:coreApi type, whose member shape a core type pins — cannot make it final');
		// Structural-conformance gate — the same `SymbolIndex` predicate the `prefer-final-*`
		// checks consult, placed after every cheaper one because it is the only gate here that
		// builds an index. A field the compiler unifies against an anonymous structure declaring
		// it mutably cannot become `final` ("Cannot unify final and non-final fields"), and no
		// write scan can see that: the unification is a READ position. The answer is only as
		// strong as `scopeFiles` — without a `--scope` the index holds this file alone, so a
		// structure declared elsewhere is invisible and only what THIS file states is decided.
		final index: SymbolIndex = SymbolIndex.build(scopeFiles, plugin);
		if (index.structural.structuralConformanceForbidsFinal(typeName, fieldName))
			return Err('"$fieldName" is a member a structural type may require to stay mutable — cannot make it final');
		final rewritten: String = '${src.source.substring(0, fieldSpanNN.from)}final${src.source.substring(fieldSpanNN.from + VAR.length)}';

		try
			plugin.parseFile(rewritten)
		catch (exception: Exception)
			return Err('rewritten $srcFile does not parse: ${exception.message}');
		return Ok(rewritten);
	}

	/**
	 * Partition every write to `fieldName` across the scope into a count of
	 * constructor-local writes and the list of files with a write elsewhere.
	 */
	private static function classifyWrites(
		parsed: Array<Parsed>, srcFile: String, fieldName: String, ctorSpan: Null<Span>
	): { ctorWrites: Int, outside: Array<String> } {
		var ctorWrites: Int = 0;
		final outside: Array<String> = [];
		for (entry in parsed) for (w in writeOffsets(entry.tree, fieldName, entry.file == srcFile)) {
			final inCtor: Bool = entry.file == srcFile && ctorSpan != null && w >= ctorSpan.from && w < ctorSpan.to;
			if (inCtor)
				ctorWrites++
			else if (!outside.contains(entry.file))
				outside.push(entry.file);
		}
		return { ctorWrites: ctorWrites, outside: outside };
	}

	/**
	 * Resolve the plain `var` field `fieldName` of the sole type `typeName`
	 * (final-aware). Null when the type or a mutable field of that name is
	 * absent / ambiguous (a `final` field is already done and not matched).
	 */
	private static function resolveVarField(
		tree: QueryNode, typeName: String, fieldName: String, source: String, shape: RefShape, regions: () -> Array<LexRegion>
	): Null<QueryNode> {
		final decl: Null<TypeDeclMatch> = findSoleTypeDecl(tree, typeName);
		if (decl == null) return null;
		var hit: Null<QueryNode> = null;
		// Branch-aware: a field a `#if` region declares is not a direct child of the type. The swap is
		// in place, inside that region, so seeing it is the whole fix.
		MemberBranchScan.eachTypeMember(decl, shape, source, n -> n.kind == 'VarMember' || n.kind == 'VarField', (child, _) -> {
			if (hit == null && child.name == fieldName) hit = child;
		}, regions);
		return hit;
	}

	/** The span of the `new` constructor of the sole type `typeName`, or null. */
	private static function constructorSpan(
		tree: QueryNode, typeName: String, source: String, shape: RefShape, regions: () -> Array<LexRegion>
	): Null<Span> {
		final decl: Null<TypeDeclMatch> = findSoleTypeDecl(tree, typeName);
		if (decl == null) return null;
		var hit: Null<Span> = null;
		MemberBranchScan.eachTypeMember(decl, shape, source, n -> n.kind == 'FnMember', (child, _) -> {
			if (hit == null && child.name == 'new') hit = child.span;
		}, regions);
		return hit;
	}

	/**
	 * The offsets of every write to `fieldName` in `tree`: an assignment /
	 * increment whose first child is a `FieldAccess` named `fieldName`
	 * (`this.field` / `obj.field`), plus — in the declaring file only — a
	 * bare `IdentExpr` target (`field = …`). A bare write in another file is
	 * a different binding and is ignored.
	 */
	private static function writeOffsets(tree: QueryNode, fieldName: String, inSrc: Bool): Array<Int> {
		final out: Array<Int> = [];
		function walk(node: QueryNode): Void {
			final children: Array<QueryNode> = node.children;
			if ((node.kind.endsWith('Assign') || INCR_KINDS.contains(node.kind)) && children.length > 0) {
				final target: QueryNode = children[0];
				final span: Null<Span> = target.span;
				final isWrite: Bool = target.name == fieldName && (target.kind == 'FieldAccess' || (inSrc && target.kind == 'IdentExpr'));
				if (isWrite && span != null) out.push(span.from);
			}
			for (c in children) walk(c);
		}
		walk(tree);
		return out;
	}

	/** The `var`-keyword-length source slice at `from` (for the keyword check). */
	private static function keywordAt(source: String, from: Int): String {
		return from >= 0 && from + VAR.length <= source.length ? source.substr(from, VAR.length) : '';
	}


	/** The sole type declaration named `typeName` (final-aware), or null when absent / ambiguous. */
	private static function findSoleTypeDecl(tree: QueryNode, typeName: String): Null<TypeDeclMatch> {
		final decls: Array<TypeDeclMatch> = [];
		function walk(node: QueryNode): Void {
			final m: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (m != null && m.name == typeName) decls.push(m);
			for (c in node.children) walk(c);
		}
		walk(tree);
		return decls.length == 1 ? decls[0] : null;
	}

}
