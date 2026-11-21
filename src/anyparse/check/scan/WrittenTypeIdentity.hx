package anyparse.check.scan;

import anyparse.check.scan.OperandBinder.Located;
import anyparse.check.scan.OperandBinder.WrittenHost;
import anyparse.query.DeclaredNullity;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeNameBinding;
import anyparse.query.TypeSyntax;

/**
 * The one answer to "do two written types denote the same type", each read where it is written (`Located`): nominal
 * heads binding the same declarations (a built-in by its name, a name that binds nothing only spelled alike in the file
 * `here` answers for), argument for argument; function types part for part; anonymous structures written out, field for
 * field. A typedef is never read as the structure it names: Haxe 4.3.7's null safety checks a literal typed against a
 * named typedef without the narrowing it applies against the structure written out, so the two spellings do not type
 * alike. Anything else is no proof, so the answer is false.
 */
@:nullSafety(Strict)
final class WrittenTypeIdentity {

	private final _index: SymbolIndex;
	private final _here: (written: String, at: Int) -> Tier;
	private final _paramOwner: (name: String, at: Int) -> Null<Int>;
	private final _wrappers: Array<String>;
	private final _builtins: Array<String>;

	/**
	 * Over `index`; `here` binds a type written at an offset of the file a `Located` with no host is written in, and
	 * `paramOwner` says where a type parameter of a name in scope at an offset of that file is declared (null for none).
	 * `wrappers` / `builtins` are the grammar's nullable wrapper and built-in type names.
	 */
	public function new(
		index: SymbolIndex, here: (written: String, at: Int) -> Tier, paramOwner: (name: String, at: Int) -> Null<Int>,
		wrappers: Array<String>, builtins: Array<String>
	) {
		_index = index;
		_here = here;
		_paramOwner = paramOwner;
		_wrappers = wrappers;
		_builtins = builtins;
	}

	/** Whether `a` and `b` are one type. */
	public function same(a: Located, b: Located): Bool {
		final x: Located = boundOf(a);
		final y: Located = boundOf(b);
		final xs: Null<TypeSyntax> = _index.typeSyntax(x.text);
		final ys: Null<TypeSyntax> = _index.typeSyntax(y.text);
		if (xs == null || ys == null) return false;
		return switch [xs.shape, ys.shape] {
			case [Nominal(p, ps), Nominal(q, qs)]:
				sameHead(p, x, q, y) && sameParts(x, ps, y, qs);
			case [Function(ps, r, _), Function(qs, s, _)]:
				same(partOf(x, r.text), partOf(y, s.text)) && sameParams(x, ps, y, qs);
			case [Structure(fs), Structure(gs)]: sameFields(x, fs, y, gs);
			case _: false;
		};
	}

	/** Whether the parts `ps` of the type `x` and `qs` of `y` are one type each, in order. */
	private function sameParts(x: Located, ps: Array<TypeSyntax>, y: Located, qs: Array<TypeSyntax>): Bool {
		if (ps.length != qs.length) return false;
		for (i => p in ps) if (!same(partOf(x, p.text), partOf(y, qs[i].text))) return false;
		return true;
	}

	/** Whether the parameters `ps` of the function type `x` and `qs` of `y` are one type each, in order, each as optional. */
	private function sameParams(x: Located, ps: Array<TypeParam>, y: Located, qs: Array<TypeParam>): Bool {
		if (ps.length != qs.length) return false;
		for (i => p in ps) if (p.optional != qs[i].optional || !same(partOf(x, p.type.text), partOf(y, qs[i].type.text))) return false;
		return true;
	}

	/** Whether the fields `fs` of the structure `x` and `gs` of `y` are the same fields, each as optional and of one type. */
	private function sameFields(x: Located, fs: Array<TypeField>, y: Located, gs: Array<TypeField>): Bool {
		if (fs.length != gs.length) return false;
		for (f in fs) {
			final g: Null<TypeField> = gs.find(g -> g.name == f.name);
			if (g == null || g.optional != f.optional || !same(partOf(x, f.type.text), partOf(y, g.type.text))) return false;
		}
		return true;
	}

	/**
	 * Whether the heads `p` written as `x` and `q` written as `y` bind the same declarations. Two heads neither binds, in the
	 * file `here` answers for, are one only when spelled alike and the same type parameter or none: a callee's own parameter
	 * the call does not bind is not the caller's of the same name.
	 */
	private function sameHead(p: String, x: Located, q: String, y: Located): Bool {
		return switch [headTierOf(p, x), headTierOf(q, y)] {
			case [Bound(ds), Bound(es)]: TypeNameBinding.sameDecls(ds, es);
			case [Free, Free]: p == q;
			case [Unknown, Unknown]:
				p == q && x.host == null && y.host == null && _paramOwner(p, x.at) == _paramOwner(q, y.at);
			case _: false;
		};
	}

	/** What the head `path` of the type `written` binds to where that type is written. */
	private function headTierOf(path: String, written: Located): Tier {
		final host: Null<WrittenHost> = written.host;
		return host == null
			? _here(path, written.at)
			: DeclaredNullity.headTierIn(path, host.file, written.at, _index, host.params, _wrappers, _builtins);
	}

	/** The part `text` of the type `of`, written where `of` is. */
	private static inline function partOf(of: Located, text: String): Located {
		return {
			text: text,
			at: of.at,
			host: of.host,
			bindings: of.bindings
		};
	}

	/** `written` with a type parameter the call binds read as what binds it. */
	private static function boundOf(written: Located): Located {
		final bound: Null<Located> = written.bindings?.get(written.text.trim());
		return bound == null ? written : boundOf(bound);
	}

}
