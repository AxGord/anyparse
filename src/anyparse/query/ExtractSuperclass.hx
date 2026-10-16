package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.MoveSymbol.MoveResult;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.TypeExtraction.SourceClass;
import anyparse.runtime.Span;
import haxe.ds.Either;

using StringTools;
using Lambda;

/** One member selected to pull up: its name, node, and cut span. */
private typedef Moved = {
	var name: String;
	var node: QueryNode;
	var cut: Span;
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
 * lands) and the source re-parses before either is returned. The EDITED
 * source comes back at the same fixed point when it went in at one — a
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

		final src: SourceClass = switch TypeExtraction.sourceClass(srcFile, srcSource, srcTypeName, plugin) {
			case Left(message): return Err(message);
			case Right(found): found;
		};
		final declNN: TypeDeclMatch = src.decl;
		if (TypeExtraction.superNameOf(declNN) != null)
			return Err('class "$srcTypeName" already extends a class — single inheritance, refusing');

		final shape: RefShape = plugin.refShape();
		final moved: Array<Moved> = switch resolveMembers(declNN, memberNames, srcSource, shape, plugin.lexicalRegions.bind(srcSource)) {
			case Left(message): return Err(message);
			case Right(list): list;
		};
		final stranded: Array<String> = TypeExtraction.referencedMembers(
			declNN, [for (m in moved) m.name].concat(['new']),
			[for (m in moved) m.node], srcSource, shape, plugin.lexicalRegions.bind(srcSource)
		);
		if (stranded.length > 0)
			return Err('pulled-up member(s) reference member(s) staying behind: ${stranded.join(', ')} — add them to the set or refactor');

		final blocks: Array<String> = [
			for (m in moved) SourceText.trimNewlineEdges(srcSource.substring(m.cut.from, m.cut.to))
		];
		final pkg: String = ModuleScan.packageOf(src.tree);
		final imports: Array<String> = TypeExtraction.carriedImports(src.tree, blocks.join('\n'));
		var superRewrites: Null<Int> = null;
		final superSource: String = switch TypeExtraction.assembleTypeFile(
			pkg, imports, 'class $superName {\n\n${blocks.join('\n\n')}\n\n}\n', 'superclass', plugin, optsJson
		) {
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
		// as text, so it also rewrote a run inside a STRING LITERAL or a block
		// comment: `extract-superclass` on an untouched sibling member shortened a
		// multi-line literal by one newline, and every gate stayed green because the result
		// still parsed and was still canonical.
		var srcRewrites: Null<Int> = null;
		final newSrc: String = switch TypeExtraction.rewriteSource(srcFile, srcSource, edits, plugin, srcOptsJson) {
			case Err(message): return Err(message);
			case Ok(text, rewrites):
				srcRewrites = rewrites;
				text;
		};

		final advisory: String = 'pulled ${moved.length} member(s) up into new superclass "$superName'
			+ '" — subclass access preserved by inheritance; the superclass has no constructor (the source constructor is unchanged)'
			+ TypeExtraction.rewritesNotes(superFile, superRewrites, srcFile, srcRewrites);
		final changes: Array<MoveChange> = [
			{ file: superFile, newSource: superSource },
			{ file: srcFile, newSource: newSrc }
		];
		return Ok(changes, advisory);
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
			out.push({ name: name, node: hitNN.node, cut: ElementSpan.memberCutSpan(source, groupSpan, regions()) });
		}
		out.sort((a, b) -> a.cut.from - b.cut.from);
		return Right(out);
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
		return TypeExtraction.headerInsertEdit(source, decl, typeName, ' extends $superName', regions);
	}

}
