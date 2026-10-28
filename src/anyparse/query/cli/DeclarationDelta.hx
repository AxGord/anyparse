package anyparse.query.cli;

import anyparse.query.Address.AddressIndex;
import anyparse.query.LexicalRegions;
import anyparse.query.LineDiff;
import anyparse.query.ModuleScan;
import anyparse.runtime.LineIndex;
import anyparse.runtime.Span;

using Lambda;

/** How one declaration differs between the base and the working version of a file. */
enum abstract DeclarationStatus(String) to String {
	final Added = '+';
	final Removed = '-';
	final Changed = '~';
}

/** What a file's change amounts to, the cheapest reading first: each class excludes every one above it. */
enum abstract ChangeClass(String) to String {
	final Unchanged = 'unchanged';

	/** The writer emits the same text for both versions: only layout moved. */
	final Layout = 'layout';

	/** Every declaration owns the same lines in both versions; only the module header (package, imports) differs. */
	final Imports = 'imports';

	/** The declarations differ by one consistent identifier substitution and nothing else. */
	final Renamed = 'renamed';

	final Declarations = 'declarations';

	/** A version the grammar does not parse: only a line count is known. */
	final Text = 'text';
}

/** One declaration whose own lines differ, matched across the two versions by its name path, never by its position. */
typedef DeclarationChange = {
	final status: DeclarationStatus;

	/** The dotted name path (`Type.member`); several declarations may share one. */
	final key: String;

	final name: String;

	/** The `--select` address in the version that holds it — the base one for a removed declaration. */
	final selector: String;

	final added: Int;
	final removed: Int;

	/** How many named declarations enclose it: 0 for a module-level one. */
	final depth: Int;

	/** The lines its node spans in the version that holds it. */
	final spanLines: Int;
}

/** One identifier spelled differently at every one of its places. */
typedef Renaming = {
	final from: String;
	final to: String;
}

/** What `DeclarationDelta.compare` reads off two versions of one file. */
typedef FileDelta = {
	final change: ChangeClass;

	/** Header lines (package, import) only the working version has, and only the base has. */
	final headerAdded: Array<String>;

	final headerRemoved: Array<String>;

	/** The header holds the same lines in another order — which, among imports of one simple name, decides the binding. */
	final headerReordered: Bool;

	final renames: Array<Renaming>;
	final declarations: Array<DeclarationChange>;

	/** Changed lines of the whole file, counted on the writer's output where the grammar parses it. */
	final added: Int;

	final removed: Int;
}

/** A named node that owns lines of its file. */
private typedef OwnerUnit = {
	final node: QueryNode;
	final key: String;
	final header: Bool;
	final depth: Int;
	final parent: Int;
	final first: Int;
	final last: Int;
}

/** Lines an edit inserted and deleted. */
private typedef LineCounts = {
	final added: Int;
	final removed: Int;
}

/** What the declaration walk carries down the tree. */
private typedef UnitScan = {
	final valueKinds: Array<String>;
	final metaKinds: Array<String>;
	final lineIndex: LineIndex;
	final out: Array<OwnerUnit>;
}

