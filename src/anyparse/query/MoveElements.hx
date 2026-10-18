package anyparse.query;

import anyparse.query.Address.AddressSpec;
import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.runtime.Span;
import haxe.crypto.Md5;
import haxe.ds.Either;

using Lambda;
using StringTools;

/**
 * `move-elements` — move a contiguous SLICE of one array literal's elements into another array literal, in
 * another member or another module, keeping their order and text: the split a long hand-kept list takes when it
 * is cut into parts (N42 cut a 3500-entry pin census into four modules with a script; this is that cut as an op).
 *
 * The source is an array literal (or a declaration initialised with one) and a 1-based inclusive element range;
 * the target is another array, given by a selector or pattern — never a position, because it is re-resolved after
 * the cut — and receives the slice the way `add-element` gives it: appended in order (`AddElement.appendElement`)
 * or, for a sorted string list, each entry at its sorted place (`AddElement.insertSorted`, with every refusal of
 * that mode). The slice is cut with its separators (`ElementSpan.commaListCut`) and a leading `/**` doc travels
 * with its first element; the writer formats both files.
 *
 * ## What may move — a positive whitelist
 *
 * An element that reads a name (`ExtractConstantTo.firstContextRead`: a local, `this`, a member, an interpolated
 * name) would read something else, or nothing, in the target's scope, and is refused. Across modules an element
 * that names a type the destination may not see (`ExtractConstantTo.firstUnseenType`) is refused too. The source
 * and target arrays may not be one array, nor nest in each other.
 *
 * ## Digest-safe
 *
 * Before anything is handed back the result is CHECKED, not trusted: the source array, found again, must hold
 * exactly its old entries without the slice, and the target its old entries plus the slice (in order for an
 * append, as a multiset for a sorted insert). Entries compare by their source text with whitespace runs collapsed
 * (`entryText`), and the moved entries' digest is the MD5 of those texts joined by newlines — what the CLI's
 * `--dry-run` prints, so a caller can check a split mechanically.
 */
@:nullSafety(Strict)
final class MoveElements {

	/**
	 * Move the slice `request` describes. Returns the new source, the new destination text (null when the target
	 * array is in the source file), the moved entries and their digest, or an `Err` naming why nothing moves.
	 */
	public static function moveElements(request: MoveElementsRequest, plugin: GrammarPlugin): MoveElementsResult {
		final plan: MovePlan = switch planOf(request, plugin) {
			case Left(message): return Err(message);
			case Right(resolved): resolved;
		};
		final source: String = request.source;
		final slice: Span = sliceSpan(source, plan.moved, plugin.lexicalRegions(source));
		final cut: String = switch CanonicalEdit.canonicalize(
			source, [{ span: ElementSpan.commaListCut(source, slice), text: '' }], request.reformat, plugin, request.optsJson
		) {
			case Ok(text, _): text;
			case Err(message): return Err(message);
		};
		final destBefore: String = request.destSource ?? cut;
		final destOpts: Null<String> = request.destSource == null ? request.optsJson : request.destOptsJson;
		final targetBefore: QueryNode = switch targetIn(destBefore, request.target, plugin) {
			case Left(message): return Err(message);
			case Right(found): found;
		};
		final inserted: String = switch insertInto(
			destBefore, spanOf(targetBefore).from, source.substring(slice.from, slice.to), request.sorted, request.reformat, plugin,
			destOpts
		) {
			case Ok(text, _): text;
			case Err(message): return Err(message);
		};
		final entries: Array<String> = [for (e in plan.moved) entryText(e, source)];
		final check: MoveCheck = {
			oldSource: [for (e in plan.array.children) entryText(e, source)],
			oldTarget: [for (e in plan.target.children) entryText(e, plan.destOriginal)],
			sourceFrom: spanOf(plan.array).from,
			targetFrom: spanOf(targetBefore).from
		};
		final failure: Null<String> = verify(request, check, entries, cut, inserted, plugin);
		if (failure != null) return Err('the result failed its own check, nothing written: $failure');
		final newDest: Null<String> = request.destSource == null ? null : inserted;
		return Ok(request.destSource == null ? inserted : cut, newDest, entries, digestOf(entries));
	}

	/** The digest of moved `entries`: the MD5 of their `entryText`s joined by newlines. */
	public static function digestOf(entries: Array<String>): String {
		return Md5.encode(entries.join('\n'));
	}

	/** An element's source text with every whitespace run collapsed to one space — the form entries compare in. */
	public static function entryText(element: QueryNode, source: String): String {
		final span: Span = spanOf(element);
		return ~/\s+/g.replace(source.substring(span.from, span.to), ' ').trim();
	}

