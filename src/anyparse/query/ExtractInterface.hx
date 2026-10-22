package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.MoveSymbol.MoveResult;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.TypeExtraction.SourceClass;
import anyparse.runtime.Span;
import haxe.ds.Either;

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
 *
 * A class that ALREADY implements the interface is refused rather than given a
 * second clause. The header splice is additive and read nothing, so a re-run
 * produced `class C implements IFoo implements IFoo` at rc 0 — past the parse
 * gate, because the header still parses, and rejected only by the compiler. The
 * occupied-destination refusal covers the default path; `--out <fresh path>`
 * reached it. The comparison is on the clause's WRITTEN name: an existing
 * `implements other.IFoo` is a different type and does not block the extraction.
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
	 * `optsJson` is the `hxformat.json` governing where `ifaceFile` LANDS,
	 * `srcOptsJson` the one governing `srcFile` — two parameters because `--out` can put
	 * the interface under a different config from the class it came from. Neither is a
	 * neutral default when omitted, and they fail DIFFERENTLY:
	 *
	 *  - no `optsJson`: the interface is styled by the writer's compiled defaults while
	 *    `fmt --list` and the next writer-emit op's canonical gate judge it under the
	 *    project's config — drifted from birth. That is the defect it exists to close.
	 *  - no `srcOptsJson`: the SOURCE is measured for canonicality under compiled
	 *    defaults, so a project-canonical file reads as drifted and the edit quietly
	 *    falls back to the plain splice — the canonical-in/canonical-out half switches
	 *    itself off, and in the rarer reverse case the file is rewritten in the wrong
	 *    style.
	 */
	public static function extract(
		srcFile: String, srcTypeName: String, ifaceName: String, ifaceFile: String, memberNames: Null<Array<String>>, srcSource: String,
		plugin: GrammarPlugin, ?optsJson: String, ?srcOptsJson: String
	): MoveResult {
		if (!SourceText.isIdentifier(ifaceName)) return Err('interface name "$ifaceName" is not a valid identifier');
		if (ifaceName == srcTypeName) return Err('interface name must differ from the source type "$srcTypeName"');

		final src: SourceClass = switch TypeExtraction.sourceClass(srcFile, srcSource, srcTypeName, plugin) {
			case Left(message): return Err(message);
			case Right(found): found;
		};
		final declNN: TypeDeclMatch = src.decl;
		// Re-running the op against a source that already carries the clause used to
		// splice a SECOND one — `class A implements IA implements IA`, at rc 0, past
		// the parse gate because the header still parses. The occupied-destination
		// refusal hides the default path; `--out <fresh path>` reaches it. Sibling
		// register: `add-import` refuses an import already there, `extract-superclass`
		// a class that already extends one.
		if (implementsClauseFor(declNN, ifaceName) != null)
			return Err('class "$srcTypeName" already implements "$ifaceName" — refusing (nothing written)');

		final all: Array<IfaceMethod> = publicMethods(declNN, srcSource, plugin.refShape(), plugin.lexicalRegions.bind(srcSource));
		final selected: Array<IfaceMethod> = switch selectMethods(all, memberNames) {
			case Left(message): return Err(message);
			case Right(list): list;
		};
		if (selected.length == 0) return Err('class "$srcTypeName" has no public instance method to extract');

		final pkg: String = ModuleScan.packageOf(src.tree);
		final imports: Array<String> = TypeExtraction.carriedImports(src.tree, [for (m in selected) m.signature].join('\n'));
		var ifaceRewrites: Null<Int> = null;
		final ifaceSource: String = switch TypeExtraction.assembleTypeFile(
			pkg, imports, interfaceSource(ifaceName, selected), 'interface', plugin, optsJson
		) {
			case Err(message): return Err(message);
			case Ok(source, rewrites):
				ifaceRewrites = rewrites;
				source;
		};

		final srcEdit: Null<{ span: Span, text: String }> = TypeExtraction.headerInsertEdit(
			srcSource, declNN, srcTypeName, ' implements $ifaceName', plugin.lexicalRegions(srcSource)
		);
		if (srcEdit == null)
			return Err('could not verify the body brace of class "$srcTypeName" — refusing to add implements (nothing written)');
		final edit: { span: Span, text: String } = srcEdit;
		// A pure header INSERTION still changes what the writer would decide: ` implements
		// IFoo` can push the class header past the line limit, where the writer wraps the
		// clause onto a continuation line. A raw splice does not, so a source that was
		// canonical one second earlier is drifted — the very defect this op's CREATED file
		// was taught to avoid, one file over.
		var srcRewrites: Null<Int> = null;
		final newSrc: String = switch TypeExtraction.rewriteSource(srcFile, srcSource, [edit], plugin, srcOptsJson) {
			case Err(message): return Err(message);
			case Ok(text, rewrites):
				srcRewrites = rewrites;
				text;
		};

		final incomplete: Array<String> = [for (m in selected) if (m.signature.indexOf(':') < 0) m.name];
		final advisory: String = 'extracted ${selected.length} method(s) into interface "$ifaceName"'
			+ (incomplete.length > 0 ? '; method(s) without an explicit return type may need annotations: ${incomplete.join(', ')}' : '')
			+ TypeExtraction.rewritesNotes(ifaceFile, ifaceRewrites, srcFile, srcRewrites);
		final changes: Array<MoveChange> = [
			{ file: ifaceFile, newSource: ifaceSource },
			{ file: srcFile, newSource: newSrc }
		];
		return Ok(changes, advisory);
	}

	/**
	 * The `implements <ifaceName>` clause already on `decl`'s header, or null.
	 *
	 * The comparison is on the clause's WRITTEN name, so a pre-existing
	 * `implements other.IA` does not block extracting a local `IA` — that pair
	 * is legal Haxe and only a type resolution could tell the two apart. What it
	 * does catch is the exact-name duplicate, the shape a re-run produces.
	 */
	private static inline function implementsClauseFor(decl: TypeDeclMatch, ifaceName: String): Null<QueryNode> {
		// The clauses hang off the FORM node (`ClassForm` under a `final` wrapper),
		// which is `nameNode` — `declNode` is the wrapper and has only that child.
		return clauseIn(decl.nameNode.children, ifaceName);
	}

	/**
	 * The `implements <ifaceName>` clause among `nodes`, recursing through a
	 * `#if … #end` region — a guarded clause is a child of the `Conditional`, not of the
	 * form node, so a flat scan misses it and the header gains a second clause that IS a
	 * duplicate on every target the condition selects. `AddImport.guardedDuplicate` had
	 * already learned the same lesson for a guarded import; this is that walk.
	 */
	private static function clauseIn(nodes: Array<QueryNode>, ifaceName: String): Null<QueryNode> {
		for (node in nodes) {
			if (node.kind == 'ImplementsClause') for (named in node.children) if (named.name == ifaceName) return node;
			if (node.kind != 'Conditional') continue;
			final guarded: Null<QueryNode> = clauseIn(node.children, ifaceName);
			if (guarded != null) return guarded;
		}
		return null;
	}

	/**
	 * Every public, non-static, non-`final` instance method of `decl`
	 * (excluding the constructor), with its sliced signature. A method's
	 * modifiers project to sibling nodes before it; the signature is the
	 * `FnMember` span up to its body child, so it carries no modifier and
	 * no body.
	 */
	private static function publicMethods(
		decl: TypeDeclMatch, source: String, shape: RefShape, regions: () -> Array<LexRegion>
	): Array<IfaceMethod> {
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
			final sig: Null<String> = signatureOf(child, source, shape);
			if (sig != null) {
				final sigNN: String = sig;
				out.push({ name: nameNN, signature: sigNN, from: spanNN.from });
			}
		}, regions);
		return out;
	}

	/**
	 * Slice a method's signature: the `FnMember` span up to its body child, trimmed,
	 * with any trailing `;` dropped. Modifiers are separate siblings, so the slice
	 * starts at `function` and carries none.
	 *
	 * WHICH children are bodies is `RefShape.functionBodyKinds` — the seam whose own
	 * doc says a consumer reads it "to tell a body child from a return-type child".
	 * The three kinds this used to spell by hand (`BlockBody` / `ExprBody` / `NoBody`)
	 * are three of Haxe's five: a body written `untyped { … }` or spread across a
	 * conditional-compilation region projects as `UntypedBlockBody` / `CondBody`, and
	 * neither matched — so `bodyFrom` stayed at the member's END and the whole body
	 * was sliced into the interface, followed by the stray `;` the caller adds.
	 */
	private static function signatureOf(member: QueryNode, source: String, shape: RefShape): Null<String> {
		final span: Null<Span> = member.span;
		if (span == null) return null;
		final bodyKinds: Array<String> = shape.functionBodyKinds ?? [];
		var bodyFrom: Int = span.to;
		for (c in member.children) {
			final cSpan: Null<Span> = c.span;
			if (cSpan != null && bodyKinds.contains(c.kind) && cSpan.from < bodyFrom) bodyFrom = cSpan.from;
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
	 * The interface declaration itself: each selected signature becomes a body-less method requirement.
	 * `TypeExtraction.assembleTypeFile` puts the package and the carried imports above it.
	 */
	private static function interfaceSource(ifaceName: String, methods: Array<IfaceMethod>): String {
		final sb: StringBuf = new StringBuf();
		sb.add('interface ');
		sb.add(ifaceName);
		sb.add(' {\n');
		for (m in methods) {
			sb.add('\t');
			sb.add(m.signature);
			sb.add(';\n');
		}
		sb.add('}\n');
		return sb.toString();
	}

}
