package anyparse.query.merge;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.merge.KeyedMerge.LineMerge;
import anyparse.query.merge.KeyedMerge.MergeChoice;
import anyparse.query.merge.KeyedMerge.MergeConflict;
import anyparse.query.merge.KeyedMerge.MergeOutcome;
import haxe.Exception;

/** How a grammar's files are taken apart for a merge. */
enum MergeShape {
	/** By the declarations that own their lines (`DeclarationTree`): source code. */
	Declarations;

	/** By the members and elements their nodes span (`RecordTree`): a data document. */
	Records;
}

/** The trees of three versions, or why they are not merged by key. */
private enum TreesRead {
	Read(trees: Array<MergeTree>);
	Refused(why: String);
}

/** What `StructuralMerge.merge` makes of three versions of one file. */
enum MergeResult {
	/** The merged text and how the two sides were combined. */
	Merged(text: String, how: Array<String>);

	/** The text with each conflicting place between conflict markers, and the places. */
	Conflicted(text: String, conflicts: Array<MergeConflict>);

	/** A version the grammar does not read, or a merge it cannot read back: a line merge's job. */
	Unreadable(why: String);
}

/**
 * The three-way merge of one file through its grammar, a widening of the caller's line merge: a file that merges clean
 * by lines takes that merge, so the grammar decides only where lines collide. Then, for a file whose layout the writer
 * owns (ours is in its form), all three versions are read as the writer emits them, so a side that changed only layout
 * changed nothing and yields to the other whole; otherwise they are taken apart by `shape` and merged by key
 * (`KeyedMerge`, each colliding place line-merged on its own before it is a conflict), an import only theirs added is
 * placed where the grammar places a fresh one (`AddImport`), and the result is read back by the writer — one that does
 * not parse is `Unreadable`, never a merge. Source with a conditional-compilation line between declarations is left to
 * the line merge: a member's key does not say which branch holds it.
 */
@:nullSafety(Strict)
final class StructuralMerge {

	/**
	 * `base` merged with the changes of `ours` and `theirs`, read with `plugin` as `shape` says and written under the
	 * writer configuration `optsJson`; `choices` settles a conflicting place by its key, and `lineMerge` is the line merge
	 * tried on the whole file first and on each colliding place before it is a conflict.
	 */
	public static function merge(
		plugin: GrammarPlugin, shape: MergeShape, base: String, ours: String, theirs: String, ?optsJson: String,
		?choices: Map<String, MergeChoice>, ?lineMerge: LineMerge
	): MergeResult {
		if (ours == theirs || base == theirs) return Merged(ours, []);
		if (base == ours) return Merged(theirs, []);
		final byLines: Null<String> = lineMerge == null ? null : lineMerge(base, ours, theirs);
		if (byLines != null) return Merged(byLines, ['line merge']);
		final canonBase: Null<String> = canonical(plugin, base, optsJson);
		final canonOurs: Null<String> = canonical(plugin, ours, optsJson);
		final canonTheirs: Null<String> = canonical(plugin, theirs, optsJson);
		if (canonBase == null || canonOurs == null || canonTheirs == null) return Unreadable('a version does not parse');
		// a file whose layout the writer does not own (a fixture kept in a shape on purpose) is not rewritten in its form
		if (canonOurs != ours) return Unreadable('ours is not in the writer\'s form');
		if (canonOurs == canonTheirs) return Merged(canonOurs, ['the sides differ in layout only']);
		if (canonBase == canonTheirs) return Merged(ours, ['theirs changed layout only']);
		if (canonBase == canonOurs) return Merged(theirs, ['ours changed layout only']);
		final trees: Array<MergeTree> = switch treesOf(plugin, shape, [canonBase, canonOurs, canonTheirs]) {
			case Read(read): read;
			case Refused(why): return Unreadable(why);
		};
		final outcome: MergeOutcome = KeyedMerge.merge(trees[0], trees[1], trees[2], choices, lineMerge);
		if (outcome.conflicts.length > 0) return Conflicted(outcome.text, outcome.conflicts);
		var text: String = outcome.text;
		for (seat in outcome.seated) switch AddImport.addImport(text, seat, false, true, plugin, optsJson) {
			case Ok(placed, _):
				text = placed;
			case Err(message):
				return Unreadable('`$seat` found no seat: $message');
		}
		final merged: Null<String> = canonical(plugin, text, optsJson);
		if (merged == null) return Unreadable('the merged text does not parse');
		final how: Array<String> = outcome.notes.copy();
		if (outcome.seated.length > 0) how.push('imports united');
		if (how.length == 0) how.push('declarations merged');
		return Merged(merged, how);
	}

	/** The trees of `sources`, or why they are not merged by key. */
	private static function treesOf(plugin: GrammarPlugin, shape: MergeShape, sources: Array<String>): TreesRead {
		final out: Array<MergeTree> = [];
		for (source in sources) switch shape {
			case Declarations:
				final version: Null<FileVersion> = DeclarationLines.versionOf(plugin, source);
				if (version == null) return Refused('a version does not parse in the writer\'s form');
				final directives: Array<Int> = [
					for (directive in CondDirectives.scan(source, plugin.refShape(), () -> plugin.lexicalRegions(source)))
						directive.span.from
				];
				if (DeclarationTree.conditionalBetween(version, directives))
					return Refused('a conditional-compilation line stands between declarations');
				out.push(DeclarationTree.of(version));
			case Records:
				final root: Null<QueryNode> = try plugin.parseFile(source) catch (exception: Exception) null;
				if (root == null) return Refused('a version does not parse in the writer\'s form');
				out.push(RecordTree.of(source, root));
		}
		return Read(out);
	}

	/** `source` as the writer emits it, or null when it does not parse. */
	private static function canonical(plugin: GrammarPlugin, source: String, optsJson: Null<String>): Null<String> {
		return try plugin.writeRoundTrip(source, optsJson) ?? source catch (exception: Exception) null;
	}

}
