package anyparse.grammar.haxe;

/**
 * Message argument of a `#error "msg"` / `#error 'msg'` preprocessor
 * directive — a single- or double-quoted span captured verbatim.
 *
 * Haxe's `#error` directive aborts compilation with a diagnostic; in
 * the wild (and in every haxe-formatter corpus fixture) the message is
 * a quoted string. Two shapes are recognised:
 *
 *  - Double-quoted: `"please implement"`, `"js is defined"`.
 *  - Single-quoted: `'should be indented if using policy = "aligned"'`
 *    (note the single-quoted form may itself contain `"`).
 *
 * The regex is quote-delimited rather than rest-of-line on purpose: the
 * single-line conditional form `#if js #error "x" #elseif php #else #end`
 * places `#elseif` on the SAME line right after the message, so a
 * rest-of-line capture would greedily swallow the trailing directives.
 * No corpus `#error` message contains an escaped inner quote, so the
 * simple `"[^"]*"` / `'[^']*'` classes suffice — deepen to a
 * backslash-aware class only if a real grammar site demands it.
 *
 * Like `HxPpCondLit`, this is captured as the matched substring
 * (quotes included) and routed through `Lowering.lowerTerminal` with
 * `@:rawString` so the slice round-trips byte-for-byte without the
 * Haxe string-unescape loop — a preprocessor diagnostic is not a Haxe
 * string literal, so `\n` etc. stay as literal backslash-n.
 */
@:re("\"[^\"]*\"|'[^']*'")
@:rawString
abstract HxErrorMsg(String) from String to String {}
