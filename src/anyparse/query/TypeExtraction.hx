package anyparse.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.runtime.Span;
import haxe.ds.Either;

/** The class an extraction starts from: the parsed source and the class declaration in it. */
typedef SourceClass = {
	final tree: QueryNode;
	final decl: TypeDeclMatch;
}

/**
 * The core the type-extracting ops share — `extract-interface` and `extract-superclass`, which
 * generate a NEW type from a class and splice a header clause into it, and `pull-up` /
 * `push-down`, which move a member along the same `extends` axis. Each op keeps only what makes it
 * that op (which members it selects, what the new type holds, which clause it adds).
 */
@:nullSafety(Strict)
final class TypeExtraction {

	private static final CLASS_KINDS: Array<String> = ['ClassDecl'];

	/** The sole CLASS declaration named `typeName` in `tree` (final-aware), or null on none / several. */
	public static inline function uniqueClass(tree: QueryNode, typeName: String): Null<TypeDeclMatch> {
		return RefactorSupport.uniqueTypeDeclNamed(tree, typeName, CLASS_KINDS);
	}

	/**
	 * Parse `srcSource` and resolve the sole class named `srcTypeName` in it: the `Left` diagnostic
	 * is the one the op returns as its `Err`, the `Right` the tree and the declaration.
	 */
	public static function sourceClass(
		srcFile: String, srcSource: String, srcTypeName: String, plugin: GrammarPlugin
	): Either<String, SourceClass> {
		final tree: QueryNode = switch ParseGate.parse(plugin, srcSource, srcFile) {
			case Unparsed(message): return Left(message);
			case Parsed(parsed): parsed;
		};
		final decl: Null<TypeDeclMatch> = uniqueClass(tree, srcTypeName);
		if (decl == null) return Left('no unique class "$srcTypeName" in $srcFile');
		final declNN: TypeDeclMatch = decl;
		return Right({ tree: tree, decl: declNN });
	}

	/**
	 * The zero-width edit that inserts `text` (` implements I`, ` extends S`) into `decl`'s header,
	 * just past its last header token and before the body `{` — so the existing spacing and every
	 * clause already there are kept. Anchored on the AST (`RefactorSupport.typeHeaderInsertOffset`),
	 * never on a text scan for the brace. Null when the body brace cannot be verified, which must
	 * abort the extraction before anything is written.
	 */
	public static function headerInsertEdit(
		source: String, decl: TypeDeclMatch, typeName: String, text: String, regions: Array<LexRegion>
	): Null<{ span: Span, text: String }> {
		final at: Null<Int> = RefactorSupport.typeHeaderInsertOffset(source, decl, typeName, regions);
		return at == null ? null : { span: new Span(at, at), text: text };
	}

	/** The written name of a class's direct superclass (`extends X`), or null. */
	public static function superNameOf(decl: TypeDeclMatch): Null<String> {
		for (child in decl.nameNode.children)
			if (child.kind == 'ExtendsClause')
				for (gc in child.children)
					if (gc.kind == 'Named') return gc.name;
		return null;
	}

	/**
	 * The member names of `decl` — other than `excluded` — that a node under `roots` references:
	 * the members a moved subtree would STRAND if it left `decl` without them. Matches a bare call,
	 * a read and `this.member` by AST name, so a comment or a string never triggers it; a local or
	 * a parameter that shadows a member name over-reports, which only ever keeps a member in place.
	 *
	 * Branch-aware, and silently wrong when it is not: a member left behind inside a `#if` region
	 * was absent from the member set, so a body reading it passed the gate and the moved code did
	 * not compile.
	 */
	public static function referencedMembers(
		decl: TypeDeclMatch, excluded: Array<String>, roots: Array<QueryNode>, source: String, shape: RefShape,
		regions: () -> Array<LexRegion>
	): Array<String> {
		final memberNames: Map<String, Bool> = [];
		MemberBranchScan.eachTypeMember(
			decl, shape, source, n -> MemberKinds.isFieldMemberKind(n.kind) || MemberKinds.FN_DECL_KINDS.contains(n.kind), (child, _) -> {
				final nm: Null<String> = child.name;
				if (nm != null && !excluded.contains(nm)) memberNames[nm] = true;
			},
			regions
		);
		final found: Map<String, Bool> = [];
		function walk(node: QueryNode): Void {
			final nm: Null<String> = node.name;
			if (nm != null && memberNames.exists(nm) && (node.kind == 'IdentExpr' || node.kind == 'FieldAccess' || node.kind == 'Call'))
				found[nm] = true;
			for (c in node.children) walk(c);
		}
		for (root in roots) walk(root);
		return [for (k in found.keys()) k];
	}

