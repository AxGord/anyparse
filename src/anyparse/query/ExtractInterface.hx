package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.MoveSymbol.MoveResult;
import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;
using Lambda;

/**
 * One selected public method: its name, sliced signature (no body / no
 * modifiers), and the group span for member-ordering.
 */
private typedef IfaceMethod = {
	var name: String;
	var signature: String;
	var from: Int;
}

/**
 * `extract-interface` — generate an interface from a class's public
 * methods and make the class `implements` it. The structural inverse of
 * `hxq new --implements` (which stubs a class FROM an interface); the two
 * share the `[FnMember, body)` signature slice and the import-carry.
 *
 * ## What it produces
 *
 *  - A NEW interface file in the source type's package: one method-
 *    signature requirement per selected member (default: every public,
 *    non-static instance method), plus the source imports those
 *    signatures reference (so the interface type-checks, not just parses).
 *    Built through `NewFile.createRaw`, so it is byte-canonical at the
 *    WRITER FIXED POINT under the format config governing where the file
 *    lands.
 *  - The source class gains an `implements <Iface>` clause — no call sites
 *    change; an interface is purely additive, so nothing else in the scope
 *    needs rewriting. A source that was already the writer fixed point comes
 *    back at it: the splice can push the header past the line limit, where
 *    only the writer knows to wrap the clause. A source that was NOT canonical
 *    keeps its own layout (format-preserving), which is what a span-splice op
 *    has always promised.
 *
 * ## Boundary
 *
 * A method whose parameters / return type are not explicitly annotated
 * yields an incomplete interface signature (the class relied on
 * inference) — reported in the advisory, surfaces as a compile error if
 * it matters, never a silent change. Static members and the constructor
 * are excluded (interfaces have neither). `final` methods are skipped
 * (an interface method cannot be `final`). Atomic: the interface must
 * parse (via `NewFile`) and the source edit re-parses before either is
 * returned.
 */
@:nullSafety(Strict)
final class ExtractInterface {

