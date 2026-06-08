package anyparse.query;

import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Outcome of a `CrossRename.crossRenameType` call. `Ok` carries the
 * per-file rewrites (only files that actually changed) plus a non-null
 * advisory — the static-receiver / cross-package caveat the caller
 * surfaces to the user. `Err` carries a human-readable diagnostic
 * (cursor not on a type declaration, an ambiguous / missing type, a
 * scope file that does not parse, a post-rewrite re-parse failure, or a
 * no-op). Modelled as a sum type so the CLI maps it to stdout vs.
 * stderr + a non-zero exit without a sentinel-string convention.
 * Mirrors `RenameResult` / `ChangeSigResult`.
 */
enum CrossRenameResult {
	Ok(changes:Array<FileChange>, advisory:Null<String>);
	Err(message:String);
}

/**
 * One file's rewrite. `count` is the number of occurrence spans
 * replaced in `file`. Only files whose `count > 0` are emitted — an
 * unchanged scope file is never returned.
 */
typedef FileChange = {
	var file:String;
	var newSource:String;
	var count:Int;
}

/**
 * Scope-correct, format-preserving cross-file TYPE rename — hardens the
 * single-file ceiling of the refactoring quartet (`Rename` / `Inline` /
 * `ExtractVar` / `ChangeSig`). The sibling `Rename` renames ONE binding
 * within ONE file; this operation renames ONE type declaration across
 * EVERY `.hx` file in a scope directory.
 *
 * ## Why type-only — the correctness model
 *
 * Cross-file value / method rename needs a type system: the receiver
 * type of an `obj.foo()` call is not resolvable syntactically, so a
 * by-name transform would rename unrelated members. TYPE references, by
 * contrast, live in the TYPE NAMESPACE — a type-position occurrence of
 * `T` can ONLY be the type `T`, never a value / enum-constructor named
 * `T`. Covering the type-namespace forms therefore yields ZERO false
 * positives. The forms collected:
 *
 *  - Type positions + `new T` + cast + `extends` / `implements` + type
 *    parameters — every node `Uses.find` emits on the
 *    `parseFileTypeRefs` tree.
 *  - The type DECLARATION's own name — spliced in the declaring file.
 *  - `import ….T;` / `using ….T;` — the LAST dotted segment `T`,
 *    located precisely (the earlier segments are lower-case packages,
 *    but the splice anchors on the segment after the final `.` so a
 *    package segment that happens to match the type name is never hit).
 *
 * ## Documented residual (loud-fail, not silent)
 *
 * A type-namespace occurrence this operation does NOT rewrite leaves a
 * dangling `T` that fails to COMPILE — it is never a silent semantic
 * change. Excluded in v1:
 *
 *  - Static-receiver access `T.staticMethod()` — a bare value-position
 *    `IdentExpr T`. Including it would risk a same-named
 *    enum-constructor / value false positive, so it is out of scope.
 *  - Aliased imports `import pkg.T as U;` — the node's name slot is the
 *    alias `U`, not `T`, so the `pkg.T` segment is not matched. The
 *    alias `U` (used in type positions) IS covered, but the import's
 *    own `T` segment is left, which dangles if `T` moved package.
 *  - Cross-package: a type declared under a DIFFERENT scope than the
 *    one being renamed (the uniqueness proof is over the given scope
 *    only).
 *
 * The advisory (always non-null on success) reminds the user to check
 * these. Combined with atomicity — every rewritten file is re-parsed
 * before ANY is returned, and the caller writes nothing unless all
 * parse — a missed form surfaces as a compile error the user can see,
 * never as a corrupted file.
 *
 * Coordinate convention: `line` / `col` are interpreted exactly as
 * `apq refs` PRINTS them (`Span.lineCol().col - 1`), inverted via
 * `Span.offsetOf(source, line, col + 1)` — identical to `Rename`.
 */
@:nullSafety(Strict)
final class CrossRename {

	/**
	 * Type-declaration kinds the cursor may land on and that the scope
	 * walk counts / collects. Mirrors the five top-level Haxe decls; a
	 * type-position occurrence can only ever resolve to one of these.
	 */
	private static final TYPE_DECL_KINDS:Array<String> = [
		'ClassDecl', 'InterfaceDecl', 'EnumDecl', 'TypedefDecl', 'AbstractDecl',
	];

	/** The advisory appended to every successful rename. */
	private static final ADVISORY:String =
		'type-namespace rename only — verify static-receiver accesses '
		+ '(`T.staticMethod()`), aliased imports (`import pkg.T as U;`), '
		+ 'and any cross-package declarations by hand.';

