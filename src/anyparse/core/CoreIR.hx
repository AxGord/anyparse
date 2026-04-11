package anyparse.core;

#if macro
import haxe.macro.Expr;

/**
 * Specification of one field on a `Build` node: the target field name
 * and the CoreIR subtree whose match result populates it.
 */
typedef BuildField = {
	name:String,
	ir:CoreIR,
};

/**
 * Binary primitive encoding kinds used by the `Binary` strategy.
 *
 * Fixed-width integer types use the suffix convention `UNlE`/`UNbE` or
 * `INlE`/`INbE` for little/big endian respectively. `Varint`/`Zigzag`
 * are LEB128 variable-length encodings. `BytesFixed`/`BytesVar` consume
 * raw bytes by compile-time or runtime-computed length. `Magic` asserts
 * that the next bytes match a fixed signature.
 */
enum BinKind {
	U8;
	U16LE;
	U16BE;
	U32LE;
	U32BE;
	U64LE;
	U64BE;
	I8;
	I16LE;
	I16BE;
	I32LE;
	I32BE;
	I64LE;
	I64BE;
	F32LE;
	F32BE;
	F64LE;
	F64BE;
	Varint;
	Zigzag;
	BytesFixed(n:Int);
	BytesVar(len:CoreIR);
	Magic(expected:haxe.io.Bytes);
}

/**
 * Internal representation of parser primitives that strategies lower
 * into and codegen consumes. Intentionally minimal: any construct that
 * cannot be expressed here is either wrapped in `Host` as an escape
 * hatch or is a signal that CoreIR needs to grow.
 *
 * Design rules (see `docs/architecture.md` and
 * `docs/cross-family-contract.md`):
 *
 * - **Family-agnostic.** No primitive may bake in curly-brace, Lisp or
 *   ML assumptions. A method call is `Seq([fieldAccess, Lit("("),
 *   args, Lit(")")])`, not a dedicated `MethodCall` node.
 * - **No statement/expression distinction.** That is a family concern,
 *   not a core one.
 * - **Reversible.** Every primitive must have a sensible writer-side
 *   counterpart; if emitting `X` is nonsensical, `X` is the wrong
 *   primitive.
 * - **Host is a smell.** Overuse means a primitive is missing. Only
 *   Pratt loops and indent push/pop are expected to need it in the
 *   base library.
 */
enum CoreIR {
	/** Matches nothing; the codegen emits a no-op. */
	Empty;

	/** Sequence of sub-patterns matched left-to-right, all required. */
	Seq(items:Array<CoreIR>);

	/** Ordered choice: try alternatives left-to-right, first success wins. */
	Alt(items:Array<CoreIR>);

	/** Zero-or-more of `item`, optionally separated by `sep`. */
	Star(item:CoreIR, ?sep:CoreIR);

	/** Optional `item`. Succeeds without consuming if not present. */
	Opt(item:CoreIR);

	/** Reference to another generated rule by name. */
	Ref(ruleName:String);

	/** Literal text match; writer emits `s` verbatim. */
	Lit(s:String);

	/** Regex pattern match on the current input position. */
	Re(pattern:String);

	/** Positive lookahead: succeeds without consuming if `item` would match. */
	And(item:CoreIR);

	/** Negative lookahead: succeeds without consuming if `item` would fail. */
	Not(item:CoreIR);

	/** Store the text matched by `inner` in a named capture slot. */
	Capture(label:String, inner:CoreIR);

	/** Require the current position to match previously captured `label`. */
	Backref(label:String);

	/** Bind the value matched by `inner` to a name usable by `ExprRef`. */
	Bind(name:String, inner:CoreIR);

	/** Macro expression evaluated at codegen time, producing a value. */
	ExprRef(e:Expr);

	/** Build a typed value from matched fields using the named constructor. */
	Build(typePath:String, ctor:String, fields:Array<BuildField>);

	/** Match and decode one binary primitive. */
	Bin(kind:BinKind);

	/** Length-prefixed repetition: `len` yields the count, `item` is repeated. */
	Count(len:CoreIR, item:CoreIR);

	/** Tagged union dispatch: `discr` picks a case by integer value. */
	Switch(discr:CoreIR, cases:Map<Int, CoreIR>);

	/** Transform bytes matched by `inner` into a typed value via named decoder. */
	Decode(name:String, inner:CoreIR);

	/** Escape hatch: opaque host code that wraps `inner`. Use sparingly. */
	Host(code:Expr, inner:CoreIR);
}
#end