	/**
	 * Why the result does not hold what the move promised, or null: the source array (found again in `cut`) must
	 * be its old entries without the slice, the target (found again in `inserted`) its old entries plus the slice.
	 */
	public static function verify(
		request: MoveElementsRequest, check: MoveCheck, entries: Array<String>, cut: String, inserted: String, plugin: GrammarPlugin
	): Null<String> {
		final sourceAfter: Null<Array<String>> = entriesAfter(cut, request.address, check.sourceFrom, plugin);
		final expectedSource: Array<String> = check.oldSource.slice(0, request.first - 1).concat(check.oldSource.slice(request.last));
		if (sourceAfter == null || !sameSequence(sourceAfter, expectedSource))
			return 'the source array does not hold its old entries without the slice';
		final targetAfter: Null<Array<String>> = entriesAfter(inserted, request.target, check.targetFrom, plugin);
		final expectedTarget: Array<String> = check.oldTarget.concat(entries);
		if (targetAfter == null) return 'the target array cannot be found again';
		if (!request.sorted)
			return sameSequence(targetAfter, expectedTarget) ? null : 'the target array does not end with the slice, in order';
		final got: Array<String> = targetAfter.copy();
		final want: Array<String> = expectedTarget.copy();
		got.sort(Reflect.compare);
		want.sort(Reflect.compare);
		return sameSequence(got, want) ? null : 'the target array does not hold its old entries plus the slice';
	}

	/** A spanned node's span — every node this op reads came out of a parse of real source. */
	private static inline function spanOf(node: QueryNode): Span {
		return node.span ?? new Span(0, 0);
	}

	/** Whether `a` and `b` are one node or one's span holds the other's. */
	private static inline function nests(a: QueryNode, b: QueryNode): Bool {
		final sa: Span = spanOf(a);
		final sb: Span = spanOf(b);
		return (sa.from <= sb.from && sb.to <= sa.to) || (sb.from <= sa.from && sa.to <= sb.to);
	}

	/**
	 * What `request` moves, resolved in the ORIGINAL texts — the source array, the slice, the target array — or `Left`
	 * naming the refusal: a target position, an address naming no array, a range outside it, an element that may not
	 * leave (`elementRefusal`), or source and target that are one array or nest.
	 */
	private static function planOf(request: MoveElementsRequest, plugin: GrammarPlugin): Either<String, MovePlan> {
		if (request.target.at != null) return Left('address the target array by --select / --match — a position does not survive the cut');
		final source: String = request.source;
		final tree: QueryNode = switch ParseGate.parse(plugin, source, request.sourceFile) {
			case Unparsed(message): return Left(message);
			case Parsed(parsed): parsed;
		};
		final array: QueryNode = switch arrayAt(tree, source, plugin, request.address, 'source') {
			case Left(message): return Left(message);
			case Right(found): found;
		};
		final elements: Array<QueryNode> = array.children;
		if (request.first < 1 || request.last < request.first || request.last > elements.length)
			return Left('range ${request.first}..${request.last} is outside the ${elements.length} element(s) of the source array');
		final moved: Array<QueryNode> = elements.slice(request.first - 1, request.last);
		final refusal: Null<String> = elementRefusal(moved, request.first, request.destSource != null, plugin);
		if (refusal != null) return Left(refusal);
		final destOriginal: String = request.destSource ?? source;
		final destTree: QueryNode = if (request.destSource == null)
			tree
		else
			switch ParseGate.parse(plugin, destOriginal, 'destination') {
				case Unparsed(message): return Left(message);
				case Parsed(parsed): parsed;
			};
		final target: QueryNode = switch arrayAt(destTree, destOriginal, plugin, request.target, 'target') {
			case Left(message): return Left(message);
			case Right(found): found;
		};
		return request.destSource == null && nests(array, target)
			? Left('the target array is the source array or nests with it')
			: Right({
				array: array,
				moved: moved,
				target: target,
				destOriginal: destOriginal
			});
	}

	/**
	 * The array literal `spec` names in `tree` — the node itself, or the initializer of a declaration it names —
	 * or `Left` naming what it names instead. `role` says which address failed.
	 */
	private static function arrayAt(
		tree: QueryNode, source: String, plugin: GrammarPlugin, spec: AddressSpec, role: String
	): Either<String, QueryNode> {
		final node: Null<QueryNode> = switch Address.resolve(tree, source, plugin, spec) {
			case Ok(_, resolved): resolved;
			case Err(message): return Left('$role: $message');
		};
		if (node == null) return Left('$role: the address resolves to no node');
		final arrayKind: Null<String> = plugin.refShape().arrayLiteralKind;
		if (arrayKind == null) return Left('the grammar names no array literal');
		if (node.kind == arrayKind) return Right(node);
		final last: Null<QueryNode> = node.children.length == 0 ? null : node.children[node.children.length - 1];
		return last != null && last.kind == arrayKind
			? Right(last)
			: Left('$role: the address names a ${node.kind}, not an array literal (or a declaration initialised with one)');
	}

