package anyparse.check;

import anyparse.check.Check.CrossFileEdits;
import anyparse.query.CondRegionScan;
import anyparse.query.FieldRefScan;
import anyparse.query.GrammarPlugin;
import anyparse.query.OccurrenceScan;
import anyparse.query.QueryNode;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Who ELSE touches the backing field — every reference outside the accessor pair the
 * `trivial-getter` collapse is about to delete, and whether the collapse can handle each one.
 *
 * One question asked twice, at two ranges, because the collapse changes what a reference MEANS
 * in two different ways:
 *
 * - INSIDE the owner class, a surviving write to the field becomes a write through the property,
 *   which on a `(default, set)` collapse would route through the kept setter. `collectExternalWrites`
 *   finds the statement-level writes that `applyBypassMarks` can annotate `@:bypassAccessor`
 *   (restoring the direct physical write exactly), `countExternalWrites` counts what a bail must
 *   report, and `hasExternalRead` gates the mirror-image `(get, default)` collapse, where a
 *   surviving READ would newly route through the kept getter.
 * - OUTSIDE it, in a subtype's own file or in a file granting itself `@:access(owner)`, the field
 *   is simply gone. `crossFileReadRewrite` attributes every occurrence of the name in those files
 *   to a binding and either rewrites it, excludes it, or refuses the whole collapse — the
 *   completeness gate is the point, so an occurrence nobody could attribute BLOCKS rather than
 *   being skipped.
 *
 * The bias is the same on both sides and it is not symmetric with the check's other gates: this
 * module refuses on doubt. An occurrence it cannot bind, a write it cannot mark, a receiver shape
 * it cannot resolve — each costs one missed collapse, while admitting it costs a silently wrong
 * rewrite in someone else's file.
 */
@:nullSafety(Strict)
final class BackingFieldRefs {

	/**
	 * Whether `node`'s subtree contains a READ of `field` outside `exclude` (the kept getter).
	 * After the `(get, set)` -> `(get, default)` collapse, reading the property routes through the
	 * non-trivial `get_field` EVERYWHERE except inside `get_field` itself (there the property is a
	 * direct physical read, since the `default` write forces physical storage), so a backing-field
	 * read outside the getter, once renamed to the property name, would newly route through the
	 * real getter -- a behavior change. Writes are direct (`default` write) and never gate.
	 *
	 * A bare `field` / `this.field` that is the TARGET of a plain `=` is a pure write, not a read,
	 * so its RHS is scanned but the target itself is not. A compound-assignment / incr / decr
	 * target IS a read (`x += 1` compiles to `x = get_x() + 1`), so it disqualifies. Every other
	 * `field` occurrence (RHS, call arg, `arr[field]` index, plain read) is a read.
	 */
	public static function hasExternalRead(node: QueryNode, field: String, exclude: Span): Bool {
		final span: Null<Span> = node.span;
		if (span != null && span.from >= exclude.from && span.to <= exclude.to) return false;
		if (node.kind == 'Plain') return false;
		if (FieldRefScan.writeTargetField(node) == field) {
			if (node.kind != 'Assign') return true;
			for (i in 1...node.children.length) if (hasExternalRead(node.children[i], field, exclude)) return true;
			return false;
		}
		return FieldRefScan.fieldRefName(node) == field || node.children.exists(child -> hasExternalRead(child, field, exclude));
	}

	/**
	 * Prefix each statement-level bypass write in `bypassStmts` with `@:bypassAccessor ` — on the
	 * collapsed `(default, set)` property such a write is a DIRECT physical field write, so the
	 * marker preserves the pre-collapse semantics exactly. When a backing-field rename already
	 * replaces the statement's first token (a bare `_x` write target, at the same offset), the
	 * marker is FOLDED into that rename's replacement text instead of emitted as a separate
	 * zero-width edit — a zero-width insert coinciding with the rename's start is dropped by
	 * `dropContainedEdits`. A `this._x` write starts before its renamed name token, so its marker
	 * is a standalone insert. Returns false only on an unspanned statement the fix cannot place.
	 */
	public static function applyBypassMarks(bypassStmts: Array<QueryNode>, edits: Array<{ span: Span, text: String }>): Bool {
		for (stmt in bypassStmts) {
			final span: Null<Span> = stmt.span;
			if (span == null) return false;
			final at: Int = span.from;
			final folded: Null<{ span: Span, text: String }> = edits.find(e -> e.span.from == at && e.span.to > at);
			if (folded != null)
				folded.text = '@:bypassAccessor ${folded.text}';
			else
				edits.push({ span: new Span(at, at), text: '@:bypassAccessor ' });
		}
		return true;
	}

