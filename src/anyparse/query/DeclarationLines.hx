package anyparse.query;

import anyparse.query.LexicalRegions;
import anyparse.runtime.LineIndex;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Which declaration owns each line of a file: a named node with at most one named ancestor (none below a module-level
 * value declaration) owns the lines it spans, the innermost one winning, and the blank, comment and annotation lines
 * right above it. What `DeclarationDelta` compares two versions by and `StructuralMerge` merges three by.
 */
@:nullSafety(Strict)
final class DeclarationLines {

	/** How many named ancestors a declaration may have. */
	private static inline final NAMED_DEPTH: Int = 1;

	/**
	 * The lines of `source`, read with `plugin`, each assigned to the declaration that owns it; null when it does not parse.
	 */
	public static function versionOf(plugin: GrammarPlugin, source: String): Null<FileVersion> {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: Exception) return null;
		final index: LineIndex = new LineIndex(source);
		final units: Array<OwnerUnit> = [];
		collectUnits(tree, -1, '', {
			valueKinds: plugin.refShape().moduleValueDeclKinds,
			metaKinds: plugin.metaShape().metaKinds,
			lineIndex: index,
			out: units
		});
		final text: Array<String> = lines(source);
		final starts: Array<Int> = [];
		var offset: Int = 0;
		for (line in text) {
			starts.push(offset);
			offset += line.length + 1;
		}
		final comment: Array<Bool> = commentLines(plugin.lexicalRegions(source), text, starts, index);
		final owner: Array<Int> = [for (_ in text) -1];
		for (i => unit in units) for (line in unit.first ... unit.last + 1) if (owner[line] == unit.parent) owner[line] = i;
		// a line above a declaration that nothing else holds is the declaration's while it is a blank, a comment or an
		// annotation; a line of code punctuation — a closing brace — ends the run
		for (i => unit in units) {
			final floor: Int = unit.parent < 0 ? -1 : units[unit.parent].first;
			var line: Int = unit.first - 1;
			while (line > floor && owner[line] == unit.parent && (comment[line] || text[line].trim() == '' || carriesWords(text[line]))) {
				owner[line] = i;
				line--;
			}
		}
		final owned: Array<Array<String>> = [for (_ in units) []];
		final rest: Array<String> = [];
		for (line => holder in owner) if (holder < 0)
			rest.push(text[line])
		else
			owned[holder].push(text[line]);
		return {
			source: source,
			tree: tree,
			lines: text,
			starts: starts,
			units: units,
			owner: owner,
			owned: owned,
			rest: rest
		};
	}

	public static function lines(text: String): Array<String> {
		return text.length == 0 ? [] : text.split('\n');
	}

	/**
	 * Whether `line` holds an identifier character — a line of punctuation alone, a closing brace, holds none.
	 */
	public static function carriesWords(line: String): Bool {
		for (i in 0...line.length) if (SourceText.isIdentChar(line.fastCodeAt(i))) return true;
		return false;
	}

	/** For each line, whether it opens inside a comment — a doc block's every line, its close included. */
	private static function commentLines(
		regions: Array<LexRegion>, text: Array<String>, starts: Array<Int>, index: LineIndex
	): Array<Bool> {
		final out: Array<Bool> = [for (_ in text) false];
		for (region in regions) if (region.kind == LexRegionKind.LineComment || region.kind == LexRegionKind.BlockComment) {
			final last: Int = index.lineColAt(region.to > region.from ? region.to - 1 : region.from).line - 1;
			for (line in index.lineColAt(region.from).line - 1...last + 1) {
				final first: Int = starts[line] + (text[line].length - text[line].ltrim().length);
				if (first >= region.from && first < region.to) out[line] = true;
			}
		}
		return out;
	}

	private static function collectUnits(node: QueryNode, parent: Int, parentKey: String, scan: UnitScan): Void {
		for (child in node.children) {
			// an annotation is no declaration of its own: its lines go to the declaration it precedes
			if (scan.metaKinds.contains(child.kind)) continue;
			final name: Null<String> = child.name;
			final span: Null<Span> = child.span;
			if (name == null || span == null) {
				collectUnits(child, parent, parentKey, scan);
				continue;
			}
			final first: Int = scan.lineIndex.lineColAt(span.from).line - 1;
			// a name on its declaration's own first line — a supertype, a type parameter — is part of that declaration
			if (parent >= 0 && first == scan.out[parent].first) continue;
			final depth: Int = parent < 0 ? 0 : scan.out[parent].depth + 1;
			final key: String = parentKey == '' ? name : '$parentKey.$name';
			final index: Int = scan.out.length;
			scan.out.push({
				node: child,
				key: key,
				header: ModuleScan.IMPORT_DECL_KINDS.contains(child.kind) || ModuleScan.PACKAGE_DECL_KINDS.contains(child.kind),
				depth: depth,
				parent: parent,
				first: first,
				last: scan.lineIndex.lineColAt(span.to > span.from ? span.to - 1 : span.from).line - 1
			});
			if (depth < NAMED_DEPTH && !scan.valueKinds.contains(child.kind)) collectUnits(child, index, key, scan);
		}
	}

}

/** One version of a file as the writer emits it, each line assigned to the declaration that owns it. */
typedef FileVersion = {
	final source: String;
	final tree: QueryNode;
	final lines: Array<String>;

	/** The offset each line starts at. */
	final starts: Array<Int>;

	final units: Array<OwnerUnit>;

	/** Per line, the index of the unit owning it, or -1. */
	final owner: Array<Int>;

	/** Per unit, the lines it owns. */
	final owned: Array<Array<String>>;

	/** The lines no declaration owns. */
	final rest: Array<String>;
}

/** A named node that owns lines of its file. */
typedef OwnerUnit = {
	final node: QueryNode;
	final key: String;
	final header: Bool;
	final depth: Int;
	final parent: Int;
	final first: Int;
	final last: Int;
}

/** What the declaration walk carries down the tree. */
typedef UnitScan = {
	final valueKinds: Array<String>;
	final metaKinds: Array<String>;
	final lineIndex: LineIndex;
	final out: Array<OwnerUnit>;
}