	/**
	 * Rename the type declaration at `line:col` (in `cursorFile` /
	 * `cursorSource`) to `newName` across every file in `scopeFiles`.
	 * `plugin` / `typeRefShape` are the caller-owned grammar plugin and
	 * its `TypeRefShape` (the same pair the `uses` CLI builds), so the
	 * walk stays language-agnostic.
	 *
	 * The function is PURE: it never reads or writes the filesystem — the
	 * CLI reads the scope files and passes them in, and decides whether
	 * to write the returned rewrites. `scopeFiles` SHOULD include
	 * `cursorFile` (the CLI adds it when the file is not already under
	 * the scope directory).
	 *
	 * Returns `Ok(changes, advisory)` with only the files that changed,
	 * or an `Err` describing why the rename could not be applied.
	 */
	public static function crossRenameType(cursorFile:String, cursorSource:String, line:Int, col:Int, newName:String,
			scopeFiles:Array<{file:String, source:String}>, plugin:GrammarPlugin, typeRefShape:TypeRefShape):CrossRenameResult {
		if (!RefactorSupport.isIdentifier(newName)) return Err('new name "$newName" is not a valid identifier');

		// 1. Resolve the type declaration the cursor sits on.
		final cursorTree:QueryNode = try plugin.parseFile(cursorSource)
			catch (exception:ParseError) return Err('$cursorFile does not parse: ${exception.toString()}')
			catch (exception:Exception) return Err('$cursorFile does not parse: ${exception.message}');

		// `apq refs` prints `Span.lineCol().col - 1`; invert that here so a
		// position copied from `refs` / `uses` output maps to the offset.
		final cursor:Int = Span.offsetOf(cursorSource, line, col + 1);
		final declNode:Null<QueryNode> = resolveTypeDeclAtCursor(cursorTree, cursor, cursorSource);
		if (declNode == null)
			return Err('position $line:$col is not on a type declaration (cross-file --scope renames types only)');
		final typeName:Null<String> = declNode.name;
		if (typeName == null)
			return Err('position $line:$col is not on a type declaration (cross-file --scope renames types only)');
		if (typeName == newName)
			return Err('rename "$typeName" -> "$newName" is a no-op');

		// 2. Parse every scope file once; refuse on any skip-parse (a file
		//    we cannot read cannot be proven free of references to the type).
		final parsed:Array<{file:String, source:String, tree:QueryNode}> = [];
		final skipped:Array<String> = [];
		for (entry in scopeFiles) {
			final tree:Null<QueryNode> = try plugin.parseFile(entry.source)
				catch (exception:ParseError) null
				catch (exception:Exception) null;
			if (tree == null) skipped.push(entry.file);
			else parsed.push({file: entry.file, source: entry.source, tree: tree});
		}
		if (skipped.length > 0)
			return Err('cannot rename across scope: ${skipped.length} file(s) do not parse: ${skipped.join(", ")}');

		// 3. Uniqueness: exactly one declaration of `typeName` under scope.
		var declCount:Int = 0;
		var declInCursorFile:Bool = false;
		for (entry in parsed) {
			final n:Int = countTypeDecls(entry.tree, typeName);
			declCount += n;
			if (n > 0 && entry.file == cursorFile) declInCursorFile = true;
		}
		if (declCount == 0)
			return Err('no type "$typeName" declared under scope');
		if (declCount > 1)
			return Err('type "$typeName" is declared in $declCount files under scope — ambiguous, refusing');
		if (!declInCursorFile)
			return Err('the type "$typeName" at the cursor is not the one declared under scope — refusing');

		// 4. Collect occurrence spans + apply edits per file.
		final changes:Array<FileChange> = [];
		for (entry in parsed) {
			final occurrences:Array<Span> = collectOccurrences(entry.source, typeName, entry.tree, plugin, typeRefShape);
			if (occurrences.length == 0) continue;
			final edits:Array<{span:Span, text:String}> = [for (occ in occurrences) {span: occ, text: newName}];
			final newSource:String = RefactorSupport.applyEdits(entry.source, edits);

			// 6. Atomic validation: every rewritten file must re-parse.
			try plugin.parseFile(newSource)
				catch (exception:ParseError) return Err('rewritten ${entry.file} does not parse: ${exception.toString()}')
				catch (exception:Exception) return Err('rewritten ${entry.file} does not parse: ${exception.message}');

			changes.push({file: entry.file, newSource: newSource, count: occurrences.length});
		}

		if (changes.length == 0)
			return Err('rename "$typeName" -> "$newName" changed nothing');

		return Ok(changes, ADVISORY);
	}