	/**
	 * The statement-level external writes to `field` in `node`'s subtree, outside `exclude` (the
	 * kept setter) and the `allowStmt` subtree (a relocatable constructor-init statement) — each an
	 * `ExprStmt` whose single child writes `field` (`writeTargetField`, bare or `this.`). Null the
	 * moment a write to `field` appears NOT in statement position (nested inside a larger
	 * expression, e.g. `if ((_x = v)) ...`): such a write cannot be marked `@:bypassAccessor`, so
	 * the caller must fall back to inlining the getter rather than collapsing.
	 */
	public static function collectExternalWrites(
		node: QueryNode, field: String, exclude: Span, allowStmt: Null<QueryNode>
	): Null<Array<QueryNode>> {
		final out: Array<QueryNode> = [];
		return collectExternalWritesInto(node, field, exclude, allowStmt, out) ? out : null;
	}

	/**
	 * The total number of writes to `field` in `node`'s subtree, at ANY expression position, outside
	 * `exclude` and the `allowStmt` subtree — the count the inline-fallback message reports (the
	 * statement-level list of `collectExternalWrites` is null when it bails, so the message uses this
	 * position-agnostic count instead).
	 */
	public static function countExternalWrites(node: QueryNode, field: String, exclude: Span, allowStmt: Null<QueryNode>): Int {
		final span: Null<Span> = node.span;
		if (span != null && span.from >= exclude.from && span.to <= exclude.to) return 0;
		if (node == allowStmt) return 0;
		var n: Int = FieldRefScan.writeTargetField(node) == field ? 1 : 0;
		for (c in node.children) n += countExternalWrites(c, field, exclude, allowStmt);
		return n;
	}

