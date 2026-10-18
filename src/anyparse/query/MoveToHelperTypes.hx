package anyparse.query;

import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.MoveMember.MovePrep;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.Span;
import haxe.ds.Either;

using StringTools;
using Lambda;

/**
 * One module-private type of the source module that travels into the helper module with the moved members: its name, the
 * group (modifiers, metas, declaration) the import carry reads, the span cut out of the source, and the text pasted into
 * the helper module (doc included).
 */
typedef CarriedType = {
	final name: String;
	final group: Span;
	final cut: Span;
	final text: String;
}

/**
 * The private types `move-to-helper` carries (`MoveToHelper`): a module-`private` type of the source module is visible
 * only inside that module, so moved code naming one compiles in the helper module only when the type moves too — and
 * only when nothing staying behind still names it.
 */
@:nullSafety(Strict)
@:access(anyparse.query.MoveMember)
final class MoveToHelperTypes {

	/**
	 * The private types of the source module that only the moved code — the moved members and the other types travelling —
	 * references, grown to a fixpoint (a carried typedef may name another). A private type referenced both by the moved code
	 * and by code staying in the source module is refused: it would have to be visible from two modules.
	 */
	public static function carriedTypes(
		prep: MovePrep, plugin: GrammarPlugin, typeRefShape: TypeRefShape
	): Either<String, Array<CarriedType>> {
		if (prep.srcFile == prep.destFile) return Right([]);
		final privates: Array<TypeDeclInfo> = prep.srcInfo.types.filter(t -> t.isPrivate && t.name != prep.srcTypeName);
		if (privates.length == 0) return Right([]);
		final typeTree: QueryNode = plugin.parseFileTypeRefs(prep.srcSource);
		final regions: Array<LexRegion> = plugin.lexicalRegions(prep.srcSource);
		final candidates: Array<{ type: CarriedType, decl: Span, refs: Array<Int> }> = [];
		for (t in privates) {
			final refs: Array<Int> = referencesOf(prep, typeTree, typeRefShape, t.name);
			final placed: Null<{ type: CarriedType, decl: Span }> = groupOf(prep, t.name, regions);
			if (placed == null) {
				if (refs.exists(at -> MoveMember.insideAnyCut(prep, at)))
					return Left(
						'the moved code names the private type "${t.name}", which is not a plain top-level declaration of '
						+ '${prep.srcFile} (a `#if` region holds it) — move it by hand first'
					);
				continue;
			}
			candidates.push(
				{ type: placed.type, decl: placed.decl, refs: refs.filter(at -> at < placed.decl.from || at >= placed.decl.to) }
			);
		}
		final carried: Array<{ type: CarriedType, decl: Span, refs: Array<Int> }> = [];
		function travels(at: Int): Bool {
			return MoveMember.insideAnyCut(prep, at) || carried.exists(c -> at >= c.decl.from && at < c.decl.to);
		}
		var grew: Bool = true;
		while (grew) {
			grew = false;
			for (c in candidates) if (!carried.contains(c) && c.refs.length > 0 && c.refs.foreach(travels)) {
				carried.push(c);
				grew = true;
			}
		}
		for (c in candidates) if (!carried.contains(c) && c.refs.exists(travels))
			return Left(
				'the private type "${c.type.name}" is named both by the moved code and by code staying in ${prep.srcFile} — '
				+ 'it cannot be private to two modules; make it public first (hxq set-modifier)'
			);
		return Right([for (c in carried) c.type]);
	}

	public static function relocate(
		prep: MovePrep, types: Array<CarriedType>, editsByFile: Map<String, Array<{ span: Span, text: String }>>, advisory: Array<String>
	): Void {
		if (types.length == 0) return;
		for (cut in sourceCuts(prep.srcSource, [for (t in types) t.cut])) ScopeFiles.editsFor(editsByFile, prep.srcFile).push(cut);
		var end: Int = prep.destSource.length;
		while (end > 0 && SourceText.isSpace(prep.destSource.fastCodeAt(end - 1))) end--;
		ScopeFiles.editsFor(editsByFile, prep.destFile).push({
			span: new Span(end, prep.destSource.length),
			text: '\n\n${[for (t in types) t.text].join('\n\n')}\n'
		});
		advisory.push(
			'moved the private type(s) ${[for (t in types) '"${t.name}"'].join(', ')} into ${prep.destFile}, which only the moved code names'
		);
	}

	/** Every offset of `name` in the source: its type positions and its value positions (a private enum's `E.A`). */
	private static function referencesOf(prep: MovePrep, typeTree: QueryNode, typeRefShape: TypeRefShape, name: String): Array<Int> {
		final out: Array<Int> = [for (hit in Uses.find(name, typeTree, typeRefShape)) hit.span.from];
		function walk(node: QueryNode): Void {
			final from: Null<Int> = node.span?.from;
			if (from != null && node.kind == prep.shape.identKind && node.name == name && !out.contains(from)) out.push(from);
			for (c in node.children) walk(c);
		}
		walk(prep.srcTree);
		return out;
	}

	/** The top-level declaration of `name` in the source: its carry group, its cut and its text — or null. */
	private static function groupOf(prep: MovePrep, name: String, regions: Array<LexRegion>): Null<{ type: CarriedType, decl: Span }> {
		final tree: QueryNode = prep.srcTree;
		final decl: Null<QueryNode> = tree.children.find(c -> c.name == name && RefactorSupport.typeDeclOf(c) != null);
		final declSpan: Null<Span> = decl?.span;
		if (decl == null || declSpan == null) return null;
		final source: String = prep.srcSource;
		final trimmed: Span = ElementSpan.trailingTrimmedSpan(source, declSpan, () -> regions);
		final group: Span = new Span(ElementSpan.declRunStart(decl, tree, declSpan), trimmed.to);
		final text: String = source.substring(ElementSpan.docExtendedSpan(source, group, regions).from, group.to);
		return {
			type: {
				name: name,
				group: group,
				cut: ElementSpan.memberCutSpan(source, group, regions),
				text: text
			},
			decl: declSpan
		};
	}

	/**
	 * The source-side deletions of the carried types: their cuts, merged where only whitespace separates two, and the one
	 * reaching the end of the module widened back over the blank run before it — a cut that leaves the module's last
	 * declaration followed by a blank line would leave a trailing blank line behind (`memberCutSpan` takes a blank run only
	 * between two siblings).
	 */
	private static function sourceCuts(source: String, cuts: Array<Span>): Array<{ span: Span, text: String }> {
		final sorted: Array<Span> = cuts.copy();
		sorted.sort((a, b) -> a.from - b.from);
		final merged: Array<Span> = [];
		for (cut in sorted) {
			final last: Null<Span> = merged[merged.length - 1];
			if (last != null && isBlank(source, last.to, cut.from))
				merged[merged.length - 1] = new Span(last.from, cut.to);
			else
				merged.push(cut);
		}
		return [
			for (cut in merged)
				if (isBlank(source, cut.to, source.length)) {
					var from: Int = cut.from;
					while (from > 0 && SourceText.isSpace(source.fastCodeAt(from - 1))) from--;
					{ span: new Span(from, source.length), text: '\n' };
				} else
					{ span: cut, text: '' }
		];
	}

	private static function isBlank(source: String, from: Int, to: Int): Bool {
		for (i in from ... to) if (!SourceText.isSpace(source.fastCodeAt(i))) return false;
		return true;
	}

}
