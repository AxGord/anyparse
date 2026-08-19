package anyparse.query;

import anyparse.format.comment.CommentLossException;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.MoveSymbol.MoveResult;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;
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

		final shape: RefShape = plugin.refShape();
		final moved: Array<Moved> = switch resolveMembers(declNN, memberNames, srcSource, shape) {
			case Left(message): return Err(message);
			case Right(list): list;
		};
		final stranded: Array<String> = strandedRefs(declNN, moved, srcSource, shape);
		if (stranded.length > 0)
			return Err('pulled-up member(s) reference member(s) staying behind: ${stranded.join(', ')} — add them to the set or refactor');

		final blocks: Array<String> = [for (m in moved) trimNewlineEdges(srcSource.substring(m.cut.from, m.cut.to))];
		final pkg: String = ModuleScan.packageOf(tree);
		final imports: Array<String> = carriedImports(tree, blocks);
		final superSource: String = switch buildSuperclass(superName, pkg, blocks, imports, plugin) {
			case Left(message): return Err(message);
			case Right(source): source;
		};

		final headerEdit: Null<{ span: Span, text: String }> = extendsEdit(srcSource, declNN, srcTypeName, superName);
		if (headerEdit == null)
			return Err('could not verify the body brace of class "$srcTypeName" — refusing to add extends (nothing written)');
		final edits: Array<{ span: Span, text: String }> = [for (m in moved) { span: m.cut, text: '' }];
		edits.push(headerEdit);
		final newSrc: String = collapseBlankRuns(RefactorSupport.applyEdits(srcSource, edits));

		try
			plugin.parseFile(newSrc)
		catch (exception: ParseError)
			return Err('rewritten $srcFile does not parse: ${exception.toString()}')
		catch (exception: Exception)
			return Err('rewritten $srcFile does not parse: ${exception.message}');

		final advisory: String = 'pulled ${moved.length} member(s) up into new superclass "$superName'
			+ '" — subclass access preserved by inheritance; the superclass has no constructor (the source constructor is unchanged).';
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
	private static function resolveMembers(
		decl: TypeDeclMatch, names: Array<String>, source: String, shape: RefShape
	): Either<String, Array<Moved>> {
		final out: Array<Moved> = [];
		// Branch-aware: a member a `#if` region declares is not a direct child of the type, and the
		// scan that missed it answered "class has no instance member" on one that plainly exists.
		final found: Map<String, { node: QueryNode, run: Array<QueryNode>, span: Span }> = [];
		MemberBranchScan.eachTypeMember(
			decl, shape, source, n -> RefactorSupport.isFieldMemberKind(n.kind) || RefactorSupport.FN_DECL_KINDS.contains(n.kind),
			(child, run) -> {
				final nm: Null<String> = child.name;
				final span: Null<Span> = child.span;
				if (nm != null && span != null && !found.exists(nm)) found[nm] = { node: child, run: run, span: span };
			}
		);
		for (name in names) {
			if (name == 'new') return Left('cannot pull up a constructor');
			if (out.exists(m -> m.name == name)) return Left('member "$name" is listed twice');
			final hit: Null<{ node: QueryNode, run: Array<QueryNode>, span: Span }> = found[name];
			if (hit == null) return Left('class has no instance member "$name"');
			final hitNN: { node: QueryNode, run: Array<QueryNode>, span: Span } = hit;
			var isStatic: Bool = false;
			var isOverride: Bool = false;
			for (mod in hitNN.run) switch mod.kind {
				case 'Static':
					isStatic = true;
				case 'Override':
					isOverride = true;
				case _:
			}
			if (isStatic) return Left('"$name" is static — inheritance moves cover instance members only');
			if (isOverride) return Left('"$name" is an override — cannot pull it up');
			// Seeing a guarded member is not licence to MOVE it: cutting it out of its branch and
			// pasting it into the superclass unguarded gives it to builds that never had it.
			if (MemberBranchScan.isGuardedMember(decl, shape, source, hitNN.node))
				return Left(
					'"$name" is declared inside a conditional-compilation region — pulling it out of its branch would change which '
					+ 'builds declare it'
				);
			final groupSpan: Span = RefactorSupport.declGroupSpan(hitNN.node, decl.nameNode, hitNN.span);
			out.push({ name: name, node: hitNN.node, cut: cutSpanOf(source, groupSpan) });
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
	private static function strandedRefs(decl: TypeDeclMatch, moved: Array<Moved>, source: String, shape: RefShape): Array<String> {
		final movingNames: Map<String, Bool> = [for (m in moved) m.name => true];
		final memberNames: Map<String, Bool> = [];
		// Branch-aware, and this one fails SILENTLY when it is not: a member left behind inside a `#if`
		// region was absent from this set, so a pulled-up method reading it passed the stranded-reference
		// gate and the generated superclass did not compile.
		MemberBranchScan.eachTypeMember(
			decl, shape, source, n -> RefactorSupport.isFieldMemberKind(n.kind) || RefactorSupport.FN_DECL_KINDS.contains(n.kind),
			(child, _) -> {
				final nm: Null<String> = child.name;
				if (nm != null && !movingNames.exists(nm) && nm != 'new') memberNames[nm] = true;
			}
		);
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
		} catch (exception: CommentLossException) {
			return Left('the assembled superclass cannot be written without losing the comment `${exception.comment}`');
		} catch (exception: Exception) {
			return Left('assembled superclass does not parse: ${exception.message}');
		};
		return canonical == null ? Left('no writer for this grammar') : Right(canonical);
	}

	/**
	 * The header edit that inserts `extends <Super>` — before an existing
	 * `implements` clause, else just past the last header token. Null when
	 * the body brace cannot be verified, which aborts the whole extraction
	 * before any member is cut.
	 */
	private static function extendsEdit(
		source: String, decl: TypeDeclMatch, typeName: String, superName: String
	): Null<{ span: Span, text: String }> {
		for (child in decl.nameNode.children) if (child.kind == 'ImplementsClause') {
			final s: Null<Span> = child.span;
			if (s != null) return { span: new Span(s.from, s.from), text: 'extends $superName ' };
		}
		final at: Null<Int> = RefactorSupport.typeHeaderInsertOffset(source, decl, typeName);
		if (at == null) return null;
		final atNN: Int = at;
		return { span: new Span(atNN, atNN), text: ' extends $superName' };
	}

	/** The cut span of a member group: decl + leading doc + whole line(s). */
	private static function cutSpanOf(source: String, groupSpan: Span): Span {
		return RefactorSupport.blankExtendedSpan(
			source, RefactorSupport.lineExtendedSpan(source, RefactorSupport.docExtendedSpan(source, groupSpan))
		);
	}

	/** Strip leading / trailing newlines from a cut block. */
	private static function trimNewlineEdges(block: String): String {
		var from: Int = 0;
		while (from < block.length) {
			final c: Int = block.fastCodeAt(from);
			if (c == '\n'.code || c == '\r'.code)
				from++
			else
				break;
		}
		var to: Int = block.length;
		while (to > from) {
			final c: Int = block.fastCodeAt(to - 1);
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
			final c: Int = source.fastCodeAt(i);
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