	/** Why one of the `moved` elements (the first at 1-based `first`) may not leave its array, or null. */
	private static function elementRefusal(moved: Array<QueryNode>, first: Int, crossModule: Bool, plugin: GrammarPlugin): Null<String> {
		final shape: RefShape = plugin.refShape();
		for (i => element in moved) {
			final read: Null<QueryNode> = ExtractConstantTo.firstContextRead(element, shape);
			if (read != null)
				return 'element ${first + i} reads `${read.name ?? read.kind}` — a moved element must not read a local, `this` or a member';
			final unseen: Null<String> = crossModule ? ExtractConstantTo.firstUnseenType(element, plugin) : null;
			if (unseen != null) return 'element ${first + i} names the type `$unseen`, which the destination module may not see';
		}
		return null;
	}

	/** The slice's span: from its first element (with that element's leading `/**` doc) to its last element's end. */
	private static function sliceSpan(source: String, moved: Array<QueryNode>, regions: Array<LexRegion>): Span {
		final from: Int = ElementSpan.docExtendedSpan(source, spanOf(moved[0]), regions, true).from;
		return new Span(from, spanOf(moved[moved.length - 1]).to);
	}

	/** The target array `target` names in `destSource` — the text the slice is inserted into, after the cut when it is the source. */
	private static function targetIn(destSource: String, target: AddressSpec, plugin: GrammarPlugin): Either<String, QueryNode> {
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, destSource);
		return tree == null ? Left('the destination does not parse after the cut') : arrayAt(tree, destSource, plugin, target, 'target');
	}

	/** Hand `sliceText` to the target array starting at `from` in `destSource`: appended, or sorted in. */
	private static function insertInto(
		destSource: String, from: Int, sliceText: String, sorted: Bool, reformat: Bool, plugin: GrammarPlugin, optsJson: Null<String>
	): EditResult {
		final pos: Position = new Span(from, from).lineCol(destSource);
		return sorted
			? AddElement.insertSorted(destSource, pos.line, pos.col, sliceText, reformat, plugin, optsJson)
			: AddElement.appendElement(destSource, pos.line, pos.col, sliceText, reformat, plugin, optsJson);
	}

	/**
	 * The entries of the array `spec` names in `text`, found again after an edit — by the address, else (a pattern
	 * that matched the old content no longer matches) as the array literal starting at `from`. Null when neither.
	 */
	private static function entriesAfter(text: String, spec: AddressSpec, from: Int, plugin: GrammarPlugin): Null<Array<String>> {
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, text);
		if (tree == null) return null;
		final array: Null<QueryNode> = switch arrayAt(tree, text, plugin, spec, 'check') {
			case Right(found): found;
			case Left(_): arrayStartingAt(tree, from, plugin.refShape().arrayLiteralKind);
		};
		return array == null ? null : [for (e in array.children) entryText(e, text)];
	}

	/** The array literal starting at `from` in `tree`, or null. */
	private static function arrayStartingAt(tree: QueryNode, from: Int, arrayKind: Null<String>): Null<QueryNode> {
		if (tree.kind == arrayKind && tree.span?.from == from) return tree;
		for (child in tree.children) {
			final hit: Null<QueryNode> = arrayStartingAt(child, from, arrayKind);
			if (hit != null) return hit;
		}
		return null;
	}

	/** Whether `a` and `b` hold the same strings in the same order. */
	private static function sameSequence(a: Array<String>, b: Array<String>): Bool {
		if (a.length != b.length) return false;
		for (i => s in a) if (s != b[i]) return false;
		return true;
	}

}

/** What `MoveElements.moveElements` moves: the source array and its 1-based inclusive range, the target array. */
typedef MoveElementsRequest = {
	final source: String;
	final sourceFile: String;
	final address: AddressSpec;
	final first: Int;
	final last: Int;

	/** The destination file's source, or null when the target array is in the source file. */
	final destSource: Null<String>;

	/** The target array — a selector or pattern, never a position. */
	final target: AddressSpec;

	/** Insert each entry at its sorted place (`AddElement.insertSorted`) instead of appending the slice. */
	final sorted: Bool;
	final reformat: Bool;
	final optsJson: Null<String>;
	final destOptsJson: Null<String>;
}

/** The result of `MoveElements.moveElements`: both new texts (dest null = the source file), the moved entries, their digest. */
enum MoveElementsResult {

	Ok(source: String, dest: Null<String>, entries: Array<String>, digest: String);
	Err(message: String);

}

/** What `verify` compares the result against: the old entries of both arrays and where the arrays start. */
typedef MoveCheck = {
	final oldSource: Array<String>;
	final oldTarget: Array<String>;
	final sourceFrom: Int;
	final targetFrom: Int;
}

/** What `planOf` resolves: the source array and the moved slice of it, the target array, and the text the target is in. */
private typedef MovePlan = {
	final array: QueryNode;
	final moved: Array<QueryNode>;
	final target: QueryNode;
	final destOriginal: String;
}
