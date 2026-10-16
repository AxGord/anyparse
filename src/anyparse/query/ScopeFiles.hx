package anyparse.query;

import anyparse.query.MoveSymbol.MoveChange;
import anyparse.runtime.Span;
import haxe.ds.Either;

/** One scope file parsed once: its path, source and parse tree. */
typedef ParsedFile = {
	final file: String;
	final source: String;
	final tree: QueryNode;
};

/**
 * The scope parsed for a cross-file op: the files that parsed, plus a non-null `error` when any
 * did not (the op is then refused).
 */
typedef ScopeParse = {
	final parsed: Array<ParsedFile>;
	final error: Null<String>;
};

/**
 * The cross-file half the scope-wide ops share — `rename --scope` (type and member), `move`,
 * `move-member`, `pull-up` / `push-down`: parse the scope once, prove a type is declared exactly
 * once in it, collect edits per file, and apply them all-or-none. Each op keeps what it rewrites;
 * the bookkeeping around it was written once per op.
 */
@:nullSafety(Strict)
final class ScopeFiles {

	/**
	 * Parse every scope file once. A file that does not parse cannot be proven free of what the op
	 * rewrites, so every such file is named in `error` and `op` refuses (atomicity) — `op` is the
	 * verb the diagnostic reads (`cannot <op> across scope: …`).
	 */
	public static function parseScope(scopeFiles: Array<{ file: String, source: String }>, plugin: GrammarPlugin, op: String): ScopeParse {
		final parsed: Array<ParsedFile> = [];
		final skipped: Array<String> = [];
		for (entry in scopeFiles) switch ParseGate.parse(plugin, entry.source, entry.file) {
			case Parsed(tree):
				parsed.push({ file: entry.file, source: entry.source, tree: tree });
			case Unparsed(_):
				skipped.push(entry.file);
		}
		return { parsed: parsed, error: unparsedRefusal(op, skipped) };
	}

	/**
	 * The refusal of `op` over a scope in which the `skipped` files do not parse — every one of
	 * them named, which is what makes it actionable — or null when none was skipped.
	 */
	public static function unparsedRefusal(op: String, skipped: Array<String>): Null<String> {
		return skipped.length > 0 ? 'cannot $op across scope: ${skipped.length} file(s) do not parse: ${skipped.join(', ')}' : null;
	}

	/**
	 * Prove exactly one declaration of `typeName` exists under scope and that it is the one in
	 * `cursorFile` — a second same-named type would make every simple-name match ambiguous.
	 * Returns the refusal (none declared, declared more than once, or not the cursor's) or null.
	 */
	public static function uniquenessRefusal(parsed: Array<ParsedFile>, cursorFile: String, typeName: String): Null<String> {
		var declCount: Int = 0;
		var declInCursorFile: Bool = false;
		for (entry in parsed) {
			final n: Int = RefactorSupport.typeDeclsNamed(entry.tree, typeName).length;
			declCount += n;
			if (n > 0 && entry.file == cursorFile) declInCursorFile = true;
		}
		return if (declCount == 0)
			'no type "$typeName" declared under scope'
		else if (declCount > 1)
			'type "$typeName" is declared in $declCount files under scope — ambiguous, refusing'
		else if (!declInCursorFile)
			'the type "$typeName" at the cursor is not the one declared under scope — refusing'
		else
			null;
	}

	/** The edit list of `file` in `editsByFile`, created on first use. */
	public static function editsFor(
		editsByFile: Map<String, Array<{ span: Span, text: String }>>, file: String
	): Array<{ span: Span, text: String }> {
		final existing: Null<Array<{ span: Span, text: String }>> = editsByFile[file];
		if (existing != null) return existing;
		final created: Array<{ span: Span, text: String }> = [];
		editsByFile[file] = created;
		return created;
	}

	/**
	 * Apply each file's edits to its source in `sourceOf` and re-parse every result — all or none: a
	 * single rewrite that does not parse refuses the whole op (`Left`). `Right` carries the files
	 * whose content actually changed; an edit list on a file outside `sourceOf` is skipped.
	 */
	public static function applyAll(
		editsByFile: Map<String, Array<{ span: Span, text: String }>>, sourceOf: Map<String, String>, plugin: GrammarPlugin
	): Either<String, Array<MoveChange>> {
		final changes: Array<MoveChange> = [];
		for (file => edits in editsByFile) {
			final original: Null<String> = sourceOf[file];
			if (original == null) continue;
			final newSource: String = CanonicalEdit.applyEdits(original, edits);
			if (newSource == original) continue;
			final refusal: Null<String> = ParseGate.refusal(plugin, newSource, 'rewritten $file');
			if (refusal != null) return Left(refusal);
			changes.push({ file: file, newSource: newSource });
		}
		return Right(changes);
	}

}