	/**
	 * The plain imports of the source file whose exposed name appears in `text` on identifier
	 * boundaries — the type-position dependencies a generated type must carry so it type-checks.
	 * `using` / wildcard / aliased imports are not carried.
	 */
	public static function carriedImports(tree: QueryNode, text: String): Array<String> {
		final whole: Span = new Span(0, text.length);
		final out: Array<String> = [];
		function walk(node: QueryNode): Void {
			final raw: Null<String> = node.kind == 'ImportDecl' ? node.name : null;
			if (raw != null && !out.contains(raw) && SourceText.identTokenOffset(text, whole, SourceText.lastSegment(raw)) >= 0)
				out.push(raw);
			for (c in node.children) walk(c);
		}
		walk(tree);
		return out;
	}

	/**
	 * Assemble a generated module — `package pkg;`, one plain `import` per entry of `imports`,
	 * then `typeSource` — through `NewFile.createRaw`, so the result is parse-validated and
	 * canonical AT THE WRITER'S FIXED POINT under `optsJson`, the config governing where the file
	 * lands — the one `fmt --list` judges it by — rather than under compiled defaults, and past the
	 * single round trip that lands short of the fixed point (`WrapFlatSourceFixedPointTest`). `what`
	 * names the type in the refusal.
	 */
	public static function assembleTypeFile(
		pkg: String, imports: Array<String>, typeSource: String, what: String, plugin: GrammarPlugin, optsJson: Null<String>
	): EditResult {
		final sb: StringBuf = new StringBuf();
		if (pkg != '') {
			sb.add('package ');
			sb.add(pkg);
			sb.add(';\n\n');
		}
		for (raw in imports) {
			sb.add('import ');
			sb.add(raw);
			sb.add(';\n');
		}
		if (imports.length > 0) sb.add('\n');
		sb.add(typeSource);
		return switch NewFile.createRaw(sb.toString(), plugin, optsJson) {
			case Ok(text, rewrites): Ok(text, rewrites);
			case Err(message): Err('the assembled $what: $message');
		};
	}

	/**
	 * Apply `edits` to the source an extraction started from, canonical in / canonical out
	 * (`CanonicalEdit.editKeepingCanonical` under `srcOptsJson`), and re-parse the result. A pure
	 * header insertion still changes what the writer would decide — ` implements IFoo` can push the
	 * header past the line limit, and a cut can double a blank separator — so a source that went in
	 * at the writer's fixed point comes back at it; a drifted one keeps its own layout.
	 */
	public static function rewriteSource(
		srcFile: String, srcSource: String, edits: Array<{ span: Span, text: String }>, plugin: GrammarPlugin, srcOptsJson: Null<String>
	): EditResult {
		final rewritten: { text: String, rewrites: Null<Int> } = switch CanonicalEdit.editKeepingCanonical(
			srcSource, edits, plugin, srcOptsJson
		) {
			case Err(message): return Err('the rewritten $srcFile: $message');
			case Ok(text, rewrites): { text: text, rewrites: rewrites };
		};
		final refusal: Null<String> = ParseGate.refusal(plugin, rewritten.text, 'rewritten $srcFile');
		return refusal != null ? Err(refusal) : Ok(rewritten.text, rewritten.rewrites);
	}

	/**
	 * The advisory tail naming each file the writer needed more than one pass to settle — the
	 * count is the WRITER's, not the extraction's: a created file that needed two passes is the
	 * defect `apq fmt` reports, and this advisory is the only place the user hears of it.
	 */
	public static function rewritesNotes(newFile: String, newRewrites: Null<Int>, srcFile: String, srcRewrites: Null<Int>): String {
		final newNote: Null<String> = FormatFixedPoint.rewritesNote(newRewrites);
		final srcNote: Null<String> = FormatFixedPoint.rewritesNote(srcRewrites);
		return (newNote == null ? '' : '; $newFile: $newNote') + (srcNote == null ? '' : '; $srcFile: $srcNote');
	}

}