	/**
	 * Resolve the cursor to the type declaration it sits on: the
	 * innermost node whose span contains `cursor`, whose kind is a
	 * type-decl kind, and whose own name identifier-token contains the
	 * cursor OR whose `span.from == cursor` (the `apq refs --decls`
	 * convention, where the printed column maps to the decl's span start
	 * — the `class` / `enum` keyword). Returns null when the cursor is
	 * not on a type declaration.
	 */
	private static function resolveTypeDeclAtCursor(tree:QueryNode, cursor:Int, source:String):Null<QueryNode> {
		var best:Null<QueryNode> = null;
		function walk(node:QueryNode):Void {
			final span:Null<Span> = node.span;
			if (span != null && cursor >= span.from && cursor < span.to && TYPE_DECL_KINDS.contains(node.kind)) {
				final name:Null<String> = node.name;
				if (name != null) {
					final onName:Bool = RefactorSupport.identTokenContains(node, cursor, source);
					if (onName || span.from == cursor) best = node;
				}
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return best;
	}

	/**
	 * Count the type-declaration nodes named `typeName` in `tree` (a
	 * `parseFile` tree). Drives the cross-scope uniqueness proof.
	 */
	private static function countTypeDecls(tree:QueryNode, typeName:String):Int {
		var count:Int = 0;
		function walk(node:QueryNode):Void {
			if (node.name == typeName && TYPE_DECL_KINDS.contains(node.kind)) count++;
			for (c in node.children) walk(c);
		}
		walk(tree);
		return count;
	}

	/**
	 * Gather every occurrence-token span of `typeName` in one file:
	 *
	 *  a. Type positions — `Uses.find` on the `parseFileTypeRefs` tree
	 *     (annotations, `extends` / `implements`, type params, cast,
	 *     `new T`).
	 *  b. The declaration name — every type-decl node named `typeName` in
	 *     the `parseFile` tree.
	 *  c. Imports / using — `ImportDecl` / `UsingDecl` whose dotted path's
	 *     LAST segment is `typeName`.
	 *
	 * Each returned span is the identifier token `[from, from+len)`.
	 * Spans are deduped by `from` offset (a node can be matched by more
	 * than one collector).
	 */
	private static function collectOccurrences(source:String, typeName:String, tree:QueryNode, plugin:GrammarPlugin,
			typeRefShape:TypeRefShape):Array<Span> {
		final out:Array<Span> = [];
		final seen:Array<Int> = [];
		inline function add(identFrom:Int):Void
			RefactorSupport.pushUniqueSpan(out, seen, identFrom, typeName.length);

		// a. Type positions.
		final typeRefTree:QueryNode = plugin.parseFileTypeRefs(source);
		for (hit in Uses.find(typeName, typeRefTree, typeRefShape))
			add(RefactorSupport.identTokenOffset(source, hit.span, typeName));

		// b. Declaration names + c. imports / using (one walk of the
		//    parseFile tree — both read node kinds from it).
		function walk(node:QueryNode):Void {
			final span:Null<Span> = node.span;
			if (span != null) {
				if (node.name == typeName && TYPE_DECL_KINDS.contains(node.kind))
					add(RefactorSupport.identTokenOffset(source, span, typeName));
				else if (node.kind == 'ImportDecl' || node.kind == 'UsingDecl')
					add(importSegmentOffset(source, span, node.name, typeName));
			}
			for (c in node.children) walk(c);
		}
		walk(tree);

		return out;
	}

	/**
	 * Offset of the LAST dotted segment of an `import` / `using` path
	 * when that segment equals `typeName`, else -1. `pathName` is the
	 * node's name slot — the verbatim dotted path (`pkg.sub.Foo`). The
	 * segment is located by finding the path text inside the node span
	 * and anchoring on the character after the final `.`, so a leading
	 * package segment that happens to match `typeName` (e.g.
	 * `import Foo.sub.Foo;`) is never mistaken for the type segment.
	 */
	private static function importSegmentOffset(source:String, span:Span, pathName:Null<String>, typeName:String):Int {
		if (pathName == null) return -1;
		final lastDot:Int = pathName.lastIndexOf('.');
		final lastSegment:String = lastDot < 0 ? pathName : pathName.substr(lastDot + 1);
		if (lastSegment != typeName) return -1;
		final pathStart:Int = source.indexOf(pathName, span.from);
		if (pathStart < 0 || pathStart >= span.to) return -1;
		return pathStart + lastDot + 1;
	}
}
