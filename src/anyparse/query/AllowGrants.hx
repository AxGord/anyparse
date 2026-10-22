package anyparse.query;

import anyparse.query.Meta.MetaHit;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.Span;

using Lambda;

/**
 * What a Haxe `@:allow` grant actually reaches, read per MEMBER rather than per file.
 *
 * `@:allow(path)` on a MEMBER opens that one member to `path`; on a TYPE it opens every private member
 * of the type. `path` is compared literally against the accessing class's dot path and its parents'
 * (no import resolution): a type path grants that type and every SUBTYPE of it (the compiler walks the
 * accessing class's super chain), a package path grants every type of that package and of its
 * subpackages. Verified on Haxe 4.3.7: `@:allow(B)` reaches `class BSub extends B`, `@:allow(foo)`
 * reaches `foo.bar.Q`, `@:allow(G)` does NOT reach `foo.G`, and a plain `class C` is refused.
 *
 * The file-level question (`RefactorSupport.carriesAllowGrant`) taints every private member of a file
 * that holds one grant anywhere; `reaching` answers which grants reach ONE member, and `granteeFiles`
 * which files those grants open it to. Both answer null when they cannot be sure: a grant in this file
 * the projection does not attribute to a declaration, an argument that is not a plain dot path, a path
 * naming no type the index sees.
 */
@:nullSafety(Strict)
final class AllowGrants {

	/** The annotation this class reads. */
	public static inline final TAG: String = '@:allow';

	/** A grant argument this class can enumerate: a plain dot path. */
	private static final DOT_PATH: EReg = new EReg('^[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)*$', '');

	/**
	 * The grantee paths of every `@:allow` that reaches the member declared at `member` inside the type
	 * named `owner`: the member's own grants and its type's. Empty when none does; null when some
	 * `@:allow` written in code in `source` is not one the projection attributes to a declaration -
	 * then which members it reaches is unknown, and the caller falls back to the file-level answer.
	 */
	public static function reaching(
		tree: QueryNode, source: String, plugin: GrammarPlugin, member: Span, owner: String
	): Null<Array<String>> {
		final written: Array<Int> = RefactorSupport.allowGrantOffsets(source, plugin);
		if (written.length == 0) return [];
		final hits: Array<MetaHit> = Meta.find(tree, plugin.metaShape(), source).filter(h -> h.annotation == TAG);
		return written.foreach(at -> hits.exists(h -> h.metaSpan != null && h.metaSpan.from == at))
			? ([
				for (hit in hits) if (reachesMember(hit, member, owner)) for (path in hit.args) path.trim()
			]: Array<String>)
			: null;
	}

	/**
	 * Every file of `index` a grant path in `paths` opens a member to: the files declaring a type whose dot
	 * path the grant names, lies under (a package grant), or extends (a `pkg.Type.field` grant), plus the
	 * files declaring a transitive subtype of one. Name-keyed, so the set OVER-approximates - the safe side
	 * for a caller that edits or scans the files it gets back. `unmatched` names the first path the index
	 * cannot enumerate (not a dot path, or naming no type it sees), and `files` is then empty.
	 */
	public static function granteeFiles(paths: Array<String>, index: SymbolIndex): Grantees {
		final files: Array<String> = [];
		for (path in paths) {
			if (!DOT_PATH.match(path)) return { files: [], unmatched: path };
			var matched: Bool = false;
			for (fi in index.allFiles()) for (t in fi.types) if (names(path, typePath(fi, t))) {
				matched = true;
				if (!files.contains(fi.file)) files.push(fi.file);
				for (sub in index.subtypes.subtypeDecls(t.name, fi.file)) if (!files.contains(sub.file.file)) files.push(sub.file.file);
			}
			if (!matched) return { files: [], unmatched: path };
		}
		return { files: files, unmatched: null };
	}

	/** Whether a grant `path` reaches the type whose dot path is `type`: equal, a package above it, or the type with a field below. */
	private static inline function names(path: String, type: String): Bool {
		return type == path || type.startsWith('$path.') || path.startsWith('$type.');
	}

	/**
	 * The dot path the compiler compares a grant against: the type's package and its own name - a module's
	 * sub-type sits directly in the package.
	 */
	private static inline function typePath(fi: FileInfo, t: TypeDeclInfo): String {
		return fi.pkg == '' ? t.name : '${fi.pkg}.${t.name}';
	}

	/** Whether `hit` sits on the member at `member` or on the type named `owner` that encloses it. */
	private static function reachesMember(hit: MetaHit, member: Span, owner: String): Bool {
		final decl: Null<Span> = hit.declSpan;
		return decl != null && (decl.from == member.from || hit.declName == owner && decl.from <= member.from && member.to <= decl.to);
	}

}

/** What `AllowGrants.granteeFiles` enumerated: the files a grant opens a member to, or the first path it could not enumerate. */
typedef Grantees = {
	final files: Array<String>;
	final unmatched: Null<String>;
};
