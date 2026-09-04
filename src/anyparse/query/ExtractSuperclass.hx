package anyparse.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
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
 * Atomic: the superclass is assembled through `NewFile.createRaw` (canonical at
 * the WRITER FIXED POINT, under the format config governing where the file
 * lands) and the source re-parses before either is returned. The EDITED source comes back at the same fixed point when it went in at one — a
 * cut can double a blank separator, and the writer is what gives one back. It cannot
 * damage a literal or a comment doing so, and not because it knows what one is: a
 * canonical source cannot hold an over-long blank run ANYWHERE, literals included,
 * so there is never one for it to shorten. The hand-rolled whole-file scan that
 * stood here could, and did.
 *
 * A source that was NOT canonical takes the plain splice and keeps its own layout —
 * including, where two blank lines already flanked the cut member, a run the scan
 * used to trim. That trim is gone with the scan; `blankExtendedSpan` still gives
 * back the single separator, which is the case that occurs on a canonical tree.
 */
@:nullSafety(Strict)
final class ExtractSuperclass {

	/**
	 * Extract a superclass `superName` (written to `superFile`) from
	 * `srcTypeName` in `srcSource`, pulling up `memberNames`. PURE — the
	 * CLI writes the returned changes. `Ok` carries two changes (the new
	 * superclass, the modified source); `Err` a diagnostic.
	 *
	 * `optsJson` is the `hxformat.json` governing where `superFile` LANDS,
	 * `srcOptsJson` the one governing `srcFile` — see `ExtractInterface.extract`
	 * for why omitting either is not a neutral default.
	 */
	public static function extract(
		srcFile: String, srcTypeName: String, superName: String, superFile: String, memberNames: Array<String>, srcSource: String,
		plugin: GrammarPlugin, ?optsJson: String, ?srcOptsJson: String
	): MoveResult {
		if (!SourceText.isIdentifier(superName)) return Err('superclass name "$superName" is not a valid identifier');
		if (superName == srcTypeName) return Err('superclass name must differ from the source type "$srcTypeName"');
		if (memberNames.length == 0) return Err('no members named — nothing to pull up');

		final tree: QueryNode = try plugin.parseFile(srcSource) catch (exception: ParseError) return Err(
			'$srcFile does not parse: $exception'
		)
		catch (exception: Exception) return Err('$srcFile does not parse: ${exception.message}');

		final decl: Null<TypeDeclMatch> = uniqueClass(tree, srcTypeName);
		if (decl == null) return Err('no unique class "$srcTypeName" in $srcFile');
		final declNN: TypeDeclMatch = decl;
		if (superNameOf(declNN) != null) return Err('class "$srcTypeName" already extends a class — single inheritance, refusing');

		final shape: RefShape = plugin.refShape();
		final moved: Array<Moved> = switch resolveMembers(declNN, memberNames, srcSource, shape, plugin.lexicalRegions.bind(srcSource)) {
			case Left(message): return Err(message);
			case Right(list): list;
		};
		final stranded: Array<String> = strandedRefs(declNN, moved, srcSource, shape, plugin.lexicalRegions.bind(srcSource));
		if (stranded.length > 0)
			return Err('pulled-up member(s) reference member(s) staying behind: ${stranded.join(', ')} — add them to the set or refactor');

		final blocks: Array<String> = [for (m in moved) trimNewlineEdges(srcSource.substring(m.cut.from, m.cut.to))];
		final pkg: String = ModuleScan.packageOf(tree);
		final imports: Array<String> = carriedImports(tree, blocks);
		// The count is the WRITER's, not the extraction's, and it reaches the user only
		// through the advisory: a created file the writer needed two passes to settle is
		// the defect `apq fmt` reports and every op used to absorb in silence.
		var superRewrites: Null<Int> = null;
		final superSource: String = switch buildSuperclass(superName, pkg, blocks, imports, plugin, optsJson) {
			case Err(message): return Err(message);
			case Ok(source, rewrites):
				superRewrites = rewrites;
				source;
		};

		final headerEdit: Null<{ span: Span, text: String }> = extendsEdit(
			srcSource, declNN, srcTypeName, superName, plugin.lexicalRegions(srcSource)
		);
		if (headerEdit == null)
			return Err('could not verify the body brace of class "$srcTypeName" — refusing to add extends (nothing written)');
		final edits: Array<{ span: Span, text: String }> = [for (m in moved) { span: m.cut, text: '' }];
		edits.push(headerEdit);
		// The WRITER gives back the separator a cut left doubled, and it is the only thing
		// that can: the hand-rolled newline-run collapse that stood here read the whole file
		// as text, so it also rewrote a run inside a STRING LITERAL or a block comment —
		// measured, `extract-superclass` on an untouched sibling member shortened a
		// multi-line literal by one newline, and every gate stayed green because the result
		// still parsed and was still canonical.
		var srcRewrites: Null<Int> = null;
		final newSrc: String = switch CanonicalEdit.editKeepingCanonical(srcSource, edits, plugin, srcOptsJson) {
			case Err(message): return Err('the rewritten $srcFile: $message');
			case Ok(text, rewrites):
				srcRewrites = rewrites;
				text;
		};

		try
			plugin.parseFile(newSrc)
		catch (exception: ParseError)
			return Err('rewritten $srcFile does not parse: $exception')
		catch (exception: Exception)
			return Err('rewritten $srcFile does not parse: ${exception.message}');

		final rewritesNote: Null<String> = FormatFixedPoint.rewritesNote(superRewrites);
		final srcRewritesNote: Null<String> = FormatFixedPoint.rewritesNote(srcRewrites);
		final advisory: String = 'pulled ${moved.length} member(s) up into new superclass "$superName'
			+ '" — subclass access preserved by inheritance; the superclass has no constructor (the source constructor is unchanged)'
			+ (rewritesNote == null ? '' : '; $superFile: $rewritesNote') + (srcRewritesNote == null ? '' : '; $srcFile: $srcRewritesNote');
		final changes: Array<MoveChange> = [
			{ file: superFile, newSource: superSource },
			{ file: srcFile, newSource: newSrc }
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
		for (child in decl.nameNode.children)
			if (child.kind == 'ExtendsClause')
				for (gc in child.children)
					if (gc.kind == 'Named') return gc.name;
		return null;
	}

	/**
	 * Resolve each requested member: an instance field / method (not
	 * static / `new` / override), with its cut span. Refuses an unknown /
	 * duplicate / ineligible member.
	 */
	private static function resolveMembers(
		decl: TypeDeclMatch, names: Array<String>, source: String, shape: RefShape, regions: () -> Array<LexRegion>
	): Either<String, Array<Moved>> {
		final out: Array<Moved> = [];
		// Branch-aware: a member a `#if` region declares is not a direct child of the type, and the
		// scan that missed it answered "class has no instance member" on one that plainly exists.
		final found: Map<String, { node: QueryNode, run: Array<QueryNode>, span: Span }> = [];
		MemberBranchScan.eachTypeMember(
			decl, shape, source, n -> MemberKinds.isFieldMemberKind(n.kind) || MemberKinds.FN_DECL_KINDS.contains(n.kind),
			(child, run) -> {
				final nm: Null<String> = child.name;
				final span: Null<Span> = child.span;
				if (nm != null && span != null && !found.exists(nm)) found[nm] = { node: child, run: run, span: span };
			},
			regions
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
			if (MemberBranchScan.isGuardedMember(decl, shape, source, hitNN.node, regions))
				return Left(
					'"$name" is declared inside a conditional-compilation region — pulling it out of its branch would change which '
					+ 'builds declare it'
				);
			final groupSpan: Span = ElementSpan.declGroupSpan(hitNN.node, decl.nameNode, hitNN.span);
			out.push({ name: name, node: hitNN.node, cut: cutSpanOf(source, groupSpan, regions()) });
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
	private static function strandedRefs(
		decl: TypeDeclMatch, moved: Array<Moved>, source: String, shape: RefShape, regions: () -> Array<LexRegion>
	): Array<String> {
		final movingNames: Map<String, Bool> = [for (m in moved) m.name => true];
		final memberNames: Map<String, Bool> = [];
		// Branch-aware, and this one fails SILENTLY when it is not: a member left behind inside a `#if`
		// region was absent from this set, so a pulled-up method reading it passed the stranded-reference
		// gate and the generated superclass did not compile.
		MemberBranchScan.eachTypeMember(
			decl, shape, source, n -> MemberKinds.isFieldMemberKind(n.kind) || MemberKinds.FN_DECL_KINDS.contains(n.kind), (child, _) -> {
				final nm: Null<String> = child.name;
				if (nm != null && !movingNames.exists(nm) && nm != 'new') memberNames[nm] = true;
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
					if (SourceText.identTokenOffset(blob, new Span(0, blob.length), exposed) >= 0 && !out.contains(raw)) out.push(raw);
				}
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return out;
	}

	/**
	 * Assemble the superclass through `NewFile.createRaw` — parse-validated and
	 * canonical AT THE WRITER'S FIXED POINT, under `optsJson` rather than under
	 * compiled defaults.
	 *
	 * A moved member carries its BODY, so every writer shape that needs two round
	 * trips to settle can arrive here; and a `writeRoundTrip(source, null)` styled
	 * the new file by the writer's built-in defaults while `fmt --list` judged it
	 * under the project's discovered `hxformat.json`. Either alone left the created
	 * file drifted from birth.
	 */
	private static function buildSuperclass(
		superName: String, pkg: String, blocks: Array<String>, imports: Array<String>, plugin: GrammarPlugin, optsJson: Null<String>
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
		sb.add('class ');
		sb.add(superName);
		sb.add(' {\n\n');
		sb.add(blocks.join('\n\n'));
		sb.add('\n\n}\n');
		return switch NewFile.createRaw(sb.toString(), plugin, optsJson) {
			case Ok(text, rewrites): Ok(text, rewrites);
			case Err(message): Err('the assembled superclass: $message');
		};
	}

	/**
	 * The header edit that inserts `extends <Super>` — before an existing
	 * `implements` clause, else just past the last header token. Null when
	 * the body brace cannot be verified, which aborts the whole extraction
	 * before any member is cut.
	 */
	private static function extendsEdit(
		source: String, decl: TypeDeclMatch, typeName: String, superName: String, regions: Array<LexRegion>
	): Null<{ span: Span, text: String }> {
		for (child in decl.nameNode.children) if (child.kind == 'ImplementsClause') {
			final s: Null<Span> = child.span;
			if (s != null) return { span: new Span(s.from, s.from), text: 'extends $superName ' };
		}
		final at: Null<Int> = RefactorSupport.typeHeaderInsertOffset(source, decl, typeName, regions);
		if (at == null) return null;
		final atNN: Int = at;
		return { span: new Span(atNN, atNN), text: ' extends $superName' };
	}

	/** The cut span of a member group: decl + leading doc + whole line(s). */
	private static function cutSpanOf(source: String, groupSpan: Span, regions: Array<LexRegion>): Span {
		return ElementSpan.blankExtendedSpan(
			source, ElementSpan.lineExtendedSpan(source, ElementSpan.docExtendedSpan(source, groupSpan, regions))
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

}