/** One version of a file as the writer emits it, each line assigned to the declaration that owns it. */
private typedef FileVersion = {
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

/** An identifier run or a single non-blank character, at its offset in the text it was read from. */
private typedef BodyToken = {
	final text: String;
	final at: Int;
}

/**
 * Which declarations of a file changed between two versions of it, matched by NAME — a declaration inserted in the
 * middle shifts no other one, which a positional tree walk (`Diff`) reports as every following sibling differing.
 *
 * Both versions are compared as the writer emits them, so a change of layout alone changes no declaration. A
 * declaration is a named node with at most one named ancestor (a module-level one and its members, the two levels
 * `source`'s selector menu offers), except below a module-level VALUE declaration, whose named descendants are its
 * locals. Every line of the file belongs to one: the innermost declaration spanning it, else the next declaration
 * below it in the same parent when nothing but blank, comment or annotation lines lie between. Lines are compared
 * as the writer emits them, never trimmed or filtered, so two versions whose writer output differs are never
 * `Layout`. Grammar-agnostic but for the module header, whose kinds are `ModuleScan`'s.
 */
@:nullSafety(Strict)
final class DeclarationDelta {

	/** The pseudo-declaration owning the lines no declaration owns. */
	public static inline final MODULE_REST: String = '(module)';

	/** How many named ancestors a declaration may have. */
	private static inline final NAMED_DEPTH: Int = 1;

	/** The edit distance past which a line count falls back to the multiset of lines. */
	private static inline final MAX_LINE_EDITS: Int = 2000;

	/**
	 * The change from `base` to `now`, both read with `plugin`. A version that does not parse makes the whole answer
	 * `Text`, a line count of the raw sources. `optsJson` is the writer configuration both versions are emitted under.
	 */
	public static function compare(plugin: GrammarPlugin, base: String, now: String, ?optsJson: String): FileDelta {
		if (base == now) return textDelta(Unchanged, [], []);
		final canonBase: Null<String> = canonical(plugin, base, optsJson);
		final canonNow: Null<String> = canonical(plugin, now, optsJson);
		if (canonBase == null || canonNow == null) return textDelta(Text, lines(base), lines(now));
		if (canonBase == canonNow) return textDelta(Layout, [], []);
		final before: Null<FileVersion> = versionOf(plugin, canonBase);
		final after: Null<FileVersion> = versionOf(plugin, canonNow);
		if (before == null || after == null) return textDelta(Text, lines(base), lines(now));
		final counts: LineCounts = lineCounts(before.lines, after.lines);
		final headerBefore: Array<String> = headerLines(before);
		final headerAfter: Array<String> = headerLines(after);
		final headerAdded: Array<String> = [for (line in multisetMinus(headerAfter, headerBefore)) line.trim()];
		final headerRemoved: Array<String> = [for (line in multisetMinus(headerBefore, headerAfter)) line.trim()];
		final headerMoved: Bool = !sameLines(headerBefore, headerAfter);
		inline function delta(change: ChangeClass, renames: Array<Renaming>, declarations: Array<DeclarationChange>): FileDelta {
			return {
				change: change,
				headerAdded: headerAdded,
				headerRemoved: headerRemoved,
				headerReordered: headerMoved && headerAdded.length + headerRemoved.length == 0,
				renames: renames,
				declarations: declarations,
				added: counts.added,
				removed: counts.removed
			};
		}
		final bodyBefore: Array<BodyToken> = bodyTokens(before);
		final bodyAfter: Array<BodyToken> = bodyTokens(after);
		// the writer's outputs differ, so an unchanged body and header still leave a change of placement to name
		if (headerMoved && sameLines(bodyLines(before), bodyLines(after))) return delta(Imports, [], []);
		final renames: Null<Array<Renaming>> = renamingsOf(bodyBefore, bodyAfter);
		if (renames == null || renames.length == 0) return delta(Declarations, [], declarationChanges(plugin, before, after));
		for (renaming in renames) if (
			!boundEverywhere(plugin, before, bodyBefore, renaming.from) || !boundEverywhere(plugin, after, bodyAfter, renaming.to)
		)
			return delta(Declarations, [], declarationChanges(plugin, before, after));
		return delta(Renamed, renames, []);
	}

	/** The change from `base` to `now` as lines alone, for a file no grammar reads. */
	public static function compareText(base: String, now: String): FileDelta {
		return textDelta(base == now ? Unchanged : Text, lines(base), lines(now));
	}

	/**
	 * The simple names of `delta`'s declarations — what a reader asks `mentions` about; with `topOnly`, of the
	 * module-level ones alone, for a file added or deleted whole, whose members nothing outside it can have reached.
	 */
	public static function namesOf(delta: FileDelta, topOnly: Bool = false): Array<String> {
		final out: Array<String> = [];
		for (change in delta.declarations) if (change.key != MODULE_REST && !(topOnly && change.depth > 0) && !out.contains(change.name))
			out.push(change.name);
		return out;
	}

	/**
	 * The identifier substitution turning `before` into `after`, or null when they differ by anything else: equal
	 * token runs where every differing token is an identifier, each old spelling always becomes the same new one and no
	 * two old spellings become one. An identifier kept at one place and renamed at another is no rename.
	 */
	public static function renamings(before: String, after: String): Null<Array<Renaming>> {
		return renamingsOf(tokens(before, 0, []), tokens(after, 0, []));
	}

	private static function renamingsOf(a: Array<BodyToken>, b: Array<BodyToken>): Null<Array<Renaming>> {
		if (a.length != b.length) return null;
		final forward: Map<String, String> = [];
		final backward: Map<String, String> = [];
		final out: Array<Renaming> = [];
		for (i => token in a) {
			final from: String = token.text;
			final to: String = b[i].text;
			if (from == to && !SourceText.isIdentifier(from)) continue;
			if (!SourceText.isIdentifier(from) || !SourceText.isIdentifier(to)) return null;
			final mapped: Null<String> = forward[from];
			final source: Null<String> = backward[to];
			if (mapped != null && mapped != to || source != null && source != from) return null;
			if (mapped == null && from != to) out.push({ from: from, to: to });
			forward[from] = to;
			backward[to] = from;
		}
		return out;
	}

	/**
	 * Whether every place `name` is spelled in `version`'s body is a binding of it to a declaration in the same file —
	 * a reference `Refs` resolves, or the name of a declaration itself. A spelling anywhere else (a member access, a
	 * comment, a string) may name something the rename did not touch, so the substitution is no rename.
	 */
	private static function boundEverywhere(plugin: GrammarPlugin, version: FileVersion, body: Array<BodyToken>, name: String): Bool {
		final bound: Map<Int, Bool> = [];
		for (hit in Refs.find(name, version.tree, plugin.refShape())) if (hit.bindingSpan != null)
			bound[SourceText.identTokenOffset(version.source, hit.span, name)] = true;
		for (unit in version.units) {
			final span: Null<Span> = unit.node.span;
			if (unit.node.name == name && span != null) bound[SourceText.identTokenOffset(version.source, span, name)] = true;
		}
		return body.foreach(token -> !(token.text == name && !bound.exists(token.at)));
	}

	private static function canonical(plugin: GrammarPlugin, source: String, optsJson: Null<String>): Null<String> {
		return try plugin.writeRoundTrip(source, optsJson) ?? source catch (exception: Exception) null;
	}

	private static function versionOf(plugin: GrammarPlugin, source: String): Null<FileVersion> {
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

	private static function declarationChanges(plugin: GrammarPlugin, before: FileVersion, after: FileVersion): Array<DeclarationChange> {
		final out: Array<DeclarationChange> = [];
		final partner: Array<Int> = matchUnits(before, after);
		final matched: Array<Bool> = [for (_ in before.units) false];
		final nowAddress: AddressIndex = Address.describerFor(after.tree, plugin.selectKindEquivalence());
		final baseAddress: AddressIndex = Address.describerFor(before.tree, plugin.selectKindEquivalence());
		for (i => unit in after.units) {
			final known: Int = partner[i];
			if (known >= 0) matched[known] = true;
			final mine: Array<String> = after.owned[i];
			if (unit.header || known >= 0 && sameLines(before.owned[known], mine)) continue;
			final counts: LineCounts = known < 0 ? { added: mine.length, removed: 0 } : lineCounts(before.owned[known], mine);
			out.push(changeOf(known < 0 ? Added : Changed, unit, nowAddress.describe(after.source, unit.node), counts));
		}
		for (i => unit in before.units) if (!unit.header && !matched[i])
			out.push(
				changeOf(Removed, unit, baseAddress.describe(before.source, unit.node), { added: 0, removed: before.owned[i].length })
			);
		// lines no declaration owns, or a difference no declaration's own lines show — where the header sits among them
		if (!sameLines(before.rest, after.rest) || out.length == 0) {
			final rest: LineCounts = out.length == 0 ? lineCounts(before.lines, after.lines) : lineCounts(before.rest, after.rest);
			out.push({
				status: Changed,
				key: MODULE_REST,
				name: MODULE_REST,
				selector: MODULE_REST,
				added: rest.added,
				removed: rest.removed,
				depth: 0,
				spanLines: 0
			});
		}
		return out;
	}

	/**
	 * For each declaration of `after`, the index of its counterpart in `before`, or -1. Counterparts share a name path;
	 * among several of one path — the records of a list, the branches of a conditional — an identical one is taken first
	 * and the rest pair up in order, so one inserted record leaves every other matched to itself.
	 */
	private static function matchUnits(before: FileVersion, after: FileVersion): Array<Int> {
		final partner: Array<Int> = [for (_ in after.units) -1];
		final taken: Array<Bool> = [for (_ in before.units) false];
		final byKey: Map<String, Array<Int>> = [];
		for (i => unit in before.units) {
			final bucket: Null<Array<Int>> = byKey[unit.key];
			if (bucket == null)
				byKey[unit.key] = [i]
			else
				bucket.push(i);
		}
		for (identical in [true, false]) for (i => unit in after.units) if (partner[i] < 0) {
			for (j in byKey[unit.key] ?? []) if (!taken[j] && (!identical || sameLines(before.owned[j], after.owned[i]))) {
				partner[i] = j;
				taken[j] = true;
				break;
			}
		}
		return partner;
	}

	private static function changeOf(status: DeclarationStatus, unit: OwnerUnit, selector: String, counts: LineCounts): DeclarationChange {
		return {
			status: status,
			key: unit.key,
			name: unit.node.name ?? unit.key,
			selector: selector,
			added: counts.added,
			removed: counts.removed,
			depth: unit.depth,
			spanLines: unit.last - unit.first + 1
		};
	}

	/** Identifier runs and single non-blank characters of `text`, each with its offset past `base`. */
	private static function tokens(text: String, base: Int, out: Array<BodyToken>): Array<BodyToken> {
		var i: Int = 0;
		while (i < text.length) {
			final code: Int = text.fastCodeAt(i);
			if (SourceText.isIdentStartChar(code)) {
				final from: Int = i;
				while (i < text.length && SourceText.isIdentChar(text.fastCodeAt(i))) i++;
				out.push({ text: text.substring(from, i), at: base + from });
				continue;
			}
			if (!SourceText.isSpace(code)) out.push({ text: String.fromCharCode(code), at: base + i });
			i++;
		}
		return out;
	}

	private static function carriesWords(line: String): Bool {
		for (i in 0...line.length) if (SourceText.isIdentChar(line.fastCodeAt(i))) return true;
		return false;
	}

	/** The header's lines in order, as the writer emits them. */
	private static function headerLines(version: FileVersion): Array<String> {
		return [
			for (line => holder in version.owner) if (holder >= 0 && version.units[holder].header) version.lines[line]
		];
	}

	/** Every line outside the header, as the writer emits it. */
	private static function bodyLines(version: FileVersion): Array<String> {
		return [
			for (line in 0...version.lines.length) if (inBody(version, line)) version.lines[line]
		];
	}

	/** The tokens of every line outside the header, at their offsets in the version's text — what a rename must explain. */
	private static function bodyTokens(version: FileVersion): Array<BodyToken> {
		final out: Array<BodyToken> = [];
		for (line in 0...version.lines.length) if (inBody(version, line)) tokens(version.lines[line], version.starts[line], out);
		return out;
	}

	/** Whether `line` lies outside the header — every such line counts, a brace alone or a blank as much as code. */
	private static function inBody(version: FileVersion, line: Int): Bool {
		final holder: Int = version.owner[line];
		return holder < 0 || !version.units[holder].header;
	}

	private static function textDelta(change: ChangeClass, before: Array<String>, after: Array<String>): FileDelta {
		final counts: LineCounts = lineCounts(before, after);
		return {
			change: change,
			headerAdded: [],
			headerRemoved: [],
			headerReordered: false,
			renames: [],
			declarations: [],
			added: counts.added,
			removed: counts.removed
		};
	}

	/** Lines inserted and deleted, by the shortest edit script, or by multiset difference past `MAX_LINE_EDITS`. */
	private static function lineCounts(before: Array<String>, after: Array<String>): LineCounts {
		final edits: Null<LineEdits> = LineDiff.edits(before, after, MAX_LINE_EDITS);
		return edits != null
			? { added: edits.inserted.length, removed: edits.deleted.length }
			: { added: multisetMinus(after, before).length, removed: multisetMinus(before, after).length };
	}

	private static function multisetMinus(from: Array<String>, minus: Array<String>): Array<String> {
		final left: Map<String, Int> = [];
		for (line in minus) left[line] = (left[line] ?? 0) + 1;
		final out: Array<String> = [];
		for (line in from) {
			final count: Int = left[line] ?? 0;
			if (count > 0)
				left[line] = count - 1
			else
				out.push(line);
		}
		return out;
	}

	private static function sameLines(a: Array<String>, b: Array<String>): Bool {
		if (a.length != b.length) return false;
		for (i => line in a) if (line != b[i]) return false;
		return true;
	}

	private static function lines(text: String): Array<String> {
		return text.length == 0 ? [] : text.split('\n');
	}

}
