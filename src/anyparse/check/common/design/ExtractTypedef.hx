package anyparse.check.common.design;

import anyparse.check.Check.CrossFileEdits;
import anyparse.check.common.design.AnonTypeDup.AnonCtx;
import anyparse.check.common.design.AnonTypeDup.Occurrence;
import anyparse.check.common.design.AnonTypeDup.Placement;
import anyparse.check.common.design.AnonTypeDup.Plan;
import anyparse.query.IndexScope;
import anyparse.query.ParseGate;
import anyparse.query.SymbolIndex;
import anyparse.util.Compare;
import haxe.ds.Either;

using anyparse.util.Arrays;
using StringTools;

/** What naming one anonymous structure came to: the slices to apply and what they rewrite, or the reason nothing may be done. */
enum Extraction {

	/**
	 * `slices` create the typedef and rewrite `rewritten` occurrences;
	 * each of `skipped` is an equal-looking one left as written, with why.
	 */
	Done(slices: Array<CrossFileEdits>, rewritten: Int, skipped: Array<String>);
	Declined(reason: String);

}

/**
 * The one answer to "name this anonymous structure": the typedef module of the structure written at an address, and the rewrite
 * of every occurrence in the scope that is the same type to its name. Behind `apq extract-typedef`; the lint rule `anon-type-dup`
 * names the command for a structure it finds written out many times.
 *
 * ## Same type
 *
 * The equality of `prefer-existing-typedef`: the same fields (name, optionality, written type, in any order), every simple type
 * name denoting the same declaration from the occurrence's file as from the addressed one, and no type parameter in scope that
 * a name of the structure would bind. An occurrence that fails a part is left as written and listed, never rewritten. The
 * typedef's own fields are read off the addressed occurrence as written.
 *
 * ## Declined
 *
 * A path that is not `pkg.Name`, a name some type of the scope already holds, a module already in the scope (a module on disk
 * outside the scope is the caller's check), an address that holds no structure the rule can key (an extended, class-notation
 * or `#if`-guarded one), or an addressed structure that names a type parameter.
 */
@:nullSafety(Strict)
final class ExtractTypedef {

