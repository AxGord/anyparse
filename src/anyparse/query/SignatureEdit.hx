package anyparse.query;

import anyparse.query.CallSites.CursorFn;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;
import haxe.ds.Either;

/** The function a signature edit works on: its tree, its declaration, its name and binding offset. */
typedef SignatureTarget = {
	final tree: QueryNode;
	final decl: QueryNode;
	final name: String;
	final binding: Int;
}

/**
 * The core the signature-editing ops share — `change-sig` and `remove-param`, which rewrite a
 * function's parameter list together with every in-file call site, and `add-param`, which rewrites
 * the declaration alone. Each op keeps how it rewrites the slots; resolving the function, the
 * arity proof over its call sites, committing the edits and the cross-file advisory were written
 * once per op.
 */
@:nullSafety(Strict)
final class SignatureEdit {

	/**
	 * The function declaration at `line:col` — on the declaration itself, or on a bare call that
	 * resolves back to it (`CallSites.resolveFnAtCursor`). A cursor on anything that is not a
	 * function is the `Left` diagnostic `"<name>" is not a function (<opDoes>)`.
	 */
	public static function resolve(
		source: String, line: Int, col: Int, plugin: GrammarPlugin, shape: RefShape, opDoes: String
	): Either<String, SignatureTarget> {
		final found: CursorFn = switch CallSites.resolveFnAtCursor(source, line, col, plugin, shape) {
			case FnAtErr(message): return Left(message);
			case FnAt(fn): fn;
		};
		final name: String = found.name;
		if (!MemberKinds.FN_DECL_KINDS.contains(found.decl.kind)) return Left('"$name" is not a function ($opDoes)');
		final declSpan: Null<Span> = found.decl.span;
		return declSpan == null
			? Left('"$name" declaration has no source span')
			: Right({
				tree: found.tree,
				decl: found.decl,
				name: name,
				binding: declSpan.from
			});
	}

	/**
	 * The refusal for the first of `callSites` whose positional argument count is not `n`, or null
	 * when every call passes exactly `n`. A call that omits an optional or defaulted argument
	 * cannot have its slots rewritten unambiguously, so it is a hard refusal rather than a silent
	 * misedit; `cannot` is the op's own phrase for what it then cannot do.
	 */
	public static function arityRefusal(source: String, callSites: Array<QueryNode>, n: Int, cannot: String): Null<String> {
		for (call in callSites) {
			final argc: Int = call.children.length - 1;
			if (argc == n) continue;
			final at: String = CallSites.posOf(source, call.span);
			return 'call at $at has $argc args, expected $n — $cannot calls with omitted optional arguments';
		}
		return null;
	}

	/**
	 * Commit `edits` to `source`: a set that changes nothing is the `Left` `noop`; otherwise the
	 * splice comes back canonical when `source` was (`CanonicalEdit.editKeepingCanonical` under
	 * `optsJson` — a longer or reordered list may break where the writer would not have broken it,
	 * a shorter one may now fit), and the result must re-parse.
	 */
	public static function commit(
		source: String, edits: Array<{ span: Span, text: String }>, plugin: GrammarPlugin, optsJson: Null<String>, noop: String
	): Either<String, String> {
		if (CanonicalEdit.applyEdits(source, edits) == source) return Left(noop);
		final rewritten: String = switch CanonicalEdit.editKeepingCanonical(source, edits, plugin, optsJson) {
			case Err(message): return Left(message);
			case Ok(text, _): text;
		};
		final refusal: Null<String> = ParseGate.refusal(plugin, rewritten, 'rewritten source');
		return refusal != null ? Left(refusal) : Right(rewritten);
	}

	/**
	 * The advisory a METHOD's signature edit carries — `did` (what was rewritten in this file)
	 * followed by the reminder that callers in other files are out of scope — or null for a local
	 * function, which no other file can call.
	 */
	public static function crossFileAdvisory(decl: QueryNode, did: String, name: String): Null<String> {
		return decl.kind != 'LocalFnStmt'
			? '$did; if "$name" is called from other files, update those call sites too — cross-file resolution is out of scope'
			: null;
	}

	/**
	 * The reader of qualified-call receivers in `file` for the declaration at `binding`, or null when the caller named no
	 * file: a call `R.name(...)` is then unproven, so the op refuses it rather than leave it on the old signature.
	 */
	public static function receiversOf(
		file: Null<String>, source: String, plugin: GrammarPlugin, shape: RefShape, binding: Int
	): Null<QualifiedReceiver> {
		return file == null ? null : new QualifiedReceiver(file, source, plugin, shape, binding);
	}

}
