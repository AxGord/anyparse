package anyparse.query;

import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.MoveSymbol.MoveResult;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/** One member selected to pull up: its name, node, and cut span. */
private typedef Moved = {
	var name: String;
	var node: QueryNode;
	var cut: Span;
}

/** A computed value or an error message. */
private enum Either<L, R> {

	Left(value: L);
	Right(value: R);

}

/**
 * `extract-superclass` — generate a superclass, pull a chosen set of
 * instance members up into it, and make the source class `extends` it.
 * The class flavour of `extract-interface`: it moves member BODIES (not
 * just signatures) and adds `extends` rather than `implements`. No call
 * sites change — the source's instances inherit the pulled members.
 *
 * ## What it produces
 *
 *  - A NEW superclass file (no constructor, so the source's own
 *    constructor keeps working without a `super(...)` call), containing
 *    the moved members verbatim plus the imports their bodies reference.
 *  - The source class with those members removed and an `extends
 *    <Super>` clause added (before any `implements`).
 *
 * ## Boundary
 *
 *  - The source must not already extend a class (single inheritance).
 *  - Only INSTANCE members move; statics, the constructor, and `override`
 *    members are refused.
 *  - A moved member whose body references a source member NOT in the
 *    moved set is refused — it would be stranded on the superclass (add
 *    it to the set or refactor first). Members in the set may reference
 *    each other freely.
 *
 * Atomic: the superclass is assembled through `writeRoundTrip` (canonical
 * + validated) and the source re-parses before either is returned.
 */
@:nullSafety(Strict)
final class ExtractSuperclass {

	/** The sibling node kinds a member's modifiers / metadata project to. */
	private static final MODIFIER_META: Array<String> = [
		'Meta',
		'Public',
		'Private',
		'Static',
		'Inline',
		'Override',
		'Macro',
		'Extern',
		'Dynamic'
	];