	/**
	 * Name the structure written at `line` (and `col`, when given) of `file` as the typedef `path`, over `files`: the
	 * occurrence containing the position, else the single one starting on that line.
	 */
	public static function extract(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, file: String, line: Int, col: Null<Int>, path: String
	): Extraction {
		if (!~/^([a-z_][A-Za-z0-9_]*\.)*[A-Z][A-Za-z0-9_]*$/.match(path))
			return Declined('"$path" is not a type path — expected pkg.Name, the package lowercase and the name capitalised');
		final ctx: Null<AnonCtx> = AnonTypeDup.buildCtx(plugin.refShape());
		final entry: Null<{ file: String, source: String }> = files.find(f -> f.file == file);
		if (ctx == null) return Declined('this grammar has no anonymous structure type');
		if (entry == null) return Declined('$file is not in the scope');
		final groups: Map<String, Array<Occurrence>> = [];
		final order: Array<String> = [];
		for (f in files) {
			final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, f.source);
			if (tree != null) AnonTypeDup.collect(tree, null, f.file, f.source, ctx, 1, groups, order);
		}
		final addressed: Occurrence = switch occurrenceAt(groups, order, entry, line, col) {
			case Left(hit): hit;
			case Right(reason): return Declined(reason);
		};
		final index: SymbolIndex = IndexScope.resolution(files, plugin);
		if (index.importPathsOf(path.substr(path.lastIndexOf('.') + 1)).contains(path)) return Declined('the type $path already exists');
		final scopes: Map<String, Map<String, Array<Span>>> = [];
		if (PreferExistingTypedef.bindsAParameter(addressed, plugin, scopes))
			return Declined('the structure names a type parameter in scope where it is written, so it cannot become a typedef');
		final denotes: String = PreferExistingTypedef.denotesOf(addressed.typeNames, addressed.file, index);
		final fields: String = PreferExistingTypedef.sortedFields(addressed.fields);
		final hits: Array<Occurrence> = [addressed];
		final skipped: Array<String> = [];
		for (hit in sameKeyAs(groups, addressed)) if (hit != addressed) {
			final why: Null<String> = if (PreferExistingTypedef.sortedFields(hit.fields) != fields)
				'a nested structure is written with its fields in another order'
			else if (PreferExistingTypedef.denotesOf(hit.typeNames, hit.file, index) != denotes)
				'a type name of it denotes another declaration here'
			else if (PreferExistingTypedef.bindsAParameter(hit, plugin, scopes))
				'it names a type parameter in scope'
			else
				null;
			if (why == null)
				hits.push(hit)
			else
				skipped.push('${placeOf(hit)}: $why');
		}
		final spelled: Null<Array<String>> = spelledFields(addressed, plugin);
		if (spelled == null) return Declined('${placeOf(addressed)} does not parse');
		final plan: Plan = { named: AnonTypeDup.namedOf(path, spelled), hits: hits };
		return switch AnonTypeDup.slicesOf(plan, files, plugin, index) {
			case Placed(slices): Done(slices, hits.length, skipped);
			case Refused(reason): Declined(reason);
		};
	}

	/** `file:line:col` of an occurrence, as the CLI addresses one. */
	private static function placeOf(hit: Occurrence): String {
		final at: Position = hit.at.lineCol(hit.source);
		return '${hit.file}:${at.line}:${at.col}';
	}

	/** The occurrences written under the same structural key as `addressed`, in scope order. */
	private static function sameKeyAs(groups: Map<String, Array<Occurrence>>, addressed: Occurrence): Array<Occurrence> {
		return groups.find(bucket -> bucket.contains(addressed)) ?? [];
	}

	/** The structure of `file` at the position, or why there is none: containing it (the innermost), else the one starting on its line. */
	private static function occurrenceAt(
		groups: Map<String, Array<Occurrence>>, order: Array<String>, entry: { file: String, source: String }, line: Int, col: Null<Int>
	): Either<Occurrence, String> {
		final here: Array<Occurrence> = [ for (key in order) for (hit in groups[key] ?? []) if (hit.file == entry.file) hit ];
		final offset: Int = Span.offsetOf(entry.source, line, col ?? 1);
		final holding: Array<Occurrence> = here.filter(h -> col != null && h.at.from <= offset && offset < h.at.to);
		holding.sort((a, b) -> Compare.compareInt(a.at.to - a.at.from, b.at.to - b.at.from));
		if (holding.length > 0) return Left(holding[0]);
		final starting: Array<Occurrence> = col != null ? [] : here.filter(h -> h.at.lineCol(entry.source).line == line);
		if (starting.length == 1) return Left(starting[0]);
		if (starting.length > 1)
			return Right(
				'${starting.length} structures start on line $line (${starting.map(placeOf).join(', ')}) — address one by its column'
			);
		return Right('no anonymous structure with named, typed fields at ${entry.file}:$line${col == null ? '' : ':$col'}');
	}

	/** The fields of the structure of `hit` as written, one text each, from the tree of its file. */
	private static function spelledFields(hit: Occurrence, plugin: GrammarPlugin): Null<Array<String>> {
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, hit.source);
		final node: Null<QueryNode> = tree == null ? null : nodeAt(tree, hit.at);
		if (node == null) return null;
		final out: Array<String> = [];
		for (child in node.children) {
			final span: Null<Span> = child.span;
			if (span == null) return null;
			out.push(hit.source.substring(span.from, span.to).trim());
		}
		return out;
	}

	private static function nodeAt(node: QueryNode, at: Span): Null<QueryNode> {
		final span: Null<Span> = node.span;
		return span != null && span.from == at.from && span.to == at.to && node.children.length > 0
			? node
			: node.children.findMap(child -> nodeAt(child, at));
	}

}