	/**
	 * Extract an interface named `ifaceName` (written to `ifaceFile`) from
	 * `srcTypeName` in `srcSource`. `memberNames` selects the methods; null
	 * means every public instance method. PURE — the CLI writes the returned
	 * changes. Returns an `Ok` with two changes (the new interface file, the
	 * modified source) or an `Err`.
	 *
	 * `optsJson` is the `hxformat.json` governing where `ifaceFile` LANDS, and
	 * `srcOptsJson` the one governing `srcFile` — two parameters because `--out` can
	 * put the interface under a different config from the class it came from.
	 * Omitting either is not a neutral default: the interface is then styled by the
	 * writer's compiled defaults while `fmt --list` and the next writer-emit
	 * op's canonical gate judge it under the project's config. That is the
	 * defect this parameter exists to close.
	 */
	public static function extract(
		srcFile: String, srcTypeName: String, ifaceName: String, ifaceFile: String, memberNames: Null<Array<String>>, srcSource: String,
		plugin: GrammarPlugin, ?optsJson: String, ?srcOptsJson: String
	): MoveResult {
		if (!RefactorSupport.isIdentifier(ifaceName)) return Err('interface name "$ifaceName" is not a valid identifier');
		if (ifaceName == srcTypeName) return Err('interface name must differ from the source type "$srcTypeName"');

		final tree: QueryNode = try plugin.parseFile(srcSource) catch (exception: ParseError) return Err(
			'$srcFile does not parse: $exception'
		)
		catch (exception: Exception) return Err('$srcFile does not parse: ${exception.message}');

		final decl: Null<TypeDeclMatch> = uniqueClass(tree, srcTypeName);
		if (decl == null) return Err('no unique class "$srcTypeName" in $srcFile');
		final declNN: TypeDeclMatch = decl;

		final all: Array<IfaceMethod> = publicMethods(declNN, srcSource, plugin.refShape());
		final selected: Array<IfaceMethod> = switch selectMethods(all, memberNames) {
			case Left(message): return Err(message);
			case Right(list): list;
		};
		if (selected.length == 0) return Err('class "$srcTypeName" has no public instance method to extract');

		final pkg: String = ModuleScan.packageOf(tree);
		final imports: Array<String> = carriedImports(tree, selected);
		// The count is the WRITER's, not the extraction's, and it reaches the user only
		// through the advisory: a created file the writer needed two passes to settle is
		// the defect `apq fmt` reports and every op used to absorb in silence.
		var ifaceRewrites: Null<Int> = null;
		final ifaceSource: String = switch buildInterface(ifaceName, pkg, selected, imports, plugin, optsJson) {
			case Err(message): return Err(message);
			case Ok(source, rewrites):
				ifaceRewrites = rewrites;
				source;
		};

		final srcEdit: Null<{ span: Span, text: String }> = implementsEdit(srcSource, decl, srcTypeName, ifaceName);
		if (srcEdit == null)
			return Err('could not verify the body brace of class "$srcTypeName" — refusing to add implements (nothing written)');
		final edit: { span: Span, text: String } = srcEdit;
		// A pure header INSERTION still changes what the writer would decide: ` implements
		// IFoo` can push the class header past the line limit, where the writer wraps the
		// clause onto a continuation line. A raw splice does not, so a source that was
		// canonical one second earlier is drifted — the very defect this op's CREATED file
		// was taught to avoid, one file over.
		var srcRewrites: Null<Int> = null;
		final newSrc: String = switch RefactorSupport.editKeepingCanonical(srcSource, [edit], plugin, srcOptsJson) {
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

		final incomplete: Array<String> = [for (m in selected) if (m.signature.indexOf(':') < 0) m.name];
		final rewritesNote: Null<String> = FormatFixedPoint.rewritesNote(ifaceRewrites);
		final srcRewritesNote: Null<String> = FormatFixedPoint.rewritesNote(srcRewrites);
		final advisory: String = 'extracted ${selected.length} method(s) into interface "$ifaceName"' + (
			incomplete.length > 0 ? '; method(s) without an explicit return type may need annotations: ${incomplete.join(', ')}' : ''
		) + (rewritesNote == null ? '' : '; $ifaceFile: $rewritesNote') + (srcRewritesNote == null ? '' : '; $srcFile: $srcRewritesNote');
		final changes: Array<MoveChange> = [
			{ file: ifaceFile, newSource: ifaceSource },
			{ file: srcFile, newSource: newSrc }
		];
		return Ok(changes, advisory);
	}

	/** The sole class declaration named `typeName`, or null. Final-aware. */
	private static function uniqueClass(tree: QueryNode, typeName: String): Null<TypeDeclMatch> {
		final matches: Array<TypeDeclMatch> = [];
		function walk(node: QueryNode): Void {
			final m: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (m != null && m.name == typeName && m.kind == 'ClassDecl') matches.push(m);
			for (c in node.children) walk(c);
		}
		walk(tree);
		return matches.length == 1 ? matches[0] : null;
	}

	/**
	 * Every public, non-static, non-`final` instance method of `decl`
	 * (excluding the constructor), with its sliced signature. A method's
	 * modifiers project to sibling nodes before it; the signature is the
	 * `FnMember` span up to its body child, so it carries no modifier and
	 * no body.
	 */
	private static function publicMethods(decl: TypeDeclMatch, source: String, shape: RefShape): Array<IfaceMethod> {
		final out: Array<IfaceMethod> = [];
		// Branch-aware: a method a `#if` region declares is not a direct child of the type, and the
		// scan that missed it produced an interface silently short of that method.
		MemberBranchScan.eachTypeMember(decl, shape, source, n -> n.kind == 'FnMember', (child, run) -> {
			final name: Null<String> = child.name;
			final span: Null<Span> = child.span;
			if (name == null || span == null || name == 'new') return;
			final nameNN: String = name;
			final spanNN: Span = span;
			var isPublic: Bool = false;
			var isStatic: Bool = false;
			for (mod in run) switch mod.kind {
				case 'Public':
					isPublic = true;
				case 'Static':
					isStatic = true;
				case _:
			}
			// A `final function` wraps into FinalModifiedMember, never a plain
			// FnMember, so this loop only ever sees non-final methods.
			if (!isPublic || isStatic) return;
			final sig: Null<String> = signatureOf(child, source);
			if (sig != null) {
				final sigNN: String = sig;
				out.push({ name: nameNN, signature: sigNN, from: spanNN.from });
			}
		});
		return out;
	}

	/**
	 * Slice a method's signature: the `FnMember` span up to its body child
	 * (`BlockBody` / `ExprBody` / `NoBody`), trimmed, with any trailing
	 * `;` dropped. Modifiers are separate siblings, so the slice starts at
	 * `function` and carries none.
	 */
	private static function signatureOf(member: QueryNode, source: String): Null<String> {
		final span: Null<Span> = member.span;
		if (span == null) return null;
		var bodyFrom: Int = span.to;
		for (c in member.children) {
			final cSpan: Null<Span> = c.span;
			if (cSpan != null && (c.kind == 'BlockBody' || c.kind == 'ExprBody' || c.kind == 'NoBody') && cSpan.from < bodyFrom)
				bodyFrom = cSpan.from;
		}
		var sig: String = source.substring(span.from, bodyFrom).trim();
		if (sig.endsWith(';')) sig = sig.substr(0, sig.length - 1).trim();
		return sig == '' ? null : sig;
	}

	/**
	 * Filter `all` to the requested `memberNames` (each must be an
	 * extractable public method), or return all of them when null.
	 */
	private static function selectMethods(all: Array<IfaceMethod>, memberNames: Null<Array<String>>): Either<String, Array<IfaceMethod>> {
		if (memberNames == null) return Right(all);
		final out: Array<IfaceMethod> = [];
		for (name in memberNames) {
			final m: Null<IfaceMethod> = all.find(x -> x.name == name);
			if (m == null)
				return Left('"$name" is not a public instance method of the class (have: ${[for (x in all) x.name].join(', ')})');
			out.push(m);
		}
		return Right(out);
	}

	/**
	 * The plain imports of the source file whose exposed name appears in
	 * any selected signature — the type-position dependencies the
	 * interface must carry so it type-checks. `using` / wildcard / aliased
	 * imports are not carried (signatures never reference them).
	 */
	private static function carriedImports(tree: QueryNode, methods: Array<IfaceMethod>): Array<String> {
		final sigBlob: String = [for (m in methods) m.signature].join('\n');
		final out: Array<String> = [];
		function walk(node: QueryNode): Void {
			if (node.kind == 'ImportDecl') {
				final raw: Null<String> = node.name;
				if (raw != null) {
					final dot: Int = raw.lastIndexOf('.');
					final exposed: String = dot < 0 ? raw : raw.substr(dot + 1);
					if (referencedWord(sigBlob, exposed) && !out.contains(raw)) out.push(raw);
				}
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return out;
	}

	/** Does `word` occur in `hay` on identifier boundaries? */
	private static function referencedWord(hay: String, word: String): Bool {
		return RefactorSupport.identTokenOffset(hay, new Span(0, hay.length), word) >= 0;
	}

	/**
	 * Assemble the interface source through `NewFile.createRaw` — the signatures
	 * become body-less method requirements, the carried imports plain import
	 * statements — so the result is parse-validated and canonical AT THE WRITER'S
	 * FIXED POINT, under `optsJson` rather than under compiled defaults.
	 *
	 * Both of those used to be wrong here, and each on its own is enough to make
	 * the created file drift: a `plugin.writeRoundTrip(source, null)` formatted the
	 * interface with the writer's built-in style while `fmt --list` judged it under
	 * the project's discovered `hxformat.json`, and one round trip lands short of
	 * the fixed point on the shapes `WrapFlatSourceFixedPointTest` pins. The doc on
	 * this class claimed `NewFile` all along; now it is true.
	 */
	private static function buildInterface(
		ifaceName: String, pkg: String, methods: Array<IfaceMethod>, imports: Array<String>, plugin: GrammarPlugin, optsJson: Null<String>
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
		sb.add('interface ');
		sb.add(ifaceName);
		sb.add(' {\n');
		for (m in methods) {
			sb.add('\t');
			sb.add(m.signature);
			sb.add(';\n');
		}
		sb.add('}\n');
		return switch NewFile.createRaw(sb.toString(), plugin, optsJson) {
			case Ok(text, rewrites): Ok(text, rewrites);
			case Err(message): Err('the assembled interface: $message');
		};
	}

	/**
	 * The span-splice that adds `implements <Iface>` to the class header —
	 * inserted just past the last header token, before the body `{`, so the
	 * existing spacing and any `extends` / `implements` clauses are
	 * preserved. Null when the body brace cannot be verified, which aborts
	 * the extraction before anything is written.
	 */
	private static function implementsEdit(
		source: String, decl: TypeDeclMatch, typeName: String, ifaceName: String
	): Null<{ span: Span, text: String }> {
		final at: Null<Int> = RefactorSupport.typeHeaderInsertOffset(source, decl, typeName);
		if (at == null) return null;
		final atNN: Int = at;
		return { span: new Span(atNN, atNN), text: ' implements $ifaceName' };
	}

}

/**
 * A tiny sum type for a computed value or an error message, so the
 * extraction phases short-circuit without sentinel strings.
 */
private enum Either<L, R> {

	Left(value: L);
	Right(value: R);

}