	/**
	 * Extract a superclass `superName` (written to `superFile`) from
	 * `srcTypeName` in `srcSource`, pulling up `memberNames`. PURE — the
	 * CLI writes the returned changes. `Ok` carries two changes (the new
	 * superclass, the modified source); `Err` a diagnostic.
	 */
	public static function extract(
		srcFile: String, srcTypeName: String, superName: String, superFile: String, memberNames: Array<String>, srcSource: String,
		plugin: GrammarPlugin
	): MoveResult {
		if (!RefactorSupport.isIdentifier(superName)) return Err('superclass name "$superName" is not a valid identifier');
		if (superName == srcTypeName) return Err('superclass name must differ from the source type "$srcTypeName"');
		if (memberNames.length == 0) return Err('no members named — nothing to pull up');

		final tree: QueryNode = try plugin.parseFile(srcSource) catch (exception: ParseError) return Err(
			'$srcFile does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('$srcFile does not parse: ${exception.message}');

		final decl: Null<TypeDeclMatch> = uniqueClass(tree, srcTypeName);
		if (decl == null) return Err('no unique class "$srcTypeName" in $srcFile');
		final declNN: TypeDeclMatch = decl;
		if (superNameOf(declNN) != null) return Err('class "$srcTypeName" already extends a class — single inheritance, refusing');

		final moved: Array<Moved> = switch resolveMembers(declNN, memberNames, srcSource) {
			case Left(message): return Err(message);
			case Right(list): list;
		};
		final stranded: Array<String> = strandedRefs(declNN, moved);
		if (stranded.length > 0)
			return Err('pulled-up member(s) reference member(s) staying behind: ${stranded.join(', ')} — add them to the set or refactor');

		final blocks: Array<String> = [for (m in moved) trimNewlineEdges(srcSource.substring(m.cut.from, m.cut.to))];
		final pkg: String = packageOf(tree);
		final imports: Array<String> = carriedImports(tree, blocks);
		final superSource: String = switch buildSuperclass(superName, pkg, blocks, imports, plugin) {
			case Left(message): return Err(message);
			case Right(source): source;
		};

		final headerEdit: Null<{ span: Span, text: String }> = extendsEdit(srcSource, declNN, srcTypeName, superName);
		if (headerEdit == null) return Err('could not locate the class body of "$srcTypeName" to add extends');
		final edits: Array<{ span: Span, text: String }> = [for (m in moved) { span: m.cut, text: '' }];
		edits.push(headerEdit);
		final newSrc: String = collapseBlankRuns(RefactorSupport.applyEdits(srcSource, edits));

		try
			plugin.parseFile(newSrc)
		catch (exception: ParseError)
			return Err('rewritten $srcFile does not parse: ${exception.toString()}')
		catch (exception: Exception)
			return Err('rewritten $srcFile does not parse: ${exception.message}');

		final advisory: String = 'pulled ${moved.length} member(s) up into new superclass "$superName" — subclass access preserved by inheritance; '
			+ 'the superclass has no constructor (the source constructor is unchanged).';
		final changes: Array<MoveChange> = [
			{ file: superFile, newSource: superSource },
			{ file: srcFile, newSource: newSrc },
		];
		return Ok(changes, advisory);
	}

	/** The sole class declaration named `typeName`, or null. Final-aware. */
	private static function uniqueClass(tree: QueryNode, typeName: String): Null<TypeDeclMatch> {
		final matches: Array<TypeDeclMatch> = [];
		function walk(node: QueryNode): Void {
			final t: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (t != null && t.name == typeName && t.kind == 'ClassDecl') matches.push(t);
			for (c in node.children) walk(c);
		}
		walk(tree);
		return matches.length == 1 ? matches[0] : null;
	}

	/** The simple name of a class's direct superclass (`extends X`), or null. */
	private static function superNameOf(decl: TypeDeclMatch): Null<String> {
		for (child in decl.nameNode.children) if (child.kind == 'ExtendsClause') for (gc in child.children) if (gc.kind == 'Named')
			return gc.name;
		return null;
	}

	/**
	 * Resolve each requested member: an instance field / method (not
	 * static / `new` / override), with its cut span. Refuses an unknown /
	 * duplicate / ineligible member.
	 */
	private static function resolveMembers(decl: TypeDeclMatch, names: Array<String>, source: String): Either<String, Array<Moved>> {
		final out: Array<Moved> = [];
		final siblings: Array<QueryNode> = decl.nameNode.children;
		for (name in names) {
			if (name == 'new') return Left('cannot pull up a constructor');
			if (out.exists(m -> m.name == name)) return Left('member "$name" is listed twice');
			var hit: Null<Moved> = null;
			for (i => child in siblings) {
				final kind: String = child.kind;
				if (child.name != name) continue;
				if (!RefactorSupport.isFieldMemberKind(kind) && !RefactorSupport.FN_DECL_KINDS.contains(kind)) continue;
				final span: Null<Span> = child.span;
				if (span == null) continue;
				final spanNN: Span = span;
				var isStatic: Bool = false;
				var isOverride: Bool = false;
				var j: Int = i - 1;
				while (j >= 0 && MODIFIER_META.contains(siblings[j].kind)) {
					switch siblings[j].kind {
						case 'Static':
							isStatic = true;
						case 'Override':
							isOverride = true;
						case _:
					}
					j--;
				}
				if (isStatic) return Left('"$name" is static — inheritance moves cover instance members only');
				if (isOverride) return Left('"$name" is an override — cannot pull it up');
				final groupSpan: Span = RefactorSupport.declGroupSpan(child, decl.nameNode, spanNN);
				hit = { name: name, node: child, cut: cutSpanOf(source, groupSpan) };
				break;
			}
			if (hit == null) return Left('class has no instance member "$name"');
			out.push(hit);
		}
		out.sort((a, b) -> a.cut.from - b.cut.from);
		return Right(out);
	}

	/**
	 * The source member names that a moved body references but that are
	 * NOT in the moved set — they would be stranded on the superclass.
	 * AST-name match (bare call / read / `this.member`), so comments and
	 * strings never trigger it.
	 */
	private static function strandedRefs(decl: TypeDeclMatch, moved: Array<Moved>): Array<String> {
		final movingNames: Map<String, Bool> = [for (m in moved) m.name => true];
		final memberNames: Map<String, Bool> = [];
		for (child in decl.nameNode.children) {
			final kind: String = child.kind;
			final nm: Null<String> = child.name;
			if (
				nm != null && !movingNames.exists(nm) && nm != 'new'
				&& (RefactorSupport.isFieldMemberKind(kind) || RefactorSupport.FN_DECL_KINDS.contains(kind))
			)
				memberNames[nm] = true;
		}
		final found: Map<String, Bool> = [];
		function walk(node: QueryNode): Void {
			final nm: Null<String> = node.name;
			if (nm != null && memberNames.exists(nm) && (node.kind == 'IdentExpr' || node.kind == 'FieldAccess' || node.kind == 'Call'))
				found[nm] = true;
			for (c in node.children) walk(c);
		}
		for (m in moved) walk(m.node);
		return [for (k in found.keys()) k];
	}

	/** The file's `package` path, or "" when none. */
	private static function packageOf(tree: QueryNode): String {
		for (child in tree.children) if (child.kind == 'PackageDecl') return child.name ?? '';
		return '';
	}

	/** The source imports whose exposed name appears in any moved block. */
	private static function carriedImports(tree: QueryNode, blocks: Array<String>): Array<String> {
		final blob: String = blocks.join('\n');
		final out: Array<String> = [];
		function walk(node: QueryNode): Void {
			if (node.kind == 'ImportDecl') {
				final raw: Null<String> = node.name;
				if (raw != null) {
					final dot: Int = raw.lastIndexOf('.');
					final exposed: String = dot < 0 ? raw : raw.substr(dot + 1);
					if (RefactorSupport.identTokenOffset(blob, new Span(0, blob.length), exposed) >= 0 && !out.contains(raw)) out.push(raw);
				}
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return out;
	}

	/** Assemble the superclass through `writeRoundTrip` (canonical + validated). */
	private static function buildSuperclass(
		superName: String, pkg: String, blocks: Array<String>, imports: Array<String>, plugin: GrammarPlugin
	): Either<String, String> {
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
		sb.add('class ');
		sb.add(superName);
		sb.add(' {\n\n');
		sb.add(blocks.join('\n\n'));
		sb.add('\n\n}\n');
		final canonical: Null<String> = try plugin.writeRoundTrip(sb.toString(), null) catch (exception: ParseError) {
			return Left('assembled superclass does not parse: ${exception.toString()}');
		} catch (exception: Exception) {
			return Left('assembled superclass does not parse: ${exception.message}');
		};
		return canonical == null ? Left('no writer for this grammar') : Right(canonical);
	}

	/**
	 * The header edit that inserts `extends <Super>` — before an existing
	 * `implements` clause, else before the body `{`. Null when the brace
	 * cannot be found.
	 */
	private static function extendsEdit(
		source: String, decl: TypeDeclMatch, typeName: String, superName: String
	): Null<{ span: Span, text: String }> {
		for (child in decl.nameNode.children) if (child.kind == 'ImplementsClause') {
			final s: Null<Span> = child.span;
			if (s != null) return { span: new Span(s.from, s.from), text: 'extends $superName ' };
		}
		final nameSpan: Span = decl.nameNode.span ?? decl.fullSpan;
		final nameFrom: Int = RefactorSupport.identTokenOffset(source, nameSpan, typeName);
		final searchFrom: Int = nameFrom < 0 ? nameSpan.from : nameFrom + typeName.length;
		final brace: Int = source.indexOf('{', searchFrom);
		if (brace < 0) return null;
		var headerEnd: Int = brace;
		while (headerEnd > searchFrom && isSpace(StringTools.fastCodeAt(source, headerEnd - 1))) headerEnd--;
		return { span: new Span(headerEnd, headerEnd), text: ' extends $superName' };
	}

	private static inline function isSpace(code: Int): Bool {
		return code == ' '.code || code == '\t'.code || code == '\n'.code || code == '\r'.code;
	}

	/** The cut span of a member group: decl + leading doc + whole line(s). */
	private static function cutSpanOf(source: String, groupSpan: Span): Span {
		final lineCut: Span = RefactorSupport.lineExtendedSpan(source, RefactorSupport.docExtendedSpan(source, groupSpan));
		final blankBefore: Bool = lineCut.from >= 2 && StringTools.fastCodeAt(source, lineCut.from - 2) == '\n'.code;
		final blankAfter: Bool = lineCut.to < source.length && StringTools.fastCodeAt(source, lineCut.to) == '\n'.code;
		return blankBefore && blankAfter ? new Span(lineCut.from, lineCut.to + 1) : lineCut;
	}

	/** Strip leading / trailing newlines from a cut block. */
	private static function trimNewlineEdges(block: String): String {
		var from: Int = 0;
		while (from < block.length) {
			final c: Int = StringTools.fastCodeAt(block, from);
			if (c == '\n'.code || c == '\r'.code)
				from++
			else
				break;
		}
		var to: Int = block.length;
		while (to > from) {
			final c: Int = StringTools.fastCodeAt(block, to - 1);
			if (c == '\n'.code || c == '\r'.code)
				to--
			else
				break;
		}
		return block.substring(from, to);
	}


	/**
	 * Collapse any run of 3+ consecutive newlines to a single blank line —
	 * cutting adjacent members can leave a doubled blank where they were, and
	 * canonical Haxe never has more than one blank line in a row.
	 */
	private static function collapseBlankRuns(source: String): String {
		final buf: StringBuf = new StringBuf();
		var newlines: Int = 0;
		for (i in 0...source.length) {
			final c: Int = StringTools.fastCodeAt(source, i);
			if (c == '\n'.code) {
				newlines++;
				if (newlines <= 2) buf.addChar(c);
			} else {
				newlines = 0;
				buf.addChar(c);
			}
		}
		return buf.toString();
	}

}