	/**
	 * The per-file read-rewrite slices for every strict subtype of `owner` that READS the backing
	 * field `field`, or null when the cross-file collapse cannot be proven safe. Enumerates the
	 * transitive-subtype declaring files plus `@:access(owner)` grant files; in each, attributes
	 * every occurrence of `field` (`collectSubtypeFieldRefs`) and gates the remainder through
	 * `classifyOccurrences` (ConditionalRaw / StringLiteral / DirectiveComment / uncovered ActiveCode
	 * block; a distinctive comment mention renames along). The owner's declaring file is scanned too
	 * (its owner-class occurrences excluded — `buildFix` owns them) so a same-file sibling subtype is
	 * handled. An empty result (no subtype reads) means the collapse is safe with no subtype edits.
	 */
	public static function crossFileReadRewrite(
		owner: String, field: String, propName: String, ownerFile: String, index: SymbolIndex, sourceByFile: Map<String, String>,
		plugin: GrammarPlugin
	): Null<Array<CrossFileEdits>> {
		final distinctive: Bool = isDistinctiveName(field);
		final slices: Array<CrossFileEdits> = [];
		for (file in affectedSubtypeFiles(owner, index)) {
			final source: Null<String> = sourceByFile[file];
			if (source == null) return null;
			final src: String = source;
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, src);
			if (tree == null) return null;
			final refs: Null<{ renameEdits: Array<{ span: Span, text: String }>, excludeSpans: Array<Span> }> = collectSubtypeFieldRefs(
				tree, field, owner, propName, index, src, file == ownerFile
			);
			if (refs == null) return null;
			final excluded: Array<Span> = [for (e in refs.renameEdits) e.span];
			for (s in refs.excludeSpans) excluded.push(s);
			// A `package` / `import` path is a dotted module path, not a reference to the field —
			// same reading as `Naming`'s collectors.
			for (s in OccurrenceScan.modulePathSpans(tree, plugin.refShape())) excluded.push(s);
			final classified: Null<Array<ClassifiedOccurrence>> = OccurrenceScan.classifyOccurrences(
				src, field, plugin, 0, src.length, excluded
			);
			final edits: Array<{ span: Span, text: String }> = refs.renameEdits.copy();
			if (classified == null) {
				if (OccurrenceScan.referencedInRange(src, field, 0, src.length, excluded)) return null;
			} else
				for (occ in classified) switch occ.kind {
					case OccurrenceClass.CommentTrivia if (distinctive):
						edits.push({ span: occ.span, text: propName });
					// Neither renamed nor a blocker: a word inside a longer literal is prose, and a
					// non-distinctive comment mention cannot make the collapse unsafe.
					case OccurrenceClass.StringWord, OccurrenceClass.CommentTrivia:
					case _:
						return null;
				}
			if (edits.length > 0) slices.push({ file: file, edits: edits });
		}
		return slices;
	}

	/**
	 * Recursive worker of `collectExternalWrites`: appends each statement-level write of `field` to
	 * `out` and returns true, or returns false the moment a write to `field` sits in a non-statement
	 * position. A subtree inside `exclude` or equal to `allowStmt` is skipped. A statement-level
	 * write's own RHS is still scanned (its write target aside), so a nested write there is caught.
	 */
	private static function collectExternalWritesInto(
		node: QueryNode, field: String, exclude: Span, allowStmt: Null<QueryNode>, out: Array<QueryNode>
	): Bool {
		final span: Null<Span> = node.span;
		if (span != null && span.from >= exclude.from && span.to <= exclude.to) return true;
		if (node == allowStmt) return true;
		if (node.kind == 'ExprStmt' && node.children.length == 1 && FieldRefScan.writeTargetField(node.children[0]) == field) {
			out.push(node);
			return node.children[0].children.foreach(c -> collectExternalWritesInto(c, field, exclude, allowStmt, out));
		}
		return FieldRefScan.writeTargetField(node) != field
			&& node.children.foreach(c -> collectExternalWritesInto(c, field, exclude, allowStmt, out));
	}

	/**
	 * Whether `name` is distinctive enough (an underscore or an uppercase letter) that a
	 * word-boundary comment mention is unlikely to be prose — a backing field like `_x` is, so its
	 * comment mentions rename along with the code on a cross-file collapse.
	 */
	private static function isDistinctiveName(name: String): Bool {
		for (i in 0...name.length) {
			final code: Int = name.fastCodeAt(i);
			if (code == '_'.code || (code >= 'A'.code && code <= 'Z'.code)) return true;
		}
		return false;
	}

	/**
	 * Every report file that may reference `owner`'s backing field through inheritance: the
	 * declaring file of each TRANSITIVE subtype of `owner` (`SubtypeGraph.subtypeFiles`), plus
	 * every file granting itself `@:access(owner)`. Deduped, in discovery order.
	 *
	 * The closure is the index's own subtype adjacency, not a `supertypes.contains(parent)` scan
	 * of its own. Asking the same question a second way is what broke this: the private
	 * scan could not follow an `import p.Owner as O;` supertype alias, so `class Child extends O`
	 * was not an affected file, only the owner was rewritten, and the collapse left the subtype
	 * naming a field that no longer existed (`Unknown identifier : _v`) — while `subtypeBlocks` /
	 * `subtypeFieldBlocks`, which go through the index, saw that subtype perfectly well on the
	 * same tree. Reaching the file is not the same as rewriting it: the occurrence there is
	 * attributed through `isSubtype`, whose UPWARD walk cannot resolve the alias either, so the
	 * completeness gate now refuses the collapse instead of half-applying it.
	 */
	private static function affectedSubtypeFiles(owner: String, index: SymbolIndex): Array<String> {
		final out: Array<String> = index.subtypes.subtypeFiles(owner);
		for (fi in index.allFiles()) if (fi.accessGrants.contains(owner) && !out.contains(fi.file)) out.push(fi.file);
		return out;
	}

	/** The `field` token offset inside a `this.`/`super.` field access `node` (`span` its whole access), or -1 for any other receiver shape. */
	private static function fieldAccessTokenOffset(node: QueryNode, span: Span, source: String, field: String): Int {
		if (node.children.length != 1) return -1;
		final recv: QueryNode = node.children[0];
		final recvSpan: Null<Span> = recv.span;
		return recv.kind == 'IdentExpr' && (recv.name == 'this' || recv.name == 'super') && recvSpan != null
			? SourceText.identTokenOffset(source, new Span(recvSpan.to, span.to), field)
			: -1;
	}

	/**
	 * Classify an owner-attributed occurrence at `off` by its enclosing class `cls`: an occurrence in
	 * the OWNER class (only when its file is scanned) is excluded (`buildFix` rewrites it); a strict
	 * subtype's READ is a rename edit (`_x` -> `x`, or `this.x` under a prop-name shadow when the ref
	 * is a bare identifier), a strict subtype's WRITE returns false (block — the collapsed setter
	 * would intercept it); an occurrence in a class that declares `field` itself or inherits it from a
	 * non-owner supertype is excluded; any other (unresolvable) class leaves it uncovered so the
	 * completeness gate blocks. `bareIdent` distinguishes a bare identifier (shadow-qualifiable) from
	 * a `this.`/`super.` field-token rewrite (already receiver-qualified).
	 */
	private static function classifyOwnerBinding(
		off: Int, bareIdent: Bool, owner: String, field: String, propName: String, index: SymbolIndex, ownerFileScan: Bool,
		cls: Null<String>, writePos: Bool, shadowsProp: Bool, renameEdits: Array<{ span: Span, text: String }>, excludeSpans: Array<Span>
	): Bool {
		if (cls == null) return true;
		final c: String = cls;
		if (ownerFileScan && c == owner) {
			excludeSpans.push(new Span(off, off + field.length));
			return true;
		}
		if (index.subtypes.isSubtype(c, owner) && !index.members.typeDeclaresMember(c, field)) {
			if (writePos) return false;
			renameEdits.push({ span: new Span(off, off + field.length), text: bareIdent && shadowsProp ? 'this.$propName' : propName });
			return true;
		}
		if (index.members.typeDeclaresMember(c, field) || index.members.supertypeDeclaresMember(c, field))
			excludeSpans.push(new Span(off, off + field.length));
		return true;
	}

	/**
	 * Attribute ONE occurrence node whose name is `field`: a bare `IdentExpr` or a `this.`/`super.`
	 * `FieldAccess` is bound by its enclosing `cls` (`classifyOwnerBinding`); any other shape (typed
	 * receiver, interpolation, pattern) is left uncovered (returns true without recording, so the
	 * completeness gate blocks). Returns false only on an owner-bound WRITE.
	 */
	private static function attributeOccurrence(
		node: QueryNode, field: String, owner: String, propName: String, index: SymbolIndex, source: String, ownerFileScan: Bool,
		cls: Null<String>, writePos: Bool, shadowsProp: Bool, renameEdits: Array<{ span: Span, text: String }>, excludeSpans: Array<Span>
	): Bool {
		final span: Null<Span> = node.span;
		if (span == null) return true;
		final off: Int = switch node.kind {
			case 'IdentExpr': SourceText.identTokenOffset(source, span, field);
			case 'FieldAccess': fieldAccessTokenOffset(node, span, source, field);
			case _: -1;
		}
		return off < 0
			|| classifyOwnerBinding(
				off, node.kind == 'IdentExpr', owner, field, propName, index, ownerFileScan, cls, writePos, shadowsProp, renameEdits,
				excludeSpans
			);
	}

	/**
	 * Recursive worker of `collectSubtypeFieldRefs`: walks `node` tracking the enclosing class
	 * (`cls`), whether the node sits in the WRITE-target position of its parent (`writePos`), and
	 * whether an enclosing function binds `propName` (`shadowsProp`, so a bare rewritten read is
	 * qualified `this.propName`). `#if...#end` interiors are not descended (they stay `ConditionalRaw`
	 * for the completeness gate). Returns false on the first owner-bound WRITE.
	 */
	private static function subtypeRefWalk(
		node: QueryNode, field: String, owner: String, propName: String, index: SymbolIndex, source: String, ownerFileScan: Bool,
		cls: Null<String>, writePos: Bool, shadowsProp: Bool, renameEdits: Array<{ span: Span, text: String }>, excludeSpans: Array<Span>
	): Bool {
		if (CondRegionScan.isConditionalKind(node.kind)) return true;
		final isClass: Bool = CheckScan.isClassBodyKind(node.kind);
		// The owner's own class is rewritten wholesale by `buildFix`; exclude its whole span from the
		// completeness scan and stop descending, so a same-file sibling subtype is still walked.
		if (ownerFileScan && isClass && node.name == owner) {
			final ownerSpan: Null<Span> = node.span;
			if (ownerSpan != null) excludeSpans.push(ownerSpan);
			return true;
		}
		final cls2: Null<String> = isClass && node.name != null ? node.name : cls;
		if (
			node.name == field
			&& !attributeOccurrence(
				node, field, owner, propName, index, source, ownerFileScan, cls2, writePos, shadowsProp, renameEdits, excludeSpans
			)
		)
			return false;
		final childShadows: Bool = shadowsProp || (FieldRefScan.isFnScope(node) && FieldRefScan.functionBindsName(node, propName));
		final isWrite: Bool = FieldRefScan.isWriteNodeKind(node.kind);
		for (i in 0...node.children.length) if (!subtypeRefWalk(
			node.children[i], field, owner, propName, index, source, ownerFileScan, cls2, isWrite && i == 0, childShadows, renameEdits,
			excludeSpans
		))
			return false;
		return true;
	}

	/**
	 * Attribute every occurrence of `field` in one file's `tree` into `renameEdits` (owner-bound
	 * subtype READS, `_x` -> `x`) and `excludeSpans` (owner-class / different-owner occurrences the
	 * completeness gate must ignore). Null on the first owner-bound WRITE (`subtypeRefWalk` bails).
	 * `ownerFileScan` marks the owner's own file, whose owner-class occurrences are excluded because
	 * `buildFix` rewrites them.
	 */
	private static function collectSubtypeFieldRefs(
		tree: QueryNode, field: String, owner: String, propName: String, index: SymbolIndex, source: String, ownerFileScan: Bool
	): Null<{ renameEdits: Array<{ span: Span, text: String }>, excludeSpans: Array<Span> }> {
		final renameEdits: Array<{ span: Span, text: String }> = [];
		final excludeSpans: Array<Span> = [];
		return subtypeRefWalk(tree, field, owner, propName, index, source, ownerFileScan, null, false, false, renameEdits, excludeSpans) ? {
			renameEdits: renameEdits,
			excludeSpans: excludeSpans
		} : null;
	}

}
