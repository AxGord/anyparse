package anyparse.query;

import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.MoveSymbol.MoveResult;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

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
 *    Built through `NewFile.create` so it is byte-canonical + validated.
 *  - The source class gains an `implements <Iface>` clause (a verbatim
 *    header splice — no call sites change; an interface is purely
 *    additive, so nothing else in the scope needs rewriting).
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
	 * Extract an interface named `ifaceName` (written to `ifaceFile`) from
	 * `srcTypeName` in `srcSource`. `memberNames` selects the methods; null
	 * means every public instance method. PURE — the CLI writes the
	 * returned changes. Returns an `Ok` with two changes (the new
	 * interface file, the modified source) or an `Err`.
	 */
	public static function extract(
		srcFile: String, srcTypeName: String, ifaceName: String, ifaceFile: String, memberNames: Null<Array<String>>, srcSource: String,
		plugin: GrammarPlugin
	): MoveResult {
		if (!RefactorSupport.isIdentifier(ifaceName)) return Err('interface name "$ifaceName" is not a valid identifier');
		if (ifaceName == srcTypeName) return Err('interface name must differ from the source type "$srcTypeName"');

		final tree: QueryNode = try plugin.parseFile(srcSource) catch (exception: ParseError) return Err(
			'$srcFile does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('$srcFile does not parse: ${exception.message}');

		final decl: Null<TypeDeclMatch> = uniqueClass(tree, srcTypeName);
		if (decl == null) return Err('no unique class "$srcTypeName" in $srcFile');
		final declNN: TypeDeclMatch = decl;

		final all: Array<IfaceMethod> = publicMethods(declNN, srcSource);
		final selected: Array<IfaceMethod> = switch selectMethods(all, memberNames) {
			case Left(message): return Err(message);
			case Right(list): list;
		};
		if (selected.length == 0) return Err('class "$srcTypeName" has no public instance method to extract');

		final pkg: String = packageOf(tree);
		final imports: Array<String> = carriedImports(tree, selected);
		final ifaceSource: String = switch buildInterface(ifaceName, pkg, selected, imports, plugin) {
			case Left(message): return Err(message);
			case Right(source): source;
		};

		final srcEdit: Null<{ span: Span, text: String }> = implementsEdit(srcSource, decl, srcTypeName, ifaceName);
		if (srcEdit == null) return Err('could not locate the class body of "$srcTypeName" to add implements');
		final edit: { span: Span, text: String } = srcEdit;
		final newSrc: String = srcSource.substring(0, edit.span.from) + edit.text + srcSource.substring(edit.span.to);

		try
			plugin.parseFile(newSrc)
		catch (exception: ParseError)
			return Err('rewritten $srcFile does not parse: ${exception.toString()}')
		catch (exception: Exception)
			return Err('rewritten $srcFile does not parse: ${exception.message}');

		final incomplete: Array<String> = [for (m in selected) if (m.signature.indexOf(':') < 0) m.name];
		final advisory: String = 'extracted ${selected.length} method(s) into interface "$ifaceName"' + (
			incomplete.length > 0 ? '; method(s) without an explicit return type may need annotations: ${incomplete.join(', ')}' : ''
		);
		final changes: Array<MoveChange> = [
			{ file: ifaceFile, newSource: ifaceSource },
			{ file: srcFile, newSource: newSrc },
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
	private static function publicMethods(decl: TypeDeclMatch, source: String): Array<IfaceMethod> {
		final out: Array<IfaceMethod> = [];
		final siblings: Array<QueryNode> = decl.nameNode.children;
		for (i => child in siblings) {
			if (child.kind != 'FnMember') continue;
			final name: Null<String> = child.name;
			final span: Null<Span> = child.span;
			if (name == null || span == null || name == 'new') continue;
			final nameNN: String = name;
			final spanNN: Span = span;
			var isPublic: Bool = false;
			var isStatic: Bool = false;
			var j: Int = i - 1;
			while (j >= 0 && MODIFIER_META.contains(siblings[j].kind)) {
				switch siblings[j].kind {
					case 'Public':
						isPublic = true;
					case 'Static':
						isStatic = true;
					case _:
				}
				j--;
			}
			// A `final function` wraps into FinalModifiedMember, never a plain
			// FnMember, so this loop only ever sees non-final methods.
			if (!isPublic || isStatic) continue;
			final sig: Null<String> = signatureOf(child, source);
			if (sig != null) {
				final sigNN: String = sig;
				out.push({ name: nameNN, signature: sigNN, from: spanNN.from });
			}
		}
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
		var sig: String = StringTools.trim(source.substring(span.from, bodyFrom));
		if (StringTools.endsWith(sig, ';')) sig = StringTools.trim(sig.substr(0, sig.length - 1));
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

	/** The file's `package` path, or "" when none. */
	private static function packageOf(tree: QueryNode): String {
		for (child in tree.children) if (child.kind == 'PackageDecl') return child.name ?? '';
		return '';
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
	 * Assemble the interface source through `NewFile.create` — the
	 * signatures become body-less method requirements, the carried imports
	 * an `@@ imports` section — so the result is byte-canonical and
	 * validated.
	 */
	private static function buildInterface(
		ifaceName: String, pkg: String, methods: Array<IfaceMethod>, imports: Array<String>, plugin: GrammarPlugin
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
		sb.add('interface ');
		sb.add(ifaceName);
		sb.add(' {\n');
		for (m in methods) {
			sb.add('\t');
			sb.add(m.signature);
			sb.add(';\n');
		}
		sb.add('}\n');
		final canonical: Null<String> = try plugin.writeRoundTrip(sb.toString(), null) catch (exception: ParseError) {
			return Left('assembled interface does not parse: ${exception.toString()}');
		} catch (exception: Exception) {
			return Left('assembled interface does not parse: ${exception.message}');
		};
		return canonical == null ? Left('no writer for this grammar') : Right(canonical);
	}

	/**
	 * The span-splice that adds `implements <Iface>` to the class header —
	 * inserted right after the last header token, before the body `{`, so
	 * the existing spacing and any `extends` / `implements` clauses are
	 * preserved. Null when the body brace cannot be located.
	 */
	private static function implementsEdit(
		source: String, decl: TypeDeclMatch, typeName: String, ifaceName: String
	): Null<{ span: Span, text: String }> {
		final nameSpan: Span = decl.nameNode.span ?? decl.fullSpan;
		final nameFrom: Int = RefactorSupport.identTokenOffset(source, nameSpan, typeName);
		final searchFrom: Int = nameFrom < 0 ? nameSpan.from : nameFrom + typeName.length;
		final brace: Int = source.indexOf('{', searchFrom);
		if (brace < 0) return null;
		var headerEnd: Int = brace;
		while (headerEnd > searchFrom && isSpace(StringTools.fastCodeAt(source, headerEnd - 1))) headerEnd--;
		return { span: new Span(headerEnd, headerEnd), text: ' implements $ifaceName' };
	}

	private static inline function isSpace(code: Int): Bool {
		return code == ' '.code || code == '\t'.code || code == '\n'.code || code == '\r'.code;
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
